import { beforeEach, describe, expect, it, vi } from "vitest";

const TOKEN = "0x77f117df69e4345fCfF11Bc4AFE4eB41339F8888";
const TAX_PROCESSOR = "0x60ce1D8E40473668932845DD3c3E34Dd0B8c178d";
const PAIR = "0xB7bcaD5AfBa34a8B1Ad16F35982347e3260E9084";
const WBNB = "0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd";
const KEEPER = "0x9f87b1973361b23387D7F1b536484543a5ea1eFB";

const mock = vi.hoisted(() => ({
  startRun: vi.fn(),
  finishRun: vi.fn(),
  markAssetChecked: vi.fn(),
  recordTransaction: vi.fn(),
  heartbeat: vi.fn(async () => ({ active: false })),
  execute: vi.fn(),
}));

vi.mock("cloudflare:workers", () => ({
  WorkflowEntrypoint: class {
    readonly env: unknown;
    constructor(_ctx: unknown, env: unknown) {
      this.env = env;
    }
  },
}));

vi.mock("../src/config", () => ({
  getConfig: () => ({
    chainId: 97,
    readRpcUrl: "https://read.invalid/",
    sendRpcUrl: "https://send.invalid/",
    coordinator: "0x9a7594114f4b79544f7CA00FBd1E902C556BbC47",
    keeper: KEEPER,
    discoveryPageSize: 8,
    maxAssetsPerRun: 8,
    checkIntervalSeconds: 60,
  }),
}));

vi.mock("../src/db", () => ({
  startRun: mock.startRun,
  finishRun: mock.finishRun,
  listDueAssets: async () => [
    {
      chain_id: 97,
      token: TOKEN,
      tax_processor: TAX_PROCESSOR,
      vault: null,
      pair: PAIR,
      wbnb: WBNB,
      status: "active",
      next_check_at: 0,
      last_checked_at: null,
      last_error: null,
    },
  ],
  markAssetChecked: mock.markAssetChecked,
  recordTransaction: mock.recordTransaction,
}));

vi.mock("../src/discovery", () => ({ discoverAssets: async () => 1 }));
vi.mock("../src/health", () => ({ assertEnvironment: async () => undefined }));
vi.mock("../src/planner", () => ({
  inspectAsset: async (_config: unknown, asset: unknown) => ({ asset }),
  storeCurrentSample: async () => undefined,
  buildExecutionPlan: async (_db: unknown, _config: unknown, _snapshot: unknown, kind: string) =>
    kind === "tax"
      ? {
          job: {
            id: "block-derived-id",
            kind: "tax",
            chainId: 97,
            token: TOKEN,
            target: TAX_PROCESSOR,
            snapshotBlock: "123",
            createdAt: 1_700_000_000,
          },
        }
      : null,
}));

const { KeeperWorkflow } = await import("../src/workflow");

describe("KeeperWorkflow free-tier orchestration", () => {
  const env = {
    DB: {},
    SIGNER: {
      idFromName: () => "signer-id",
      get: () => ({ heartbeat: mock.heartbeat, execute: mock.execute }),
    },
  };

  beforeEach(() => {
    vi.clearAllMocks();
    mock.execute.mockImplementation(async (job: { id: string }) => ({
      jobId: job.id,
      status: "submitted",
      txHash: `0x${"34".repeat(32)}`,
      nonce: 7,
    }));
  });

  it("uses one Workflow step with an explicit retry limit and a deterministic signer job id", async () => {
    const workflow = new KeeperWorkflow({} as never, env as never);
    const stepNames: string[] = [];
    const stepConfigs: unknown[] = [];
    const step = {
      // 真实签名是 step.do(name, config, callback)，config 可省略；两种形态都要支持。
      do: async (
        _name: string,
        configOrCallback: unknown,
        maybeCallback?: () => Promise<unknown>,
      ) => {
        stepNames.push(_name);
        if (typeof configOrCallback === "function") return configOrCallback();
        stepConfigs.push(configOrCallback);
        return maybeCallback ? maybeCallback() : undefined;
      },
    };
    const event = {
      instanceId: "97-cron-1700000000000",
      payload: { trigger: "cron", requestedAt: 1_700_000_000 },
    };

    const result = await workflow.run(event as never, step as never);

    expect(stepNames).toEqual(["keeper-run"]);
    // 重试不占 step 额度，但平台默认 limit=5 会让失败拖过后续 Cron 轮次；锁死显式配置。
    expect(stepConfigs).toEqual([
      { retries: { limit: 2, delay: "10 seconds", backoff: "exponential" } },
    ]);
    expect(result).toMatchObject({ discovered: 1, inspected: 1, planned: 1, submitted: 1 });
    expect(mock.execute).toHaveBeenCalledWith(
      expect.objectContaining({ id: `97-cron-1700000000000:tax:${TOKEN.toLowerCase()}` }),
    );
    expect(mock.recordTransaction).toHaveBeenCalledTimes(1);
    expect(mock.markAssetChecked).toHaveBeenCalledTimes(1);
    expect(mock.finishRun).toHaveBeenCalledWith(
      env.DB,
      event.instanceId,
      expect.any(Number),
      expect.objectContaining({ submitted: 1 }),
    );
  });
});
