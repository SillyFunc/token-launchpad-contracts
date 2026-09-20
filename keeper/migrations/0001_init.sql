CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS assets (
  chain_id INTEGER NOT NULL,
  token TEXT NOT NULL,
  tax_processor TEXT NOT NULL,
  vault TEXT,
  pair TEXT NOT NULL,
  wbnb TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  next_check_at INTEGER NOT NULL DEFAULT 0,
  last_checked_at INTEGER,
  last_error TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (chain_id, token)
);

CREATE INDEX IF NOT EXISTS idx_assets_due
  ON assets(chain_id, status, next_check_at);

CREATE TABLE IF NOT EXISTS price_samples (
  chain_id INTEGER NOT NULL,
  pair TEXT NOT NULL,
  block_number INTEGER NOT NULL,
  sampled_at INTEGER NOT NULL,
  reserve_token TEXT NOT NULL,
  reserve_wbnb TEXT NOT NULL,
  PRIMARY KEY (chain_id, pair, block_number)
);

CREATE INDEX IF NOT EXISTS idx_price_samples_anchor
  ON price_samples(chain_id, pair, sampled_at);

CREATE TABLE IF NOT EXISTS keeper_runs (
  id TEXT PRIMARY KEY,
  trigger_kind TEXT NOT NULL,
  started_at INTEGER NOT NULL,
  finished_at INTEGER,
  status TEXT NOT NULL,
  discovered_count INTEGER NOT NULL DEFAULT 0,
  inspected_count INTEGER NOT NULL DEFAULT 0,
  planned_count INTEGER NOT NULL DEFAULT 0,
  submitted_count INTEGER NOT NULL DEFAULT 0,
  error TEXT
);

CREATE TABLE IF NOT EXISTS transactions (
  job_id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL,
  chain_id INTEGER NOT NULL,
  kind TEXT NOT NULL,
  token TEXT NOT NULL,
  target TEXT NOT NULL,
  tx_hash TEXT,
  nonce INTEGER,
  status TEXT NOT NULL,
  detail TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_transactions_recent
  ON transactions(chain_id, updated_at DESC);

CREATE TABLE IF NOT EXISTS alerts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  severity TEXT NOT NULL,
  code TEXT NOT NULL,
  message TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  resolved_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_alerts_open
  ON alerts(resolved_at, created_at DESC);
