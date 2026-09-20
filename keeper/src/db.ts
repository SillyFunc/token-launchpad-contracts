import type { Address, Hex } from "viem";
import type { AssetRow, JobKind, PairSample, SignerResult } from "./types";

export async function getSetting(db: D1Database, key: string): Promise<string | null> {
  const row = await db.prepare("SELECT value FROM settings WHERE key = ?1").bind(key).first<{ value: string }>();
  return row?.value ?? null;
}

export async function setSetting(db: D1Database, key: string, value: string, now: number): Promise<void> {
  await db
    .prepare(
      "INSERT INTO settings(key,value,updated_at) VALUES(?1,?2,?3) " +
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at",
    )
    .bind(key, value, now)
    .run();
}

export async function upsertAssets(
  db: D1Database,
  chainId: number,
  assets: readonly { token: Address; taxProcessor: Address; vault: Address | null; pair: Address; wbnb: Address }[],
  now: number,
): Promise<void> {
  if (assets.length === 0) return;
  await db.batch(
    assets.map((asset) =>
      db
        .prepare(
          "INSERT INTO assets(chain_id,token,tax_processor,vault,pair,wbnb,status,next_check_at,created_at,updated_at) " +
            "VALUES(?1,?2,?3,?4,?5,?6,'active',0,?7,?7) " +
            "ON CONFLICT(chain_id,token) DO UPDATE SET tax_processor=excluded.tax_processor, " +
            "vault=excluded.vault, pair=excluded.pair, wbnb=excluded.wbnb, updated_at=excluded.updated_at",
        )
        .bind(
          chainId,
          asset.token.toLowerCase(),
          asset.taxProcessor.toLowerCase(),
          asset.vault?.toLowerCase() ?? null,
          asset.pair.toLowerCase(),
          asset.wbnb.toLowerCase(),
          now,
        ),
    ),
  );
}

export async function listDueAssets(db: D1Database, chainId: number, now: number, limit: number): Promise<AssetRow[]> {
  const rows = await db
    .prepare(
      "SELECT chain_id,token,tax_processor,vault,pair,wbnb,status,next_check_at,last_checked_at,last_error " +
        "FROM assets WHERE chain_id=?1 AND status='active' AND next_check_at<=?2 " +
        "ORDER BY next_check_at ASC, created_at ASC LIMIT ?3",
    )
    .bind(chainId, now, limit)
    .all<AssetRow>();
  return rows.results;
}

export async function getAsset(db: D1Database, chainId: number, token: Address): Promise<AssetRow | null> {
  return (
    (await db
      .prepare(
        "SELECT chain_id,token,tax_processor,vault,pair,wbnb,status,next_check_at,last_checked_at,last_error " +
          "FROM assets WHERE chain_id=?1 AND token=?2",
      )
      .bind(chainId, token.toLowerCase())
      .first<AssetRow>()) ?? null
  );
}

export async function markAssetChecked(
  db: D1Database,
  chainId: number,
  token: Address,
  now: number,
  nextCheckAt: number,
  error?: string,
): Promise<void> {
  await db
    .prepare(
      "UPDATE assets SET last_checked_at=?1,next_check_at=?2,last_error=?3,updated_at=?1 " +
        "WHERE chain_id=?4 AND token=?5",
    )
    .bind(now, nextCheckAt, error?.slice(0, 1000) ?? null, chainId, token.toLowerCase())
    .run();
}

export async function storeSample(db: D1Database, chainId: number, pair: Address, sample: PairSample): Promise<void> {
  await db
    .prepare(
      "INSERT OR IGNORE INTO price_samples(chain_id,pair,block_number,sampled_at,reserve_token,reserve_wbnb) " +
        "VALUES(?1,?2,?3,?4,?5,?6)",
    )
    .bind(
      chainId,
      pair.toLowerCase(),
      Number(sample.blockNumber),
      sample.sampledAt,
      sample.reserveToken.toString(),
      sample.reserveWbnb.toString(),
    )
    .run();
}

interface SampleRow {
  block_number: number;
  sampled_at: number;
  reserve_token: string;
  reserve_wbnb: string;
}

export async function loadAnchorSamples(
  db: D1Database,
  chainId: number,
  pair: Address,
  oldest: number,
  newest: number,
  limit = 15,
): Promise<PairSample[]> {
  const rows = await db
    .prepare(
      "SELECT block_number,sampled_at,reserve_token,reserve_wbnb FROM price_samples " +
        "WHERE chain_id=?1 AND pair=?2 AND sampled_at>=?3 AND sampled_at<=?4 " +
        "ORDER BY sampled_at DESC LIMIT ?5",
    )
    .bind(chainId, pair.toLowerCase(), oldest, newest, limit)
    .all<SampleRow>();
  return rows.results.map((row) => ({
    blockNumber: BigInt(row.block_number),
    sampledAt: row.sampled_at,
    reserveToken: BigInt(row.reserve_token),
    reserveWbnb: BigInt(row.reserve_wbnb),
  }));
}

export async function startRun(db: D1Database, id: string, trigger: string, now: number): Promise<void> {
  await db
    .prepare("INSERT OR REPLACE INTO keeper_runs(id,trigger_kind,started_at,status) VALUES(?1,?2,?3,'running')")
    .bind(id, trigger, now)
    .run();
}

export async function finishRun(
  db: D1Database,
  id: string,
  now: number,
  counts: { discovered: number; inspected: number; planned: number; submitted: number },
  error?: string,
): Promise<void> {
  await db
    .prepare(
      "UPDATE keeper_runs SET finished_at=?1,status=?2,discovered_count=?3,inspected_count=?4," +
        "planned_count=?5,submitted_count=?6,error=?7 WHERE id=?8",
    )
    .bind(
      now,
      error ? "failed" : "complete",
      counts.discovered,
      counts.inspected,
      counts.planned,
      counts.submitted,
      error?.slice(0, 2000) ?? null,
      id,
    )
    .run();
}

export async function recordTransaction(
  db: D1Database,
  runId: string,
  chainId: number,
  kind: JobKind,
  token: Address,
  target: Address,
  result: SignerResult,
  now: number,
): Promise<void> {
  await db
    .prepare(
      "INSERT INTO transactions(job_id,run_id,chain_id,kind,token,target,tx_hash,nonce,status,detail,created_at,updated_at) " +
        "VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?11) " +
        "ON CONFLICT(job_id) DO UPDATE SET tx_hash=excluded.tx_hash,nonce=excluded.nonce,status=excluded.status," +
        "detail=excluded.detail,updated_at=excluded.updated_at",
    )
    .bind(
      result.jobId,
      runId,
      chainId,
      kind,
      token.toLowerCase(),
      target.toLowerCase(),
      (result.txHash as Hex | undefined) ?? null,
      result.nonce ?? null,
      result.status,
      result.detail?.slice(0, 2000) ?? null,
      now,
    )
    .run();
}

export async function createAlert(
  db: D1Database,
  severity: "warning" | "critical",
  code: string,
  message: string,
  now: number,
): Promise<void> {
  const existing = await db
    .prepare("SELECT id FROM alerts WHERE code=?1 AND resolved_at IS NULL ORDER BY created_at DESC LIMIT 1")
    .bind(code)
    .first<{ id: number }>();
  if (existing) return;
  await db
    .prepare("INSERT INTO alerts(severity,code,message,created_at) VALUES(?1,?2,?3,?4)")
    .bind(severity, code, message.slice(0, 2000), now)
    .run();
}
