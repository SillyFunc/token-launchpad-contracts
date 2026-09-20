// signer.ts 是唯一会签名并广播真实交易的模块。这里用可编程的 RPC 假实现 +
// 真实 SQLite 支撑的 Durable Object storage / D1 垫片，覆盖资金相关边界：
// 余额不足、gas 超限、广播响应丢失、pending 重播与同 nonce 替换、幂等与串行（busy）、
// 目标与注册表不一致。全程不访问网络，私钥为公开的 anvil 测试键。
import { beforeEach, describe, expect, it, vi } from "vitest";
import { keccak256, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import type { PlannedJob, SignerResult } from "../src/types";

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

const mock = vi.hoisted(() => {
  const ADDRESSES = {
    token: "0x77f117df69e4345fCfF11Bc4AFE4eB41339F8888",
    taxProcessor: "0x60ce1D8E40473668932845DD3c3E34Dd0B8c178d",
    pair: "0xB7bcaD5AfBa34a8B1Ad16F35982347e3260E9084",
    wbnb: "0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd",
    vault: "0x82ecDFaDb98CDfb3001Edf05e688d8e067d714b4",
  } as const;

  const state = {
    block: { number: 1000n, timestamp: 1_700_000_000, tag: "0x3e8" as Hex },
    reserveToken: 500_000_000n * 10n ** 18n,
    reserveWbnb: 10n ** 17n,
    poolState: [2, 500, 1000, true, 10_000_000n * 10n ** 18n, 1_700_003_600, 0],
    pendingTax: 10n ** 24n,
    nonce: "0x5" as Hex,
    latestNonce: "0x5" as Hex,
    gasPrice: "0x3b9aca00" as Hex,
    balance: "0x2386f26fc10000" as Hex,
    estimateGas: "0x30d40" as Hex,
    receipt: null as { transactionHash: Hex; status: Hex; blockNumber: Hex } | null,
    sendError: null as string | null,
    simulationError: null as string | null,
    sendCalls: 0,
    keccak: null as ((value: Hex) => Hex) | null,
  };

  const contract = (functionName: string): unknown => {
    switch (functionName) {
      case "token0":
        return ADDRESSES.token;
      case "token1":
        return ADDRESSES.wbnb;
      case "getReserves":
        return [state.reserveToken, state.reserveWbnb, 0];
      case "poolState":
        return state.poolState;
      case "pendingTaxTokens":
        return state.pendingTax;
      default:
        throw new Error(`unexpected contract call ${functionName}`);
    }
  };

  const handle = (method: string, params: unknown[]): unknown => {
    switch (method) {
      case "eth_getTransactionCount":
        return params[1] === "latest" ? state.latestNonce : state.nonce;
      case "eth_gasPrice":
        return state.gasPrice;
      case "eth_getBalance":
        return state.balance;
      case "eth_estimateGas":
        return state.estimateGas;
      case "eth_call":
        if (state.simulationError) throw new Error(state.simulationError);
        return "0x";
      case "eth_getTransactionReceipt":
        return state.receipt;
      case "eth_sendRawTransaction": {
        state.sendCalls += 1;
        if (state.sendError) throw new Error(state.sendError);
        if (!state.keccak) throw new Error("keccak not wired");
        return state.keccak(params[0] as Hex);
      }
      default:
        throw new Error(`unexpected rpc method ${method}`);
    }
  };

  return { ADDRESSES, state, handle, contract };
});

vi.mock("cloudflare:workers", () => ({
  DurableObject: class {
    constructor(
      readonly ctx: unknown,
      readonly env: unknown,
    ) {}
  },
}));

vi.mock("../src/rpc", () => ({
  getLatestBlock: async () => mock.state.block,
  batchContractCalls: async (_url: string, calls: { functionName: string }[]) =>
    calls.map((call) => mock.contract(call.functionName)),
  contractCall: async (_url: string, call: { functionName: string }) => mock.contract(call.functionName),
  rpcRequest: async (_url: string, method: string, params: unknown[]) => mock.handle(method, params),
  rpcBatch: async (_url: string, requests: { method: string; params: unknown[] }[]) =>
    requests.map((request) => mock.handle(request.method, request.params)),
}));

const { SignerDurableObject } = await import("../src/signer");
mock.state.keccak = keccak256 as (value: Hex) => Hex;

const KEEPER_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d" as Hex;
const KEEPER = privateKeyToAccount(KEEPER_KEY).address;
const { token: TOKEN, taxProcessor: TAX_PROCESSOR, pair: PAIR, wbnb: WBNB } = mock.ADDRESSES;

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

class SqlShim {
  constructor(readonly db: SqliteDb) {}
  exec(sql: string, ...params: unknown[]) {
    const rows = this.db.prepare(sql).all(...params) as Record<string, unknown>[];
    return { toArray: () => rows };
  }
}

withSqlite("signer durable object", () => {
  let db: D1Shim;
  let storage: SqlShim;
  let signer: { execute: (job: PlannedJob) => Promise<SignerResult> };

  const env = () => ({
    CHAIN_ID: "97",
    READ_RPC_URL: "https://rpc.invalid",
    SEND_RPC_URL: "https://rpc.invalid",
    COORDINATOR_ADDRESS: "0x9a7594114f4b79544f7CA00FBd1E902C556BbC47",
    KEEPER_ADDRESS: KEEPER,
    KEEPER_PRIVATE_KEY: KEEPER_KEY,
    DB: db,
  });

  const job = (overrides: Partial<PlannedJob> = {}): PlannedJob => ({
    id: `tax-${TOKEN.toLowerCase()}-1000`,
    kind: "tax",
    chainId: 97,
    token: TOKEN,
    target: TAX_PROCESSOR,
    snapshotBlock: "1000",
    createdAt: Math.floor(Date.now() / 1000),
    ...overrides,
  });

  const signerRows = () => storage.exec("SELECT * FROM signer_jobs").toArray() as Record<string, unknown>[];
  const alertCodes = async () =>
    ((await db.prepare("SELECT severity,code FROM alerts").bind().all()).results ?? []) as {
      severity: string;
      code: string;
    }[];

  const seedActiveJob = (id: string, overrides: Record<string, unknown> = {}) => {
    const now = Math.floor(Date.now() / 1000);
    const row = {
      status: "submitted",
      nonce: 5,
      gasPrice: "1000000000",
      deadline: now + 300,
      submittedAt: now,
      ...overrides,
    };
    storage.exec(
      "INSERT INTO signer_jobs(job_id,kind,token,target,status,tx_hash,nonce,raw_tx,gas_price,deadline,submitted_at,attempts) VALUES(?1,'tax',?2,?3,?4,?5,?6,?7,?8,?9,?10,1)",
      id,
      TOKEN.toLowerCase(),
      TAX_PROCESSOR.toLowerCase(),
      row.status,
      "0x" + "ab".repeat(32),
      row.nonce,
      "0x" + "cd".repeat(100),
      row.gasPrice,
      row.deadline,
      row.submittedAt,
    );
  };

  beforeEach(() => {
    const sqlite = new sqliteModule!.DatabaseSync(":memory:");
    sqlite.exec(
      "CREATE TABLE assets (chain_id INTEGER, token TEXT, tax_processor TEXT, vault TEXT, pair TEXT, wbnb TEXT, status TEXT, next_check_at INTEGER, last_checked_at INTEGER, last_error TEXT, created_at INTEGER, updated_at INTEGER, PRIMARY KEY (chain_id, token));" +
        "CREATE TABLE price_samples (chain_id INTEGER, pair TEXT, block_number INTEGER, sampled_at INTEGER, reserve_token TEXT, reserve_wbnb TEXT, PRIMARY KEY (chain_id, pair, block_number));" +
        "CREATE TABLE alerts (id INTEGER PRIMARY KEY AUTOINCREMENT, severity TEXT, code TEXT, message TEXT, created_at INTEGER, resolved_at INTEGER);",
    );
    sqlite
      .prepare(
        "INSERT INTO assets(chain_id,token,tax_processor,vault,pair,wbnb,status,next_check_at,created_at,updated_at) VALUES(?1,?2,?3,?4,?5,?6,'active',0,0,0)",
      )
      .run(97, TOKEN.toLowerCase(), TAX_PROCESSOR.toLowerCase(), null, PAIR.toLowerCase(), WBNB.toLowerCase());
    for (let index = 0; index < 3; index++) {
      sqlite
        .prepare(
          "INSERT INTO price_samples(chain_id,pair,block_number,sampled_at,reserve_token,reserve_wbnb) VALUES(?1,?2,?3,?4,?5,?6)",
        )
        .run(
          97,
          PAIR.toLowerCase(),
          990 + index,
          mock.state.block.timestamp - 600 + index * 60,
          mock.state.reserveToken.toString(),
          mock.state.reserveWbnb.toString(),
        );
    }
    db = new D1Shim(sqlite);

    const doDb = new sqliteModule!.DatabaseSync(":memory:");
    storage = new SqlShim(doDb);
    signer = new SignerDurableObject({ storage: { sql: storage } } as never, env() as never);

    mock.state.nonce = "0x5";
    mock.state.latestNonce = "0x5";
    mock.state.gasPrice = "0x3b9aca00";
    mock.state.balance = "0x2386f26fc10000";
    mock.state.receipt = null;
    mock.state.sendError = null;
    mock.state.simulationError = null;
    mock.state.sendCalls = 0;
  });

  it("签名并广播成功，落库为 submitted", async () => {
    const result = await signer.execute(job());
    expect(result.status).toBe("submitted");
    expect(result.nonce).toBe(5);
    expect(mock.state.sendCalls).toBe(1);
    const rows = signerRows();
    expect(rows).toHaveLength(1);
    expect(rows[0].status).toBe("submitted");
    expect(rows[0].nonce).toBe(5);
  });

  it("余额不足：不签名并写入 critical 告警", async () => {
    mock.state.balance = "0x1";
    const result = await signer.execute(job());
    expect(result.status).toBe("skipped");
    expect(String(result.detail)).toContain("balance is too low");
    expect(mock.state.sendCalls).toBe(0);
    expect(signerRows()).toHaveLength(0);
    const alerts = await alertCodes();
    expect(alerts.some((row) => row.code === "keeper-balance-low" && row.severity === "critical")).toBe(true);
  });

  it("gas 价格超上限：不签名并写入 warning 告警", async () => {
    mock.state.gasPrice = "0x3b9aca0000";
    const result = await signer.execute(job());
    expect(result.status).toBe("skipped");
    expect(String(result.detail)).toContain("gas price exceeds configured maximum");
    expect(mock.state.sendCalls).toBe(0);
    const alerts = await alertCodes();
    expect(alerts.some((row) => row.code === "gas-price-high" && row.severity === "warning")).toBe(true);
  });

  it("广播响应丢失（already known）：视为成功且不重复签名", async () => {
    mock.state.sendError = "already known";
    const result = await signer.execute(job());
    expect(result.status).toBe("submitted");
    expect(mock.state.sendCalls).toBe(1);
    const rows = signerRows();
    expect(rows).toHaveLength(1);
    expect(rows[0].status).toBe("submitted");
    expect(rows[0].detail).toBeNull();
  });

  it("广播未知错误：保留同一签名交易并标记不确定", async () => {
    mock.state.sendError = "connection reset";
    const result = await signer.execute(job());
    expect(result.status).toBe("submitted");
    const rows = signerRows();
    expect(rows).toHaveLength(1);
    expect(String(rows[0].detail)).toContain("initial broadcast uncertain");
    expect(String(rows[0].raw_tx)).toMatch(/^0x/);
  });

  it("同一 job 重复执行：不产生第二笔交易", async () => {
    await signer.execute(job());
    const second = await signer.execute(job());
    expect(second.status).toBe("already-submitted");
    expect(mock.state.sendCalls).toBe(1);
    expect(signerRows()).toHaveLength(1);
  });

  it("已有活跃任务：新任务返回 busy 且不签名", async () => {
    seedActiveJob("tax-active-job");
    const result = await signer.execute(job({ id: "tax-other-job-1001" }));
    expect(result.status).toBe("busy");
    expect(result.detail).toBe("tax-active-job");
    expect(mock.state.sendCalls).toBe(0);
  });

  it("pending 过期且 nonce 未消费：同 nonce 提价替换", async () => {
    const now = Math.floor(Date.now() / 1000);
    seedActiveJob("tax-expired-job", { deadline: now - 10, submittedAt: now - 200 });
    const result = await signer.execute(job({ id: "tax-replacement-job-1002" }));
    expect(result.status).toBe("submitted");
    const replaced = storage.exec("SELECT status FROM signer_jobs WHERE job_id='tax-expired-job'").toArray() as Record<
      string,
      unknown
    >[];
    expect(replaced[0].status).toBe("replaced");
    const fresh = signerRows().find((row) => row.job_id === "tax-replacement-job-1002")!;
    expect(fresh.nonce).toBe(5);
    expect(BigInt(String(fresh.gas_price))).toBeGreaterThanOrEqual((1_000_000_000n * 9n) / 8n + 1n);
  });

  it("nonce 已被消费：标记 consumed 并用新 nonce 继续", async () => {
    const now = Math.floor(Date.now() / 1000);
    seedActiveJob("tax-consumed-job", { deadline: now - 10, submittedAt: now - 200 });
    mock.state.latestNonce = "0x6";
    mock.state.nonce = "0x6";
    const result = await signer.execute(job({ id: "tax-after-consumed-1003" }));
    expect(result.status).toBe("submitted");
    const consumed = storage.exec("SELECT status FROM signer_jobs WHERE job_id='tax-consumed-job'").toArray() as Record<
      string,
      unknown
    >[];
    expect(consumed[0].status).toBe("consumed");
    const fresh = signerRows().find((row) => row.job_id === "tax-after-consumed-1003")!;
    expect(fresh.nonce).toBe(6);
  });

  it("目标与 D1 注册表不一致：跳过且不签名", async () => {
    const result = await signer.execute(job({ target: mock.ADDRESSES.vault }));
    expect(result.status).toBe("skipped");
    expect(String(result.detail)).toContain("does not match the D1 asset registry");
    expect(mock.state.sendCalls).toBe(0);
  });

  it("模拟失败：跳过且不签名", async () => {
    mock.state.simulationError = "execution reverted: PancakeRouter: INSUFFICIENT_OUTPUT_AMOUNT";
    const result = await signer.execute(job());
    expect(result.status).toBe("skipped");
    expect(String(result.detail)).toContain("simulation failed");
    expect(mock.state.sendCalls).toBe(0);
  });
});
