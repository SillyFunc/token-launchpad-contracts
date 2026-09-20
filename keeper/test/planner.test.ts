import { describe, expect, it } from "vitest";
import { buildExecutionPlan } from "../src/planner";
import { amountAfterTransferTax, getAmountOut } from "../src/policy";
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
    vaultCanExecute: true,
    vaultBuybackAmount: 1_000n,
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

  it("produces independent protected outputs for an LP buyback", async () => {
    const plan = await buildExecutionPlan(database(anchors()), config, snapshot({ vaultMode: 1 }), "buyback", 10_000);

    expect(plan).not.toBeNull();
    expect(plan?.target).toBe(vault);
    expect(plan?.minimumOut).toBeGreaterThan(0n);
    expect(plan?.secondaryMinimumOut).toBeGreaterThan(0n);
    expect(plan?.secondaryMinimumOut).toBeLessThan(plan?.minimumOut ?? 0n);
    expect(plan?.deadline).toBe(10_300n);
  });
});
