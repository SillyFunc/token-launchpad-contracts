const feeConfigComponents = [
  { name: "marketBps", type: "uint16" },
  { name: "deflationBps", type: "uint16" },
  { name: "lpBps", type: "uint16" },
  { name: "dividendBps", type: "uint16" },
  { name: "feeRate", type: "uint16" },
  { name: "isWeth", type: "bool" },
  { name: "commissionBps", type: "uint16" },
  { name: "dividendToken", type: "address" },
] as const;

export const readerAbi = [
  { type: "function", name: "coordinator", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  {
    type: "function", name: "getTokenSnapshot", stateMutability: "view",
    inputs: [{ name: "token", type: "address" }],
    outputs: [{ name: "snapshot", type: "tuple", components: [
      { name: "schemaVersion", type: "uint8" },
      { name: "blockNumber", type: "uint256" },
      { name: "blockTimestamp", type: "uint256" },
      { name: "contracts", type: "tuple", components: [
        { name: "token", type: "address" }, { name: "pair", type: "address" },
        { name: "taxProcessor", type: "address" }, { name: "vault", type: "address" },
        { name: "wbnb", type: "address" },
      ] },
      { name: "controls", type: "tuple", components: [{ name: "executionFlags", type: "uint8" }] },
      { name: "pool", type: "tuple", components: [
        { name: "reserveToken", type: "uint256" }, { name: "reserveWbnb", type: "uint256" },
        { name: "totalSupply", type: "uint256" }, { name: "state", type: "uint8" },
        { name: "buyTaxRate", type: "uint16" }, { name: "sellTaxRate", type: "uint16" },
        { name: "taxExpirationTime", type: "uint256" },
      ] },
      { name: "tax", type: "tuple", components: [
        { name: "pendingAmount", type: "uint256" },
        { name: "feeConfig", type: "tuple", components: feeConfigComponents },
      ] },
      { name: "liquidity", type: "tuple", components: [
        { name: "pendingToken", type: "uint256" }, { name: "pendingWbnb", type: "uint256" },
      ] },
      { name: "buyback", type: "tuple", components: [
        { name: "balance", type: "uint256" }, { name: "executableAmount", type: "uint256" },
        { name: "mode", type: "uint8" }, { name: "readiness", type: "uint8" },
        { name: "nextExecuteTime", type: "uint64" },
      ] },
    ] }],
  },
] as const;
