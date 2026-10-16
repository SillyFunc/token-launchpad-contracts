import { DurableObject } from "cloudflare:workers";
import {
  getAddress,
  keccak256,
  parseTransaction,
  recoverTransactionAddress,
  toHex,
  type Hex,
  type TransactionSerializedLegacy,
} from "viem";
import { getConfig } from "./config";
import { createAlert, getAsset } from "./db";
import { GasLedger } from "./gas-ledger";
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
  gasUsed?: Hex;
  effectiveGasPrice?: Hex;
}

function unixNow(): number {
  return Math.floor(Date.now() / 1000);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export class SignerDurableObject extends DurableObject<Env> {
  private queue: Promise<void> = Promise.resolve();
  private readonly gasLedger: GasLedger;

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
    this.gasLedger = new GasLedger(ctx.storage.sql);
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

  /** Recover reservations when upgrading an existing Signer; unreadable pending data fails closed. */
  private hydrateGasExpenses(now: number): void {
    const config = getConfig(this.env);
    const legacy = this.ctx.storage.sql.exec<SignerJobRow>(
      "SELECT j.* FROM signer_jobs j LEFT JOIN signer_gas_expenses g ON g.job_id=j.job_id " +
        "WHERE g.job_id IS NULL AND (j.status IN ('prepared','submitted','replaced') OR j.submitted_at>?1)",
      now - config.gasBudgetWindowSeconds,
    ).toArray();
    this.ctx.storage.transactionSync(() => {
      for (const row of legacy) {
        const transaction = parseTransaction(row.raw_tx);
        if (!transaction.gas || transaction.gasPrice === undefined || transaction.gasPrice <= 0n) {
          throw new Error(`Cannot recover the gas reservation for ${row.job_id}`);
        }
        this.gasLedger.reserve(
          { id: row.job_id, token: getAddress(row.token), kind: row.kind as PlannedJob["kind"] },
          row.nonce, transaction.gas * transaction.gasPrice, row.submitted_at,
        );
      }
      // Reserve the whole nonce family first, regardless of legacy row iteration order.
      for (const row of legacy) {
        if (row.status === "confirmed" || row.status === "reverted" || row.status === "consumed") {
          this.gasLedger.settleUnknownNonce(row.nonce, row.job_id, now);
        }
      }
    });
  }

  private async settleReceipt(row: SignerJobRow, receipt: RpcReceipt): Promise<void> {
    const reservation = this.gasLedger.get(row.job_id);
    if (!reservation) throw new Error(`Missing gas reservation for ${row.job_id}`);
    const fee = receipt.gasUsed !== undefined && receipt.effectiveGasPrice !== undefined
      ? BigInt(receipt.gasUsed) * BigInt(receipt.effectiveGasPrice)
      : BigInt(reservation.reserved_wei);
    const successful = BigInt(receipt.status) === 1n;
    const now = unixNow();
    this.ctx.storage.transactionSync(() => {
      this.gasLedger.settleNonce(row.nonce, row.job_id, fee, now);
      this.updateStatus(row.job_id, successful ? "confirmed" : "reverted", `block ${BigInt(receipt.blockNumber)}`);
      this.ctx.storage.sql.exec(
        "UPDATE signer_jobs SET status='consumed',detail='another tracked transaction at this nonce was mined' " +
          "WHERE nonce=?1 AND job_id<>?2 AND status IN ('prepared','submitted')",
        row.nonce, row.job_id,
      );
    });
    if (!successful) {
      await createAlert(this.env.DB, "critical", `tx-reverted:${row.job_id}`, `Keeper transaction ${row.tx_hash} reverted`, now);
    }
  }

  /** A replaced transaction may win. Check its receipt before assigning an unknown nonce cost. */
  private async settleConsumedExpenses(): Promise<void> {
    const unsettled = this.ctx.storage.sql.exec<SignerJobRow>(
      "SELECT j.* FROM signer_jobs j JOIN signer_gas_expenses g ON g.job_id=j.job_id " +
        "WHERE g.spent_wei IS NULL ORDER BY j.submitted_at DESC",
    ).toArray();
    if (unsettled.length === 0) return;
    const config = getConfig(this.env);
    const latestNonce = BigInt(await rpcRequest<Hex>(config.readRpcUrl, "eth_getTransactionCount", [config.keeper, "latest"]));
    for (const nonce of new Set(unsettled.map((row) => row.nonce))) {
      if (BigInt(nonce) >= latestNonce) continue;
      const family = unsettled.filter((row) => row.nonce === nonce);
      let winner: SignerJobRow | undefined;
      for (const row of family) {
        const receipt = await rpcRequest<RpcReceipt | null>(config.readRpcUrl, "eth_getTransactionReceipt", [row.tx_hash]);
        if (receipt) {
          await this.settleReceipt(row, receipt);
          winner = row;
          break;
        }
      }
      if (!winner) {
        this.ctx.storage.transactionSync(() => {
          this.gasLedger.settleUnknownNonce(nonce, family[0].job_id, unixNow());
          this.ctx.storage.sql.exec(
            "UPDATE signer_jobs SET status='consumed',detail='nonce advanced; maximum signed gas charged without receipt' " +
              "WHERE nonce=?1 AND status IN ('prepared','submitted')", nonce,
          );
        });
        await createAlert(this.env.DB, "warning", `gas-receipt-missing:${nonce}`, "Nonce advanced without a tracked receipt; gas budget charged conservatively", unixNow());
      }
    }
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

  /**
   * Gate for sending an existing signed transaction (prepared recovery or submitted rebroadcast).
   * Decodes the stored raw transaction, verifies it matches the tracked row, simulates the exact
   * fields at latest state, and rechecks the deadline. Returns false without sending when it fails.
   * Never mutates the raw transaction; a refused check leaves tracking, nonce and gas reservation intact.
   */
  private async replayAllowed(row: SignerJobRow, config: ReturnType<typeof getConfig>, now: number): Promise<{ ok: boolean; reason?: string }> {
    const key = `replay-check:${row.job_id}`;
    const lastCheck = this.ctx.storage.kv.get<number>(key);
    if (lastCheck !== undefined && now - lastCheck < config.pendingRetrySeconds) {
      return { ok: false, reason: `replay check throttled until ${lastCheck + config.pendingRetrySeconds}` };
    }
    this.ctx.storage.kv.put(key, now);

    let transaction: ReturnType<typeof parseTransaction>;
    try {
      transaction = parseTransaction(row.raw_tx);
    } catch (error) {
      return { ok: false, reason: `raw transaction unreadable: ${errorMessage(error)}` };
    }
    if (keccak256(row.raw_tx).toLowerCase() !== row.tx_hash.toLowerCase()) {
      return { ok: false, reason: "raw transaction hash does not match tracked hash" };
    }
    if (transaction.chainId !== config.chainId || transaction.nonce !== row.nonce) {
      return { ok: false, reason: "raw transaction chain or nonce does not match tracked row" };
    }
    if (!transaction.to || getAddress(transaction.to) !== getAddress(row.target)) {
      return { ok: false, reason: "raw transaction target does not match tracked target" };
    }
    const sender = await recoverTransactionAddress({ serializedTransaction: row.raw_tx as TransactionSerializedLegacy });
    if (getAddress(sender) !== getAddress(config.keeper)) {
      return { ok: false, reason: "raw transaction signer is not the keeper" };
    }

    try {
      await rpcRequest<Hex>(config.readRpcUrl, "eth_call", [
        {
          from: config.keeper,
          to: transaction.to,
          data: transaction.data ?? "0x",
          value: toHex(transaction.value ?? 0n),
          gas: toHex(transaction.gas ?? 0n),
          gasPrice: toHex(transaction.gasPrice ?? 0n),
        },
        "latest",
      ]);
    } catch (error) {
      return { ok: false, reason: `replay simulation failed: ${errorMessage(error)}` };
    }

    if (unixNow() > row.deadline) return { ok: false, reason: "deadline expired during replay simulation" };
    return { ok: true };
  }

  private async reconcile(
    row: SignerJobRow,
    allowReplacement: boolean,
  ): Promise<{ busy: boolean; replacementGasFloor?: bigint; replacementNonce?: number; replacementJobId?: string }> {
    const config = getConfig(this.env);
    const existingReceipt = await rpcRequest<RpcReceipt | null>(config.readRpcUrl, "eth_getTransactionReceipt", [row.tx_hash]);
    if (existingReceipt) {
      await this.settleReceipt(row, existingReceipt);
      return { busy: false };
    }

    if (row.status === "prepared" && unixNow() <= row.deadline) {
      const gate = await this.replayAllowed(row, config, unixNow());
      if (!gate.ok) {
        this.ctx.storage.sql.exec("UPDATE signer_jobs SET detail=?1 WHERE job_id=?2", String(gate.reason).slice(0, 1000), row.job_id);
        return { busy: true };
      }
      const hash = await this.broadcast(row.raw_tx);
      this.ctx.storage.sql.exec(
        "UPDATE signer_jobs SET status='submitted',tx_hash=?1,submitted_at=?2,attempts=attempts+1 WHERE job_id=?3",
        hash,
        unixNow(),
        row.job_id,
      );
      return { busy: true };
    }

    const now = unixNow();
    if (now - row.submitted_at < config.pendingRetrySeconds) return { busy: true };
    if (now <= row.deadline) {
      const gate = await this.replayAllowed(row, config, now);
      if (!gate.ok) {
        this.ctx.storage.sql.exec("UPDATE signer_jobs SET detail=?1 WHERE job_id=?2", String(gate.reason).slice(0, 1000), row.job_id);
        return { busy: true };
      }
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
      this.ctx.storage.transactionSync(() => this.gasLedger.settleUnknownNonce(row.nonce, row.job_id, now));
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

    return {
      busy: false,
      replacementGasFloor: (BigInt(row.gas_price) * 9n) / 8n + 1n,
      replacementNonce: row.nonce,
      replacementJobId: row.job_id,
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
    this.hydrateGasExpenses(now);
    await this.settleConsumedExpenses();

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
    let replacementJobId: string | undefined;
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
      replacementJobId = state.replacementJobId;
    }

    const asset = await getAsset(this.env.DB, config.chainId, getAddress(job.token));
    if (!asset || asset.status !== "active") return { jobId: job.id, status: "skipped", detail: "asset is not active" };
    const expectedTarget = job.kind === "tax" || job.kind === "liquidity" ? asset.tax_processor : asset.vault;
    if (!expectedTarget || getAddress(expectedTarget) !== getAddress(job.target)) {
      return { jobId: job.id, status: "skipped", detail: "job target does not match the D1 asset registry" };
    }

    const interval = job.kind === "tax" ? config.taxExecutionIntervalSeconds
      : job.kind === "liquidity" ? config.liquidityExecutionIntervalSeconds : 0;
    const latestAttempt = this.gasLedger.latestAttemptAt(job.token, job.kind, replacementNonce);
    if (latestAttempt !== null && now < latestAttempt + interval) {
      return { jobId: job.id, status: "deferred", detail: `cooldown: next ${job.kind} attempt at ${latestAttempt + interval}` };
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
    const maximumFee = gas * gasPrice;
    if (plan.economicValueWei <= 0n || maximumFee * 10_000n > plan.economicValueWei * BigInt(config.maxGasCostBps)) {
      return { jobId: job.id, status: "deferred", detail: `gas-ratio: maximum fee ${maximumFee} wei exceeds ${config.maxGasCostBps} bps of processing value ${plan.economicValueWei} wei` };
    }
    const projected = this.gasLedger.projectedUsage(job.token, nonce, maximumFee, now, config.gasBudgetWindowSeconds);
    if (projected.token > config.maxTokenGasPerWindowWei) {
      return { jobId: job.id, status: "deferred", detail: `token-gas-budget: ${projected.token} wei exceeds ${config.maxTokenGasPerWindowWei} wei` };
    }
    if (projected.global > config.maxTotalGasPerWindowWei) {
      return { jobId: job.id, status: "deferred", detail: `global-gas-budget: ${projected.global} wei exceeds ${config.maxTotalGasPerWindowWei} wei` };
    }
    const requiredBalance = maximumFee + config.minKeeperBalanceWei;
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
    this.ctx.storage.transactionSync(() => {
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
      this.gasLedger.reserve(job, nonce, maximumFee, now);
      if (replacementJobId) this.updateStatus(replacementJobId, "replaced", "deadline expired; replacement persisted at the same nonce");
    });

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
      this.hydrateGasExpenses(unixNow());
      await this.settleConsumedExpenses();
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
    const config = getConfig(this.env);
    // Local recovery only: an admin read must not broadcast or reconcile a transaction.
    this.hydrateGasExpenses(unixNow());
    const usage = this.gasLedger.usage(unixNow(), config.gasBudgetWindowSeconds);
    const gasBudget = { windowSeconds: config.gasBudgetWindowSeconds, spentWei: usage.spent.toString(), reservedWei: usage.pending.toString(), maximumWei: config.maxTotalGasPerWindowWei.toString() };
    const active = this.one(
      "SELECT * FROM signer_jobs WHERE status IN ('prepared','submitted') ORDER BY submitted_at ASC LIMIT 1",
    );
    if (!active) return { active: false, gasBudget };
    return {
      active: true,
      gasBudget,
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
