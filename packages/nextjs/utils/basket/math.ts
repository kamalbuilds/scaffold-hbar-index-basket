import { BPS, WEIBAR_PER_TINYBAR } from "./constants";

/** HBAR in the EVM is tinybar (8 decimals); wallets and JSON-RPC count weibar (18 decimals). */
export const tinybarToWeibar = (tinybar: bigint) => tinybar * WEIBAR_PER_TINYBAR;
export const weibarToTinybar = (weibar: bigint) => weibar / WEIBAR_PER_TINYBAR;

/** An 8-decimal HBAR amount in USD (8 decimals) at an 8-decimal HBAR/USD price. */
export const hbarToUsd8 = (tinybar: bigint, hbarUsd8: bigint) => (tinybar * hbarUsd8) / 10n ** 8n;

/**
 * Shares a deposit mints. The first deposit mints 1 share unit per tinybar less the dead shares the vault locks;
 * every later one mints value x supply / NAV. Null when there is nothing to estimate (no amount, or no NAV to divide by).
 */
export function estimateShares(tinybar: bigint | null, supply: bigint, nav: bigint, deadShares: bigint): bigint | null {
  if (tinybar === null || tinybar === 0n) return null;
  if (supply === 0n) return tinybar > deadShares ? tinybar - deadShares : 0n;
  return nav > 0n ? (tinybar * supply) / nav : null;
}

/** The `minShares` argument of `deposit`: the estimate less the slippage the user allows. */
export const minSharesFor = (estimated: bigint, slippageBps: number) => (estimated * (BPS - BigInt(slippageBps))) / BPS;

/** Leg i is token i + 1 of the vault's token list; token 0 is WHBAR, which always pays out. */
export const isPaidOut = (skipped: Record<number, boolean>, tokenIndex: number) =>
  tokenIndex === 0 || !skipped[tokenIndex - 1];

/** The `skipLegsMask` argument of `redeemExcept`: bit i set means leg i is not paid. */
export function skipMaskOf(skipped: Record<number, boolean>, legCount: number): bigint {
  let mask = 0n;
  for (let i = 0; i < legCount; i++) if (skipped[i]) mask |= 1n << BigInt(i);
  return mask;
}

export type Holding = { balance: bigint; valueWhbar: bigint };

/** In-kind payout: the same fraction of every token the vault holds as the fraction of supply burned. */
export function redeemPayout(
  holdings: readonly Holding[],
  shares: bigint,
  supply: bigint,
  skipped: Record<number, boolean>,
): { amount: bigint; skipped: boolean }[] | null {
  if (supply === 0n) return null;
  return holdings.map((h, i) => ({ amount: (h.balance * shares) / supply, skipped: !isPaidOut(skipped, i) }));
}

/** What the paid-out slice is worth in WHBAR tinybar; a skipped leg stays in the vault and counts for nothing. */
export function redeemPayoutWhbar(
  holdings: readonly Holding[],
  shares: bigint,
  supply: bigint,
  skipped: Record<number, boolean>,
): bigint | null {
  if (supply === 0n) return null;
  return holdings.reduce((sum, h, i) => (isPaidOut(skipped, i) ? sum + (h.valueWhbar * shares) / supply : sum), 0n);
}
