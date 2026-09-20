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
    ADMIN_TOKEN: "unused",
    ...overrides,
  } as Env;
}

describe("keeper configuration guards", () => {
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
});
