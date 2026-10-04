import { formatUnits, parseUnits } from "viem";

export const HBAR_DECIMALS = 8;
export const SHARE_DECIMALS = 8;
export const BPS = 10_000n;
/** JSON-RPC counts HBAR in weibar (18 decimals); the EVM inside Hedera counts tinybar (8). */
export const WEIBAR_PER_TINYBAR = 10_000_000_000n;

const DECIMAL = /^\d+(\.\d{1,8})?$/;

/** Parses a decimal string with at most 8 decimals into its integer unit. Throws on anything else, and on zero. */
export function parseAmount(text: string, label = "amount"): bigint {
  const t = text.trim();
  if (!DECIMAL.test(t)) throw new Error(`${label} must be a plain decimal with at most 8 decimals, got "${text}"`);
  const value = parseUnits(t, 8);
  if (value === 0n) throw new Error(`${label} must be above zero`);
  return value;
}

export const fmt8 = (value: bigint) => formatUnits(value, 8);

/** Shares an HBAR deposit would mint before pool fees and price impact: value x supply / NAV (first deposit: value - dead shares). */
export function estimateShares(tinybar: bigint, supply: bigint, nav: bigint, deadShares: bigint): bigint | null {
  if (supply === 0n) return tinybar > deadShares ? tinybar - deadShares : 0n;
  if (nav === 0n) return null;
  return (tinybar * supply) / nav;
}

export const applySlippage = (amount: bigint, slippageBps: number) => (amount * (BPS - BigInt(slippageBps))) / BPS;
