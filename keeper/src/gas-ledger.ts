import type { JobKind, PlannedJob } from "./types";

interface GasExpenseRow {
  [key: string]: string | number | null;
  job_id: string;
  token: string;
  kind: string;
  nonce: number;
  reserved_wei: string;
  spent_wei: string | null;
  created_at: number;
  settled_at: number | null;
}

export interface GasUsage {
  spent: bigint;
  pending: bigint;
  total: bigint;
}

/** Owned by the serialized Signer. Wei remain decimal strings in SQLite. */
export class GasLedger {
  constructor(private readonly sql: SqlStorage) {
    sql.exec(`CREATE TABLE IF NOT EXISTS signer_gas_expenses (
      job_id TEXT PRIMARY KEY, token TEXT NOT NULL, kind TEXT NOT NULL,
      nonce INTEGER NOT NULL, reserved_wei TEXT NOT NULL, spent_wei TEXT,
      created_at INTEGER NOT NULL, settled_at INTEGER
    )`);
  }

  get(jobId: string): GasExpenseRow | null {
    return this.sql.exec<GasExpenseRow>("SELECT * FROM signer_gas_expenses WHERE job_id=?1", jobId).toArray()[0] ?? null;
  }

  reserve(job: Pick<PlannedJob, "id" | "token" | "kind">, nonce: number, maximumFee: bigint, now: number): void {
    if (maximumFee <= 0n) throw new Error("Gas reservation must be positive");
    const original = this.sql.exec<{ first_attempt: number | null }>(
      "SELECT MIN(created_at) AS first_attempt FROM signer_gas_expenses WHERE token=?1 AND kind=?2 AND nonce=?3",
      job.token.toLowerCase(), job.kind, nonce,
    ).toArray()[0]?.first_attempt;
    this.sql.exec(
      "INSERT OR IGNORE INTO signer_gas_expenses(job_id,token,kind,nonce,reserved_wei,created_at) VALUES(?1,?2,?3,?4,?5,?6)",
      job.id, job.token.toLowerCase(), job.kind, nonce, maximumFee.toString(), original ?? now,
    );
  }

  private expenses(now: number, windowSeconds: number, token?: string): GasExpenseRow[] {
    const condition = "(spent_wei IS NULL OR settled_at>?1)";
    return token
      ? this.sql.exec<GasExpenseRow>(`SELECT * FROM signer_gas_expenses WHERE ${condition} AND token=?2`, now - windowSeconds, token.toLowerCase()).toArray()
      : this.sql.exec<GasExpenseRow>(`SELECT * FROM signer_gas_expenses WHERE ${condition}`, now - windowSeconds).toArray();
  }

  usage(now: number, windowSeconds: number, token?: string): GasUsage {
    let spent = 0n;
    const pendingNonces = new Map<number, bigint>();
    for (const row of this.expenses(now, windowSeconds, token)) {
      if (row.spent_wei !== null) spent += BigInt(row.spent_wei);
      else {
        const reserved = BigInt(row.reserved_wei);
        if (reserved > (pendingNonces.get(row.nonce) ?? 0n)) pendingNonces.set(row.nonce, reserved);
      }
    }
    const pending = [...pendingNonces.values()].reduce((sum, amount) => sum + amount, 0n);
    return { spent, pending, total: spent + pending };
  }

  projectedUsage(token: string, nonce: number, maximumFee: bigint, now: number, windowSeconds: number) {
    const project = (scope?: string) => {
      const current = this.usage(now, windowSeconds, scope).total;
      const sameNonce = this.expenses(now, windowSeconds, scope)
        .filter((row) => row.nonce === nonce && row.spent_wei === null)
        .reduce((maximum, row) => BigInt(row.reserved_wei) > maximum ? BigInt(row.reserved_wei) : maximum, 0n);
      return current + (maximumFee > sameNonce ? maximumFee - sameNonce : 0n);
    };
    return { token: project(token), global: project() };
  }

  latestAttemptAt(token: string, kind: JobKind, exceptNonce?: number): number | null {
    const row = this.sql.exec<{ latest: number | null }>(
      "SELECT MAX(created_at) AS latest FROM signer_gas_expenses WHERE token=?1 AND kind=?2 AND (?3 IS NULL OR nonce<>?3)",
      token.toLowerCase(), kind, exceptNonce ?? null,
    ).toArray()[0];
    return row?.latest ?? null;
  }

  /** Exactly one transaction at a wallet nonce can land, including status=0 receipts. */
  settleNonce(nonce: number, winnerJobId: string, actualFee: bigint, now: number): void {
    const winner = this.get(winnerJobId);
    if (!winner || winner.nonce !== nonce) throw new Error("Missing winning gas reservation");
    if (winner.spent_wei !== null) {
      this.sql.exec(
        "UPDATE signer_gas_expenses SET spent_wei='0',settled_at=?1 WHERE nonce=?2 AND spent_wei IS NULL",
        winner.settled_at ?? now, nonce,
      );
      return;
    }
    if (actualFee < 0n) throw new Error("Gas expense cannot be negative");
    this.sql.exec(
      "UPDATE signer_gas_expenses SET spent_wei='0',settled_at=?1 WHERE nonce=?2 AND spent_wei IS NULL",
      now, nonce,
    );
    this.sql.exec("UPDATE signer_gas_expenses SET spent_wei=?1 WHERE job_id=?2", actualFee.toString(), winnerJobId);
  }

  /** Missing receipt is never treated as free. Charge each possibly affected token conservatively. */
  settleUnknownNonce(nonce: number, preferredJobId: string, now: number): void {
    const rows = this.sql.exec<GasExpenseRow>(
      "SELECT * FROM signer_gas_expenses WHERE nonce=?1 AND spent_wei IS NULL", nonce,
    ).toArray();
    if (rows.length === 0) return;
    const charges = new Map<string, { row: GasExpenseRow; fee: bigint }>();
    for (const row of rows) {
      const previous = charges.get(row.token);
      const fee = BigInt(row.reserved_wei);
      if (!previous || fee > previous.fee || (fee === previous.fee && row.job_id === preferredJobId)) {
        charges.set(row.token, { row, fee });
      }
    }
    this.sql.exec("UPDATE signer_gas_expenses SET spent_wei='0',settled_at=?1 WHERE nonce=?2 AND spent_wei IS NULL", now, nonce);
    for (const { row, fee } of charges.values()) {
      this.sql.exec("UPDATE signer_gas_expenses SET spent_wei=?1 WHERE job_id=?2", fee.toString(), row.job_id);
    }
  }
}
