const BPS = 10_000n;

export function minBigInt(a: bigint, b: bigint): bigint {
  return a < b ? a : b;
}

export function medianBigInt(values: readonly bigint[]): bigint {
  if (values.length === 0) throw new Error("median requires at least one value");
  const sorted = [...values].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2n;
}

export function amountAfterTransferTax(amount: bigint, taxBps: number): bigint {
  if (amount < 0n || taxBps < 0 || taxBps > 10_000) throw new Error("invalid transfer tax input");
  return (amount * (BPS - BigInt(taxBps))) / BPS;
}

export function getAmountOut(
  amountIn: bigint,
  reserveIn: bigint,
  reserveOut: bigint,
  feeBps: number,
): bigint {
  if (amountIn <= 0n || reserveIn <= 0n || reserveOut <= 0n) return 0n;
  if (feeBps < 0 || feeBps >= 10_000) throw new Error("invalid AMM fee");
  const inputWithFee = amountIn * (BPS - BigInt(feeBps));
  return (inputWithFee * reserveOut) / (reserveIn * BPS + inputWithFee);
}

export function deviationBps(current: bigint, anchor: bigint): bigint {
  if (current < 0n || anchor <= 0n) throw new Error("invalid price deviation input");
  const difference = current >= anchor ? current - anchor : anchor - current;
  return (difference * BPS) / anchor;
}

export interface ProtectedMinimum {
  ok: boolean;
  minimumOut: bigint;
  deviationBps: bigint;
  reason?: string;
}

export function protectedMinimumOut(
  currentQuote: bigint,
  anchorQuote: bigint,
  slippageBps: number,
  maxDeviationBps: number,
): ProtectedMinimum {
  if (currentQuote <= 0n || anchorQuote <= 0n) {
    return { ok: false, minimumOut: 0n, deviationBps: 0n, reason: "zero quote" };
  }
  const deviation = deviationBps(currentQuote, anchorQuote);
  if (deviation > BigInt(maxDeviationBps)) {
    return { ok: false, minimumOut: 0n, deviationBps: deviation, reason: "price deviation exceeds policy" };
  }
  const currentFloor = (currentQuote * (BPS - BigInt(slippageBps))) / BPS;
  const anchorFloor = (anchorQuote * (BPS - BigInt(slippageBps))) / BPS;
  const minimumOut = currentFloor > anchorFloor ? currentFloor : anchorFloor;
  if (minimumOut === 0n) return { ok: false, minimumOut, deviationBps: deviation, reason: "minimum output rounds to zero" };
  return { ok: true, minimumOut, deviationBps: deviation };
}

export function activeTaxRate(
  state: number,
  configuredRate: number,
  blockTimestamp: number,
  taxExpirationTime: number,
): number {
  const taxState = state === 2 || state === 3;
  return taxState && blockTimestamp <= taxExpirationTime ? configuredRate : 0;
}
