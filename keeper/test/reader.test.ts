import { afterEach, describe, expect, it, vi } from "vitest";
import { encodeFunctionResult, zeroAddress } from "viem";
import type { ContractFunctionReturnType } from "viem";
import { inspectAsset } from "../src/planner";
import { readerAbi } from "../src/reader-abi";
import { getTokenSnapshot } from "../src/reader";
import { BuybackReadiness } from "../src/types";
import type { AssetRow, KeeperConfig } from "../src/types";

const TOKEN = "0x1111111111111111111111111111111111111111";
const WBNB = "0x2222222222222222222222222222222222222222";
const PAIR = "0x3333333333333333333333333333333333333333";
const PROCESSOR = "0x4444444444444444444444444444444444444444";
const VAULT = "0x5555555555555555555555555555555555555555";
const READER = "0x6666666666666666666666666666666666666666";
const config = { readRpcUrl: "https://read.invalid", readerAddress: READER } as unknown as KeeperConfig;
const asset: AssetRow = {
  chain_id: 97, token: TOKEN, wbnb: WBNB, pair: PAIR, tax_processor: PROCESSOR, vault: VAULT,
  status: "active", next_check_at: 0, last_checked_at: null, last_error: null,
};
type ReaderResult = ContractFunctionReturnType<typeof readerAbi, "view", "getTokenSnapshot">;
function snapshot(): ReaderResult {
  return {
    schemaVersion: 1, blockNumber: 100n, blockTimestamp: 1_700_000_000n,
    contracts: { token: TOKEN, pair: PAIR, taxProcessor: PROCESSOR, vault: VAULT, wbnb: WBNB },
    controls: { executionFlags: 7 },
    pool: { reserveToken: 1_000_000n, reserveWbnb: 50_000n, totalSupply: 10_000n,
      state: 3, buyTaxRate: 500, sellTaxRate: 1_000, taxExpirationTime: 4_800_000_000n },
    tax: { pendingAmount: 4_000n, feeConfig: { marketBps: 4_000, deflationBps: 1_000,
      lpBps: 2_000, dividendBps: 3_000, feeRate: 0, isWeth: true, commissionBps: 0, dividendToken: WBNB } },
    liquidity: { pendingToken: 3_000n, pendingWbnb: 200n },
    buyback: { balance: 1_000n, executableAmount: 500n, mode: 0, readiness: 0,
      nextExecuteTime: 1_700_000_001n },
  };
}
function rpc(result: ReaderResult | null) {
  const fetch = vi.fn(async (_url, options) => {
    const calls = JSON.parse(options.body as string) as { id: number }[];
    return { ok: true, json: async () => calls.map((call) => result
      ? { jsonrpc: "2.0", id: call.id, result: encodeFunctionResult({ abi: readerAbi, functionName: "getTokenSnapshot", result }) }
      : { jsonrpc: "2.0", id: call.id, error: { code: -32000, message: "Reader read reverted" } }) };
  });
  vi.stubGlobal("fetch", fetch);
  return fetch;
}
afterEach(() => vi.unstubAllGlobals());

describe("explicit Reader adapter", () => {
  it("exposes the Reader's named nested struct for DApp reuse", async () => {
    const expected = snapshot();
    const fetch = rpc(expected);
    await expect(getTokenSnapshot(config, TOKEN)).resolves.toEqual(expected);
    expect(fetch).toHaveBeenCalledTimes(1);
  });
  it("maps one eth_call into the shared planning snapshot without extra getter or block reads", async () => {
    const fetch = rpc(snapshot());
    const result = await inspectAsset(config, asset);
    expect(fetch).toHaveBeenCalledTimes(1);
    const calls = JSON.parse(fetch.mock.calls[0][1].body as string);
    expect(calls).toHaveLength(1);
    expect(calls[0]).toMatchObject({ method: "eth_call", params: [expect.objectContaining({ to: READER }), "latest"] });
    expect(result).toMatchObject({ blockNumber: 100n, blockTimestamp: 1_700_000_000,
      pendingTax: 4_000n, lpTokenBalance: 3_000n, lpQuoteBalance: 200n, pairTotalSupply: 10_000n,
      vaultVersion: 2, vaultExecutableAmount: 500n, vaultReadiness: BuybackReadiness.Ready,
      controls: { taxProcessingEnabled: true, liquidityEnabled: true, buybackEnabled: true } });
    expect(result.reserves).toMatchObject({ reserveToken: 1_000_000n, reserveWbnb: 50_000n });
  });

  it("does not downgrade a failed Reader call into legacy reads", async () => {
    const fetch = rpc(null);
    await expect(inspectAsset(config, asset)).rejects.toThrow("Reader read reverted");
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("maps Paused without treating enum 6 as a legacy reserve error", async () => {
    const value = snapshot();
    value.controls.executionFlags = 3;
    value.buyback.readiness = 6;
    value.buyback.executableAmount = 0n;
    rpc(value);
    const result = await inspectAsset(config, asset);
    expect(result.controls.buybackEnabled).toBe(false);
    expect(result.vaultReadiness).toBe(BuybackReadiness.Paused);
  });

  it("rejects unknown schemas, invalid flags and mismatched registry wiring", async () => {
    const value = snapshot();
    value.schemaVersion = 2;
    rpc(value);
    await expect(inspectAsset(config, asset)).rejects.toThrow(/schema/i);
    value.schemaVersion = 1;
    value.controls.executionFlags = 8;
    rpc(value);
    await expect(inspectAsset(config, asset)).rejects.toThrow(/execution flags/i);
    value.controls.executionFlags = 7;
    value.contracts.taxProcessor = READER;
    rpc(value);
    await expect(inspectAsset(config, asset)).rejects.toThrow(/registry/i);
  });

  it("represents no vault explicitly without inventing a deployed vault ABI", async () => {
    const value = snapshot();
    value.contracts.vault = zeroAddress;
    value.buyback = { balance: 0n, executableAmount: 0n, mode: 0, readiness: 0, nextExecuteTime: 0n };
    rpc(value);
    const result = await inspectAsset(config, { ...asset, vault: null });
    expect(result.vaultVersion).toBe(0);
    expect(result.vaultExecutableAmount).toBe(0n);
  });
});
