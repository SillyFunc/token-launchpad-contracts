import { describe, expect, it } from "vitest";
import { getAddress, recoverTransactionAddress, type Hex, type TransactionSerializedLegacy } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { keeperAccount, signLegacyKeeperTransaction } from "../src/transaction";

const privateKey = "0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const account = privateKeyToAccount(privateKey);

describe("keeper transaction signing", () => {
  it("refuses a valid key that does not belong to the configured keeper", () => {
    expect(() => keeperAccount(privateKey, "0x1111111111111111111111111111111111111111")).toThrow(/does not match/);
  });

  it("signs a BSC legacy transaction whose sender can be recovered", async () => {
    const { rawTransaction, txHash } = await signLegacyKeeperTransaction(privateKey, account.address, {
      chainId: 97,
      to: "0x2222222222222222222222222222222222222222",
      data: "0x12345678" as Hex,
      nonce: 7,
      gas: 120_000n,
      gasPrice: 1_000_000_000n,
    });
    expect(txHash).toMatch(/^0x[0-9a-f]{64}$/);
    expect(
      getAddress(
        await recoverTransactionAddress({ serializedTransaction: rawTransaction as TransactionSerializedLegacy }),
      ),
    ).toBe(
      getAddress(account.address),
    );
  });
});
