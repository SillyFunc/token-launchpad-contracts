// health.ts 是每个 Workflow 轮次的第一步：校验链、Coordinator 代码与 Keeper 角色。
// 撤销 KEEPER_ROLE 后必须在此失败并停止后续资金动作，这里用 mock RPC 覆盖该边界。
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { KeeperConfig } from "../src/types";

const mock = vi.hoisted(() => ({
  chainOk: true,
  codeOk: true,
  role: "0x" + "11".repeat(32),
  authorized: true,
}));

vi.mock("../src/rpc", () => ({
  assertRpcChain: async (_url: string, expected: number) => {
    if (!mock.chainOk) throw new Error(`RPC chain mismatch: expected ${expected}, received 56`);
  },
  assertContractCode: async (_url: string, address: string) => {
    if (!mock.codeOk) throw new Error(`No contract code at ${address}`);
  },
  batchContractCalls: async (_url: string, calls: { functionName: string }[]) =>
    calls.map((call) => (call.functionName === "KEEPER_ROLE" ? mock.role : mock.authorized)),
}));

const { assertEnvironment } = await import("../src/health");

const config = {
  chainId: 97,
  readRpcUrl: "https://rpc.invalid",
  sendRpcUrl: "https://rpc.invalid",
  coordinator: "0x9a7594114f4b79544f7CA00FBd1E902C556BbC47",
  keeper: "0x9f87b1973361b23387D7F1b536484543a5ea1eFB",
} as unknown as KeeperConfig;

describe("assertEnvironment", () => {
  beforeEach(() => {
    mock.chainOk = true;
    mock.codeOk = true;
    mock.authorized = true;
  });

  it("链、代码与角色都正确时通过", async () => {
    await expect(assertEnvironment(config)).resolves.toBeUndefined();
  });

  it("RPC 链 ID 不符时失败", async () => {
    mock.chainOk = false;
    await expect(assertEnvironment(config)).rejects.toThrow(/chain mismatch/);
  });

  it("Coordinator 地址无代码时失败", async () => {
    mock.codeOk = false;
    await expect(assertEnvironment(config)).rejects.toThrow(/No contract code/);
  });

  it("Keeper 被撤销 KEEPER_ROLE 后失败", async () => {
    mock.authorized = false;
    await expect(assertEnvironment(config)).rejects.toThrow(/does not have KEEPER_ROLE/);
  });
});
