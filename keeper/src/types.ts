import type { Address, Hex } from "viem";
import type { SignerDurableObject } from "./signer";

export interface KeeperWorkflowPayload {
  trigger: "cron" | "manual";
  requestedAt: number;
}

export interface Env {
  DB: D1Database;
  SIGNER: DurableObjectNamespace<SignerDurableObject>;
  KEEPER_WORKFLOW: Workflow<KeeperWorkflowPayload>;

  CHAIN_ID: string;
  READ_RPC_URL: string;
  SEND_RPC_URL: string;
  COORDINATOR_ADDRESS: string;
  KEEPER_ADDRESS: string;
  KEEPER_PRIVATE_KEY: string;
  READER_ADDRESS?: string;

  DISCOVERY_PAGE_SIZE?: string;
  MAX_ASSETS_PER_RUN?: string;
  CHECK_INTERVAL_SECONDS?: string;
  AMM_FEE_BPS?: string;
  TAX_MAX_RESERVE_BPS?: string;
  SLIPPAGE_BPS?: string;
  MAX_PRICE_DEVIATION_BPS?: string;
  ANCHOR_MIN_AGE_SECONDS?: string;
  ANCHOR_MAX_AGE_SECONDS?: string;
  MIN_ANCHOR_SAMPLES?: string;
  DEADLINE_SECONDS?: string;
  GAS_PRICE_MULTIPLIER_BPS?: string;
  MAX_GAS_PRICE_WEI?: string;
  MIN_KEEPER_BALANCE_WEI?: string;
  MAX_GAS_COST_BPS?: string;
  TAX_EXECUTION_INTERVAL_SECONDS?: string;
  LIQUIDITY_EXECUTION_INTERVAL_SECONDS?: string;
  GAS_BUDGET_WINDOW_SECONDS?: string;
  MAX_TOKEN_GAS_PER_WINDOW_WEI?: string;
  MAX_TOTAL_GAS_PER_WINDOW_WEI?: string;
  PENDING_RETRY_SECONDS?: string;
  ALERT_WEBHOOK_URL?: string;
}

export interface KeeperConfig {
  chainId: 56 | 97;
  readRpcUrl: string;
  sendRpcUrl: string;
  coordinator: Address;
  keeper: Address;
  readerAddress?: Address;
  discoveryPageSize: number;
  maxAssetsPerRun: number;
  checkIntervalSeconds: number;
  ammFeeBps: number;
  taxMaxReserveBps: number;
  slippageBps: number;
  maxPriceDeviationBps: number;
  anchorMinAgeSeconds: number;
  anchorMaxAgeSeconds: number;
  minAnchorSamples: number;
  deadlineSeconds: number;
  gasPriceMultiplierBps: number;
  maxGasPriceWei: bigint;
  minKeeperBalanceWei: bigint;
  maxGasCostBps: number;
  taxExecutionIntervalSeconds: number;
  liquidityExecutionIntervalSeconds: number;
  gasBudgetWindowSeconds: number;
  maxTokenGasPerWindowWei: bigint;
  maxTotalGasPerWindowWei: bigint;
  pendingRetrySeconds: number;
}

export interface AssetRow {
  chain_id: number;
  token: Address;
  tax_processor: Address;
  vault: Address | null;
  pair: Address;
  wbnb: Address;
  status: string;
  next_check_at: number;
  last_checked_at: number | null;
  last_error: string | null;
}

export interface PairSample {
  blockNumber: bigint;
  sampledAt: number;
  reserveToken: bigint;
  reserveWbnb: bigint;
}

export interface PoolStateSnapshot {
  state: number;
  buyTaxRate: number;
  sellTaxRate: number;
  taxExpirationTime: number;
}

/// @dev 0…6 match Solidity; 7 is a local diagnostic for a legacy fixed-input vault.
export enum BuybackReadiness {
  Ready = 0,
  InsufficientBalance = 1,
  TriggerBalanceNotMet = 2,
  TooEarly = 3,
  InvalidPoolReserves = 4,
  ReserveCapBelowMinimum = 5,
  Paused = 6,
  LegacyFixedAmountExceedsReserveCap = 7,
}

export interface ExecutionControls {
  taxProcessingEnabled: boolean;
  liquidityEnabled: boolean;
  buybackEnabled: boolean;
}

export interface AssetSnapshot {
  controls: ExecutionControls;
  asset: AssetRow;
  blockNumber: bigint;
  blockTimestamp: number;
  reserves: PairSample;
  poolState: PoolStateSnapshot;
  pendingTax: bigint;
  feeConfig: {
    marketBps: number;
    deflationBps: number;
    lpBps: number;
    dividendBps: number;
    feeRate: number;
    commissionBps: number;
  };
  lpTokenBalance: bigint;
  lpQuoteBalance: bigint;
  pairTotalSupply: bigint;
  vaultVersion: 0 | 1 | 2;
  vaultExecutableAmount: bigint;
  vaultReadiness: BuybackReadiness;
  vaultMode: number;
  // Available from Reader; absent in the legacy adapter rather than guessed as zero.
  vaultBalance?: bigint;
  vaultNextExecuteTime?: number;
}

export type JobKind = "tax" | "liquidity" | "buyback";

export interface PlannedJob {
  id: string;
  kind: JobKind;
  chainId: number;
  token: Address;
  target: Address;
  snapshotBlock: string;
  createdAt: number;
}

export interface ExecutionPlan {
  job: PlannedJob;
  target: Address;
  data: Hex;
  amountIn: bigint;
  currentQuote: bigint;
  anchorQuote: bigint;
  economicValueWei: bigint;
  minimumOut: bigint;
  secondaryMinimumOut: bigint;
  deadline: bigint;
}

export interface SignerResult {
  jobId: string;
  status: "submitted" | "busy" | "skipped" | "already-submitted" | "deferred";
  txHash?: Hex;
  nonce?: number;
  detail?: string;
}
