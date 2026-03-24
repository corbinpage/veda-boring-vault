// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PrincipalAccountant} from "../src/PrincipalAccountant.sol";
import {BaseAaveYieldManager} from "../src/BaseAaveYieldManager.sol";

// ─── Veda BoringVault Library Imports ────────────────────────────────────────
// These require: forge install Se7en-Seas/boring-vault --no-commit
// After installing, update foundry.toml with the correct remappings.
import {BoringVault}                   from "boring-vault/src/base/BoringVault.sol";
import {RolesAuthority}                from "boring-vault/src/base/Roles/Authority.sol";
import {Authority}                     from "solmate/src/auth/Auth.sol";
import {TellerWithMultiAssetSupport}   from "boring-vault/src/base/Roles/TellerWithMultiAssetSupport.sol";
import {ManagerWithMerkleVerification} from "boring-vault/src/base/Roles/ManagerWithMerkleVerification.sol";
import {AtomicQueue}                   from "boring-vault/src/atomic-queue/AtomicQueue.sol";
import {AaveV3DecoderAndSanitizer}     from "boring-vault/src/base/DecodersAndSanitizers/AaveV3DecoderAndSanitizer.sol";

/**
 * @title DeployVaultSystem
 * @notice Full end-to-end deployment script for the Veda BoringVault / Aave Yield System on Base Mainnet.
 *
 * Deploys and wires all eight contracts in a single transaction batch:
 *   1. RolesAuthority        — permission registry
 *   2. BoringVault           — ERC-20 share token (vUSDC)
 *   3. PrincipalAccountant   — 1:1 rate provider (our contract)
 *   4. TellerWithMultiAsset  — deposit / exit router
 *   5. AtomicQueue           — 1-hour withdrawal queue
 *   6. AaveV3Decoder         — calldata sanitizer for Merkle-verified manager calls
 *   7. ManagerWithMerkle     — execution engine for Aave interactions
 *   8. BaseAaveYieldManager  — yield harvesting + stakeholder distribution (our contract)
 *
 * ─── PREREQUISITES ───────────────────────────────────────────────────────────
 *
 *   1. Install Foundry: https://book.getfoundry.sh/getting-started/installation
 *   2. Install dependencies:
 *        forge install Se7en-Seas/boring-vault --no-commit
 *        forge install transmissions11/solmate --no-commit
 *        forge install OpenZeppelin/openzeppelin-contracts --no-commit
 *   3. Add to foundry.toml [profile.default]:
 *        remappings = [
 *          "boring-vault/=lib/boring-vault/",
 *          "solmate/=lib/solmate/",
 *          "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/"
 *        ]
 *
 * ─── ENVIRONMENT VARIABLES ───────────────────────────────────────────────────
 *
 *   BASE_RPC_URL=https://mainnet.base.org
 *   PRIVATE_KEY=0x...          # Funded deployer key (DO NOT COMMIT)
 *   BASESCAN_API_KEY=...       # For --verify flag
 *   ADMIN_ADDRESS=0x...        # Gnosis Safe or multisig (receives admin rights)
 *   DISTRIBUTOR_ADDRESS=0x...  # Bot wallet for distributeAndRebalance() automation
 *
 * ─── DEPLOYMENT COMMANDS ─────────────────────────────────────────────────────
 *
 *   Dry-run (simulation, no broadcast):
 *     forge script script/DeployVaultSystem.s.sol \
 *       --rpc-url $BASE_RPC_URL --private-key $PRIVATE_KEY -vvvv
 *
 *   Broadcast to Base Mainnet + verify on Basescan:
 *     forge script script/DeployVaultSystem.s.sol \
 *       --rpc-url $BASE_RPC_URL --private-key $PRIVATE_KEY \
 *       --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY -vvvv
 *
 *   Base Sepolia testnet (run this first!):
 *     forge script script/DeployVaultSystem.s.sol \
 *       --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY \
 *       --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY -vvvv
 *
 * ─────────────────────────────────────────────────────────────────────────────
 */

// ─── Base Mainnet Constants ───────────────────────────────────────────────────

address constant BASE_USDC      = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
address constant BASE_AUSDC     = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
address constant BASE_AAVE_POOL = 0xA238Dd80C259a72e81d7e4674A963d919642167C;

// Role IDs — must match the RolesAuthority configuration used by BoringVault
uint8 constant ADMIN_ROLE       = 1;
uint8 constant MANAGER_ROLE     = 7;
uint8 constant TELLER_ROLE      = 8;
uint8 constant DISTRIBUTOR_ROLE = 9;

// ─────────────────────────────────────────────────────────────────────────────

contract DeployVaultSystem is Script {

    // Deployed addresses — populated by run()
    RolesAuthority                public rolesAuthority;
    BoringVault                   public boringVault;
    PrincipalAccountant           public accountant;
    TellerWithMultiAssetSupport   public teller;
    AtomicQueue                   public atomicQueue;
    AaveV3DecoderAndSanitizer     public decoder;
    ManagerWithMerkleVerification public manager;
    BaseAaveYieldManager          public yieldManager;

    function run() external {
        uint256 deployerKey  = vm.envUint("PRIVATE_KEY");
        address adminAddress = vm.envAddress("ADMIN_ADDRESS");
        address distributor  = vm.envAddress("DISTRIBUTOR_ADDRESS");

        address deployer = vm.addr(deployerKey);

        console2.log("=================================================");
        console2.log("Veda BoringVault System — Base Mainnet Deployment");
        console2.log("=================================================");
        console2.log("Deployer:   ", deployer);
        console2.log("Admin:      ", adminAddress);
        console2.log("Distributor:", distributor);
        console2.log("Chain ID:   ", block.chainid);

        require(
            block.chainid == 8453 || block.chainid == 84532,
            "DeployVaultSystem: must deploy to Base Mainnet (8453) or Base Sepolia (84532)"
        );
        require(adminAddress   != address(0), "DeployVaultSystem: ADMIN_ADDRESS not set");
        require(distributor    != address(0), "DeployVaultSystem: DISTRIBUTOR_ADDRESS not set");

        vm.startBroadcast(deployerKey);

        // ── Step 1: RolesAuthority ──────────────────────────────────────────
        // Deployer is initial owner; ownership transferred to adminAddress at the end.
        rolesAuthority = new RolesAuthority(deployer, Authority(address(0)));
        console2.log("[Step 1] RolesAuthority:    ", address(rolesAuthority));

        // ── Step 2: BoringVault ─────────────────────────────────────────────
        // ERC-20 share token; authority is the RolesAuthority.
        boringVault = new BoringVault(
            address(rolesAuthority),
            "Veda Aave USDC",
            "vUSDC",
            18
        );
        console2.log("[Step 2] BoringVault:       ", address(boringVault));

        // ── Step 3: PrincipalAccountant (our contract) ─────────────────────
        // 1:1 rate provider — getRate() always returns 1e6.
        accountant = new PrincipalAccountant(address(boringVault), BASE_USDC);
        require(accountant.validateRatePeg(), "PrincipalAccountant rate peg validation failed");
        console2.log("[Step 3] PrincipalAccountant:", address(accountant));

        // ── Step 4: TellerWithMultiAssetSupport ─────────────────────────────
        // Handles deposit and bulk-withdraw; checks asset whitelist and share lock.
        teller = new TellerWithMultiAssetSupport(
            address(rolesAuthority),
            address(boringVault),
            address(accountant),
            BASE_USDC
        );
        // Whitelist USDC as the accepted deposit/withdrawal asset.
        teller.addAsset(BASE_USDC);
        // [H-04] 1-second share lock prevents same-block deposit→withdraw arbitrage.
        teller.setShareLockPeriod(1);
        console2.log("[Step 4] Teller:             ", address(teller));

        // ── Step 5: AtomicQueue ─────────────────────────────────────────────
        // 1-hour withdrawal queue; fulfilled by the distributor bot.
        atomicQueue = new AtomicQueue();
        console2.log("[Step 5] AtomicQueue:        ", address(atomicQueue));

        // ── Step 6a: AaveV3DecoderAndSanitizer ──────────────────────────────
        // Validates all calldata passed to the Aave pool through the Manager.
        decoder = new AaveV3DecoderAndSanitizer(address(boringVault));
        console2.log("[Step 6a] Decoder:           ", address(decoder));

        // ── Step 6b: ManagerWithMerkleVerification ──────────────────────────
        // Execution engine; requires a Merkle proof for every Aave call.
        // Set the Merkle root post-deploy via IManager(manager).setMerkleRoot(root, cid).
        manager = new ManagerWithMerkleVerification(
            address(rolesAuthority),
            address(boringVault),
            address(decoder)
        );
        console2.log("[Step 6b] Manager:           ", address(manager));

        // ── Step 6c: BaseAaveYieldManager (our contract) ───────────────────
        // Supplies USDC to Aave, harvests yield, distributes to stakeholders.
        // Requires MANAGER_ROLE to call vault.manage() — granted in _wireContracts.
        yieldManager = new BaseAaveYieldManager(
            BASE_USDC,
            BASE_AUSDC,
            address(boringVault),
            adminAddress
        );
        console2.log("[Step 6c] YieldManager:     ", address(yieldManager));

        // ── Post-Deploy: Wire contracts ─────────────────────────────────────
        _wireContracts(adminAddress, distributor);

        vm.stopBroadcast();

        _printManifest(adminAddress);
    }

    function _wireContracts(address adminAddress, address distributor) internal {
        console2.log("\n[Post-Deploy] Wiring contracts...");

        // ── Role capabilities: TELLER_ROLE ──────────────────────────────────
        // Teller can call BoringVault.enter() and exit() to mint/burn shares.
        rolesAuthority.setUserRole(address(teller), TELLER_ROLE, true);
        rolesAuthority.setRoleCapability(
            TELLER_ROLE,
            address(boringVault),
            BoringVault.enter.selector,
            true
        );
        rolesAuthority.setRoleCapability(
            TELLER_ROLE,
            address(boringVault),
            BoringVault.exit.selector,
            true
        );

        // ── Role capabilities: MANAGER_ROLE ─────────────────────────────────
        // Both ManagerWithMerkleVerification and BaseAaveYieldManager need MANAGER_ROLE
        // so they can call BoringVault.manage() to execute Aave supply/withdraw calls.
        rolesAuthority.setUserRole(address(manager),     MANAGER_ROLE, true);
        rolesAuthority.setUserRole(address(yieldManager), MANAGER_ROLE, true);
        rolesAuthority.setRoleCapability(
            MANAGER_ROLE,
            address(boringVault),
            BoringVault.manage.selector,
            true
        );

        // ── Role capabilities: DISTRIBUTOR_ROLE ──────────────────────────────
        // The distributor bot wallet can call distributeAndRebalance() on YieldManager.
        rolesAuthority.setUserRole(distributor, DISTRIBUTOR_ROLE, true);
        // Register the distributor bot in the YieldManager itself.
        yieldManager.setDistributor(distributor, true);

        // ── Transfer ownership of RolesAuthority to admin multisig ──────────
        // [H-02]: Admin private key must not remain a single EOA in production.
        rolesAuthority.transferOwnership(adminAddress);

        console2.log("  TELLER_ROLE(enter/exit):  granted to Teller");
        console2.log("  MANAGER_ROLE(manage):     granted to Manager");
        console2.log("  DISTRIBUTOR_ROLE:         granted to YieldManager + bot");
        console2.log("  RolesAuthority ownership: transferred to", adminAddress);
        console2.log("\n  [ACTION REQUIRED] Build and set Merkle root:");
        console2.log("    npx ts-node script/build-merkle-tree.ts");
        console2.log("    cast send $MANAGER_ADDRESS 'setMerkleRoot(bytes32,string)' \\");
        console2.log("      $MERKLE_ROOT $MERKLE_IPFS_CID --rpc-url $BASE_RPC_URL");
        console2.log("  [ACTION REQUIRED] Queue stakeholder distribution via Admin Panel UI");
    }

    function _printManifest(address adminAddress) internal view {
        console2.log("\n======================================================");
        console2.log("          DEPLOYMENT MANIFEST — SET THESE ENV VARS");
        console2.log("======================================================");
        console2.log("BORING_VAULT_ADDRESS=  ", address(boringVault));
        console2.log("TELLER_ADDRESS=        ", address(teller));
        console2.log("ACCOUNTANT_ADDRESS=    ", address(accountant));
        console2.log("MANAGER_ADDRESS=       ", address(manager));
        console2.log("ATOMIC_QUEUE_ADDRESS=  ", address(atomicQueue));
        console2.log("YIELD_MANAGER_ADDRESS= ", address(yieldManager));
        console2.log("ROLES_AUTHORITY_ADDRESS=", address(rolesAuthority));
        console2.log("------------------------------------------------------");
        console2.log("Chain ID:    ", block.chainid);
        console2.log("Admin:       ", adminAddress);
        console2.log("USDC:        ", BASE_USDC);
        console2.log("aUSDC:       ", BASE_AUSDC);
        console2.log("Aave V3:     ", BASE_AAVE_POOL);
        console2.log("======================================================");
        console2.log("\nPost-deployment checklist:");
        console2.log("  [ ] Set all BORING_VAULT_ADDRESS etc. env vars in API server");
        console2.log("  [ ] Build Merkle tree and set root on Manager (see above)");
        console2.log("  [ ] Queue + execute stakeholder distribution via Admin Panel");
        console2.log("  [ ] Test with a small $100 USDC deposit before scaling TVL");
        console2.log("  [ ] Verify all contracts on Basescan");
        console2.log("  [ ] Store admin key in Gnosis Safe — never use plain EOA in prod");
    }
}
