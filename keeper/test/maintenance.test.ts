import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AssetRow, AssetSnapshot, ExecutionPlan, JobKind, KeeperConfig, PlannedJob } from "../src/types";

const mock = vi.hoisted(() => ({ inspect: vi.fn(), plan: vi.fn(), store: vi.fn(), record: vi.fn(), readiness: vi.fn() }));
vi.mock("../src/planner", () => ({
  inspectAsset: mock.inspect, buildExecutionPlan: mock.plan, storeCurrentSample: mock.store,
}));
vi.mock("../src/db", () => ({ recordTransaction: mock.record, recordBuybackReadiness: mock.readiness }));
const { maintainToken, MaintenanceInspectionError } = await import("../src/maintenance");

const asset: AssetRow = {
  chain_id: 97, token: "0x1111111111111111111111111111111111111111", vault: null,
  tax_processor: "0x2222222222222222222222222222222222222222",
  pair: "0x3333333333333333333333333333333333333333", wbnb: "0x4444444444444444444444444444444444444444",
  status: "active", next_check_at: 0, last_checked_at: null, last_error: null,
};
const config = { chainId: 97 } as KeeperConfig;
function snapshot(block = 1n): AssetSnapshot {
  return {
    asset, blockNumber: block,
    controls: { taxProcessingEnabled: true, liquidityEnabled: true, buybackEnabled: true },
  } as AssetSnapshot;
}
function plan(kind: JobKind, block = "1"): ExecutionPlan {
  return { job: {
    id: "unstable-block-id", kind, chainId: 97, token: asset.token, target: asset.token,
    snapshotBlock: block, createdAt: 1_000,
  } } as ExecutionPlan;
}

describe("serial token maintenance", () => {
  const signer = { execute: vi.fn() };
  beforeEach(() => {
    vi.resetAllMocks();
    mock.inspect.mockResolvedValue(snapshot());
    mock.plan.mockImplementation(async (_db, _config, state: AssetSnapshot, kind: JobKind) => plan(kind, state.blockNumber.toString()));
    signer.execute.mockImplementation(async (job: PlannedJob) => ({ jobId: job.id, status: "deferred" }));
  });

  it("does not quote or broadcast when all controls are paused", async () => {
    mock.inspect.mockResolvedValue({ ...snapshot(), controls: {
      taxProcessingEnabled: false, liquidityEnabled: false, buybackEnabled: false,
    } });
    const result = await maintainToken({} as D1Database, config, asset, "run-1", signer, () => 1_000);
    expect(result).toEqual({ planned: 0, submitted: 0 });
    expect(mock.inspect).toHaveBeenCalledTimes(1);
    expect(mock.plan).not.toHaveBeenCalled();
    expect(signer.execute).not.toHaveBeenCalled();
  });

  it("uses one unchanged snapshot for no-op candidates in tax / liquidity / buyback order", async () => {
    await maintainToken({} as D1Database, config, asset, "run-1", signer, () => 1_000);
    expect(mock.plan.mock.calls.map((call) => [call[3], call[2].blockNumber])).toEqual([
      ["tax", 1n], ["liquidity", 1n], ["buyback", 1n],
    ]);
    expect(mock.inspect).toHaveBeenCalledTimes(1);
    expect(signer.execute.mock.calls.map((call) => call[0].id)).toEqual([
      `run-1:tax:${asset.token}`, `run-1:liquidity:${asset.token}`, `run-1:buyback:${asset.token}`,
    ]);
    expect(mock.record).toHaveBeenCalledTimes(3);
  });

  it("counts readiness diagnostics once per token check", async () => {
    const withVault = { ...asset, vault: "0x5555555555555555555555555555555555555555" as const };
    mock.inspect.mockResolvedValue({ ...snapshot(), asset: withVault, vaultReadiness: 6, vaultExecutableAmount: 0n });
    await maintainToken({} as D1Database, config, withVault, "run-1", signer, () => 1_000);
    expect(mock.inspect).toHaveBeenCalledTimes(1);
    expect(mock.readiness).toHaveBeenCalledTimes(1);
  });

  it("reads the next run's state before planning liquidity funded by a prior tax transaction", async () => {
    mock.inspect.mockResolvedValueOnce(snapshot(1n)).mockResolvedValueOnce(snapshot(2n));
    mock.plan.mockImplementation(async (_db, _config, state: AssetSnapshot, kind: JobKind) =>
      state.blockNumber === 2n && kind === "tax" ? null : plan(kind, state.blockNumber.toString()));
    signer.execute.mockImplementation(async (job: PlannedJob) => ({ jobId: job.id, status: "submitted" }));
    await maintainToken({} as D1Database, config, asset, "run-1", signer, () => 1_000);
    await maintainToken({} as D1Database, config, asset, "run-2", signer, () => 1_100);
    expect(mock.inspect).toHaveBeenCalledTimes(2);
    expect(signer.execute.mock.calls.map((call) => [call[0].kind, call[0].snapshotBlock]))
      .toEqual([["tax", "1"], ["liquidity", "2"]]);
  });

  it.each(["submitted", "already-submitted", "busy"])("stops after %s without prequoting later steps", async (status) => {
    signer.execute.mockImplementation(async (job: PlannedJob) => ({ jobId: job.id, status, txHash: `0x${"12".repeat(32)}` }));
    await maintainToken({} as D1Database, config, asset, "run-1", signer, () => 1_000);
    expect(mock.inspect).toHaveBeenCalledTimes(1);
    expect(mock.plan).toHaveBeenCalledTimes(1);
    expect(signer.execute).toHaveBeenCalledTimes(1);
    expect(mock.record).toHaveBeenCalledTimes(1);
  });

  it("keeps the same signer id when a workflow step retries at a later block", async () => {
    signer.execute.mockImplementation(async (job: PlannedJob) => ({ jobId: job.id, status: "submitted" }));
    await maintainToken({} as D1Database, config, asset, "fixed-run", signer, () => 1_000);
    mock.inspect.mockResolvedValue(snapshot(2n));
    await maintainToken({} as D1Database, config, asset, "fixed-run", signer, () => 1_100);
    expect(signer.execute.mock.calls[0][0].id).toBe(signer.execute.mock.calls[1][0].id);
  });

  it("does not swallow transaction-recording failures after signing", async () => {
    mock.record.mockRejectedValue(new Error("D1 unavailable after broadcast"));
    await expect(maintainToken({} as D1Database, config, asset, "run-1", signer, () => 1_000))
      .rejects.toThrow("D1 unavailable after broadcast");
    expect(signer.execute).toHaveBeenCalledTimes(1);
  });

  it("distinguishes inspection failures from signer failures for workflow retries", async () => {
    mock.inspect.mockRejectedValue(new Error("Reader reverted"));
    await expect(maintainToken({} as D1Database, config, asset, "run-1", signer, () => 1_000))
      .rejects.toBeInstanceOf(MaintenanceInspectionError);
    mock.inspect.mockResolvedValue(snapshot());
    signer.execute.mockRejectedValue(new Error("signer unavailable"));
    await expect(maintainToken({} as D1Database, config, asset, "run-1", signer, () => 1_000))
      .rejects.toThrow("signer unavailable");
  });
});
