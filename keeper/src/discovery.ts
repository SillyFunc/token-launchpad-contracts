import { getAddress, zeroAddress, type Address } from "viem";
import { coordinatorAbi, taxProcessorAbi, tokenAbi } from "./abis";
import { getSetting, setSetting, upsertAssets } from "./db";
import { batchContractCalls, contractCall } from "./rpc";
import type { Env, KeeperConfig } from "./types";

interface TokenPairResult {
  tokenAddress: Address;
}

function pairToken(value: unknown): Address {
  if (typeof value === "object" && value !== null && "tokenAddress" in value) {
    return getAddress(String((value as TokenPairResult).tokenAddress));
  }
  if (Array.isArray(value)) return getAddress(String(value[0]));
  throw new Error("Coordinator returned an invalid token pair record");
}

export async function discoverAssets(env: Env, config: KeeperConfig, now: number): Promise<number> {
  const total = (await contractCall(config.readRpcUrl, {
    address: config.coordinator,
    abi: coordinatorAbi,
    functionName: "getTotalTokenCount",
  })) as bigint;
  if (total === 0n) return 0;

  const cursorKey = `discovery_cursor:${config.chainId}`;
  const storedCursor = BigInt((await getSetting(env.DB, cursorKey)) ?? "0");
  const offset = storedCursor >= total ? 0n : storedCursor;
  const remaining = total - offset;
  const limit = remaining < BigInt(config.discoveryPageSize) ? remaining : BigInt(config.discoveryPageSize);

  const rawPairs = (await contractCall(config.readRpcUrl, {
    address: config.coordinator,
    abi: coordinatorAbi,
    functionName: "getAllTokenPresalePairs",
    args: [offset, limit],
  })) as unknown[];
  const tokens = rawPairs.map(pairToken);

  const metadataCalls = tokens.flatMap((token) => [
    { address: token, abi: tokenAbi, functionName: "taxProcessor" },
    { address: token, abi: tokenAbi, functionName: "mainPool" },
    { address: config.coordinator, abi: coordinatorAbi, functionName: "tokenVaults", args: [token] },
  ]);
  const metadata = await batchContractCalls(config.readRpcUrl, metadataCalls);
  const preliminary = tokens.map((token, index) => ({
    token,
    taxProcessor: getAddress(String(metadata[index * 3])) as Address,
    pair: getAddress(String(metadata[index * 3 + 1])) as Address,
    vaultValue: getAddress(String(metadata[index * 3 + 2])) as Address,
  }));

  const processorMetadata = await batchContractCalls(
    config.readRpcUrl,
    preliminary.flatMap((asset) => [
      { address: asset.taxProcessor, abi: taxProcessorAbi, functionName: "taxToken" },
      { address: asset.taxProcessor, abi: taxProcessorAbi, functionName: "weth" },
    ]),
  );

  const assets = preliminary.map((asset, index) => {
    const processorToken = getAddress(String(processorMetadata[index * 2]));
    if (processorToken !== asset.token) throw new Error(`TaxProcessor token mismatch for ${asset.token}`);
    return {
      token: asset.token,
      taxProcessor: asset.taxProcessor,
      pair: asset.pair,
      vault: asset.vaultValue === zeroAddress ? null : asset.vaultValue,
      wbnb: getAddress(String(processorMetadata[index * 2 + 1])) as Address,
    };
  });

  await upsertAssets(env.DB, config.chainId, assets, now);
  const nextCursor = offset + BigInt(tokens.length) >= total ? 0n : offset + BigInt(tokens.length);
  await setSetting(env.DB, cursorKey, nextCursor.toString(), now);
  return assets.length;
}
