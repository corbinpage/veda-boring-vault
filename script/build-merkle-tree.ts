/**
 * Build the Merkle tree of allowed Manager actions for ManagerWithMerkleVerification.
 *
 * The Veda Manager only executes calls whose (decoder, target, selector, args) tuple
 * is included in a Merkle tree. This script builds that tree for the Aave V3 integration
 * on Base and prints the root to set in the Manager contract.
 *
 * Usage:
 *   npm install ethers @openzeppelin/merkle-tree
 *   npx ts-node build-merkle-tree.ts
 *
 * Or with Bun:
 *   bun build-merkle-tree.ts
 */

import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import { ethers } from "ethers";

// ─── Base Mainnet Addresses ───────────────────────────────────────────────────
const BASE_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const BASE_AUSDC = "0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB";
const BASE_AAVE_POOL = "0xA238Dd80C259a72e81d7e4674A963d919642167C";

// These will be known after deploying Step 2 and Step 6a
const VAULT_ADDRESS = process.env.VAULT_ADDRESS ?? "0x0000000000000000000000000000000000000000";
const DECODER_ADDRESS = process.env.DECODER_ADDRESS ?? "0x0000000000000000000000000000000000000000";
const MANAGER_ADDRESS = process.env.MANAGER_ADDRESS ?? "0x0000000000000000000000000000000000000000";

// ─── Aave V3 Function Selectors ───────────────────────────────────────────────
const SUPPLY_SELECTOR = ethers.id("supply(address,uint256,address,uint16)").slice(0, 10);
const WITHDRAW_SELECTOR = ethers.id("withdraw(address,uint256,address)").slice(0, 10);

console.log("Aave supply selector:  ", SUPPLY_SELECTOR);   // 0x617ba037
console.log("Aave withdraw selector:", WITHDRAW_SELECTOR); // 0x69328dec

/**
 * Each leaf in the Veda Merkle tree is a packed encoding of:
 *   (address decoderAndSanitizer, address target, bytes4 selector, bytes decodedData)
 *
 * For Aave supply(asset, amount, onBehalfOf, referralCode):
 *   - asset must be USDC (whitelisted)
 *   - onBehalfOf must be the vault
 *   - amount is unconstrained (checked by Manager logic, not Merkle)
 *   - referralCode is unconstrained
 *
 * For Aave withdraw(asset, amount, to):
 *   - asset must be USDC
 *   - to must be the Manager or YieldManager
 *   - amount is unconstrained
 */

interface MerkleLeaf {
  description: string;
  decoder: string;
  target: string;
  selector: string;
  addressArguments: string[];
}

const leaves: MerkleLeaf[] = [
  {
    description: "Aave V3 supply USDC on behalf of vault",
    decoder: DECODER_ADDRESS,
    target: BASE_AAVE_POOL,
    selector: SUPPLY_SELECTOR,
    addressArguments: [
      BASE_USDC,      // asset (must be USDC)
      VAULT_ADDRESS,  // onBehalfOf (must be vault)
    ],
  },
  {
    description: "Aave V3 withdraw USDC to Manager",
    decoder: DECODER_ADDRESS,
    target: BASE_AAVE_POOL,
    selector: WITHDRAW_SELECTOR,
    addressArguments: [
      BASE_USDC,       // asset (must be USDC)
      MANAGER_ADDRESS, // to (withdraw destination)
    ],
  },
  {
    description: "Aave V3 withdraw aUSDC (aToken approval for vault operations)",
    decoder: DECODER_ADDRESS,
    target: BASE_AUSDC,
    selector: ethers.id("approve(address,uint256)").slice(0, 10),
    addressArguments: [
      BASE_AAVE_POOL, // spender must be Aave Pool
    ],
  },
];

// ─── Build the Tree ───────────────────────────────────────────────────────────

/**
 * Encodes a leaf for the Veda Merkle verification scheme.
 * The ManagerWithMerkleVerification encodes leaves as:
 *   keccak256(abi.encodePacked(decoder, target, selector, decodedAddresses...))
 *
 * This matches the Veda Arctic implementation leaf encoding.
 */
function encodeLeaf(leaf: MerkleLeaf): string {
  const packed = ethers.solidityPacked(
    ["address", "address", "bytes4", ...leaf.addressArguments.map(() => "address")],
    [leaf.decoder, leaf.target, leaf.selector, ...leaf.addressArguments]
  );
  return ethers.keccak256(packed);
}

const leafValues = leaves.map((leaf) => [encodeLeaf(leaf)]);

const tree = StandardMerkleTree.of(leafValues, ["bytes32"]);

console.log("\n════════════ MERKLE TREE ════════════");
console.log("Root:", tree.root);
console.log("\nLeaves:");
for (const [i, v] of tree.entries()) {
  const proof = tree.getProof(i);
  console.log(`  [${i}] ${leaves[i].description}`);
  console.log(`       Hash:  ${v[0]}`);
  console.log(`       Proof: ${JSON.stringify(proof)}`);
}

console.log("\n════════════ FORGE COMMAND ════════════");
console.log(`cast send $MANAGER_ADDRESS \\`);
console.log(`  "setMerkleRoot(bytes32,string)" \\`);
console.log(`  "${tree.root}" \\`);
console.log(`  "ipfs://YOUR_IPFS_CID" \\`);
console.log(`  --rpc-url $BASE_RPC_URL \\`);
console.log(`  --private-key $PRIVATE_KEY`);

console.log("\nSave this root in your deployment manifest and set it in the Manager.");
