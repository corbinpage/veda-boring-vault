# Security Audit — Veda BoringVault / Base Aave Yield System

> **Date**: March 2026  
> **Scope**: Five-contract system — BoringVault, TellerWithMultiAssetSupport, AccountantWithRateProviders (PrincipalAccountant), ManagerWithMerkleVerification (BaseAaveYieldManager), AtomicQueue  
> **Chain**: Base Mainnet  
> **External Protocol**: Aave V3 (Pool: `0xA238Dd80C259a72e81d7e4674A963d919642167C`)

---

## Executive Summary

The system is architecturally sound for its stated purpose: an ERC-20 vault that supplies USDC to Aave V3, separates yield from principal via a fixed 1:1 rate, and fulfills withdrawals through a 1-hour AtomicQueue. However, several **HIGH** and **MEDIUM** severity issues exist across the custom extensions that must be resolved before mainnet deployment.

| Severity | Count |
|----------|-------|
| CRITICAL  | 1 |
| HIGH      | 4 |
| MEDIUM    | 5 |
| LOW       | 4 |
| INFO      | 3 |

---

## CRITICAL

### [C-01] Yield Calculation Can Be Gamed via Flash Loans or Donation Attack

**Contract**: `BaseAaveYieldManager.distributeAndRebalance()`  
**Location**: Yield extraction logic:  
```solidity
uint256 totalAUM = aUSDC.balanceOf(address(vault));
uint256 totalPrincipal = vault.totalSupply(); // Since it's 1:1
uint256 yield = totalAUM - totalPrincipal;
```

**Description**: `vault.totalSupply()` is the count of minted vUSDC shares. An attacker can:
1. Donate raw USDC directly to the BoringVault address (not through the Teller), inflating `totalAUM` without increasing `totalSupply`.
2. Call or front-run `distributeAndRebalance()`, causing artificial "yield" to be extracted and sent to the stakeholder list.

Equally, a flash loan of aUSDC donated to the vault immediately before `distributeAndRebalance()` drains real user principal as "yield."

**Impact**: Complete or partial loss of user principal. The vault appears solvent but is missing USDC backing for existing shares.

**Mitigation**:
- Track deposited principal explicitly in a storage variable incremented on deposit and decremented on redemption. Do not rely on `totalSupply()` alone.
- Add a `minYieldThreshold` and a `maxYieldPercentage` safety check (e.g. revert if yield > 20% of AUM in one call).
- The Teller should be the only path to increase principal tracking.
- Consider a `principalDeposited` state variable updated atomically with minting.

---

## HIGH

### [H-01] Reentrancy in `distributeAndRebalance()` via ERC-777/Callback Tokens

**Contract**: `BaseAaveYieldManager`  
**Description**: The function calls `_withdrawFromAave(yield)` (which interacts with the Aave pool — an external contract) and then `_sendToStakeholders(yield)` which iterates over a stakeholder mapping and sends tokens. If any stakeholder address is a contract that implements a receive hook (or if yield is sent in ETH), a reentrancy attack can re-enter `distributeAndRebalance()` before state is updated.

**Impact**: Double-distribution of yield; potential full drain of aUSDC balance.

**Mitigation**:
- Apply a `nonReentrant` modifier (OpenZeppelin `ReentrancyGuard`) to `distributeAndRebalance()`.
- Follow Checks-Effects-Interactions: update internal state (e.g. a `lastDistributedAt` timestamp) before external calls.
- Use `SafeERC20.safeTransfer` instead of raw `transfer`.

---

### [H-02] Access Control — `onlyWhitelisted` Relies on Mutable State Without Timelock

**Contract**: `BaseAaveYieldManager`  
**Description**: The `onlyWhitelisted` modifier gates `distributeAndRebalance()`. If the admin (who controls the whitelist via `setDistributionList` or equivalent) is compromised, an attacker can:
- Add themselves to the distributor whitelist.
- Call `distributeAndRebalance()` to extract all yield (and potentially principal via C-01).
- Modify the stakeholder distribution list to redirect funds.

There is no timelock or multi-sig requirement on the admin key that controls both the distributor list and the stakeholder payout list.

**Impact**: Full drain of vault yield and potentially principal with a single compromised key.

**Mitigation**:
- Separate the "Distributor" role (who calls `distributeAndRebalance`) from the "Admin" role (who manages the stakeholder list).
- Enforce a minimum 48-hour timelock on any change to the stakeholder distribution list.
- Use a 2-of-N multisig (e.g. Gnosis Safe) for the Admin role.
- Consider making the stakeholder list immutable after deployment with a separate upgrade path.

---

### [H-03] AtomicQueue Fulfillment Can Be Griefed — Withdrawal Stuck Indefinitely

**Contract**: `AtomicQueue` / Manager's `_fulfillMaturedWithdrawals()`  
**Description**: The Manager pulls funds from Aave to fulfill matured withdrawal requests. However:
- If Aave's liquidity is temporarily low (utilization near 100%), the withdrawal will revert.
- There is no fallback mechanism to fulfill requests from idle USDC in the vault.
- The `QUEUE_DELAY` is a minimum, not a maximum — there is no timeout that forces a refund to the user if the request cannot be fulfilled.

**Impact**: User funds (shares) are locked in the AtomicQueue indefinitely with no recourse. This is a critical UX and potential regulatory risk.

**Mitigation**:
- Implement a maximum wait time (e.g. 48 hours). If unfulfilled, auto-refund the user's shares back to their wallet.
- Before Aave withdrawal, attempt fulfillment from idle USDC in the vault first.
- Emit events and expose a view function so users can check their request's fulfillability off-chain.

---

### [H-04] `shareLockPeriod = 0` Enables Same-Block Deposit-and-Redeem Arbitrage

**Contract**: `TellerWithMultiAssetSupport`  
**Description**: With `shareLockPeriod = 0`, a sophisticated bot can:
1. Deposit USDC in block N, receiving vUSDC.
2. In the same block (or immediately after), queue a redemption via AtomicQueue.
3. Front-run the `distributeAndRebalance()` call to ensure the vault receives yield just before their redemption is fulfilled.

Since the share price is always 1:1 (by design), this is less profitable than in standard vaults, but it still creates noise and gas waste, and can be combined with H-03 and C-01 for profit.

**Impact**: Medium-high — denial of service and economic manipulation risk.

**Mitigation**:
- Set `shareLockPeriod` to at least 1 block (or 12 seconds on Base) to prevent same-transaction exploits.
- Rate-limit deposits per address per block.

---

## MEDIUM

### [M-01] Integer Precision Loss in Percentage Distribution

**Contract**: `BaseAaveYieldManager._sendToStakeholders()`  
**Description**: The `distributionShares` mapping stores percentage values. When distributing yield:
```solidity
uint256 payout = yield * distributionShares[addr] / 100;
```
For USDC (6 decimals), very small yield amounts will round to 0 for stakeholders with small percentages, and dust accumulates in the contract.

**Impact**: Permanent loss of small yield amounts (dust). If yield is extremely small, no stakeholder receives anything.

**Mitigation**:
- Use basis points (10,000) instead of percentage (100) for finer granularity.
- Distribute to the last stakeholder as `yield - sumOfPreviousPayouts` (remainder pattern) to eliminate dust accumulation.

---

### [M-02] No Slippage Control on Aave Supply / Withdraw

**Contract**: `BaseAaveYieldManager._supplyIdleToAave()`, `_withdrawFromAave()`  
**Description**: The Aave V3 `supply()` and `withdraw()` functions accept a minimum amount out parameter. This is not set in the design, meaning MEV bots can sandwich transactions to extract value.

**Impact**: Users and the vault lose small amounts on each rebalance due to MEV sandwich attacks. This reduces effective yield.

**Mitigation**:
- Use Aave's `supply` with an `onBehalfOf` set to the vault (correct).
- For withdrawals, specify exact `amount` rather than `type(uint256).max` to avoid over-withdrawal.
- Consider using a private mempool (e.g. Flashbots Protect RPC on Base) for `distributeAndRebalance()` calls.

---

### [M-03] No Emergency Pause Mechanism

**Contract**: All contracts  
**Description**: There is no circuit breaker. If Aave is exploited or paused, or if the vault itself is compromised, there is no way to halt deposits, stop yield distribution, or freeze the AtomicQueue without a full upgrade.

**Impact**: In a black-swan event, losses compound until a new contract is deployed and users migrate.

**Mitigation**:
- Implement OpenZeppelin `Pausable` on the Teller and Manager.
- The Admin multisig should be able to pause all entry/exit within one transaction.

---

### [M-04] Merkle Proof Staleness — `ManagerWithMerkleVerification`

**Contract**: `ManagerWithMerkleVerification`  
**Description**: The BoringVault architecture uses a Merkle tree of allowed function calls to restrict what the Manager can do. If the Merkle root is updated while a transaction is in the mempool, the transaction will fail with a stale proof. More critically, an outdated Merkle root may allow calls that should no longer be permitted if the root update is delayed.

**Impact**: Medium — operational disruption; potential window where disallowed calls are possible.

**Mitigation**:
- Implement a commit-delay (e.g. 6 hours) on Merkle root updates with an event emitted on commit.
- Monitor the root update pipeline and validate leaves match the current Aave V3 contract addresses on Base.

---

### [M-05] No Maximum AUM Cap

**Contract**: `TellerWithMultiAssetSupport`  
**Description**: There is no deposit cap. Unlimited deposits mean the vault can grow to a size where Aave liquidity becomes a systemic concern, and a large simultaneous withdrawal event (bank-run) would be catastrophic.

**Impact**: Systemic risk; withdrawal queue cannot fulfill all requests during market stress.

**Mitigation**:
- Implement a configurable `maxTVL` deposit cap (e.g. start at $10M, governed by admin with timelock).
- Monitor Aave utilization; pause deposits when utilization exceeds 90%.

---

## LOW

### [L-01] Event Emission Gaps

Several state-changing operations emit no events, making off-chain monitoring difficult:
- Changes to the stakeholder `distributionShares` mapping.
- Fulfillment of AtomicQueue requests.
- Yield extraction amounts.

**Mitigation**: Add events for all state changes, especially `YieldDistributed(uint256 amount, address[] recipients, uint256[] amounts)` and `WithdrawalFulfilled(address user, uint256 shares, uint256 usdcAmount)`.

---

### [L-02] Hardcoded `QUEUE_DELAY` Cannot Be Updated

The 3600-second delay is a constant. If network conditions change or a shorter/longer delay is needed, the contract must be redeployed.

**Mitigation**: Make it a configurable variable with a maximum upper bound (e.g. 7 days), changeable by admin with a timelock.

---

### [L-03] `getRate()` Returns Raw Integer — No Sanity Check on Consumption

`PrincipalAccountant.getRate()` returns `1e6` but there is no validation that consuming contracts (Teller, Manager) correctly interpret this as "1 USDC per share." A version mismatch between the Accountant interface and the Teller's interpretation could silently break the 1:1 peg.

**Mitigation**: Add a `decimals()` function to the Accountant and enforce that `rate / 10**decimals() == 1` in a deployment assertion test.

---

### [L-04] Distributor Role Can Be Front-Run by Anyone Watching Mempool

`distributeAndRebalance()` is restricted to whitelisted addresses but the function call is visible in the public mempool. MEV searchers can observe the distributor's call and sandwich it.

**Mitigation**: Use Flashbots Protect or a private RPC endpoint for all distributor transactions.

---

## INFO

### [I-01] Use of `address(vault)` Instead of Explicit Storage

Some calls use `address(vault)` which is assumed to be immutable. Confirm via deployment script that the vault address is set in the constructor and cannot be changed post-deployment.

### [I-02] Regulatory Risk — Yield Distribution Without KYC

Automatically distributing yield to a configured stakeholder list without KYC/AML checks may constitute an unlicensed securities or money transmission activity in some jurisdictions (particularly the US). Consult legal counsel before mainnet launch.

### [I-03] aUSDC Balance vs USDC Balance Ambiguity

The design mixes `aUSDC.balanceOf(vault)` and raw `USDC.balanceOf(vault)` in the same accounting flow. Ensure the implementation clearly distinguishes between the two at all times, especially during the transition between "idle USDC" and "deployed aUSDC" states.

---

## Deployment Checklist

Before deploying to Base Mainnet:

- [ ] Fix C-01: Explicit principal tracking via storage variable
- [ ] Fix H-01: Add `nonReentrant` to `distributeAndRebalance()`
- [ ] Fix H-02: Separate Admin/Distributor roles; add 48h timelock on stakeholder list changes
- [ ] Fix H-03: Add maximum queue wait time with auto-refund
- [ ] Fix H-04: Set `shareLockPeriod >= 1 block`
- [ ] Fix M-01: Use basis points for distribution percentages
- [ ] Fix M-02: Specify exact amounts in Aave calls
- [ ] Fix M-03: Add `Pausable` to Teller and Manager
- [ ] Fix M-04: Implement commit-delay on Merkle root updates
- [ ] Fix M-05: Set initial TVL cap (suggest $10M)
- [ ] Professional audit by Spearbit, Sherlock, or Code4rena before launch
- [ ] Deploy to Base Sepolia testnet and run 2-week soak test
- [ ] Bug bounty program active before mainnet launch

---

*This audit is based on the conceptual design specification. A full audit requires access to the complete, compilable source code of all five contracts.*
