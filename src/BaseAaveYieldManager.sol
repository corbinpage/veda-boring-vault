// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title BaseAaveYieldManager
 * @notice Manages USDC → Aave supply from the BoringVault and distributes accrued yield
 *         to configured stakeholders. Holds MANAGER_ROLE so it can call vault.manage().
 *
 * ─── Architecture ─────────────────────────────────────────────────────────────
 *
 * Token custody:
 *   The BoringVault holds all assets (USDC and aUSDC). This contract holds no assets.
 *   To interact with Aave on the vault's behalf, this contract calls vault.manage(),
 *   for which it must hold MANAGER_ROLE in the RolesAuthority. The deploy script
 *   grants this role to address(yieldManager).
 *
 * Aave supply path (in distributeAndRebalance):
 *   vault.manage(usdc.approve(aavePool, idleUsdc))
 *   vault.manage(aavePool.supply(usdc, idleUsdc, vault, 0))
 *   → aUSDC minted to the vault; USDC leaves the vault.
 *
 * Yield extraction path:
 *   vault.manage(aUSDC.approve(aavePool, yield))
 *   vault.manage(aavePool.withdraw(usdc, yield, address(this)))
 *   → USDC arrives in this contract; aUSDC burned from vault.
 *   This contract then pushes USDC to each stakeholder.
 *
 * Principal tracking:
 *   principalDeposited is set by the admin after observing on-chain deposits, or via
 *   syncPrincipal() which reads the vault's total supply and the 1:1 PrincipalAccountant
 *   exchange rate. This avoids modifying the third-party Teller contract. Admin can
 *   also call recordDeposit/recordWithdrawal to manually maintain accuracy.
 *   syncPrincipal() sets principal = vault.totalSupply() / 1e12 (shares→USDC, 18→6 dec).
 *
 * AtomicQueue fulfillment:
 *   Withdrawal requests are fulfilled by the solver bot calling AtomicQueue.solve()
 *   directly. This contract does NOT interact with AtomicQueue.
 *
 * Security notes:
 *  - [C-01] Explicit principalDeposited tracking; syncPrincipal() as fallback
 *  - [H-01] ReentrancyGuard on distributeAndRebalance
 *  - [H-02] Stakeholder changes timelocked by STAKEHOLDER_TIMELOCK (48h)
 *  - [H-03] MAX_YIELD_BPS safety cap per distributeAndRebalance call (20%)
 *  - [M-01] Basis-point (10_000) based distribution with dust-free last-recipient math
 *  - [M-03] Pausable
 *  - [L-01] Full event emission
 */

// ─── Interfaces ───────────────────────────────────────────────────────────────

interface IBoringVault {
    function totalSupply() external view returns (uint256);
    function manage(address target, bytes calldata data, uint256 value) external returns (bytes memory);
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

// ─────────────────────────────────────────────────────────────────────────────

contract BaseAaveYieldManager is ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ─────────────────────────────── Constants ────────────────────────────────

    uint256 public constant QUEUE_DELAY          = 3600;            // 1-hour minimum withdrawal delay
    uint256 public constant MAX_QUEUE_DELAY      = 48 hours;        // solver fulfillment deadline
    uint256 public constant BASIS_POINTS         = 10_000;          // [M-01] denominator
    uint256 public constant MAX_YIELD_BPS        = 2_000;           // 20% max yield per call
    uint256 public constant MAX_TVL              = 10_000_000 * 1e6; // $10M USDC cap
    uint256 public constant STAKEHOLDER_TIMELOCK = 48 hours;        // [H-02]

    /// @notice Aave V3 Pool on Base Mainnet (hardcoded — immutable protocol)
    address public constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4674A963d919642167C;

    // Decimal conversion: vault shares are 18 dec, USDC is 6 dec
    uint256 private constant SHARE_TO_USDC_SCALAR = 1e12;

    // ──────────────────────────────── Immutables ──────────────────────────────

    /// @notice Base USDC (6 decimals)
    IERC20 public immutable usdc;

    /// @notice Aave aUSDC on Base (6 decimals, rebases to track interest)
    IERC20 public immutable aUsdc;

    /// @notice BoringVault — holds all assets; this contract calls vault.manage() with MANAGER_ROLE
    IBoringVault public immutable vault;

    // ──────────────────────────────── Storage ─────────────────────────────────

    address public admin;
    mapping(address => bool) public distributors;

    /// @notice [C-01] Tracked USDC principal. Updated by admin or via syncPrincipal().
    uint256 public principalDeposited;

    /// @notice Ordered list of yield recipients
    address[] public stakeholders;

    /// @notice Basis-point yield share per stakeholder (sum must equal BASIS_POINTS)
    mapping(address => uint256) public distributionBps;

    /// @notice [H-02] Pending stakeholder update (subject to timelock)
    struct PendingStakeholderUpdate {
        address[] newStakeholders;
        uint256[] newBps;
        uint256 executableAt;
    }
    PendingStakeholderUpdate public pendingUpdate;

    /// @notice Block timestamp of the last successful distributeAndRebalance()
    uint256 public lastDistributedAt;

    // ──────────────────────────────── Events ──────────────────────────────────

    event YieldDistributed(uint256 totalYield, address[] recipients, uint256[] amounts);
    event VaultSuppliedToAave(uint256 amount);
    event VaultWithdrewFromAave(uint256 amount);
    event PrincipalSynced(uint256 oldPrincipal, uint256 newPrincipal);
    event PrincipalAdjusted(uint256 oldPrincipal, uint256 newPrincipal, bool increased);
    event StakeholderUpdateQueued(uint256 executableAt);
    event StakeholderUpdateExecuted();
    event DistributorSet(address indexed distributor, bool enabled);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    // ──────────────────────────────── Errors ──────────────────────────────────

    error NotAdmin();
    error NotDistributor();
    error TVLCapExceeded();
    error BpsMismatch();
    error BpsSumMismatch();
    error TimelockNotExpired();
    error NoPendingUpdate();
    error YieldExceedsSafeLimit();
    error ZeroAddress();
    error InsufficientAaveBalance();
    error NoStakeholders();
    error ZeroYield();

    // ─────────────────────────────── Modifiers ────────────────────────────────

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier onlyDistributor() {
        if (!distributors[msg.sender]) revert NotDistributor();
        _;
    }

    // ────────────────────────────── Constructor ───────────────────────────────

    /**
     * @param _usdc  Base USDC address
     * @param _aUsdc Aave aUSDC address on Base
     * @param _vault BoringVault address (holds all assets; this contract needs MANAGER_ROLE)
     * @param _admin Initial admin address (should be a Gnosis Safe multisig in production)
     */
    constructor(
        address _usdc,
        address _aUsdc,
        address _vault,
        address _admin
    ) {
        if (_usdc == address(0) || _aUsdc == address(0) || _vault == address(0) || _admin == address(0))
            revert ZeroAddress();

        usdc  = IERC20(_usdc);
        aUsdc = IERC20(_aUsdc);
        vault = IBoringVault(_vault);
        admin = _admin;
    }

    // ──────────────────────────────── Core Logic ──────────────────────────────

    /**
     * @notice Main rebalance + yield distribution function. Callable by any address
     *         holding the DISTRIBUTOR_ROLE (set via setDistributor).
     *
     *   Step 1  Supply idle USDC in the vault to Aave (vault → aUSDC)
     *   Step 2  Compute accrued yield = aUSDC(vault) − principalDeposited
     *   Step 3  Withdraw yield USDC from Aave into this contract
     *   Step 4  Push USDC to each stakeholder proportionally
     *
     * @dev This contract must hold MANAGER_ROLE in RolesAuthority for vault.manage() to succeed.
     *      Granted by the deploy script _wireContracts().
     *      [H-01] nonReentrant  [M-03] whenNotPaused
     */
    function distributeAndRebalance() external nonReentrant onlyDistributor whenNotPaused {
        if (stakeholders.length == 0) revert NoStakeholders();

        // ── Step 1: Supply idle USDC (vault holds it) to Aave ────────────────
        uint256 idleUsdc = usdc.balanceOf(address(vault));
        if (idleUsdc > 0) {
            uint256 currentAUM = aUsdc.balanceOf(address(vault));
            if (currentAUM + idleUsdc > MAX_TVL) revert TVLCapExceeded();

            // Vault approves Aave to spend its USDC, then calls supply
            vault.manage(
                address(usdc),
                abi.encodeCall(IERC20.approve, (AAVE_POOL, idleUsdc)),
                0
            );
            vault.manage(
                AAVE_POOL,
                abi.encodeCall(IAavePool.supply, (address(usdc), idleUsdc, address(vault), 0)),
                0
            );
            emit VaultSuppliedToAave(idleUsdc);
        }

        // ── Step 2: Calculate accrued yield ───────────────────────────────────
        // aUSDC rebases over time; balance > principalDeposited means yield accrued
        uint256 totalAUM  = aUsdc.balanceOf(address(vault));
        uint256 principal = principalDeposited;

        if (totalAUM <= principal) revert ZeroYield();
        uint256 yield = totalAUM - principal;

        // [H-03] Safety cap: refuse to extract more than MAX_YIELD_BPS of AUM per call
        if (yield > (totalAUM * MAX_YIELD_BPS) / BASIS_POINTS) {
            revert YieldExceedsSafeLimit();
        }

        // ── Step 3: Vault withdraws yield aUSDC → USDC → this contract ────────
        // Aave.withdraw burns aUSDC from the caller (vault) and sends USDC to `to`
        vault.manage(
            address(aUsdc),
            abi.encodeCall(IERC20.approve, (AAVE_POOL, yield)),
            0
        );
        vault.manage(
            AAVE_POOL,
            abi.encodeCall(IAavePool.withdraw, (address(usdc), yield, address(this))),
            0
        );
        emit VaultWithdrewFromAave(yield);

        // ── Step 4: Distribute USDC to stakeholders ───────────────────────────
        _sendToStakeholders(yield);

        lastDistributedAt = block.timestamp;
    }

    // ─────────────────────── Principal Tracking ───────────────────────────────

    /**
     * @notice Sync principalDeposited with the current vault share supply.
     * @dev Uses vault.totalSupply() (18-decimal shares) and divides by SHARE_TO_USDC_SCALAR
     *      to convert to 6-decimal USDC. Works correctly because PrincipalAccountant
     *      maintains a strict 1:1 share-to-USDC exchange rate.
     *      Any authorized distributor can call this to keep accounting accurate.
     */
    function syncPrincipal() external onlyDistributor {
        uint256 old = principalDeposited;
        // vault totalSupply is in 18-decimal shares; 1 share = 1 USDC (6 dec) at 1:1 rate
        uint256 newPrincipal = vault.totalSupply() / SHARE_TO_USDC_SCALAR;
        principalDeposited = newPrincipal;
        emit PrincipalSynced(old, newPrincipal);
    }

    /**
     * @notice Manually record a deposit (increase principal). Called by admin when
     *         the Teller processes a deposit that is not auto-synced.
     */
    function recordDeposit(address user, uint256 usdcAmount) external onlyAdmin {
        uint256 old = principalDeposited;
        principalDeposited += usdcAmount;
        emit PrincipalAdjusted(old, principalDeposited, true);
        // Suppress unused parameter warning
        user;
    }

    /**
     * @notice Manually record a withdrawal (decrease principal). Called by admin.
     */
    function recordWithdrawal(address user, uint256 usdcAmount) external onlyAdmin {
        uint256 old = principalDeposited;
        principalDeposited = usdcAmount > principalDeposited ? 0 : principalDeposited - usdcAmount;
        emit PrincipalAdjusted(old, principalDeposited, false);
        user;
    }

    // ─────────────────────── Stakeholder Management [H-02] ───────────────────

    /**
     * @notice Queue a stakeholder distribution update. Takes effect after 48h timelock.
     * @param _stakeholders Non-empty list of recipient addresses (no zero-address)
     * @param _bps          Basis point shares that must sum to exactly 10,000
     */
    function queueStakeholderUpdate(
        address[] calldata _stakeholders,
        uint256[] calldata _bps
    ) external onlyAdmin {
        if (_stakeholders.length == 0 || _stakeholders.length != _bps.length) revert BpsMismatch();

        uint256 total;
        for (uint256 i; i < _bps.length; i++) {
            if (_stakeholders[i] == address(0)) revert ZeroAddress();
            total += _bps[i];
        }
        if (total != BASIS_POINTS) revert BpsSumMismatch();

        uint256 execAt = block.timestamp + STAKEHOLDER_TIMELOCK;
        pendingUpdate = PendingStakeholderUpdate({
            newStakeholders: _stakeholders,
            newBps:          _bps,
            executableAt:    execAt
        });
        emit StakeholderUpdateQueued(execAt);
    }

    /**
     * @notice Execute the queued stakeholder update after the 48h timelock has expired.
     */
    function executeStakeholderUpdate() external onlyAdmin {
        if (pendingUpdate.executableAt == 0) revert NoPendingUpdate();
        if (block.timestamp < pendingUpdate.executableAt) revert TimelockNotExpired();

        for (uint256 i; i < stakeholders.length; i++) {
            distributionBps[stakeholders[i]] = 0;
        }
        stakeholders = pendingUpdate.newStakeholders;
        for (uint256 i; i < stakeholders.length; i++) {
            distributionBps[stakeholders[i]] = pendingUpdate.newBps[i];
        }

        delete pendingUpdate;
        emit StakeholderUpdateExecuted();
    }

    /// @return Unix timestamp when pendingUpdate becomes executable (0 = no pending update)
    function pendingStakeholderUpdateTime() external view returns (uint256) {
        return pendingUpdate.executableAt;
    }

    function setDistributor(address distributor, bool enabled) external onlyAdmin {
        if (distributor == address(0)) revert ZeroAddress();
        distributors[distributor] = enabled;
        emit DistributorSet(distributor, enabled);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    function pause()   external onlyAdmin { _pause(); }
    function unpause() external onlyAdmin { _unpause(); }

    // ─────────────────────────── Internal Helpers ─────────────────────────────

    /**
     * @notice Push `yield` USDC (already in this contract) to each stakeholder.
     *         Last recipient gets remainder to avoid dust.
     */
    function _sendToStakeholders(uint256 yield) internal {
        address[] memory _sh  = stakeholders;
        uint256 len           = _sh.length;
        uint256[] memory amts = new uint256[](len);
        uint256 distributed;

        for (uint256 i; i < len - 1; i++) {
            amts[i] = (yield * distributionBps[_sh[i]]) / BASIS_POINTS;
            distributed += amts[i];
            usdc.safeTransfer(_sh[i], amts[i]);
        }
        amts[len - 1] = yield - distributed;
        usdc.safeTransfer(_sh[len - 1], amts[len - 1]);

        emit YieldDistributed(yield, _sh, amts);
    }

    // ─────────────────────────────── View Functions ────────────────────────────

    /// @return stakeholderAddresses Ordered stakeholder addresses
    /// @return bps                  Corresponding basis-point shares
    function getStakeholders() external view returns (address[] memory stakeholderAddresses, uint256[] memory bps) {
        uint256 len          = stakeholders.length;
        stakeholderAddresses = new address[](len);
        bps                  = new uint256[](len);
        for (uint256 i; i < len; i++) {
            stakeholderAddresses[i] = stakeholders[i];
            bps[i]                  = distributionBps[stakeholders[i]];
        }
    }

    /// @return Unrealized yield = aUSDC(vault) − principalDeposited (0 if principal >= aum)
    function getCurrentYield() external view returns (uint256) {
        uint256 totalAUM = aUsdc.balanceOf(address(vault));
        return totalAUM > principalDeposited ? totalAUM - principalDeposited : 0;
    }

    /**
     * @return aum       Total aUSDC in vault (principal + accrued yield)
     * @return principal Tracked USDC principal
     * @return yield     Unrealized yield = aum − principal
     * @return idleUsdc  Uninvested USDC sitting in vault
     */
    function getVaultStats() external view returns (
        uint256 aum,
        uint256 principal,
        uint256 yield,
        uint256 idleUsdc
    ) {
        aum       = aUsdc.balanceOf(address(vault));
        principal = principalDeposited;
        yield     = aum > principal ? aum - principal : 0;
        idleUsdc  = usdc.balanceOf(address(vault));
    }
}
