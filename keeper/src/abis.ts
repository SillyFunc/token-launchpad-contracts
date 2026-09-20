export const coordinatorAbi = [
  {
    type: "function",
    name: "getTotalTokenCount",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "count", type: "uint256" }],
  },
  {
    type: "function",
    name: "getAllTokenPresalePairs",
    stateMutability: "view",
    inputs: [
      { name: "offset", type: "uint256" },
      { name: "limit", type: "uint256" },
    ],
    outputs: [
      {
        name: "pairs",
        type: "tuple[]",
        components: [
          { name: "tokenAddress", type: "address" },
          { name: "presaleAddress", type: "address" },
          { name: "creator", type: "address" },
          { name: "createdAt", type: "uint256" },
          { name: "tokenName", type: "string" },
          { name: "tokenSymbol", type: "string" },
          { name: "totalSupply", type: "uint256" },
        ],
      },
    ],
  },
  {
    type: "function",
    name: "tokenVaults",
    stateMutability: "view",
    inputs: [{ name: "token", type: "address" }],
    outputs: [{ name: "vault", type: "address" }],
  },
  {
    type: "function",
    name: "KEEPER_ROLE",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "bytes32" }],
  },
  {
    type: "function",
    name: "hasRole",
    stateMutability: "view",
    inputs: [
      { name: "role", type: "bytes32" },
      { name: "account", type: "address" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
] as const;

export const tokenAbi = [
  {
    type: "function",
    name: "taxProcessor",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "mainPool",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "poolState",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "state", type: "uint8" },
      { name: "buyTaxRate", type: "uint16" },
      { name: "sellTaxRate", type: "uint16" },
      { name: "notLiquidating", type: "bool" },
      { name: "liquidationThreshold", type: "uint96" },
      { name: "taxExpirationTime", type: "uint64" },
      { name: "antiFarmerExpirationTime", type: "uint48" },
    ],
  },
] as const;

export const pairAbi = [
  {
    type: "function",
    name: "token0",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "token1",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "getReserves",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "reserve0", type: "uint112" },
      { name: "reserve1", type: "uint112" },
      { name: "blockTimestampLast", type: "uint32" },
    ],
  },
] as const;

export const taxProcessorAbi = [
  {
    type: "function",
    name: "taxToken",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "weth",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "pendingTaxTokens",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "processPendingTax",
    stateMutability: "nonpayable",
    inputs: [
      { name: "amountIn", type: "uint256" },
      { name: "minQuoteOut", type: "uint256" },
      { name: "deadline", type: "uint64" },
    ],
    outputs: [{ name: "out", type: "uint256" }],
  },
] as const;

export const vaultAbi = [
  {
    type: "function",
    name: "canExecuteBuyback",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "buybackAmount",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "mode",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
  },
  {
    type: "function",
    name: "executeBuyback",
    stateMutability: "nonpayable",
    inputs: [
      { name: "minTokenOut", type: "uint256" },
      { name: "minLpTokenOut", type: "uint256" },
      { name: "deadline", type: "uint64" },
    ],
    outputs: [],
  },
] as const;
