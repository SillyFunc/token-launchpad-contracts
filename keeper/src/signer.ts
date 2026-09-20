import { DurableObject } from "cloudflare:workers";
import { getAddress, keccak256, type Hex } from "viem";
import { getConfig } from "./config";
import { createAlert, getAsset } from "./db";
import { buildExecutionPlan, inspectAsset } from "./planner";
import { rpcBatch, rpcRequest } from "./rpc";
import { keeperAccount, signLegacyKeeperTransaction } from "./transaction";
import type { Env, PlannedJob, SignerResult } from "./types";

interface SignerJobRow {
  [key: string]: string | number | null;
  job_id: string;
  kind: string;
  token: string;
  target: string;
  status: string;
  tx_hash: Hex;
  nonce: number;
  raw_tx: Hex;
  gas_price: string;
  deadline: number;
  submitted_at: number;
  attempts: number;
  detail: string | null;
}

interface RpcReceipt {
  transactionHash: Hex;
  status: Hex;
  blockNumber: Hex;
}

function unixNow(): number {
  return Math.floor(Date.now() / 1000);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export class SignerDurableObject extends DurableObject<Env> {
  private queue: Promise<void> = Promise.resolve();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS signer_jobs (
        job_id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        token TEXT NOT NULL,
        target TEXT NOT NULL,
        status TEXT NOT NULL,
        tx_hash TEXT NOT NULL,
        nonce INTEGER NOT NULL,
        raw_tx TEXT NOT NULL,
        gas_price TEXT NOT NULL,
        deadline INTEGER NOT NULL,
        submitted_at INTEGER NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 1,
        detail TEXT
      )
    `);
  }

  private one(sql: string, ...bindings: unknown[]): SignerJobRow | null {
    const rows = this.ctx.storage.sql.exec<SignerJobRow>(sql, ...bindings).toArray();
    return rows[0] ?? null;
  }

  private updateStatus(jobId: string, status: string, detail?: string): void {
    this.ctx.storage.sql.exec(
      "UPDATE signer_jobs SET status=?1, detail=?2 WHERE job_id=?3",
      status,
      detail?.slice(0, 1000) ?? null,
      jobId,
    );
  }

  private async broadcast(rawTransaction: Hex): Promise<Hex> {
    const config = getConfig(this.env);
    const expectedHash = keccak256(rawTransaction);
    try {
      const returnedHash = await rpcRequest<Hex>(config.sendRpcUrl, "eth_sendRawTransaction", [rawTransaction]);
      if (returnedHash.toLowerCase() !== expectedHash.toLowerCase()) {
        throw new Error(`Private RPC returned an unexpected transaction hash`);
      }
    } catch (error) {
      const message = errorMessage(error).toLowerCase();
      if (!message.includes("already known") && !message.includes("known transaction") && !message.includes("nonce too low")) {
        throw error;
      }
    }
    return expectedHash;
  }

  private async reconcile(
    row: SignerJobRow,
    allowReplacement: boolean,
  ): Promise<{ busy: boolean; replacementGasFloor?: bigint; replacementNonce?: number }> {
    const config = getConfig(this.env);
    if (row.status === "prepared") {
      const hash = await this.broadcast(row.raw_tx);
      this.ctx.storage.sql.exec(
        "UPDATE signer_jobs SET status='submitted',tx_hash=?1,submitted_at=?2,attempts=attempts+1 WHERE job_id=?3",
        hash,
        unixNow(),
        row.job_id,
      );
      return { busy: true };
    }

    const receipt = await rpcRequest<RpcReceipt | null>(config.readRpcUrl, "eth_getTransactionReceipt", [row.tx_hash]);
    if (receipt) {
      const successful = BigInt(receipt.status) === 1n;
      this.updateStatus(row.job_id, successful ? "confirmed" : "reverted", `block ${BigInt(receipt.blockNumber)}`);
      if (!successful) {
        await createAlert(
          this.env.DB,
          "critical",
          `tx-reverted:${row.job_id}`,
          `Keeper transaction ${row.tx_hash} reverted`,
          unixNow(),
        );
      }
      return { busy: false };
    }

    const now = unixNow();
    if (now - row.submitted_at < config.pendingRetrySeconds) return { busy: true };
    if (now <= row.deadline) {
      try {
        await this.broadcast(row.raw_tx);
        this.ctx.storage.sql.exec(
          "UPDATE signer_jobs SET submitted_at=?1,attempts=attempts+1,detail='rebroadcast' WHERE job_id=?2",
          now,
          row.job_id,
        );
      } catch (error) {
        this.ctx.storage.sql.exec(
          "UPDATE signer_jobs SET detail=?1 WHERE job_id=?2",
          `rebroadcast failed: ${errorMessage(error)}`.slice(0, 1000),
          row.job_id,
        );
      }
      return { busy: true };
    }

    const [latestNonceHex] = await rpcBatch<Hex>(config.readRpcUrl, [
      { method: "eth_getTransactionCount", params: [config.keeper, "latest"] },
    ]);
    if (BigInt(latestNonceHex) > BigInt(row.nonce)) {
      this.updateStatus(row.job_id, "consumed", "nonce advanced without a receipt from the configured read RPC");
      return { busy: false };
    }

    if (!allowReplacement) {
      await createAlert(
        this.env.DB,
        "warning",
        `pending-expired:${row.job_id}`,
        `Keeper transaction ${row.tx_hash} is past its deadline and awaits replacement by the next eligible job`,
        now,
      );
      return { busy: true };
    }

    this.updateStatus(row.job_id, "replaced", "deadline expired; replacing with a freshly simulated keeper job");
    return {
      busy: false,
      replacementGasFloor: (BigInt(row.gas_price) * 9n) / 8n + 1n,
      replacementNonce: row.nonce,
    };
  }

  async execute(job: PlannedJob): Promise<SignerResult> {
    const operation = this.queue.then(() => this.executeLocked(job));
    this.queue = operation.then(
      () => undefined,
      () => undefined,
    );
    return operation;
  }

  private async executeLocked(job: PlannedJob): Promise<SignerResult> {
    const config = getConfig(this.env);
    const now = unixNow();
    if (job.chainId !== config.chainId) throw new Error("Job chain does not match keeper chain");
    if (job.createdAt > now + 60 || now - job.createdAt > 900) {
      return { jobId: job.id, status: "skipped", detail: "stale or future-dated job" };
    }

    const privateKey = this.env.KEEPER_PRIVATE_KEY;
    keeperAccount(privateKey, config.keeper);

    const existing = this.one("SELECT * FROM signer_jobs WHERE job_id=?1", job.id);
    if (existing) {
      if (existing.status === "prepared" || existing.status === "submitted") {
        const state = await this.reconcile(existing, false);
        if (state.busy) {
          return {
            jobId: job.id,
            status: "already-submitted",
            txHash: existing.tx_hash,
            nonce: existing.nonce,
            detail: existing.status,
          };
        }
      }
      return {
        jobId: job.id,
        status: "already-submitted",
        txHash: existing.tx_hash,
        nonce: existing.nonce,
        detail: existing.status,
      };
    }

    let replacementGasFloor = 0n;
    let replacementNonce: number | undefined;
    const active = this.one(
      "SELECT * FROM signer_jobs WHERE status IN ('prepared','submitted') ORDER BY submitted_at ASC LIMIT 1",
    );
    if (active) {
      const state = await this.reconcile(active, true);
      if (state.busy) {
        return { jobId: job.id, status: "busy", txHash: active.tx_hash, nonce: active.nonce, detail: active.job_id };
      }
      replacementGasFloor = state.replacementGasFloor ?? 0n;
      replacementNonce = state.replacementNonce;
    }

    const asset = await getAsset(this.env.DB, config.chainId, getAddress(job.token));
    if (!asset || asset.status !== "active") return { jobId: job.id, status: "skipped", detail: "asset is not active" };
    const expectedTarget = job.kind === "tax" ? asset.tax_processor : asset.vault;
    if (!expectedTarget || getAddress(expectedTarget) !== getAddress(job.target)) {
      return { jobId: job.id, status: "skipped", detail: "job target does not match the D1 asset registry" };
    }

    const snapshot = await inspectAsset(config, asset);
    const plan = await buildExecutionPlan(this.env.DB, config, snapshot, job.kind, now);
    if (!plan) return { jobId: job.id, status: "skipped", detail: "execution conditions or price policy are not satisfied" };
    if (getAddress(plan.target) !== getAddress(job.target)) {
      return { jobId: job.id, status: "skipped", detail: "replanned target mismatch" };
    }

    try {
      await rpcRequest<Hex>(config.readRpcUrl, "eth_call", [
        { from: config.keeper, to: plan.target, data: plan.data },
        "latest",
      ]);
    } catch (error) {
      return { jobId: job.id, status: "skipped", detail: `simulation failed: ${errorMessage(error)}` };
    }

    const tx = { from: config.keeper, to: plan.target, data: plan.data, value: "0x0" };
    const [nonceHex, gasPriceHex, balanceHex, gasEstimateHex] = await rpcBatch<Hex>(config.readRpcUrl, [
      { method: "eth_getTransactionCount", params: [config.keeper, "pending"] },
      { method: "eth_gasPrice", params: [] },
      { method: "eth_getBalance", params: [config.keeper, "latest"] },
      { method: "eth_estimateGas", params: [tx, "latest"] },
    ]);
    const nonce = replacementNonce ?? Number(BigInt(nonceHex));
    const gas = (BigInt(gasEstimateHex) * 12n) / 10n + 1n;
    let gasPrice = (BigInt(gasPriceHex) * BigInt(config.gasPriceMultiplierBps)) / 10_000n;
    if (gasPrice < replacementGasFloor) gasPrice = replacementGasFloor;
    if (gasPrice > config.maxGasPriceWei) {
      await createAlert(this.env.DB, "warning", "gas-price-high", `Gas price ${gasPrice} exceeds keeper limit`, now);
      return { jobId: job.id, status: "skipped", detail: "gas price exceeds configured maximum" };
    }
    const requiredBalance = gas * gasPrice + config.minKeeperBalanceWei;
    if (BigInt(balanceHex) < requiredBalance) {
      await createAlert(
        this.env.DB,
        "critical",
        "keeper-balance-low",
        `Keeper balance is below gas requirement plus reserve (${requiredBalance} wei required)`,
        now,
      );
      return { jobId: job.id, status: "skipped", detail: "keeper BNB balance is too low" };
    }

    const { rawTransaction, txHash } = await signLegacyKeeperTransaction(privateKey, config.keeper, {
      chainId: config.chainId,
      to: plan.target,
      data: plan.data,
      nonce,
      gas,
      gasPrice,
    });
    this.ctx.storage.sql.exec(
      "INSERT INTO signer_jobs(job_id,kind,token,target,status,tx_hash,nonce,raw_tx,gas_price,deadline,submitted_at,attempts) " +
        "VALUES(?1,?2,?3,?4,'submitted',?5,?6,?7,?8,?9,?10,1)",
      job.id,
      job.kind,
      job.token.toLowerCase(),
      plan.target.toLowerCase(),
      txHash,
      nonce,
      rawTransaction,
      gasPrice.toString(),
      Number(plan.deadline),
      now,
    );

    try {
      await this.broadcast(rawTransaction);
    } catch (error) {
      this.ctx.storage.sql.exec(
        "UPDATE signer_jobs SET detail=?1 WHERE job_id=?2",
        `initial broadcast uncertain: ${errorMessage(error)}`.slice(0, 1000),
        job.id,
      );
    }
    return { jobId: job.id, status: "submitted", txHash, nonce };
  }

  async heartbeat(): Promise<Record<string, unknown>> {
    const operation = this.queue.then(async () => {
      const active = this.one(
        "SELECT * FROM signer_jobs WHERE status IN ('prepared','submitted') ORDER BY submitted_at ASC LIMIT 1",
      );
      if (!active) return { active: false };
      const state = await this.reconcile(active, false);
      return {
        active: state.busy,
        jobId: active.job_id,
        txHash: active.tx_hash,
        nonce: active.nonce,
      };
    });
    this.queue = operation.then(
      () => undefined,
      () => undefined,
    );
    return operation;
  }

  async status(): Promise<Record<string, unknown>> {
    const active = this.one(
      "SELECT * FROM signer_jobs WHERE status IN ('prepared','submitted') ORDER BY submitted_at ASC LIMIT 1",
    );
    if (!active) return { active: false };
    return {
      active: true,
      jobId: active.job_id,
      kind: active.kind,
      token: active.token,
      target: active.target,
      txHash: active.tx_hash,
      nonce: active.nonce,
      submittedAt: active.submitted_at,
      attempts: active.attempts,
      detail: active.detail,
    };
  }
}
