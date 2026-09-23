import { coordinatorAbi } from "./abis";
import { assertContractCode, assertRpcChain, batchContractCalls } from "./rpc";
import type { KeeperConfig } from "./types";

export async function assertEnvironment(config: KeeperConfig): Promise<void> {
  await Promise.all([
    assertRpcChain(config.readRpcUrl, config.chainId),
    assertRpcChain(config.sendRpcUrl, config.chainId),
    assertContractCode(config.readRpcUrl, config.coordinator),
  ]);

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
