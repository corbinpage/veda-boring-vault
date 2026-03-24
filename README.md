# Veda BoringVault — Aave Yield System on Base

  Smart contracts for the Veda BoringVault / Aave V3 USDC yield strategy deployed on Base Mainnet (chainId: 8453).

  ## Architecture

  | Contract | Role |
  |---|---|
  | `BoringVault` | ERC-20 share token vault; holds USDC + aUSDC; executes managed calls |
  | `TellerWithMultiAssetSupport` | Entry/exit router; mints/burns shares |
  | `PrincipalAccountant` | 1:1 USDC rate oracle (1 share = 1 USDC) |
  | `ManagerWithMerkleVerification` | Execution engine; verifies Merkle proofs before calling vault |
  | `AtomicQueue` | 1-hour withdrawal delay queue; fulfilled by off-chain solver |
  | `RolesAuthority` | On-chain ACL (MANAGER_ROLE, TELLER_ROLE, DISTRIBUTOR_ROLE) |
  | `AaveV3DecoderAndSanitizer` | Calldata decoder for safe Aave interactions |
  | `BaseAaveYieldManager` | Yield strategy: supply USDC to Aave V3, harvest interest, distribute to stakeholders |

  ## Key Addresses (Base Mainnet)

  | Token/Protocol | Address |
  |---|---|
  | USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
  | aUSDC (Aave V3) | `0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB` |
  | Aave V3 Pool | `0xA238Dd80C259a72e81d7e4674A963d919642167C` |

  ## Getting Started

  ### Prerequisites

  - [Foundry](https://getfoundry.sh/) (`forge`, `cast`, `anvil`)
  - Node.js 18+ (for Merkle tree builder)

  ### Install

  ```bash
  forge install
  ```

  ### Build

  ```bash
  forge build
  ```

  ### Test

  ```bash
  forge test -vvv --fork-url https://mainnet.base.org
  ```

  ### Deploy to Base Mainnet

  See [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md) for full step-by-step instructions.

  ```bash
  # Set env vars
  export PRIVATE_KEY=0x...
  export ADMIN_MULTISIG=0x...
  export BOT_WALLET=0x...

  # Deploy all 8 contracts
  forge script script/DeployVaultSystem.s.sol:DeployVaultSystem \
    --rpc-url https://mainnet.base.org \
    --broadcast \
    --verify \
    -vvvv
  ```

  ## Security

  See [SECURITY_AUDIT.md](./SECURITY_AUDIT.md) for the full security review.

  ## License

  MIT
  