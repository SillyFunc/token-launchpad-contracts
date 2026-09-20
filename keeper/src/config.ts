import { getAddress, isAddress } from "viem";
import type { Env, KeeperConfig } from "./types";

function integer(value: string | undefined, fallback: number, name: string, min: number, max: number): number {
  const parsed = value === undefined ? fallback : Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < min || parsed > max) {
    throw new Error(`${name} must be an integer between ${min} and ${max}`);
  }
  return parsed;
}

function unsigned(value: string | undefined, fallback: bigint, name: string): bigint {
  const parsed = value === undefined ? fallback : BigInt(value);
  if (parsed < 0n) throw new Error(`${name} must be unsigned`);
  return parsed;
}

function address(value: string, name: string) {
  if (!isAddress(value) || /^0x0{40}$/i.test(value)) throw new Error(`${name} must be a non-zero EVM address`);
  return getAddress(value);
}

function rpcUrl(value: string, name: string): string {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error(`${name} must be an absolute HTTPS URL`);
  }
  if (url.protocol !== "https:") throw new Error(`${name} must use HTTPS`);
  return url.toString();
}

export function getConfig(env: Env): KeeperConfig {
  const chainId = integer(env.CHAIN_ID, 97, "CHAIN_ID", 1, 2 ** 31 - 1);
  if (chainId !== 56 && chainId !== 97) throw new Error("Only BSC mainnet (56) and testnet (97) are supported");

  const config: KeeperConfig = {
    chainId,
    readRpcUrl: rpcUrl(env.READ_RPC_URL, "READ_RPC_URL"),
    sendRpcUrl: rpcUrl(env.SEND_RPC_URL, "SEND_RPC_URL"),
    coordinator: address(env.COORDINATOR_ADDRESS, "COORDINATOR_ADDRESS"),
    keeper: address(env.KEEPER_ADDRESS, "KEEPER_ADDRESS"),
    discoveryPageSize: integer(env.DISCOVERY_PAGE_SIZE, 8, "DISCOVERY_PAGE_SIZE", 1, 20),
    maxAssetsPerRun: integer(env.MAX_ASSETS_PER_RUN, 8, "MAX_ASSETS_PER_RUN", 1, 20),
    checkIntervalSeconds: integer(env.CHECK_INTERVAL_SECONDS, 60, "CHECK_INTERVAL_SECONDS", 60, 3600),
    ammFeeBps: integer(env.AMM_FEE_BPS, 25, "AMM_FEE_BPS", 0, 1000),
    taxMaxReserveBps: integer(env.TAX_MAX_RESERVE_BPS, 30, "TAX_MAX_RESERVE_BPS", 1, 100),
    slippageBps: integer(env.SLIPPAGE_BPS, 100, "SLIPPAGE_BPS", 1, 500),
    maxPriceDeviationBps: integer(env.MAX_PRICE_DEVIATION_BPS, 300, "MAX_PRICE_DEVIATION_BPS", 1, 1000),
    anchorMinAgeSeconds: integer(env.ANCHOR_MIN_AGE_SECONDS, 300, "ANCHOR_MIN_AGE_SECONDS", 60, 3600),
    anchorMaxAgeSeconds: integer(env.ANCHOR_MAX_AGE_SECONDS, 3600, "ANCHOR_MAX_AGE_SECONDS", 300, 86400),
    minAnchorSamples: integer(env.MIN_ANCHOR_SAMPLES, 3, "MIN_ANCHOR_SAMPLES", 2, 15),
    deadlineSeconds: integer(env.DEADLINE_SECONDS, 300, "DEADLINE_SECONDS", 30, 540),
    gasPriceMultiplierBps: integer(env.GAS_PRICE_MULTIPLIER_BPS, 12000, "GAS_PRICE_MULTIPLIER_BPS", 10000, 30000),
    maxGasPriceWei: unsigned(env.MAX_GAS_PRICE_WEI, 10_000_000_000n, "MAX_GAS_PRICE_WEI"),
    minKeeperBalanceWei: unsigned(env.MIN_KEEPER_BALANCE_WEI, 3_000_000_000_000_000n, "MIN_KEEPER_BALANCE_WEI"),
    pendingRetrySeconds: integer(env.PENDING_RETRY_SECONDS, 90, "PENDING_RETRY_SECONDS", 30, 540),
  };

  if (config.anchorMaxAgeSeconds <= config.anchorMinAgeSeconds) {
    throw new Error("ANCHOR_MAX_AGE_SECONDS must be greater than ANCHOR_MIN_AGE_SECONDS");
  }
  if (chainId === 56 && config.readRpcUrl === config.sendRpcUrl) {
    throw new Error("BSC mainnet requires a distinct MEV-protected SEND_RPC_URL");
  }
  return config;
}
