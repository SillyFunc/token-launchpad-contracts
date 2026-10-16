import { getAddress, zeroAddress, type Address, type ContractFunctionReturnType } from "viem";
import { executionControls } from "./controls";
import { readerAbi } from "./reader-abi";
import { contractCall } from "./rpc";
import { BuybackReadiness } from "./types";
import type { AssetRow, AssetSnapshot, KeeperConfig } from "./types";

export type TokenSnapshot = ContractFunctionReturnType<typeof readerAbi, "view", "getTokenSnapshot">;

function safeNumber(value: bigint, name: string): number {
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < 0) throw new Error(`Reader returned unsafe ${name}`);
  return number;
}

/** Shared named Reader struct for DApps and Keeper; never probes or falls back to another ABI. */
export async function getTokenSnapshot(
  config: Pick<KeeperConfig, "readRpcUrl" | "readerAddress">,
  token: Address,
): Promise<TokenSnapshot> {
  if (!config.readerAddress) throw new Error("READER_ADDRESS is required for Reader inspection");
  const state = await contractCall(config.readRpcUrl, {
    address: config.readerAddress, abi: readerAbi, functionName: "getTokenSnapshot", args: [token],
  }) as TokenSnapshot;
  if (state.schemaVersion !== 1) throw new Error(`Unsupported Reader schema ${state.schemaVersion}`);
  executionControls(state.controls.executionFlags);
  if (state.pool.state > 4 || state.buyback.mode > 1 || state.buyback.readiness > BuybackReadiness.Paused) {
    throw new Error("Reader returned an unsupported pool or buyback state");
  }
  if (getAddress(state.contracts.token) !== getAddress(token)) throw new Error("Reader returned a different token");
  return state;
}

/** Adapt the same shared object to the established planner/signer model. */
export async function inspectReaderAsset(config: KeeperConfig, asset: AssetRow): Promise<AssetSnapshot> {
  const state = await getTokenSnapshot(config, asset.token);
  const contracts = state.contracts;
  if (
    getAddress(contracts.token) !== getAddress(asset.token) ||
    getAddress(contracts.pair) !== getAddress(asset.pair) ||
    getAddress(contracts.taxProcessor) !== getAddress(asset.tax_processor) ||
    getAddress(contracts.wbnb) !== getAddress(asset.wbnb) ||
    getAddress(contracts.vault) !== getAddress(asset.vault ?? zeroAddress)
  ) throw new Error("Reader contracts do not match the D1 asset registry");
  const controls = executionControls(state.controls.executionFlags);
  const blockTimestamp = safeNumber(state.blockTimestamp, "blockTimestamp");
  return {
    asset, controls, blockNumber: state.blockNumber, blockTimestamp,
    reserves: {
      blockNumber: state.blockNumber, sampledAt: blockTimestamp,
      reserveToken: state.pool.reserveToken, reserveWbnb: state.pool.reserveWbnb,
    },
    poolState: {
      state: state.pool.state, buyTaxRate: state.pool.buyTaxRate, sellTaxRate: state.pool.sellTaxRate,
      taxExpirationTime: safeNumber(state.pool.taxExpirationTime, "taxExpirationTime"),
    },
    pendingTax: state.tax.pendingAmount,
    feeConfig: {
      marketBps: state.tax.feeConfig.marketBps, deflationBps: state.tax.feeConfig.deflationBps,
      lpBps: state.tax.feeConfig.lpBps, dividendBps: state.tax.feeConfig.dividendBps,
      feeRate: state.tax.feeConfig.feeRate, commissionBps: state.tax.feeConfig.commissionBps,
    },
    lpTokenBalance: state.liquidity.pendingToken,
    lpQuoteBalance: state.liquidity.pendingWbnb,
    pairTotalSupply: state.pool.totalSupply,
    vaultVersion: contracts.vault === zeroAddress ? 0 : 2,
    vaultExecutableAmount: state.buyback.executableAmount,
    vaultReadiness: state.buyback.readiness,
    vaultMode: state.buyback.mode,
    vaultBalance: state.buyback.balance,
    vaultNextExecuteTime: safeNumber(state.buyback.nextExecuteTime, "nextExecuteTime"),
  };
}
