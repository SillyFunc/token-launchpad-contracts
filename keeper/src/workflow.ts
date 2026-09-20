import { WorkflowEntrypoint, type WorkflowEvent, type WorkflowStep } from "cloudflare:workers";
import { getAddress } from "viem";
import { getConfig } from "./config";
import {
  finishRun,
  listDueAssets,
  markAssetChecked,
  recordTransaction,
  startRun,
} from "./db";
import { discoverAssets } from "./discovery";
import { assertEnvironment } from "./health";
import { buildExecutionPlan, inspectAsset, storeCurrentSample } from "./planner";
import type { Env, KeeperWorkflowPayload, PlannedJob } from "./types";

function unixNow(): number {
  return Math.floor(Date.now() / 1000);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export class KeeperWorkflow extends WorkflowEntrypoint<Env, KeeperWorkflowPayload> {
  async run(event: WorkflowEvent<KeeperWorkflowPayload>, step: WorkflowStep) {
    const config = getConfig(this.env);
    const runId = event.instanceId;
    const counts = { discovered: 0, inspected: 0, planned: 0, submitted: 0 };
    await step.do("start-run", async () => {
      await startRun(this.env.DB, runId, event.payload.trigger, unixNow());
      return { ok: true };
    });

    try {
      await step.do("verify-chain-and-role", async () => {
        await assertEnvironment(config);
        return { ok: true };
      });

      const signerId = this.env.SIGNER.idFromName(`${config.chainId}:${config.keeper.toLowerCase()}`);
      const signer = this.env.SIGNER.get(signerId);
      await step.do("reconcile-signer", async () => signer.heartbeat());

      counts.discovered = await step.do("discover-assets", async () =>
        discoverAssets(this.env, config, unixNow()),
      );

      const assets = await step.do("select-assets", async () =>
        listDueAssets(this.env.DB, config.chainId, unixNow(), config.maxAssetsPerRun),
      );
      const jobs: PlannedJob[] = [];
      for (const asset of assets) {
        const suffix = asset.token.slice(2, 10).toLowerCase();
        const assetJobs = await step.do(`inspect-${suffix}`, async () => {
          const now = unixNow();
          try {
            const snapshot = await inspectAsset(config, asset);
            await storeCurrentSample(this.env.DB, config, snapshot);
            const planned = await Promise.all([
              buildExecutionPlan(this.env.DB, config, snapshot, "tax", now),
              buildExecutionPlan(this.env.DB, config, snapshot, "buyback", now),
            ]);
            await markAssetChecked(
              this.env.DB,
              config.chainId,
              getAddress(asset.token),
              now,
              now + config.checkIntervalSeconds,
            );
            return planned.filter((plan) => plan !== null).map((plan) => plan.job);
          } catch (error) {
            await markAssetChecked(
              this.env.DB,
              config.chainId,
              getAddress(asset.token),
              now,
              now + config.checkIntervalSeconds,
              errorMessage(error),
            );
            return [];
          }
        });
        counts.inspected += 1;
        jobs.push(...assetJobs);
      }
      counts.planned = jobs.length;

      for (const job of jobs) {
        const result = await step.do(`execute-${job.id}`, async () => {
          const signerResult = await signer.execute(job);
          await recordTransaction(
            this.env.DB,
            runId,
            config.chainId,
            job.kind,
            getAddress(job.token),
            getAddress(job.target),
            signerResult,
            unixNow(),
          );
          return signerResult;
        });
        if (result.status === "submitted") counts.submitted += 1;
      }

      await step.do("finish-run", async () => {
        await finishRun(this.env.DB, runId, unixNow(), counts);
        return counts;
      });
      return counts;
    } catch (error) {
      await step.do("fail-run", async () => {
        await finishRun(this.env.DB, runId, unixNow(), counts, errorMessage(error));
        return { failed: true };
      });
      throw error;
    }
  }
}
