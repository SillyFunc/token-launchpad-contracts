import { describe, expect, it } from "vitest";
import { GasLedger } from "../src/gas-ledger";

const sqlite = await import("node:sqlite").catch(() => null);
const withSqlite = sqlite ? describe : describe.skip;

function ledger() {
  const db = new sqlite!.DatabaseSync(":memory:");
  const sql = { exec: (query: string, ...params: (string | number | null)[]) => {
    const rows = db.prepare(query).all(...params);
    return { toArray: () => rows };
  } };
  return new GasLedger(sql as never);
}

const job = { id: "a", token: "0x1111111111111111111111111111111111111111", kind: "tax" } as const;

withSqlite("persistent keeper gas ledger", () => {
  it("keeps pending liabilities across windows and counts same-nonce replacements once globally", () => {
    const gas = ledger();
    gas.reserve(job, 7, 100n, 10);
    gas.reserve({ ...job, id: "replacement" }, 7, 120n, 20);
    expect(gas.usage(10_000, 3600).pending).toBe(120n);
    expect(gas.projectedUsage(job.token, 7, 150n, 10_000, 3600).global).toBe(150n);
  });

  it("a replacement preserves the original attempt time for the same token and action", () => {
    const gas = ledger();
    gas.reserve(job, 7, 100n, 10);
    gas.reserve({ ...job, id: "replacement" }, 7, 120n, 200);
    expect(gas.latestAttemptAt(job.token, "tax")).toBe(10);
  });

  it("settles the actual winning transaction once, including a reverted transaction", () => {
    const gas = ledger();
    gas.reserve(job, 7, 100n, 10);
    gas.reserve({ ...job, id: "replacement" }, 7, 120n, 20);
    gas.settleNonce(7, "a", 60n, 100);
    gas.settleNonce(7, "a", 60n, 101);
    expect(gas.usage(101, 3600)).toEqual({ spent: 60n, pending: 0n, total: 60n });
    expect(gas.usage(3701, 3600).total).toBe(0n);
  });

  it("conservatively charges an advanced nonce whose receipt cannot be found", () => {
    const gas = ledger();
    gas.reserve(job, 7, 100n, 10);
    gas.reserve({ ...job, id: "replacement" }, 7, 120n, 20);
    gas.settleUnknownNonce(7, "replacement", 100);
    expect(gas.usage(101, 3600)).toEqual({ spent: 120n, pending: 0n, total: 120n });
  });
});
