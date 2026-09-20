import type { Address, Hex } from "viem";
import type { AssetRow, JobKind, PairSample, SignerResult } from "./types";

/// @dev 同一 (token, kind) 连续跳过多少次后写告警；成交即清零并解除
const SKIP_STREAK_ALERT_THRESHOLD = 5;

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
        "AND reserve_token!='0' AND reserve_wbnb!='0' " +
        "ORDER BY sampled_at DESC LIMIT ?5",
    )
    .bind(chainId, pair.toLowerCase(), oldest, newest, limit)
    .all<SampleRow>();
  // 储备为 0 的样本不含价格信息：代币先创建、后加池时每分钟都会写入一条，
  // 若计入中位数会把锚点拉到 0，让 Keeper 在已有足够有效样本时仍然不成交。
  return rows.results
    .map((row) => ({
      blockNumber: BigInt(row.block_number),
      sampledAt: row.sampled_at,
      reserveToken: BigInt(row.reserve_token),
      reserveWbnb: BigInt(row.reserve_wbnb),
    }))
    .filter((sample) => sample.reserveToken > 0n && sample.reserveWbnb > 0n);
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
  const existing = await db
    .prepare("SELECT status FROM transactions WHERE job_id=?1")
    .bind(result.jobId)
    .first<{ status: SignerResult["status"] }>();
  // Workflow 整步重试时，Signer 会把已经持久化的同一笔交易返回为
  // `already-submitted`。D1 应继续把它记作已提交，不能降级状态或重复累计告警。
  const recordedResult: SignerResult =
    result.status === "already-submitted" && result.txHash ? { ...result, status: "submitted" } : result;

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
      (recordedResult.txHash as Hex | undefined) ?? null,
      recordedResult.nonce ?? null,
      recordedResult.status,
      recordedResult.detail?.slice(0, 2000) ?? null,
      now,
    )
    .run();

  if (existing?.status !== recordedResult.status) {
    await trackSkipStreak(db, chainId, kind, token, recordedResult, now);
  }
}

/// @dev 连续跳过告警：清算停摆时 `transactions` 里只有 `skipped` 记录、`alerts` 为空，
///      运维只看告警会误判为健康。这里按 (token, kind) 记连续跳过次数，达到阈值写一条
///      去重 warning；一旦成交即清零并解除该告警，避免长期悬挂。
export async function trackSkipStreak(
  db: D1Database,
  chainId: number,
  kind: JobKind,
  token: Address,
  result: SignerResult,
  now: number,
): Promise<void> {
  const normalized = token.toLowerCase();
  const streakKey = `skip_streak:${chainId}:${normalized}:${kind}`;
  const alertCode = `skip-streak:${normalized}:${kind}`;

  if (result.status === "submitted") {
    await setSetting(db, streakKey, "0", now);
    await resolveAlert(db, alertCode, now);
    return;
  }
  if (result.status !== "skipped") return;

  const streak = Number((await getSetting(db, streakKey)) ?? "0") + 1;
  await setSetting(db, streakKey, String(streak), now);
  if (streak < SKIP_STREAK_ALERT_THRESHOLD) return;

  await createAlert(
    db,
    "warning",
    alertCode,
    `${kind} job for ${normalized} skipped ${streak} times in a row; latest reason: ${result.detail ?? "unknown"}`,
    now,
  );
}

export async function resolveAlert(db: D1Database, code: string, now: number): Promise<void> {
  await db
    .prepare("UPDATE alerts SET resolved_at=?1 WHERE code=?2 AND resolved_at IS NULL")
    .bind(now, code)
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
