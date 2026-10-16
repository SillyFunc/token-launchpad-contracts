import type { AssetSnapshot, ExecutionControls, JobKind } from "./types";

export function executionControls(flags: number): ExecutionControls {
  if (!Number.isInteger(flags) || flags < 0 || flags > 7) throw new Error(`Invalid execution flags ${flags}`);
  return {
    taxProcessingEnabled: (flags & 1) !== 0,
    liquidityEnabled: (flags & 2) !== 0,
    buybackEnabled: (flags & 4) !== 0,
  };
}

export function executionEnabled(snapshot: AssetSnapshot, kind: JobKind): boolean {
  const controls = snapshot.controls;
  if (kind === "tax") return controls.taxProcessingEnabled;
  if (kind === "liquidity") return controls.liquidityEnabled;
  return controls.buybackEnabled && (snapshot.vaultMode !== 1 || controls.liquidityEnabled);
}
