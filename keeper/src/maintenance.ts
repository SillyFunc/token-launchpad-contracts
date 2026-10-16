import { getAddress } from "viem";
import { executionEnabled } from "./controls";
import { recordBuybackReadiness, recordTransaction } from "./db";
import { buildExecutionPlan, inspectAsset, storeCurrentSample } from "./planner";
import type { AssetRow, AssetSnapshot, ExecutionPlan, JobKind, KeeperConfig, PlannedJob, SignerResult } from "./types";

/** Only reading/planning errors may be treated as an individual asset check failure. */
export class MaintenanceInspectionError extends Error {}

export async function maintainToken(
  db: D1Database,
  config: KeeperConfig,
  asset: AssetRow,
  runId: string,
  signer: { execute(job: PlannedJob): Promise<SignerResult> },
  now: () => number = () => Math.floor(Date.now() / 1000),
): Promise<{ planned: number; submitted: number }> {
  const counts = { planned: 0, submitted: 0 };
  let snapshot: AssetSnapshot;
  try {
    snapshot = await inspectAsset(config, asset);
    await storeCurrentSample(db, config, snapshot);
    if (snapshot.asset.vault) {
      await recordBuybackReadiness(
        db, config.chainId, getAddress(asset.token), snapshot.vaultReadiness, snapshot.vaultExecutableAmount, now(),
      );
    }
  } catch (error) {
    throw new MaintenanceInspectionError(error instanceof Error ? error.message : String(error), { cause: error });
  }
  for (const kind of ["tax", "liquidity", "buyback"] as const satisfies readonly JobKind[]) {
    if (!executionEnabled(snapshot, kind)) continue;
    let plan: ExecutionPlan | null;
    try {
      plan = await buildExecutionPlan(db, config, snapshot, kind, now());
    } catch (error) {
      throw new MaintenanceInspectionError(error instanceof Error ? error.message : String(error), { cause: error });
    }
    if (!plan) continue;
    const job = { ...plan.job, id: `${runId}:${kind}:${plan.job.token.toLowerCase()}` };
    counts.planned += 1;
    // Signer rechecks state, prices, simulation, cooldowns and persisted gas budgets.
    // Its errors and recording errors must reach Workflow retries after a money action.
    const result = await signer.execute(job);
    await recordTransaction(
      db, runId, config.chainId, kind, getAddress(job.token), getAddress(job.target), result, now(),
    );
    if (result.status === "submitted" || (result.status === "already-submitted" && result.txHash)) {
      counts.submitted += 1;
    }
    // Deferred/skipped candidates changed no funds, so reuse this snapshot. Signer
    // always rereads before signing; after submission a later run reads mined state.
    if (result.status === "submitted" || result.status === "already-submitted" || result.status === "busy") break;
  }
  return counts;
}
