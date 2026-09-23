import { decodeFunctionData } from "viem";
import { describe, expect, it } from "vitest";
import { legacyVaultAbi, vaultAbi } from "../src/abis";
import { buildExecutionPlan } from "../src/planner";
import { amountAfterTransferTax, getAmountOut } from "../src/policy";
import { BuybackReadiness } from "../src/types";
import type { AssetSnapshot, KeeperConfig, PairSample } from "../src/types";

const token = "0x1111111111111111111111111111111111111111";
const taxProcessor = "0x2222222222222222222222222222222222222222";
const vault = "0x3333333333333333333333333333333333333333";
const pair = "0x4444444444444444444444444444444444444444";
const wbnb = "0x5555555555555555555555555555555555555555";

const config: KeeperConfig = {
  chainId: 97,
  readRpcUrl: "https://read.example/",
  sendRpcUrl: "https://send.example/",
  coordinator: "0x6666666666666666666666666666666666666666",
  keeper: "0x9f87b1973361b23387D7F1b536484543a5ea1eFB",
  discoveryPageSize: 8,
  maxAssetsPerRun: 8,
  checkIntervalSeconds: 60,
  ammFeeBps: 25,
  taxMaxReserveBps: 30,
  slippageBps: 100,
  maxPriceDeviationBps: 300,
  anchorMinAgeSeconds: 300,
  anchorMaxAgeSeconds: 3600,
  minAnchorSamples: 3,
  deadlineSeconds: 300,
  gasPriceMultiplierBps: 12_000,
  maxGasPriceWei: 10_000_000_000n,
  minKeeperBalanceWei: 3_000_000_000_000_000n,
  pendingRetrySeconds: 90,
};

function database(samples: PairSample[]): D1Database {
  return {
    prepare: () => ({
      bind: () => ({
        all: async () => ({
          results: samples.map((sample) => ({
            block_number: Number(sample.blockNumber),
            sampled_at: sample.sampledAt,
            reserve_token: sample.reserveToken.toString(),
            reserve_wbnb: sample.reserveWbnb.toString(),
          })),
        }),
      }),
    }),
  } as unknown as D1Database;
}

function snapshot(overrides: Partial<AssetSnapshot> = {}): AssetSnapshot {
  return {
    asset: {
      chain_id: 97,
      token,
      tax_processor: taxProcessor,
      vault,
      pair,
      wbnb,
      status: "active",
      next_check_at: 0,
      last_checked_at: null,
      last_error: null,
    },
    blockNumber: 1_000n,
    blockTimestamp: 10_000,
    reserves: {
      blockNumber: 1_000n,
      sampledAt: 10_000,
      reserveToken: 1_000_000n,
      reserveWbnb: 100_000n,
    },
    poolState: {
      state: 3,
      buyTaxRate: 400,
      sellTaxRate: 500,
      taxExpirationTime: 20_000,
    },
    pendingTax: 10_000n,
    feeConfig: {
      marketBps: 10_000,
      deflationBps: 0,
      lpBps: 0,
      dividendBps: 0,
      feeRate: 0,
      commissionBps: 0,
    },
    lpTokenBalance: 0n,
    lpQuoteBalance: 0n,
    pairTotalSupply: 10_000n,
    vaultVersion: 2,
    vaultExecutableAmount: 1_000n,
    vaultReadiness: BuybackReadiness.Ready,
    vaultMode: 0,
    ...overrides,
  };
}

function anchors(reserveToken = 1_000_000n, reserveWbnb = 100_000n): PairSample[] {
  return [6_500, 7_000, 7_500].map((sampledAt, index) => ({
    blockNumber: BigInt(900 + index),
    sampledAt,
    reserveToken,
    reserveWbnb,
  }));
}

describe("execution planning", () => {
  it("does not plan until the minimum number of historical samples exists", async () => {
    await expect(buildExecutionPlan(database(anchors().slice(0, 2)), config, snapshot(), "tax", 10_000)).resolves.toBeNull();
  });

  it("caps one tax liquidation at 0.3% of the token reserve and accounts for sell tax", async () => {
    const plan = await buildExecutionPlan(database(anchors()), config, snapshot(), "tax", 10_000);
    const cappedInput = 3_000n;
    const quote = getAmountOut(amountAfterTransferTax(cappedInput, 500), 1_000_000n, 100_000n, 25);

    expect(plan).not.toBeNull();
    expect(plan?.amountIn).toBe(cappedInput);
    expect(plan?.currentQuote).toBe(quote);
    expect(plan?.minimumOut).toBe((quote * 9_900n) / 10_000n);
    expect(plan?.target).toBe(taxProcessor);
  });

  it("refuses a tax liquidation when spot price is manipulated away from the historical anchor", async () => {
    const manipulated = snapshot({
      reserves: {
        blockNumber: 1_000n,
        sampledAt: 10_000,
        reserveToken: 1_000_000n,
        reserveWbnb: 70_000n,
      },
    });
    await expect(buildExecutionPlan(database(anchors()), config, manipulated, "tax", 10_000)).resolves.toBeNull();
  });

  it("quotes only the four-channel portion that is actually swapped", async () => {
    const plan = await buildExecutionPlan(
      database(anchors()),
      config,
      snapshot({
        feeConfig: {
          marketBps: 4_000,
          deflationBps: 1_000,
          lpBps: 2_000,
          dividendBps: 3_000,
          feeRate: 0,
          commissionBps: 0,
        },
      }),
      "tax",
      10_000,
    );

    const grossBatch = 3_000n;
    const swapAmount = 2_400n;
    const quote = getAmountOut(amountAfterTransferTax(swapAmount, 500), 1_000_000n, 100_000n, 25);
    expect(plan?.amountIn).toBe(grossBatch);
    expect(plan?.currentQuote).toBe(quote);
  });

  it("plans an all-deflation batch without inventing a swap minimum", async () => {
    const plan = await buildExecutionPlan(
      database(anchors()),
      config,
      snapshot({
        feeConfig: {
          marketBps: 0,
          deflationBps: 10_000,
          lpBps: 0,
          dividendBps: 0,
          feeRate: 0,
          commissionBps: 0,
        },
      }),
      "tax",
      10_000,
    );

    expect(plan).not.toBeNull();
    expect(plan?.currentQuote).toBe(0n);
    expect(plan?.minimumOut).toBe(0n);
  });

  it("plans bounded LP minting from both reserved ledgers", async () => {
    const plan = await buildExecutionPlan(
      database(anchors()),
      config,
      snapshot({ lpTokenBalance: 3_000n, lpQuoteBalance: 1_000n, pairTotalSupply: 100_000n }),
      "liquidity",
      10_000,
    );

    expect(plan).not.toBeNull();
    expect(plan?.target).toBe(taxProcessor);
    expect(plan?.amountIn).toBe(3_000n);
    expect(plan?.currentQuote).toBe(285n);
    expect(plan?.minimumOut).toBe(282n);
    expect(plan?.secondaryMinimumOut).toBeGreaterThan(0n);
  });

  it("ignores zero-reserve samples when building the historical anchor", async () => {
    // 真实场景：代币先创建、后加池，加池前的样本储备为 0。它们不含价格信息，
    // 若计入中位数会把锚点拉到 0，导致 Keeper 在已有足够有效样本时仍然不成交。
    const zeroSamples: PairSample[] = [8_000, 8_100, 8_200, 8_300].map((sampledAt, index) => ({
      blockNumber: BigInt(950 + index),
      sampledAt,
      reserveToken: 0n,
      reserveWbnb: 0n,
    }));
    const plan = await buildExecutionPlan(database([...anchors(), ...zeroSamples]), config, snapshot(), "tax", 10_000);

    expect(plan).not.toBeNull();
    expect(plan?.minimumOut).toBe(((plan?.currentQuote ?? 0n) * 9_900n) / 10_000n);
  });

  it("still refuses when fewer than the minimum meaningful samples exist", async () => {
    const zeroSamples: PairSample[] = [7_800, 8_000, 8_200].map((sampledAt, index) => ({
      blockNumber: BigInt(960 + index),
      sampledAt,
      reserveToken: 0n,
      reserveWbnb: 0n,
    }));
    const plan = await buildExecutionPlan(
      database([...anchors().slice(0, 2), ...zeroSamples]),
      config,
      snapshot(),
      "tax",
      10_000,
    );

    expect(plan).toBeNull();
  });

  it("produces independent protected outputs for an LP buyback", async () => {
    const plan = await buildExecutionPlan(database(anchors()), config, snapshot({ vaultMode: 1 }), "buyback", 10_000);

    expect(plan).not.toBeNull();
    expect(plan?.target).toBe(vault);
    expect(plan?.minimumOut).toBeGreaterThan(0n);
    expect(plan?.secondaryMinimumOut).toBeGreaterThan(0n);
    expect(plan?.secondaryMinimumOut).toBeLessThan(plan?.minimumOut ?? 0n);
    expect(plan?.deadline).toBe(10_300n);
  });

  it("binds the exact previewed BNB input into buyback calldata", async () => {
    const plan = await buildExecutionPlan(
      database(anchors()),
      config,
      snapshot({ vaultExecutableAmount: 777n }),
      "buyback",
      10_000,
    );

    expect(plan?.amountIn).toBe(777n);
    const decoded = decodeFunctionData({ abi: vaultAbi, data: plan!.data });
    expect(decoded.functionName).toBe("executeBuyback");
    expect(decoded.args?.[0]).toBe(777n);
  });

  it("does not plan a buyback when the vault reports a non-ready reason", async () => {
    await expect(
      buildExecutionPlan(
        database(anchors()),
        config,
        snapshot({
          vaultExecutableAmount: 0n,
          vaultReadiness: BuybackReadiness.ReserveCapBelowMinimum,
        }),
        "buyback",
        10_000,
      ),
    ).resolves.toBeNull();
  });

  it("keeps the legacy three-argument execution ABI for an old ready vault", async () => {
    const plan = await buildExecutionPlan(
      database(anchors()),
      config,
      snapshot({ vaultVersion: 1 }),
      "buyback",
      10_000,
    );

    const decoded = decodeFunctionData({ abi: legacyVaultAbi, data: plan!.data });
    expect(decoded.functionName).toBe("executeBuyback");
    expect(decoded.args).toHaveLength(3);
  });
});
