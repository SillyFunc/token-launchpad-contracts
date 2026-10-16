import { coordinatorAbi } from "./abis";
import { getAddress } from "viem";
import { readerAbi } from "./reader-abi";
import { assertContractCode, assertRpcChain, batchContractCalls } from "./rpc";
import type { KeeperConfig } from "./types";

/** DApps may validate the Reader binding independently of the Keeper-role check. */
export async function assertReaderBinding(
  config: Pick<KeeperConfig, "readerAddress" | "readRpcUrl" | "coordinator">,
): Promise<void> {
  if (!config.readerAddress) return;
  const [coordinator] = await batchContractCalls(config.readRpcUrl, [
    { address: config.readerAddress, abi: readerAbi, functionName: "coordinator" },
  ]);
  if (getAddress(String(coordinator)) !== getAddress(config.coordinator)) {
    throw new Error(`Reader ${config.readerAddress} is bound to a different Coordinator`);
  }
}

export async function assertEnvironment(config: KeeperConfig): Promise<void> {
  await Promise.all([
    assertRpcChain(config.readRpcUrl, config.chainId),
    assertRpcChain(config.sendRpcUrl, config.chainId),
    assertContractCode(config.readRpcUrl, config.coordinator),
    ...(config.readerAddress ? [assertContractCode(config.readRpcUrl, config.readerAddress)] : []),
  ]);

  await assertReaderBinding(config);

  const [role] = await batchContractCalls(config.readRpcUrl, [
    { address: config.coordinator, abi: coordinatorAbi, functionName: "KEEPER_ROLE" },
  ]);
  const [authorized] = await batchContractCalls(config.readRpcUrl, [
    {
      address: config.coordinator,
      abi: coordinatorAbi,
      functionName: "hasRole",
      args: [role, config.keeper],
    },
  ]);
  if (authorized !== true) throw new Error(`Keeper ${config.keeper} does not have KEEPER_ROLE`);
}
