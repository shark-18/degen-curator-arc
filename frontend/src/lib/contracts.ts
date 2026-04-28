import { type Address } from "viem";

export const PRINCIPAL_VAULT = (process.env.NEXT_PUBLIC_PRINCIPAL_VAULT || "0x0000000000000000000000000000000000000000") as Address;
export const LOTTERY_TREASURY = (process.env.NEXT_PUBLIC_LOTTERY_TREASURY || "0x0000000000000000000000000000000000000000") as Address;
export const POSITION_MANAGER = (process.env.NEXT_PUBLIC_POSITION_MANAGER || "0x0000000000000000000000000000000000000000") as Address;
export const USDC = (process.env.NEXT_PUBLIC_USDC || "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913") as Address;

// Minimal ABIs (only the functions the dashboard needs)
export const PRINCIPAL_VAULT_ABI = [
  { type: "function", name: "deposit", stateMutability: "nonpayable",
    inputs: [{ name: "assets", type: "uint256" }, { name: "receiver", type: "address" }],
    outputs: [{ type: "uint256" }] },
  { type: "function", name: "redeem", stateMutability: "nonpayable",
    inputs: [{ name: "shares", type: "uint256" }, { name: "receiver", type: "address" }, { name: "owner", type: "address" }],
    outputs: [{ type: "uint256" }] },
  { type: "function", name: "balanceOf", stateMutability: "view",
    inputs: [{ name: "account", type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "convertToAssets", stateMutability: "view",
    inputs: [{ name: "shares", type: "uint256" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "principalHighWater", stateMutability: "view",
    inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "depositCap", stateMutability: "view",
    inputs: [], outputs: [{ type: "uint128" }] },
  { type: "function", name: "depositorCount", stateMutability: "view",
    inputs: [], outputs: [{ type: "uint32" }] },
  { type: "function", name: "depositorCap", stateMutability: "view",
    inputs: [], outputs: [{ type: "uint32" }] },
  { type: "function", name: "minDeposit", stateMutability: "view",
    inputs: [], outputs: [{ type: "uint128" }] },
  { type: "function", name: "paused", stateMutability: "view",
    inputs: [], outputs: [{ type: "bool" }] },
  { type: "function", name: "morphoBalanceInAssets", stateMutability: "view",
    inputs: [], outputs: [{ type: "uint256" }] },
] as const;

export const LOTTERY_TREASURY_ABI = [
  { type: "function", name: "claim", stateMutability: "nonpayable",
    inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "claimableOf", stateMutability: "view",
    inputs: [{ name: "user", type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "globalShareIndex", stateMutability: "view",
    inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "totalAssetsAtRisk", stateMutability: "view",
    inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "cumulativeYieldSwept", stateMutability: "view",
    inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "cumulativeStrategySpend", stateMutability: "view",
    inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "userFirstHoldTimestamp", stateMutability: "view",
    inputs: [{ name: "user", type: "address" }], outputs: [{ type: "uint64" }] },
] as const;

export const ERC20_ABI = [
  { type: "function", name: "balanceOf", stateMutability: "view",
    inputs: [{ name: "account", type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "approve", stateMutability: "nonpayable",
    inputs: [{ name: "spender", type: "address" }, { name: "amount", type: "uint256" }],
    outputs: [{ type: "bool" }] },
  { type: "function", name: "allowance", stateMutability: "view",
    inputs: [{ name: "owner", type: "address" }, { name: "spender", type: "address" }],
    outputs: [{ type: "uint256" }] },
] as const;
