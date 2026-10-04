import type { Address } from "viem";
import { BPS, WEIBAR_PER_TINYBAR, fmt8 } from "./units";

export type Holding = { token: Address; balance: bigint; valueWhbar: bigint; targetBps: number };
export type Leg = { token: Address; pool: Address; fee: number; tokenIsToken0: boolean; weightBps: number };

export type WeightRow = {
  token: Address;
  symbol: string;
  /** Position in `legs()` for a basket leg (the index `skipLegs` uses); null for the WHBAR row. */
  legIndex: number | null;
  balance: string;
  valueHbar: string;
  targetBps: number;
  actualBps: number;
  /** actual minus target, signed, in basis points of NAV. */
  driftBps: number;
  /** The vault trades this leg on the next rebalance: its value is further than `driftBps` of NAV from target. */
  outsideBand: boolean;
};

const abs = (n: bigint) => (n < 0n ? -n : n);

/**
 * Weights against targets, using the same integer test as BasketVault.rebalance: a leg is traded once
 * |value - nav x target / 10000| exceeds nav x driftBps / 10000. WHBAR is the residual leg and is never traded directly.
 */
export function weightRows(
  holdings: readonly Holding[],
  nav: bigint,
  bandBps: bigint,
  symbols: Record<string, string>,
  decimals: Record<string, number>,
): WeightRow[] {
  const band = (nav * bandBps) / BPS;
  return holdings.map((h, i) => {
    const target = (nav * BigInt(h.targetBps)) / BPS;
    const actualBps = nav === 0n ? 0 : Number((h.valueWhbar * BPS) / nav);
    const dec = decimals[h.token.toLowerCase()] ?? 8;
    return {
      token: h.token,
      symbol: symbols[h.token.toLowerCase()] ?? h.token,
      legIndex: i === 0 ? null : i - 1,
      balance: formatDecimals(h.balance, dec),
      valueHbar: fmt8(h.valueWhbar),
      targetBps: h.targetBps,
      actualBps,
      driftBps: actualBps - h.targetBps,
      outsideBand: i !== 0 && nav !== 0n && abs(h.valueWhbar - target) > band,
    };
  });
}

export function formatDecimals(value: bigint, decimals: number): string {
  const s = value.toString().padStart(decimals + 1, "0");
  const whole = s.slice(0, s.length - decimals);
  const frac = s.slice(s.length - decimals).replace(/0+$/, "");
  return frac ? `${whole}.${frac}` : whole;
}

export type NextRun = {
  automation: "on" | "off";
  intervalSeconds: number;
  pendingSchedule: Address | null;
  nextRunAt: number | null;
  secondsUntil: number | null;
  /** off: no automation. scheduled: a run is booked. past_due: booked but the network has not run it. orphaned: on with nothing booked, `book_next_run` fixes it. */
  status: "off" | "scheduled" | "past_due" | "orphaned";
};

export function nextRun(interval: bigint, pending: Address, nextRunAt: bigint, nowSeconds: number): NextRun {
  const zero = /^0x0{40}$/i.test(pending);
  if (interval === 0n)
    return { automation: "off", intervalSeconds: 0, pendingSchedule: null, nextRunAt: null, secondsUntil: null, status: "off" };
  if (zero)
    return {
      automation: "on",
      intervalSeconds: Number(interval),
      pendingSchedule: null,
      nextRunAt: null,
      secondsUntil: null,
      status: "orphaned",
    };
  const at = Number(nextRunAt);
  return {
    automation: "on",
    intervalSeconds: Number(interval),
    pendingSchedule: pending,
    nextRunAt: at,
    secondsUntil: at - nowSeconds,
    status: at - nowSeconds > 0 ? "scheduled" : "past_due",
  };
}

export type FuelRunway = {
  fuelHbar: string;
  /** The payer must hold the whole gas reservation (scheduledGas x gas price) to start a run. */
  reservationHbar: string;
  /** What the last scheduled run was charged, or null when none ran in the lookback window. */
  lastRunCostHbar: string | null;
  runsCovered: number;
  /** Days the fuel lasts at the configured interval, or null when automation is off. */
  daysCovered: number | null;
  basis: "last-run-cost" | "reservation-only";
};

const weibarToHbar = (weibar: bigint) => {
  const tiny = weibar / WEIBAR_PER_TINYBAR;
  return fmt8(tiny);
};

/** Same arithmetic as the app's AutomationCard: runs = (fuel - reservation) / cost per run + 1. */
export function fuelRunway(
  fuelWeibar: bigint,
  scheduledGas: bigint,
  gasPriceWeibar: bigint,
  lastRunFeeTinybar: bigint | null,
  intervalSeconds: bigint,
): FuelRunway {
  const reservation = scheduledGas * gasPriceWeibar;
  const cost = lastRunFeeTinybar === null ? null : lastRunFeeTinybar * WEIBAR_PER_TINYBAR;
  let runs = 0n;
  if (fuelWeibar >= reservation && reservation > 0n) runs = cost && cost > 0n ? (fuelWeibar - reservation) / cost + 1n : fuelWeibar / reservation;
  return {
    fuelHbar: weibarToHbar(fuelWeibar),
    reservationHbar: weibarToHbar(reservation),
    lastRunCostHbar: lastRunFeeTinybar === null ? null : fmt8(lastRunFeeTinybar),
    runsCovered: Number(runs),
    daysCovered: intervalSeconds === 0n ? null : Number((runs * intervalSeconds * 100n) / 86_400n) / 100,
    basis: cost && cost > 0n ? "last-run-cost" : "reservation-only",
  };
}

/** Maps leg names (symbols) or indexes to the bitmask `redeemExcept` takes. Throws on a name that is not a basket leg. */
export function resolveSkipMask(
  skip: readonly (string | number)[],
  legSymbols: readonly string[],
): { mask: bigint; skipped: string[] } {
  let mask = 0n;
  const skipped: string[] = [];
  for (const entry of skip) {
    const index =
      typeof entry === "number"
        ? entry
        : /^\d+$/.test(entry.trim())
          ? Number(entry.trim())
          : legSymbols.findIndex((s) => s.toLowerCase() === entry.trim().toLowerCase());
    if (!Number.isInteger(index) || index < 0 || index >= legSymbols.length)
      throw new Error(
        `cannot skip "${entry}": basket legs are ${legSymbols.map((s, i) => `${i}=${s}`).join(", ")} (WHBAR is always paid out)`,
      );
    mask |= 1n << BigInt(index);
    if (!skipped.includes(legSymbols[index]!)) skipped.push(legSymbols[index]!);
  }
  return { mask, skipped };
}
