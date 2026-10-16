// signer.ts 是唯一会签名并广播真实交易的模块。这里用可编程的 RPC 假实现 +
// 真实 SQLite 支撑的 Durable Object storage / D1 垫片，覆盖资金相关边界：
// 余额不足、gas 超限、广播响应丢失、pending 重播与同 nonce 替换、幂等与串行（busy）、
// 目标与注册表不一致。全程不访问网络，私钥为公开的 anvil 测试键。
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { keccak256, parseTransaction, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import type { PlannedJob, SignerResult } from "../src/types";

const sqliteModule = (await import("node:sqlite").catch(() => null)) as
  | { DatabaseSync: new (path: string) => SqliteDb }
  | null;
const withSqlite = sqliteModule ? describe : describe.skip;

interface TestReceipt {
  transactionHash: Hex;
  status: Hex;
  blockNumber: Hex;
  gasUsed: Hex;
  effectiveGasPrice: Hex;
}

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
    reserveWbnb: 10n ** 19n,
    poolState: [2, 500, 1000, true, 10_000_000n * 10n ** 18n, 1_700_003_600, 0],
    pendingTax: 10n ** 24n,
    feeConfig: [10_000, 0, 0, 0, 0, true, 0, ADDRESSES.wbnb],
    lpTokenBalance: 0n,
    lpQuoteBalance: 0n,
    pairTotalSupply: 1_000_000n,
    executionFlags: 7,
    readerError: false,
    nonce: "0x5" as Hex,
    latestNonce: "0x5" as Hex,
    gasPrice: "0x3b9aca00" as Hex,
    balance: "0x2386f26fc10000" as Hex,
    estimateGas: "0x30d40" as Hex,
    receipt: null as TestReceipt | null,
    receipts: new Map<string, TestReceipt>(),
    confirmOnSend: false,
    sendError: null as string | null,
    simulationError: null as string | null,
    sendCalls: 0,
    keccak: null as ((value: Hex) => Hex) | null,
    rawGasPrice: null as ((value: Hex) => bigint) | null,
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
      case "feeConfigV2":
        return state.feeConfig;
      case "lpTokenBalance":
        return state.lpTokenBalance;
      case "lpQuoteBalance":
        return state.lpQuoteBalance;
      case "totalSupply":
        return state.pairTotalSupply;
      case "getTokenSnapshot":
        if (state.readerError) throw new Error("Reader unavailable");
        return {
          schemaVersion: 1, blockNumber: state.block.number, blockTimestamp: BigInt(state.block.timestamp),
          contracts: { token: ADDRESSES.token, pair: ADDRESSES.pair, taxProcessor: ADDRESSES.taxProcessor,
            vault: "0x0000000000000000000000000000000000000000", wbnb: ADDRESSES.wbnb },
          controls: { executionFlags: state.executionFlags },
          pool: { reserveToken: state.reserveToken, reserveWbnb: state.reserveWbnb, totalSupply: state.pairTotalSupply,
            state: Number(state.poolState[0]), buyTaxRate: Number(state.poolState[1]), sellTaxRate: Number(state.poolState[2]),
            taxExpirationTime: BigInt(state.poolState[5]) },
          tax: { pendingAmount: state.pendingTax, feeConfig: {
            marketBps: Number(state.feeConfig[0]), deflationBps: Number(state.feeConfig[1]),
            lpBps: Number(state.feeConfig[2]), dividendBps: Number(state.feeConfig[3]), feeRate: Number(state.feeConfig[4]),
            isWeth: true, commissionBps: Number(state.feeConfig[6]), dividendToken: ADDRESSES.wbnb,
          } },
          liquidity: { pendingToken: state.lpTokenBalance, pendingWbnb: state.lpQuoteBalance },
          buyback: { balance: 0n, executableAmount: 0n, mode: 0, readiness: 0, nextExecuteTime: 0n },
        };
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
        return state.receipts.get(String(params[0]).toLowerCase()) ?? state.receipt;
      case "eth_sendRawTransaction": {
        state.sendCalls += 1;
        if (state.sendError) throw new Error(state.sendError);
        if (!state.keccak) throw new Error("keccak not wired");
        const hash = state.keccak(params[0] as Hex);
        if (state.confirmOnSend) {
          if (!state.rawGasPrice) throw new Error("transaction parser not wired");
          state.receipts.set(hash.toLowerCase(), {
            transactionHash: hash,
            status: "0x1",
            blockNumber: "0x3e9",
            gasUsed: "0x30d40",
            effectiveGasPrice: `0x${state.rawGasPrice(params[0] as Hex).toString(16)}`,
          });
          state.latestNonce = `0x${(BigInt(state.nonce) + 1n).toString(16)}`;
          state.nonce = state.latestNonce;
        }
        return hash;
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
mock.state.rawGasPrice = (raw: Hex) => parseTransaction(raw).gasPrice!;

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

  transactionSync<T>(callback: () => T): T {
    this.db.exec("BEGIN IMMEDIATE");
    try {
      const result = callback();
      this.db.exec("COMMIT");
      return result;
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
  }
}

withSqlite("signer durable object", () => {
  let db: D1Shim;
  let storage: SqlShim;
  let signer: {
    execute: (job: PlannedJob) => Promise<SignerResult>;
    heartbeat: () => Promise<Record<string, unknown>>;
    status: () => Promise<Record<string, unknown>>;
  };
  let environmentOverrides: Record<string, string>;
  const NOW = 1_700_000_000;

  const env = () => ({
    CHAIN_ID: "97",
    READ_RPC_URL: "https://rpc.invalid",
    SEND_RPC_URL: "https://rpc.invalid",
    COORDINATOR_ADDRESS: "0x8b678ed56926B975C9d926bE12778d9F17e479C1",
    KEEPER_ADDRESS: KEEPER,
    KEEPER_PRIVATE_KEY: KEEPER_KEY,
    DB: db,
    ...environmentOverrides,
  });

  // Durable Object KV survives restarts of the in-memory class instance; keep it outside restartSigner.
  let kvStore: Map<string, unknown>;
  const restartSigner = () => {
    signer = new SignerDurableObject(
      {
        storage: {
          sql: storage,
          transactionSync: <T>(callback: () => T) => storage.transactionSync(callback),
          kv: {
            get: <T>(key: string) => kvStore.get(key) as T | undefined,
            put: <T>(key: string, value: T) => void kvStore.set(key, value),
          },
        },
      } as never,
      env() as never,
    );
  };

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
  const gasRows = () => storage.exec("SELECT * FROM signer_gas_expenses ORDER BY created_at,job_id").toArray();
  const receipt = (hash: Hex, overrides: Partial<TestReceipt> = {}): TestReceipt => ({
    transactionHash: hash,
    status: "0x1",
    blockNumber: "0x3e9",
    gasUsed: "0x249f0",
    effectiveGasPrice: "0x47868c00",
    ...overrides,
  });

  const seedExpense = (
    id: string,
    overrides: Partial<{
      token: string;
      kind: string;
      nonce: number;
      reservedWei: string;
      spentWei: string | null;
      createdAt: number;
      settledAt: number | null;
    }> = {},
  ) => {
    const values = {
      token: TOKEN.toLowerCase(),
      kind: "tax",
      nonce: 4,
      reservedWei: "240001000000000",
      spentWei: null,
      createdAt: NOW,
      settledAt: null,
      ...overrides,
    };
    storage.exec(
      "INSERT INTO signer_gas_expenses(job_id,token,kind,nonce,reserved_wei,spent_wei,created_at,settled_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8)",
      id,
      values.token,
      values.kind,
      values.nonce,
      values.reservedWei,
      values.spentWei,
      values.createdAt,
      values.settledAt,
    );
  };
  const alertCodes = async () =>
    ((await db.prepare("SELECT severity,code FROM alerts").bind().all()).results ?? []) as {
      severity: string;
      code: string;
    }[];

  const seedActiveJob = async (id: string, overrides: Record<string, unknown> = {}) => {
    const now = Math.floor(Date.now() / 1000);
    const row = {
      status: "submitted",
      nonce: 5,
      gasPrice: "1000000000",
      deadline: now + 300,
      submittedAt: now,
      ...overrides,
    };
    const raw = await privateKeyToAccount(KEEPER_KEY).signTransaction({
      type: "legacy",
      chainId: 97,
      nonce: Number(row.nonce),
      gas: 240_001n,
      gasPrice: BigInt(String(row.gasPrice)),
      to: TAX_PROCESSOR,
      data: "0x",
    });
    const hash = keccak256(raw);
    storage.exec(
      "INSERT INTO signer_jobs(job_id,kind,token,target,status,tx_hash,nonce,raw_tx,gas_price,deadline,submitted_at,attempts) VALUES(?1,'tax',?2,?3,?4,?5,?6,?7,?8,?9,?10,1)",
      id,
      TOKEN.toLowerCase(),
      TAX_PROCESSOR.toLowerCase(),
      row.status,
      hash,
      row.nonce,
      raw,
      row.gasPrice,
      row.deadline,
      row.submittedAt,
    );
    return hash;
  };

  beforeEach(() => {
    vi.spyOn(Date, "now").mockReturnValue(NOW * 1000);
    environmentOverrides = {};
    mock.state.block = { number: 1000n, timestamp: NOW, tag: "0x3e8" };
    mock.state.reserveToken = 500_000_000n * 10n ** 18n;
    mock.state.reserveWbnb = 10n ** 19n;
    mock.state.poolState = [2, 500, 1000, true, 10_000_000n * 10n ** 18n, NOW + 3600, 0];
    mock.state.pendingTax = 10n ** 24n;
    mock.state.feeConfig = [10_000, 0, 0, 0, 0, true, 0, WBNB];
    mock.state.lpTokenBalance = 0n;
    mock.state.lpQuoteBalance = 0n;
    mock.state.pairTotalSupply = 1_000_000n;
    mock.state.executionFlags = 7;
    mock.state.readerError = false;
    mock.state.nonce = "0x5";
    mock.state.latestNonce = "0x5";
    mock.state.gasPrice = "0x3b9aca00";
    mock.state.balance = "0x2386f26fc10000";
    mock.state.estimateGas = "0x30d40";
    mock.state.receipt = null;
    mock.state.receipts.clear();
    mock.state.confirmOnSend = false;
    mock.state.sendError = null;
    mock.state.simulationError = null;
    mock.state.sendCalls = 0;
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
    kvStore = new Map();
    restartSigner();
  });

  afterEach(() => vi.restoreAllMocks());

  it("rechecks Reader controls before signing an old unpaused plan", async () => {
    environmentOverrides = { READER_ADDRESS: "0x1111111111111111111111111111111111111111" };
    restartSigner();
    mock.state.executionFlags = 0;
    const result = await signer.execute(job());
    expect(result.status).toBe("skipped");
    expect(mock.state.sendCalls).toBe(0);
    expect(signerRows()).toHaveLength(0);
    expect(gasRows()).toHaveLength(0);
  });

  it("does not sign using legacy getters when its configured Reader fails", async () => {
    environmentOverrides = { READER_ADDRESS: "0x1111111111111111111111111111111111111111" };
    restartSigner();
    mock.state.readerError = true;
    await expect(signer.execute(job())).rejects.toThrow("Reader unavailable");
    expect(mock.state.sendCalls).toBe(0);
    expect(signerRows()).toHaveLength(0);
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
    await seedActiveJob("tax-active-job");
    const result = await signer.execute(job({ id: "tax-other-job-1001" }));
    expect(result.status).toBe("busy");
    expect(result.detail).toBe("tax-active-job");
    expect(mock.state.sendCalls).toBe(0);
  });

  it("pending 过期且 nonce 未消费：同 nonce 提价替换", async () => {
    const now = Math.floor(Date.now() / 1000);
    await seedActiveJob("tax-expired-job", { deadline: now - 10, submittedAt: now - 200 });
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
    await seedActiveJob("tax-consumed-job", { deadline: now - 10, submittedAt: now - 1000 });
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

  it("低价值税费保留队列，累积到经济规模后恢复执行", async () => {
    mock.state.pendingTax = 100n * 10n ** 18n;
    const deferred = await signer.execute(job({ id: "tax-dust" }));
    expect(deferred.status).toBe("deferred");
    expect(deferred.detail).toMatch(/^gas-ratio/);
    expect(mock.state.sendCalls).toBe(0);
    expect(signerRows()).toHaveLength(0);

    mock.state.pendingTax = 10n ** 24n;
    const resumed = await signer.execute(job({ id: "tax-accumulated" }));
    expect(resumed.status).toBe("submitted");
    expect(mock.state.sendCalls).toBe(1);
  });

  it("仅剩 3 wei 的 LP quote 不为追尘广播交易", async () => {
    mock.state.lpTokenBalance = 10n ** 24n;
    mock.state.lpQuoteBalance = 3n;
    mock.state.pairTotalSupply = 10n ** 30n;
    const result = await signer.execute(job({ id: "lp-three-wei", kind: "liquidity" }));
    expect(result.status).toBe("deferred");
    expect(result.detail).toMatch(/^gas-ratio/);
    expect(mock.state.sendCalls).toBe(0);
    expect(signerRows()).toHaveLength(0);
  });

  it("纯销毁批次同样检查经济规模，并保留足额纯销毁的执行能力", async () => {
    mock.state.feeConfig = [0, 10_000, 0, 0, 0, true, 0, WBNB];
    mock.state.pendingTax = 100n * 10n ** 18n;
    const dust = await signer.execute(job({ id: "burn-dust" }));
    expect(dust.status).toBe("deferred");
    expect(dust.detail).toMatch(/^gas-ratio/);
    expect(mock.state.sendCalls).toBe(0);

    mock.state.pendingTax = 10n ** 24n;
    const meaningful = await signer.execute(job({ id: "burn-meaningful" }));
    expect(meaningful.status).toBe("submitted");
    expect(mock.state.sendCalls).toBe(1);
  });

  it("同币同类型冷却跨 DO 重启保持，到期后恢复", async () => {
    const first = await signer.execute(job({ id: "cooldown-first" }));
    expect(first.status).toBe("submitted");
    mock.state.receipts.set(first.txHash!.toLowerCase(), receipt(first.txHash!));
    mock.state.nonce = "0x6";
    mock.state.latestNonce = "0x6";
    await signer.heartbeat();
    restartSigner();

    const blocked = await signer.execute(job({ id: "cooldown-restarted" }));
    expect(blocked.status).toBe("deferred");
    expect(blocked.detail).toMatch(/^cooldown/);
    expect(mock.state.sendCalls).toBe(1);

    vi.mocked(Date.now).mockReturnValue((NOW + 901) * 1000);
    mock.state.block.timestamp = NOW + 901;
    const resumed = await signer.execute(job({ id: "cooldown-elapsed" }));
    expect(resumed.status).toBe("submitted");
    expect(mock.state.sendCalls).toBe(2);
  });

  it("清算冷却不会阻止同币独立的 LP 操作", async () => {
    const first = await signer.execute(job({ id: "kind-tax" }));
    expect(first.status).toBe("submitted");
    mock.state.receipts.set(first.txHash!.toLowerCase(), receipt(first.txHash!));
    mock.state.nonce = "0x6";
    mock.state.latestNonce = "0x6";
    mock.state.lpTokenBalance = 10n ** 24n;
    mock.state.lpQuoteBalance = 10n ** 16n;
    const lp = await signer.execute(job({ id: "kind-lp", kind: "liquidity" }));
    expect(lp.status).toBe("submitted");
    expect(mock.state.sendCalls).toBe(2);
  });

  it("不同 job 并发执行也不能超过共享全局 Gas 预算", async () => {
    environmentOverrides = {
      MAX_TOKEN_GAS_PER_WINDOW_WEI: "600000000000000",
      MAX_TOTAL_GAS_PER_WINDOW_WEI: "700000000000000",
    };
    restartSigner();
    seedExpense("other-token-spent", {
      token: "0x1111111111111111111111111111111111111111",
      reservedWei: "200000000000000",
      spentWei: "200000000000000",
      createdAt: NOW - 60,
      settledAt: NOW - 1,
    });
    mock.state.confirmOnSend = true;
    mock.state.lpTokenBalance = 10n ** 24n;
    mock.state.lpQuoteBalance = 10n ** 16n;

    const results = await Promise.all([
      signer.execute(job({ id: "budget-tax" })),
      signer.execute(job({ id: "budget-lp", kind: "liquidity" })),
    ]);
    expect(results.map((result) => result.status)).toEqual(["submitted", "deferred"]);
    expect(results[1].detail).toMatch(/^global-gas-budget/);
    expect(mock.state.sendCalls).toBe(1);
    expect(gasRows()).toHaveLength(2);
  });

  it("revert 也按 receipt 实际 Gas 结算，重读不重复扣费", async () => {
    const sent = await signer.execute(job({ id: "reverted-cost" }));
    expect(sent.status).toBe("submitted");
    const charged = receipt(sent.txHash!, {
      status: "0x0",
      gasUsed: "0x186a0",
      effectiveGasPrice: "0x47868c00",
    });
    mock.state.receipts.set(sent.txHash!.toLowerCase(), charged);
    await signer.heartbeat();
    await signer.heartbeat();

    const expenses = gasRows();
    expect(expenses).toHaveLength(1);
    expect(expenses[0].spent_wei).toBe((100_000n * 1_200_000_000n).toString());
    expect(expenses[0].settled_at).not.toBeNull();
    expect(signerRows()[0].status).toBe("reverted");
    expect((await alertCodes()).some((alert) => alert.code === "tx-reverted:reverted-cost")).toBe(true);
  });

  it("同一 raw transaction 重播只保留一份预算预留", async () => {
    const sent = await signer.execute(job({ id: "rebroadcast-reservation" }));
    expect(sent.status).toBe("submitted");
    const before = gasRows();
    expect(before).toHaveLength(1);
    vi.mocked(Date.now).mockReturnValue((NOW + 100) * 1000);
    await signer.heartbeat();
    expect(mock.state.sendCalls).toBe(2);
    const after = gasRows();
    expect(after).toHaveLength(1);
    expect(after[0].reserved_wei).toBe(before[0].reserved_wei);
    expect(after[0].created_at).toBe(before[0].created_at);
    expect(after[0].spent_wei).toBeNull();
  });

  it.each(["signer_jobs", "signer_gas_expenses"])("持久化 %s 失败时回滚交易和预算，不广播半写入任务", async (table) => {
    const exec = storage.exec.bind(storage);
    const fault = vi.spyOn(storage, "exec").mockImplementation((sql, ...params) => {
      if (/^INSERT/i.test(sql.trim()) && sql.includes(table)) throw new Error("simulated storage write failure");
      return exec(sql, ...params);
    });
    await expect(signer.execute(job({ id: `atomic-${table}` }))).rejects.toThrow("simulated storage write failure");
    fault.mockRestore();
    expect(signerRows()).toHaveLength(0);
    expect(gasRows()).toHaveLength(0);
    expect(mock.state.sendCalls).toBe(0);
  });

  it("过期任务的替换被经济门槛拒绝时，旧任务继续被跟踪", async () => {
    await seedActiveJob("expired-still-tracked", { deadline: NOW - 10, submittedAt: NOW - 200 });
    mock.state.pendingTax = 100n * 10n ** 18n;
    const blocked = await signer.execute(job({ id: "replacement-too-small" }));
    expect(blocked.status).toBe("deferred");
    expect(blocked.detail).toMatch(/^gas-ratio/);
    expect(signerRows()).toHaveLength(1);
    expect(signerRows()[0].status).toBe("submitted");
    expect(mock.state.sendCalls).toBe(0);
    expect(gasRows()).toHaveLength(1);
    expect(gasRows()[0].spent_wei).toBeNull();
  });

  it("旧 prepared 交易已过期时 heartbeat 不广播，后续可用同 nonce 替换", async () => {
    await seedActiveJob("expired-legacy-prepared", {
      status: "prepared",
      deadline: NOW - 10,
      submittedAt: NOW - 7200,
    });
    await signer.heartbeat();
    expect(mock.state.sendCalls).toBe(0);
    expect(["prepared", "submitted"]).toContain(signerRows()[0].status);

    const replacement = await signer.execute(job({ id: "replace-expired-prepared" }));
    expect(replacement.status).toBe("submitted");
    expect(replacement.nonce).toBe(5);
    expect(mock.state.sendCalls).toBe(1);
    expect(signerRows().find((row) => row.job_id === "expired-legacy-prepared")?.status).toBe("replaced");
  });

  it("旧 prepared 交易在合约暂停(模拟 revert)时不广播", async () => {
    const now = Math.floor(Date.now() / 1000);
    await seedActiveJob("repro-prepared-paused", { status: "prepared", deadline: now + 300, submittedAt: now });
    // When the contract pauses, the exact call reverts at latest state; the replay must not send it.
    mock.state.simulationError = "execution reverted: ExecutionPaused";
    await signer.heartbeat();
    expect(mock.state.sendCalls).toBe(0);
  });

  it("旧 submitted 交易在模拟失败时不重播", async () => {
    const now = Math.floor(Date.now() / 1000);
    await seedActiveJob("repro-submitted-sim-fail", { deadline: now + 300, submittedAt: now - 200 });
    mock.state.simulationError = "execution reverted: insufficient vault balance";
    await signer.heartbeat();
    expect(mock.state.sendCalls).toBe(0);
  });

  it("prepared 已有收据时直接结算,不广播", async () => {
    const now = Math.floor(Date.now() / 1000);
    const hash = await seedActiveJob("prepared-with-receipt", { status: "prepared", deadline: now + 300, submittedAt: now });
    mock.state.receipts.set(hash.toLowerCase(), receipt(hash));
    mock.state.nonce = "0x6";
    mock.state.latestNonce = "0x6";
    await signer.heartbeat();
    expect(mock.state.sendCalls).toBe(0);
    expect(signerRows()[0].status).toBe("confirmed");
  });

  it("prepared 模拟失败时不广播,保留交易与费用跟踪", async () => {
    const now = Math.floor(Date.now() / 1000);
    await seedActiveJob("prepared-sim-fail", { status: "prepared", deadline: now + 300, submittedAt: now });
    mock.state.simulationError = "execution reverted";
    await signer.heartbeat();
    expect(mock.state.sendCalls).toBe(0);
    const row = signerRows().find((r) => r.job_id === "prepared-sim-fail")!;
    expect(row.status).toBe("prepared");
    expect(String(row.detail)).toContain("replay simulation failed");
    expect(gasRows()).toHaveLength(1);
    expect(gasRows()[0].spent_wei).toBeNull();
  });

  it("RPC 失败时不触发盲目广播", async () => {
    const now = Math.floor(Date.now() / 1000);
    await seedActiveJob("prepared-rpc-fail", { status: "prepared", deadline: now + 300, submittedAt: now });
    mock.state.simulationError = "HTTP 503 for eth_call";
    await signer.heartbeat();
    expect(mock.state.sendCalls).toBe(0);
    expect(signerRows()[0].status).toBe("prepared");
  });

  it("限频跨 Durable Object 重启有效,但不阻挡收据对账", async () => {
    const now = Math.floor(Date.now() / 1000);
    const hash = await seedActiveJob("throttled-replay", { deadline: now + 300, submittedAt: now - 200 });
    mock.state.simulationError = "execution reverted";
    await signer.heartbeat();
    expect(mock.state.sendCalls).toBe(0);
    restartSigner();
    mock.state.simulationError = null;
    await signer.heartbeat();
    expect(mock.state.sendCalls).toBe(0);

    mock.state.receipts.set(hash.toLowerCase(), receipt(hash));
    mock.state.nonce = "0x6";
    mock.state.latestNonce = "0x6";
    await signer.heartbeat();
    expect(signerRows()[0].status).toBe("confirmed");
  });

  it("条件恢复后只发送原 raw_tx,不重复预留预算", async () => {
    const now = Math.floor(Date.now() / 1000);
    const hash = await seedActiveJob("recovered-replay", { deadline: now + 300, submittedAt: now - 200 });
    seedExpense("recovered-replay", { createdAt: now - 200, nonce: 5 });
    const raw = signerRows()[0].raw_tx;
    const before = gasRows();
    mock.state.simulationError = "execution reverted";
    await signer.heartbeat();
    expect(mock.state.sendCalls).toBe(0);
    vi.mocked(Date.now).mockReturnValue((NOW + 100) * 1000);
    mock.state.simulationError = null;
    await signer.heartbeat();
    expect(mock.state.sendCalls).toBe(1);
    const row = signerRows()[0];
    expect(row.raw_tx).toBe(raw);
    expect(row.tx_hash).toBe(hash);
    expect(gasRows()).toHaveLength(before.length);
    expect(gasRows()[0].reserved_wei).toBe(before[0].reserved_wei);
  });

  it("限频记录存在时,交易过期后仍能按原规则同 nonce 替换", async () => {
    const now = Math.floor(Date.now() / 1000);
    await seedActiveJob("throttled-then-expired", { deadline: now + 300, submittedAt: now - 200 });
    mock.state.simulationError = "execution reverted";
    await signer.heartbeat();
    expect(mock.state.sendCalls).toBe(0);
    mock.state.simulationError = null;
    // Deadline passes while the replay throttle is still active; replacement must not wait for it.
    vi.mocked(Date.now).mockReturnValue((NOW + 310) * 1000);
    mock.state.block.timestamp = NOW + 310;
    const result = await signer.execute(job({ id: "replacement-after-throttle" }));
    expect(result.status).toBe("submitted");
    expect(result.nonce).toBe(5);
    expect(mock.state.sendCalls).toBe(1);
    expect(signerRows().find((r) => r.job_id === "throttled-then-expired")?.status).toBe("replaced");
  });

  it("交易过期后仍能按原规则同 nonce 替换", async () => {
    const now = Math.floor(Date.now() / 1000);
    await seedActiveJob("expired-throttled", { deadline: now - 10, submittedAt: now - 200 });
    // Expired transactions are never replayed, so the replay gate does not apply; the original
    // same-nonce replacement path must still run.
    const result = await signer.execute(job({ id: "replacement-after-sim-fail" }));
    expect(result.status).toBe("submitted");
    expect(result.nonce).toBe(5);
    expect(signerRows().find((r) => r.job_id === "expired-throttled")?.status).toBe("replaced");
  });

  it("nonce 已消费但收据缺失时继续保守计费", async () => {
    const now = Math.floor(Date.now() / 1000);
    await seedActiveJob("consumed-no-receipt", { deadline: now + 300, submittedAt: now - 200 });
    mock.state.latestNonce = "0x6";
    mock.state.nonce = "0x6";
    await signer.heartbeat();
    expect(mock.state.sendCalls).toBe(0);
    const row = signerRows().find((r) => r.job_id === "consumed-no-receipt")!;
    expect(row.status).toBe("consumed");
    const expense = gasRows().find((g) => g.job_id === "consumed-no-receipt")!;
    expect(expense.spent_wei).not.toBeNull();
    expect(BigInt(String(expense.spent_wei))).toBeGreaterThan(0n);
  });

  it("旧 pending raw 无法恢复预算时拒绝新签名", async () => {
    await seedActiveJob("unreadable-legacy-pending");
    storage.exec("UPDATE signer_jobs SET raw_tx=?1 WHERE job_id=?2", "0x1234", "unreadable-legacy-pending");
    await expect(signer.execute(job({ id: "after-unreadable-legacy" }))).rejects.toThrow();
    expect(mock.state.sendCalls).toBe(0);
    expect(signerRows()).toHaveLength(1);
    expect(signerRows()[0].status).toBe("submitted");
    expect(gasRows()).toHaveLength(0);
  });

  it("首次只读 status 即恢复并展示旧 pending 的预算预留", async () => {
    await seedActiveJob("legacy-status-first");
    expect(gasRows()).toHaveLength(0);
    const status = await signer.status();
    expect(status.active).toBe(true);
    expect(status.gasBudget).toMatchObject({ reservedWei: "240001000000000" });
    expect(gasRows()).toHaveLength(1);
    expect(mock.state.sendCalls).toBe(0);
  });

  it("预算窗口滚动后仍保留没有 receipt 的旧交易费用负债", async () => {
    environmentOverrides = {
      MAX_TOKEN_GAS_PER_WINDOW_WEI: "400000000000000",
      MAX_TOTAL_GAS_PER_WINDOW_WEI: "1000000000000000",
    };
    restartSigner();
    await seedActiveJob("old-unconfirmed-cost", { deadline: NOW - 10, submittedAt: NOW - 7200 });
    seedExpense("old-unconfirmed-cost", { createdAt: NOW - 7200, nonce: 5 });
    mock.state.latestNonce = "0x6";
    mock.state.nonce = "0x6";
    const blocked = await signer.execute(job({ id: "new-window-job" }));
    expect(blocked.status).toBe("deferred");
    expect(blocked.detail).toMatch(/^token-gas-budget/);
    expect(mock.state.sendCalls).toBe(0);
    expect(gasRows()).toHaveLength(1);
    expect(BigInt(String(gasRows()[0].reserved_wei))).toBeGreaterThan(0n);
  });

  it("同 nonce 的旧交易晚到获胜时，仍能结算旧交易的真实费用", async () => {
    const oldHash = await seedActiveJob("late-old-winner", { deadline: NOW - 10, submittedAt: NOW - 200 });
    const replacement = await signer.execute(job({ id: "late-new-loser" }));
    expect(replacement.status).toBe("submitted");
    mock.state.receipts.set(
      oldHash.toLowerCase(),
      receipt(oldHash, { status: "0x0", gasUsed: "0x186a0", effectiveGasPrice: "0x3b9aca00" }),
    );
    mock.state.latestNonce = "0x6";
    mock.state.nonce = "0x6";
    await signer.heartbeat();

    const oldCost = gasRows().find((expense) => expense.job_id === "late-old-winner")!;
    expect(oldCost.spent_wei).toBe("100000000000000");
    expect(oldCost.settled_at).not.toBeNull();
    const costs = gasRows().reduce((sum, expense) => sum + BigInt(String(expense.spent_wei ?? expense.reserved_wei)), 0n);
    expect(costs).toBe(100_000_000_000_000n);
  });
});
