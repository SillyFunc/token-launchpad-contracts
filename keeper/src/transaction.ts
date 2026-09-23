import { getAddress, isHex, keccak256, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

export interface LegacyKeeperTransaction {
  chainId: number;
  to: Address;
  data: Hex;
  nonce: number;
  gas: bigint;
  gasPrice: bigint;
}

export function keeperAccount(privateKey: string, expectedAddress: Address) {
  if (!isHex(privateKey) || privateKey.length !== 66) throw new Error("KEEPER_PRIVATE_KEY is invalid");
  const account = privateKeyToAccount(privateKey as Hex);
  if (getAddress(account.address) !== getAddress(expectedAddress)) {
    throw new Error("Keeper private key does not match KEEPER_ADDRESS");
  }
  return account;
}

export async function signLegacyKeeperTransaction(
  privateKey: string,
  expectedAddress: Address,
  transaction: LegacyKeeperTransaction,
): Promise<{ rawTransaction: Hex; txHash: Hex }> {
  const account = keeperAccount(privateKey, expectedAddress);
  const rawTransaction = await account.signTransaction({
    chainId: transaction.chainId,
    type: "legacy",
    to: transaction.to,
    data: transaction.data,
    value: 0n,
    nonce: transaction.nonce,
    gas: transaction.gas,
    gasPrice: transaction.gasPrice,
  });
  return { rawTransaction, txHash: keccak256(rawTransaction) };
}
