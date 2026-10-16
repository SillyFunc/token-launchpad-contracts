import { WorkflowEntrypoint, type WorkflowEvent, type WorkflowStep } from "cloudflare:workers";
import { getAddress } from "viem";
import { getConfig } from "./config";
import {
  finishRun,
  listDueAssets,
  markAssetChecked,
  startRun,
} from "./db";
import { discoverAssets } from "./discovery";
import { assertEnvironment } from "./health";
import { maintainToken, MaintenanceInspectionError } from "./maintenance";
import type { Env, KeeperWorkflowPayload } from "./types";

function unixNow(): number {
  return Math.floor(Date.now() / 1000);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/// @dev 显式限制重试：平台默认 limit=5（指数退避约 10s/20s/40s/80s/160s）会让一次失败拖到
///      约 5 分钟才落定，期间后续 Cron 轮次已并发开跑、重复做同样的发现与检查，失败也更晚
///      写进 keeper_runs。limit=2 把退避压到约 30 秒，单轮通常在下一次 60 秒 Cron 之前结束。
///      重试不计入 step 额度,限制重试是为了控制单步
///      生命周期与重复外部调用，不是为了省 step。
const RUN_STEP_CONFIG = {
  retries: { limit: 2, delay: "10 seconds", backoff: "exponential" },
} as const;

export class KeeperWorkflow extends WorkflowEntrypoint<Env, KeeperWorkflowPayload> {
  async run(event: WorkflowEvent<KeeperWorkflowPayload>, step: WorkflowStep) {
    // Workflows Free 每天 3,000 steps、每步 10 ms CPU：每分钟一次 Cron 若拆成多个 step
    // （健康检查、发现、每个资产、每笔交易各自成步），会稳定超过 step 额度并停止执行。
    // 整轮只保留一个 step，日常用量 1,440 steps/day；单步 CPU 有界依赖每轮最多 8 个资产。
    // 资金动作仍由 Signer Durable Object 串行、持久化并去重。
    return step.do("keeper-run", RUN_STEP_CONFIG, async () => {
      const config = getConfig(this.env);
      const runId = event.instanceId;
      const counts = { discovered: 0, inspected: 0, planned: 0, submitted: 0 };
      await startRun(this.env.DB, runId, event.payload.trigger, unixNow());

      try {
        await assertEnvironment(config);
        const signerId = this.env.SIGNER.idFromName(`${config.chainId}:${config.keeper.toLowerCase()}`);
        const signer = this.env.SIGNER.get(signerId);
        await signer.heartbeat();

        counts.discovered = await discoverAssets(this.env, config, unixNow());
        const assets = await listDueAssets(this.env.DB, config.chainId, unixNow(), config.maxAssetsPerRun);

        for (const asset of assets) {
          counts.inspected += 1;
          const now = unixNow();
          try {
            const result = await maintainToken(this.env.DB, config, asset, runId, signer);
            counts.planned += result.planned;
            counts.submitted += result.submitted;
          } catch (error) {
            if (!(error instanceof MaintenanceInspectionError)) throw error;
            await markAssetChecked(
              this.env.DB,
              config.chainId,
              getAddress(asset.token),
              now,
              now + config.checkIntervalSeconds,
              errorMessage(error),
            );
            continue;
          }

          await markAssetChecked(
            this.env.DB,
            config.chainId,
            getAddress(asset.token),
            now,
            now + config.checkIntervalSeconds,
          );
        }

        await finishRun(this.env.DB, runId, unixNow(), counts);
        return counts;
      } catch (error) {
        await finishRun(this.env.DB, runId, unixNow(), counts, errorMessage(error));
        throw error;
      }
    });
  }
}
