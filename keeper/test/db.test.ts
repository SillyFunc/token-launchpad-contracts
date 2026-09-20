// 连续跳过告警：清算停摆时 transactions 里只有 skipped、alerts 为空，
// 运维只看告警会误判为健康。这里覆盖去重、阈值与成交后自动解除。
import { beforeEach, describe, expect, it } from "vitest";
import type { SignerResult } from "../src/types";

const sqliteModule = (await import("node:sqlite").catch(() => null)) as
  | { DatabaseSync: new (path: string) => SqliteDb }
  | null;
const withSqlite = sqliteModule ? describe : describe.skip;

interface SqliteStatement {
  all(...params: unknown[]): unknown[];
  run(...params: unknown[]): unknown;
}

interface SqliteDb {
  exec(sql: string): void;
  prepare(sql: string): SqliteStatement;
}

class Statement {
  constructor(
    private readonly db: SqliteDb,
    private readonly sql: string,
    private readonly params: unknown[] = [],
  ) {}

  bind(...params: unknown[]) {
    return new Statement(this.db, this.sql, params);
  }

  private rows(): Record<string, unknown>[] {
    return this.db.prepare(this.sql).all(...this.params) as Record<string, unknown>[];
  }

  async all() {
    return { results: this.rows(), success: true };
  }

  async first() {
    return this.rows()[0] ?? null;
  }

  async run() {
    this.db.prepare(this.sql).run(...this.params);
    return { success: true, meta: {} };
  }
}

class D1Shim {
  constructor(readonly db: SqliteDb) {}
  prepare(sql: string) {
    return new Statement(this.db, sql);
  }
  async batch(statements: Statement[]) {
    return Promise.all(statements.map((statement) => statement.run()));
  }
}

const { recordTransaction } = await import("../src/db");

const TOKEN = "0x77f117df69e4345fCfF11Bc4AFE4eB41339F8888";
const TARGET = "0x60ce1D8E40473668932845DD3c3E34Dd0B8c178d";

withSqlite("skip streak alerts", () => {
  let db: D1Shim;

  const openAlerts = async () =>
    ((await db.prepare("SELECT code,severity,message FROM alerts WHERE resolved_at IS NULL").bind().all()).results ??
      []) as { code: string; severity: string; message: string }[];

  const record = (status: SignerResult["status"], detail?: string, jobId = `tax-${TOKEN}-${Math.random()}`) =>
    recordTransaction(
      db as never,
      "run-1",
      97,
      "tax",
      TOKEN as never,
      TARGET as never,
      {
        jobId,
        status,
        detail,
        ...(status === "already-submitted" ? { txHash: `0x${"12".repeat(32)}` } : {}),
      } as SignerResult,
      Math.floor(Date.now() / 1000),
    );

  beforeEach(() => {
    const sqlite = new sqliteModule!.DatabaseSync(":memory:");
    sqlite.exec(
      "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at INTEGER NOT NULL);" +
        "CREATE TABLE transactions (job_id TEXT PRIMARY KEY, run_id TEXT, chain_id INTEGER, kind TEXT, token TEXT, target TEXT, tx_hash TEXT, nonce INTEGER, status TEXT, detail TEXT, created_at INTEGER, updated_at INTEGER);" +
        "CREATE TABLE alerts (id INTEGER PRIMARY KEY AUTOINCREMENT, severity TEXT, code TEXT, message TEXT, created_at INTEGER, resolved_at INTEGER);",
    );
    db = new D1Shim(sqlite);
  });

  it("少于阈值时不告警", async () => {
    for (let index = 0; index < 4; index++) await record("skipped", "simulation failed: reverted");
    expect(await openAlerts()).toHaveLength(0);
  });

  it("连续跳过达到阈值时写一条去重 warning", async () => {
    for (let index = 0; index < 7; index++) await record("skipped", "simulation failed: reverted");
    const alerts = await openAlerts();
    expect(alerts).toHaveLength(1);
    expect(alerts[0].code).toBe(`skip-streak:${TOKEN.toLowerCase()}:tax`);
    expect(alerts[0].severity).toBe("warning");
    expect(alerts[0].message).toContain("skipped 5 times in a row");
    expect(alerts[0].message).toContain("simulation failed");
  });

  it("成交后清零并解除告警", async () => {
    for (let index = 0; index < 5; index++) await record("skipped", "simulation failed: reverted");
    expect(await openAlerts()).toHaveLength(1);

    await record("submitted");
    expect(await openAlerts()).toHaveLength(0);

    for (let index = 0; index < 4; index++) await record("skipped", "simulation failed: reverted");
    expect(await openAlerts()).toHaveLength(0);
  });

  it("busy 与 already-submitted 不计入连续跳过", async () => {
    for (let index = 0; index < 6; index++) await record("busy", "other-job");
    await record("already-submitted", "submitted");
    expect(await openAlerts()).toHaveLength(0);
  });

  it("Workflow 重试不会把同一 job 重复计入跳过次数", async () => {
    for (let index = 0; index < 4; index++) {
      await record("skipped", "simulation failed: reverted", `retry-job-${index}`);
    }
    await record("skipped", "simulation failed: reverted", "same-retried-job");
    await record("skipped", "simulation failed: reverted", "same-retried-job");
    expect(await openAlerts()).toHaveLength(1);

    const setting = await db
      .prepare(`SELECT value FROM settings WHERE key LIKE 'skip_streak:%'`)
      .bind()
      .first();
    expect(setting?.value).toBe("5");
  });

  it("already-submitted 结果保留为 submitted 且不会重复触发状态变化", async () => {
    await record("already-submitted", "submitted", "persisted-job");
    await record("already-submitted", "submitted", "persisted-job");

    const transaction = await db
      .prepare("SELECT status,tx_hash FROM transactions WHERE job_id=?1")
      .bind("persisted-job")
      .first();
    expect(transaction?.status).toBe("submitted");
    expect(transaction?.tx_hash).toBe(`0x${"12".repeat(32)}`);
  });
});
