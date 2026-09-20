import { describe, expect, it } from "vitest";
import {
  activeTaxRate,
  amountAfterTransferTax,
  deviationBps,
  getAmountOut,
  medianBigInt,
  protectedMinimumOut,
} from "../src/policy";

describe("keeper price policy", () => {
  it("uses Pancake V2's 0.25% fee in constant-product quotes", () => {
    const amountOut = getAmountOut(1_000n, 100_000n, 50_000n, 25);
    expect(amountOut).toBe(493n);
  });

  it("quotes the actual amount reaching the pair after sell tax", () => {
    expect(amountAfterTransferTax(10_000n, 500)).toBe(9_500n);
    expect(getAmountOut(amountAfterTransferTax(10_000n, 500), 1_000_000n, 100_000n, 25)).toBe(938n);
  });

  it("takes the stricter of current and historical floors", () => {
    const result = protectedMinimumOut(10_100n, 10_000n, 100, 300);
    expect(result.ok).toBe(true);
    expect(result.minimumOut).toBe(9_999n);
    expect(result.deviationBps).toBe(100n);
  });

  it("refuses execution when spot diverges too far from the historical anchor", () => {
    const result = protectedMinimumOut(9_000n, 10_000n, 100, 300);
    expect(result.ok).toBe(false);
    expect(result.reason).toContain("deviation");
    expect(deviationBps(9_000n, 10_000n)).toBe(1_000n);
  });

  it("calculates a deterministic median without Number precision loss", () => {
    expect(medianBigInt([9n, 3n, 7n])).toBe(7n);
    expect(medianBigInt([9n, 3n, 7n, 5n])).toBe(6n);
  });

  it("turns tax off once the on-chain expiry transition is due", () => {
    expect(activeTaxRate(3, 500, 1_000, 1_000)).toBe(500);
    expect(activeTaxRate(3, 500, 1_001, 1_000)).toBe(0);
    expect(activeTaxRate(4, 500, 900, 1_000)).toBe(0);
  });
});
