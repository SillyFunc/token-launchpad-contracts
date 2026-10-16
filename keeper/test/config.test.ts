import { describe, expect, it } from "vitest";
import { getConfig } from "../src/config";
import type { Env } from "../src/types";

const keeper = "0x9f87b1973361b23387D7F1b536484543a5ea1eFB";
const coordinator = "0x1111111111111111111111111111111111111111";

function environment(overrides: Partial<Env> = {}): Env {
  return {
    CHAIN_ID: "97",
    READ_RPC_URL: "https://read.example",
    SEND_RPC_URL: "https://send.example",
    COORDINATOR_ADDRESS: coordinator,
    KEEPER_ADDRESS: keeper,
    KEEPER_PRIVATE_KEY: "unused",
    ...overrides,
  } as Env;
}

describe("keeper configuration guards", () => {
  it("uses legacy reads unless a valid Reader is explicitly configured", () => {
    expect(getConfig(environment()).readerAddress).toBeUndefined();
    expect(getConfig(environment({ READER_ADDRESS: "" })).readerAddress).toBeUndefined();
    expect(getConfig(environment({ READER_ADDRESS: coordinator })).readerAddress).toBe(coordinator);
    expect(() => getConfig(environment({ READER_ADDRESS: "0x0000000000000000000000000000000000000000" })))
      .toThrow("READER_ADDRESS");
  });
  it("accepts the dedicated BSC testnet keeper", () => {
    const config = getConfig(environment());
    expect(config.chainId).toBe(97);
    expect(config.keeper).toBe(keeper);
  });

  it("rejects a mainnet public-read endpoint reused for sending", () => {
    expect(() =>
      getConfig(
        environment({
          CHAIN_ID: "56",
          READ_RPC_URL: "https://public.example",
          SEND_RPC_URL: "https://public.example",
        }),
      ),
    ).toThrow(/MEV-protected/);
  });

  it("rejects non-BSC chain IDs", () => {
    expect(() => getConfig(environment({ CHAIN_ID: "1" }))).toThrow(/Only BSC/);
  });

  it("defaults to economic gas limits, batched execution and bounded hourly spending", () => {
    const config = getConfig(environment());
    expect(config.maxGasCostBps).toBe(1_000);
    expect(config.taxExecutionIntervalSeconds).toBe(900);
    expect(config.liquidityExecutionIntervalSeconds).toBe(900);
    expect(config.gasBudgetWindowSeconds).toBe(3_600);
    expect(config.maxTokenGasPerWindowWei).toBe(1_000_000_000_000_000n);
    expect(config.maxTotalGasPerWindowWei).toBe(10_000_000_000_000_000n);
  });

  it("loads explicit gas policy settings without changing price protections", () => {
    const config = getConfig(
      environment({
        MAX_GAS_COST_BPS: "500",
        TAX_EXECUTION_INTERVAL_SECONDS: "1800",
        LIQUIDITY_EXECUTION_INTERVAL_SECONDS: "1200",
        GAS_BUDGET_WINDOW_SECONDS: "7200",
        MAX_TOKEN_GAS_PER_WINDOW_WEI: "2000000000000000",
        MAX_TOTAL_GAS_PER_WINDOW_WEI: "20000000000000000",
      }),
    );
    expect(config.maxGasCostBps).toBe(500);
    expect(config.taxExecutionIntervalSeconds).toBe(1_800);
    expect(config.liquidityExecutionIntervalSeconds).toBe(1_200);
    expect(config.gasBudgetWindowSeconds).toBe(7_200);
    expect(config.maxTokenGasPerWindowWei).toBe(2_000_000_000_000_000n);
    expect(config.maxTotalGasPerWindowWei).toBe(20_000_000_000_000_000n);
    expect(config.taxMaxReserveBps).toBe(30);
    expect(config.slippageBps).toBe(100);
    expect(config.maxPriceDeviationBps).toBe(300);
  });

  it.each([
    ["MAX_GAS_COST_BPS", "0"],
    ["MAX_GAS_COST_BPS", "10001"],
    ["TAX_EXECUTION_INTERVAL_SECONDS", "0"],
    ["LIQUIDITY_EXECUTION_INTERVAL_SECONDS", "1.5"],
    ["GAS_BUDGET_WINDOW_SECONDS", "-1"],
    ["MAX_TOKEN_GAS_PER_WINDOW_WEI", "0"],
    ["MAX_TOKEN_GAS_PER_WINDOW_WEI", "0.001"],
    ["MAX_TOTAL_GAS_PER_WINDOW_WEI", "-1"],
  ])("rejects invalid economic policy %s=%s", (name, value) => {
    expect(() => getConfig(environment({ [name]: value }))).toThrow(name);
  });

  it("rejects a per-token budget larger than the global budget", () => {
    expect(() =>
      getConfig(environment({ MAX_TOKEN_GAS_PER_WINDOW_WEI: "20000000000000000" })),
    ).toThrow(/MAX_TOKEN_GAS_PER_WINDOW_WEI/);
  });
});
