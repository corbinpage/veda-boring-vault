# Base Mainnet Deployment Guide — Veda BoringVault Aave Yield System

## Prerequisites

### Tools
- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Node.js ≥ 18 (for Merkle tree script)
- A funded wallet with ETH on Base for gas

### External Dependencies (Install via Forge)
```bash
# From the contracts/ directory:
forge install foundry-rs/forge-std --no-commit
forge install OpenZeppelin/openzeppelin-contracts --no-commit
forge install Se7en-Seas/boring-vault --no-commit
```

### Known Base Mainnet Addresses
| Contract | Address |
|----------|---------|
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| aUSDC (Aave) | `0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB` |
| Aave V3 Pool | `0xA238Dd80C259a72e81d7e4674A963d919642167C` |

---

## Environment Setup

Create a `.env` file in `contracts/` (never commit this file):

```bash
# .env — contracts/
BASE_RPC_URL=https://mainnet.base.org
BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
PRIVATE_KEY=0x...                          # Deployer key — use a fresh wallet
BASESCAN_API_KEY=...                       # From https://basescan.org/myapikey
ADMIN_ADDRESS=0x...                        # Gnosis Safe multisig (STRONGLY RECOMMENDED)
DISTRIBUTOR_ADDRESS=0x...                  # Bot wallet for distributeAndRebalance()
STAKEHOLDER_ADDRESSES=0x...,0x...          # Comma-separated yield recipients
STAKEHOLDER_BPS=7000,3000                  # Must sum to 10000
```

---

## Step 1 — Testnet First (Base Sepolia)

Always deploy to Base Sepolia before mainnet. Base Sepolia has its own USDC and Aave V3 deployment.

Base Sepolia addresses:
- USDC: `0x036CbD53842c5426634e7929541eC2318f3dCF7e`
- Aave V3 Pool: `0x07eA79F68B2B3df564D0A34F8e19D9B1e339814b` (check Aave docs for current)

```bash
cd contracts
source .env

# Simulate first (no --broadcast):
forge script script/DeployVaultSystem.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  -vvvv

# Deploy + verify on Base Sepolia:
forge script script/DeployVaultSystem.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $BASESCAN_API_KEY \
  -vvvv
```

Run a full soak test on Sepolia (minimum 2 weeks) before proceeding.

---

## Step 2 — Build the Merkle Tree

After deploying the Manager and Decoder, build the Merkle tree:

```bash
cd contracts/script
npm install ethers @openzeppelin/merkle-tree

VAULT_ADDRESS=0x...    \
DECODER_ADDRESS=0x...  \
MANAGER_ADDRESS=0x...  \
npx ts-node build-merkle-tree.ts
```

Copy the printed root and set it on the Manager:

```bash
cast send $MANAGER_ADDRESS \
  "setMerkleRoot(bytes32,string)" \
  "0x<root>" \
  "ipfs://YOUR_IPFS_CID" \
  --rpc-url $BASE_RPC_URL \
  --private-key $PRIVATE_KEY
```

---

## Step 3 — Post-Deploy Wiring

Run these cast commands after deployment. Replace `$CONTRACT` with actual addresses.

```bash
# 1. Authorize Teller to manage vault
cast send $ROLES_AUTHORITY \
  "setUserRole(address,uint8,bool)" $TELLER 8 true \
  --rpc-url $BASE_RPC_URL --private-key $PRIVATE_KEY

# 2. Authorize Manager to manage vault
cast send $ROLES_AUTHORITY \
  "setUserRole(address,uint8,bool)" $MANAGER 7 true \
  --rpc-url $BASE_RPC_URL --private-key $PRIVATE_KEY

# 3. Set distributor bot on YieldManager
cast send $YIELD_MANAGER \
  "setDistributor(address,bool)" $DISTRIBUTOR_ADDRESS true \
  --rpc-url $BASE_RPC_URL --private-key $PRIVATE_KEY

# 4. Queue stakeholder update (48h timelock applies)
cast send $YIELD_MANAGER \
  "queueStakeholderUpdate(address[],uint256[])" \
  "[$STAKEHOLDER1,$STAKEHOLDER2]" "[7000,3000]" \
  --rpc-url $BASE_RPC_URL --private-key $PRIVATE_KEY

# 5. After 48 hours — execute stakeholder update
cast send $YIELD_MANAGER \
  "executeStakeholderUpdate()" \
  --rpc-url $BASE_RPC_URL --private-key $PRIVATE_KEY

# 6. Transfer admin to multisig
cast send $YIELD_MANAGER \
  "transferAdmin(address)" $ADMIN_ADDRESS \
  --rpc-url $BASE_RPC_URL --private-key $PRIVATE_KEY

# 7. Verify accountant peg
cast call $ACCOUNTANT "validateRatePeg()" --rpc-url $BASE_RPC_URL
# Must return: 0x0000...0001 (true)
```

---

## Step 4 — Mainnet Deployment

Once testnet is verified and all security fixes are confirmed:

```bash
# Simulate first:
forge script script/DeployVaultSystem.s.sol \
  --rpc-url $BASE_RPC_URL \
  --private-key $PRIVATE_KEY \
  -vvvv

# Deploy + verify:
forge script script/DeployVaultSystem.s.sol \
  --rpc-url $BASE_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $BASESCAN_API_KEY \
  -vvvv
```

---

## Post-Deployment Checklist

- [ ] All 7 contracts verified on Basescan
- [ ] `validateRatePeg()` returns `true`
- [ ] Teller authorized on RolesAuthority
- [ ] Manager authorized on RolesAuthority  
- [ ] Merkle root set on Manager
- [ ] Distributor bot wallet funded with ETH
- [ ] Stakeholder list queued and executed (after 48h)
- [ ] Admin transferred to Gnosis Safe multisig
- [ ] Test deposit: $100 USDC → receive 100 vUSDC
- [ ] Test `distributeAndRebalance()` once
- [ ] Monitor Aave supply confirmation in Aave dashboard
- [ ] Test withdrawal: queue → wait 1h → Manager fulfills
- [ ] Set up off-chain monitoring for:
  - Aave pool utilization > 90% → pause deposits alert
  - `distributeAndRebalance()` failure alerts
  - TVL cap approach (> 80% of max)
- [ ] Professional audit report published
- [ ] Bug bounty program live

---

## Aave V3 Decoder Setup Details

The `ManagerWithMerkleVerification` uses a `DecoderAndSanitizer` to validate each call.
For Aave V3 on Base, the decoder must handle:

| Function | Selector | Validated Arguments |
|----------|----------|---------------------|
| `supply(address,uint256,address,uint16)` | `0x617ba037` | `asset == USDC`, `onBehalfOf == vault` |
| `withdraw(address,uint256,address)` | `0x69328dec` | `asset == USDC`, `to == manager` |
| `approve(address,uint256)` on aUSDC | `0x095ea7b3` | `spender == Aave Pool` |

The Merkle tree must include one leaf per (decoder, target, selector, whitelisted-addresses) tuple.
See `script/build-merkle-tree.ts` for the full tree construction.

---

## Gas Estimates (Base Mainnet)

| Operation | Estimated Gas | Estimated Cost at 0.1 Gwei |
|-----------|--------------|---------------------------|
| Deploy all 7 contracts | ~8,000,000 | ~$0.50 |
| `distributeAndRebalance()` | ~350,000 | ~$0.02 |
| `teller.deposit()` | ~120,000 | ~$0.01 |
| `atomicQueue.requestRedeem()` | ~90,000 | ~$0.005 |

*Base has very low gas costs. These estimates are conservative.*
