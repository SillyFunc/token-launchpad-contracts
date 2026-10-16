import {
  decodeFunctionResult,
  encodeFunctionData,
  getAddress,
  type Abi,
  type Address,
  type Hex,
} from "viem";

interface JsonRpcSuccess<T> {
  jsonrpc: "2.0";
  id: number;
  result: T;
}

interface JsonRpcFailure {
  jsonrpc: "2.0";
  id: number;
  error: { code: number; message: string; data?: unknown };
}

type JsonRpcResponse<T> = JsonRpcSuccess<T> | JsonRpcFailure;
const RPC_TIMEOUT_MS = 10_000;

export class RpcError extends Error {
  constructor(
    message: string,
    readonly code?: number,
    readonly data?: unknown,
  ) {
    super(message);
  }
}

export async function rpcRequest<T>(url: string, method: string, params: readonly unknown[]): Promise<T> {
  const response = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    signal: AbortSignal.timeout(RPC_TIMEOUT_MS),
  });
  if (!response.ok) throw new RpcError(`RPC HTTP ${response.status} for ${method}`);
  const payload = (await response.json()) as JsonRpcResponse<T>;
  if ("error" in payload) throw new RpcError(`${method}: ${payload.error.message}`, payload.error.code, payload.error.data);
  return payload.result;
}

export async function rpcBatch<T>(
  url: string,
  requests: readonly { method: string; params: readonly unknown[] }[],
): Promise<T[]> {
  if (requests.length === 0) return [];
  const response = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(requests.map((request, index) => ({ jsonrpc: "2.0", id: index + 1, ...request }))),
    signal: AbortSignal.timeout(RPC_TIMEOUT_MS),
  });
  if (!response.ok) throw new RpcError(`RPC batch HTTP ${response.status}`);
  const payload = (await response.json()) as JsonRpcResponse<T>[];
  const byId = new Map(payload.map((item) => [item.id, item]));
  return requests.map((_, index) => {
    const item = byId.get(index + 1);
    if (!item) throw new RpcError(`RPC batch response missing id ${index + 1}`);
    if ("error" in item) throw new RpcError(`RPC batch: ${item.error.message}`, item.error.code, item.error.data);
    return item.result;
  });
}

export interface ContractCall {
  address: Address;
  abi: Abi | readonly unknown[];
  functionName: string;
  args?: readonly unknown[];
}

export async function batchContractCalls(
  url: string,
  calls: readonly ContractCall[],
  blockTag: Hex | "latest" = "latest",
): Promise<unknown[]> {
  const results = await rpcBatch<Hex>(
    url,
    calls.map((call) => ({
      method: "eth_call",
      params: [
        {
          to: call.address,
          data: encodeFunctionData({
            abi: call.abi as Abi,
            functionName: call.functionName,
            args: call.args,
          }),
        },
        blockTag,
      ],
    })),
  );
  return results.map((result, index) =>
    decodeFunctionResult({
      abi: calls[index].abi as Abi,
      functionName: calls[index].functionName,
      data: result,
    }),
  );
}

export async function contractCall(
  url: string,
  call: ContractCall,
  blockTag: Hex | "latest" = "latest",
): Promise<unknown> {
  return (await batchContractCalls(url, [call], blockTag))[0];
}

export interface RpcBlock {
  number: Hex;
  timestamp: Hex;
  hash: Hex;
}

export async function getLatestBlock(url: string): Promise<{ number: bigint; timestamp: number; tag: Hex }> {
  const block = await rpcRequest<RpcBlock>(url, "eth_getBlockByNumber", ["latest", false]);
  const number = BigInt(block.number);
  return { number, timestamp: Number(BigInt(block.timestamp)), tag: `0x${number.toString(16)}` as Hex };
}

export async function assertRpcChain(url: string, expectedChainId: number): Promise<void> {
  const chainHex = await rpcRequest<Hex>(url, "eth_chainId", []);
  if (Number(BigInt(chainHex)) !== expectedChainId) {
    throw new Error(`RPC chain mismatch: expected ${expectedChainId}, received ${Number(BigInt(chainHex))}`);
  }
}

export async function assertContractCode(url: string, address: Address): Promise<void> {
  const code = await rpcRequest<Hex>(url, "eth_getCode", [address, "latest"]);
  if (code === "0x") throw new Error(`No contract code at ${getAddress(address)}`);
}
