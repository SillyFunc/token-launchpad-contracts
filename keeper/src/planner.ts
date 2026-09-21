import { encodeFunctionData, getAddress, zeroAddress, type Address } from "viem";
import { pairAbi, taxProcessorAbi, tokenAbi, vaultAbi } from "./abis";
import { loadAnchorSamples, storeSample } from "./db";
import {
  activeTaxRate,
  amountAfterTransferTax,
  deviationBps,
  getAmountOut,
  medianBigInt,
  minBigInt,
  protectedMinimumOut,
} from "./policy";
import { batchContractCalls, getLatestBlock, type ContractCall } from "./rpc";
import type {
  AssetRow,
  AssetSnapshot,
  ExecutionPlan,
  JobKind,
  KeeperConfig,
  PairSample,
  PlannedJob,
} from "./types";

const LP_SWAP_BPS = 4_990n;
const BPS = 10_000n;

type PoolStateResult = readonly [number, number, number, boolean, bigint, bigint, number | bigint];
type ReservesResult = readonly [bigint, bigint, number];
type FeeConfigObject = {
  marketBps: number;
  deflationBps: number;
  lpBps: number;
  dividendBps: number;
  feeRate: number;
  commissionBps: number;
};
type FeeConfigResult = readonly [number, number, number, number, number, boolean, number, Address] | FeeConfigObject;

function configNumber(config: FeeConfigResult, name: keyof FeeConfigObject, index: number) {
  const value = Array.isArray(config) ? config[index] : (config as FeeConfigObject)[name];
  return numberValue(value as number | bigint);
}

function numberValue(value: number | bigint): number {
  const result = Number(value);
  if (!Number.isSafeInteger(result)) throw new Error("unsafe integer returned by contract");
  return result;
}

export async function inspectAsset(config: KeeperConfig, asset: AssetRow): Promise<AssetSnapshot> {
  const block = await getLatestBlock(config.readRpcUrl);
  const calls: ContractCall[] = [
    { address: asset.pair, abi: pairAbi, functionName: "token0" },
    { address: asset.pair, abi: pairAbi, functionName: "token1" },
    { address: asset.pair, abi: pairAbi, functionName: "getReserves" },
    { address: asset.token, abi: tokenAbi, functionName: "poolState" },
    { address: asset.tax_processor, abi: taxProcessorAbi, functionName: "pendingTaxTokens" },
    { address: asset.tax_processor, abi: taxProcessorAbi, functionName: "feeConfigV2" },
    { address: asset.tax_processor, abi: taxProcessorAbi, functionName: "lpTokenBalance" },
    { address: asset.tax_processor, abi: taxProcessorAbi, functionName: "lpQuoteBalance" },
    { address: asset.pair, abi: pairAbi, functionName: "totalSupply" },
  ];
  if (asset.vault) {
    calls.push(
      { address: asset.vault, abi: vaultAbi, functionName: "canExecuteBuyback" },
      { address: asset.vault, abi: vaultAbi, functionName: "buybackAmount" },
      { address: asset.vault, abi: vaultAbi, functionName: "mode" },
    );
  }
  const values = await batchContractCalls(config.readRpcUrl, calls, block.tag);
  const token0 = getAddress(String(values[0]));
  const token1 = getAddress(String(values[1]));
  if (
    !(
      (token0 === getAddress(asset.token) && token1 === getAddress(asset.wbnb)) ||
      (token1 === getAddress(asset.token) && token0 === getAddress(asset.wbnb))
    )
  ) {
    throw new Error(`Pair ${asset.pair} is not the registered token/WBNB pair`);
  }

  const reserves = values[2] as ReservesResult;
  const tokenIsToken0 = token0 === getAddress(asset.token);
  const sample: PairSample = {
    blockNumber: block.number,
    sampledAt: block.timestamp,
    reserveToken: tokenIsToken0 ? reserves[0] : reserves[1],
    reserveWbnb: tokenIsToken0 ? reserves[1] : reserves[0],
  };
  const pool = values[3] as PoolStateResult;
  const feeConfig = values[5] as FeeConfigResult;
  return {
    asset,
    blockNumber: block.number,
    blockTimestamp: block.timestamp,
    reserves: sample,
    poolState: {
      state: numberValue(pool[0]),
      buyTaxRate: numberValue(pool[1]),
      sellTaxRate: numberValue(pool[2]),
      taxExpirationTime: numberValue(pool[5]),
    },
    pendingTax: values[4] as bigint,
    feeConfig: {
      marketBps: configNumber(feeConfig, "marketBps", 0),
      deflationBps: configNumber(feeConfig, "deflationBps", 1),
      lpBps: configNumber(feeConfig, "lpBps", 2),
      dividendBps: configNumber(feeConfig, "dividendBps", 3),
      feeRate: configNumber(feeConfig, "feeRate", 4),
      commissionBps: configNumber(feeConfig, "commissionBps", 6),
    },
    lpTokenBalance: values[6] as bigint,
    lpQuoteBalance: values[7] as bigint,
    pairTotalSupply: values[8] as bigint,
    vaultCanExecute: asset.vault ? (values[9] as boolean) : false,
    vaultBuybackAmount: asset.vault ? (values[10] as bigint) : 0n,
    vaultMode: asset.vault ? numberValue(values[11] as number | bigint) : 0,
  };
}

export function taxSwapAmount(amount: bigint, config: AssetSnapshot["feeConfig"]): bigint {
  const fee = (amount * BigInt(config.feeRate)) / BPS;
  const afterFee = amount - fee;
  const commission = (afterFee * BigInt(config.commissionBps)) / BPS;
  const distributable = afterFee - commission;
  const market = (distributable * BigInt(config.marketBps)) / BPS;
  const deflation = (distributable * BigInt(config.deflationBps)) / BPS;
  const lp = (distributable * BigInt(config.lpBps)) / BPS;
  const dividend = distributable - market - deflation - lp;
  return fee + commission + market + (lp - lp / 2n) + dividend;
}

function quoteTax(
  amountIn: bigint,
  reserveToken: bigint,
  reserveWbnb: bigint,
  sellTaxBps: number,
  ammFeeBps: number,
): bigint {
  return getAmountOut(amountAfterTransferTax(amountIn, sellTaxBps), reserveToken, reserveWbnb, ammFeeBps);
}

function quoteBuyback(
  bnbIn: bigint,
  reserveToken: bigint,
  reserveWbnb: bigint,
  buyTaxBps: number,
  ammFeeBps: number,
): bigint {
  const gross = getAmountOut(bnbIn, reserveWbnb, reserveToken, ammFeeBps);
  return amountAfterTransferTax(gross, buyTaxBps);
}

function quoteLiquidity(tokenAmount: bigint, reserveToken: bigint, reserveWbnb: bigint): bigint {
  if (tokenAmount <= 0n || reserveToken <= 0n || reserveWbnb <= 0n) return 0n;
  return (tokenAmount * reserveWbnb) / reserveToken;
}

async function anchorSamples(db: D1Database, config: KeeperConfig, snapshot: AssetSnapshot): Promise<PairSample[]> {
  return loadAnchorSamples(
    db,
    config.chainId,
    snapshot.asset.pair,
    snapshot.blockTimestamp - config.anchorMaxAgeSeconds,
    snapshot.blockTimestamp - config.anchorMinAgeSeconds,
    15,
  );
}

export async function storeCurrentSample(db: D1Database, config: KeeperConfig, snapshot: AssetSnapshot): Promise<void> {
  await storeSample(db, config.chainId, snapshot.asset.pair, snapshot.reserves);
}

export async function buildExecutionPlan(
  db: D1Database,
  config: KeeperConfig,
  snapshot: AssetSnapshot,
  kind: JobKind,
  now: number,
): Promise<ExecutionPlan | null> {
  const history = await anchorSamples(db, config, snapshot);
  if (history.length < config.minAnchorSamples) return null;
  if (snapshot.reserves.reserveToken === 0n || snapshot.reserves.reserveWbnb === 0n) return null;

  const buyTax = activeTaxRate(
    snapshot.poolState.state,
    snapshot.poolState.buyTaxRate,
    snapshot.blockTimestamp,
    snapshot.poolState.taxExpirationTime,
  );
  const sellTax = activeTaxRate(
    snapshot.poolState.state,
    snapshot.poolState.sellTaxRate,
    snapshot.blockTimestamp,
    snapshot.poolState.taxExpirationTime,
  );
  const deadline = BigInt(snapshot.blockTimestamp + config.deadlineSeconds);
  let target: Address;
  let amountIn: bigint;
  let currentQuote: bigint;
  let anchorQuote: bigint;
  let minimumOut: bigint;
  let secondaryMinimumOut = 0n;
  let data;

  if (kind === "tax") {
    if (snapshot.pendingTax === 0n) return null;
    const reserveCap = (snapshot.reserves.reserveToken * BigInt(config.taxMaxReserveBps)) / BPS;
    amountIn = minBigInt(snapshot.pendingTax, reserveCap);
    if (amountIn === 0n) return null;
    const swapAmount = taxSwapAmount(amountIn, snapshot.feeConfig);
    if (swapAmount === 0n) {
      currentQuote = 0n;
      anchorQuote = 0n;
      minimumOut = 0n;
    } else {
      currentQuote = quoteTax(
        swapAmount,
        snapshot.reserves.reserveToken,
        snapshot.reserves.reserveWbnb,
        sellTax,
        config.ammFeeBps,
      );
      anchorQuote = medianBigInt(
        history.map((sample) =>
          quoteTax(swapAmount, sample.reserveToken, sample.reserveWbnb, sellTax, config.ammFeeBps),
        ),
      );
      const protectedOut = protectedMinimumOut(
        currentQuote,
        anchorQuote,
        config.slippageBps,
        config.maxPriceDeviationBps,
      );
      if (!protectedOut.ok) return null;
      minimumOut = protectedOut.minimumOut;
    }
    target = getAddress(snapshot.asset.tax_processor);
    data = encodeFunctionData({
      abi: taxProcessorAbi,
      functionName: "processPendingTax",
      args: [amountIn, minimumOut, deadline],
    });
  } else if (kind === "liquidity") {
    if (snapshot.lpTokenBalance === 0n || snapshot.lpQuoteBalance === 0n || snapshot.pairTotalSupply === 0n) {
      return null;
    }
    const reserveCap = (snapshot.reserves.reserveToken * BigInt(config.taxMaxReserveBps)) / BPS;
    amountIn = minBigInt(snapshot.lpTokenBalance, reserveCap);
    let actualToken = amountAfterTransferTax(amountIn, sellTax);
    let neededQuote = quoteLiquidity(actualToken, snapshot.reserves.reserveToken, snapshot.reserves.reserveWbnb);
    if (neededQuote > snapshot.lpQuoteBalance) {
      const actualTokenCap =
        (snapshot.lpQuoteBalance * snapshot.reserves.reserveToken) / snapshot.reserves.reserveWbnb;
      amountIn = (actualTokenCap * BPS) / (BPS - BigInt(sellTax));
      amountIn = minBigInt(amountIn, snapshot.lpTokenBalance);
      actualToken = amountAfterTransferTax(amountIn, sellTax);
      neededQuote = quoteLiquidity(actualToken, snapshot.reserves.reserveToken, snapshot.reserves.reserveWbnb);
    }
    if (amountIn === 0n || actualToken === 0n || neededQuote === 0n || neededQuote > snapshot.lpQuoteBalance) return null;

    currentQuote = neededQuote;
    anchorQuote = medianBigInt(
      history.map((sample) => quoteLiquidity(actualToken, sample.reserveToken, sample.reserveWbnb)),
    );
    if (anchorQuote === 0n || deviationBps(currentQuote, anchorQuote) > BigInt(config.maxPriceDeviationBps)) return null;

    minimumOut = (currentQuote * (BPS - BigInt(config.slippageBps))) / BPS;
    const maximumQuote = (currentQuote * (BPS + BigInt(config.slippageBps))) / BPS + 1n;
    const tokenLiquidity = (actualToken * snapshot.pairTotalSupply) / snapshot.reserves.reserveToken;
    const quoteLiquidityAmount = (currentQuote * snapshot.pairTotalSupply) / snapshot.reserves.reserveWbnb;
    const expectedLiquidity = minBigInt(tokenLiquidity, quoteLiquidityAmount);
    secondaryMinimumOut = (expectedLiquidity * (BPS - BigInt(config.slippageBps))) / BPS;
    if (minimumOut === 0n || secondaryMinimumOut === 0n) return null;

    target = getAddress(snapshot.asset.tax_processor);
    data = encodeFunctionData({
      abi: taxProcessorAbi,
      functionName: "addPendingLiquidity",
      args: [amountIn, minimumOut, maximumQuote, secondaryMinimumOut, deadline],
    });
  } else {
    if (!snapshot.asset.vault || snapshot.asset.vault === zeroAddress || !snapshot.vaultCanExecute) return null;
    amountIn = snapshot.vaultBuybackAmount;
    if (amountIn === 0n) return null;
    currentQuote = quoteBuyback(
      amountIn,
      snapshot.reserves.reserveToken,
      snapshot.reserves.reserveWbnb,
      buyTax,
      config.ammFeeBps,
    );
    anchorQuote = medianBigInt(
      history.map((sample) => quoteBuyback(amountIn, sample.reserveToken, sample.reserveWbnb, buyTax, config.ammFeeBps)),
    );
    const protectedTokenOut = protectedMinimumOut(
      currentQuote,
      anchorQuote,
      config.slippageBps,
      config.maxPriceDeviationBps,
    );
    if (!protectedTokenOut.ok) return null;
    minimumOut = protectedTokenOut.minimumOut;

    if (snapshot.vaultMode === 1) {
      const lpInput = (amountIn * LP_SWAP_BPS) / BPS;
      const currentLpQuote = quoteBuyback(
        lpInput,
        snapshot.reserves.reserveToken,
        snapshot.reserves.reserveWbnb,
        buyTax,
        config.ammFeeBps,
      );
      const anchorLpQuote = medianBigInt(
        history.map((sample) => quoteBuyback(lpInput, sample.reserveToken, sample.reserveWbnb, buyTax, config.ammFeeBps)),
      );
      const protectedLpOut = protectedMinimumOut(
        currentLpQuote,
        anchorLpQuote,
        config.slippageBps,
        config.maxPriceDeviationBps,
      );
      if (!protectedLpOut.ok) return null;
      secondaryMinimumOut = protectedLpOut.minimumOut;
    }
    target = getAddress(snapshot.asset.vault);
    data = encodeFunctionData({
      abi: vaultAbi,
      functionName: "executeBuyback",
      args: [minimumOut, snapshot.vaultMode === 1 ? secondaryMinimumOut : 0n, deadline],
    });
  }

  const job: PlannedJob = {
    id: `${kind}-${snapshot.asset.token.toLowerCase()}-${snapshot.blockNumber.toString()}`,
    kind,
    chainId: config.chainId,
    token: getAddress(snapshot.asset.token),
    target,
    snapshotBlock: snapshot.blockNumber.toString(),
    createdAt: now,
  };
  return { job, target, data, amountIn, currentQuote, anchorQuote, minimumOut, secondaryMinimumOut, deadline };
}
