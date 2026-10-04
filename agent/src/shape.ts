import type { Address } from "viem";
import { type NextRun, type WeightRow, fuelRunway, nextRun, weightRows, type FuelRunway } from "./analysis";
import type { RawState } from "./chain";
import type { VaultConfig } from "./config";
import { type Links, linkBuilder } from "./links";
import { fmt8 } from "./units";

export type BasketState = {
  vault: Address;
  owner: Address;
  navHbar: string;
  navUsd: string | null;
  hbarUsd: string | null;
  sharePriceUsd: string | null;
  oracle: { fresh: boolean; reason?: string; note: string };
  share: { token: Address; symbol: string; totalSupply: string };
  weights: WeightRow[];
  driftBandBps: number;
  needsRebalance: boolean;
  priceGuard: { enabled: boolean; maxDeviationBps: number | null };
  automation: NextRun;
  fuel: FuelRunway;
  links: Record<string, string>;
};

const ZERO_GUARD = (1n << 256n) - 1n;

/** Turns raw chain reads into the structured result of get_basket_state. Pure: no network, no clock. */
export function shapeState(raw: RawState, cfg: VaultConfig): BasketState {
  const links: Links = linkBuilder(cfg.hashscanUrl);
  const weights = weightRows(raw.holdings, raw.nav, raw.driftBps, raw.symbols, raw.decimals);
  const fresh = raw.oracle.fresh;
  const sharePrice = fresh && raw.supply > 0n ? (raw.oracle.navUsd * 10n ** 8n) / raw.supply : null;
  return {
    vault: raw.vault,
    owner: raw.owner,
    navHbar: fmt8(raw.nav),
    navUsd: fresh ? fmt8(raw.oracle.navUsd) : null,
    hbarUsd: fresh ? fmt8(raw.oracle.hbarUsd) : null,
    sharePriceUsd: sharePrice === null ? null : fmt8(sharePrice),
    oracle: fresh
      ? { fresh: true, note: "Chainlink HBAR/USD is current." }
      : {
          fresh: false,
          reason: raw.oracle.reason,
          note: "Chainlink HBAR/USD is stale. Deposits and rebalances revert until it updates; redemptions still work because they read no price.",
        },
    share: { token: raw.shareToken, symbol: raw.shareSymbol, totalSupply: fmt8(raw.supply) },
    weights,
    driftBandBps: Number(raw.driftBps),
    needsRebalance: weights.some((w) => w.outsideBand),
    priceGuard: raw.guardLeg === ZERO_GUARD ? { enabled: false, maxDeviationBps: null } : { enabled: true, maxDeviationBps: Number(raw.maxDeviationBps) },
    automation: nextRun(raw.interval, raw.pendingSchedule, raw.nextRunAt, raw.nowSeconds),
    fuel: fuelRunway(raw.fuelWeibar, raw.scheduledGas, raw.gasPriceWeibar, raw.lastRunFeeTinybar, raw.interval),
    links: {
      vault: links.contract(raw.vault),
      shareToken: links.token(raw.shareToken),
      owner: links.account(raw.owner),
      ...(raw.pendingSchedule !== "0x0000000000000000000000000000000000000000" ? { pendingSchedule: links.schedule(raw.pendingSchedule) } : {}),
    },
  };
}

export function describeState(s: BasketState): string {
  const lines = [
    `Index Basket ${s.vault}: NAV ${s.navHbar} HBAR${s.navUsd ? ` ($${s.navUsd})` : ""}, ${s.share.totalSupply} ${s.share.symbol} outstanding${s.sharePriceUsd ? `, $${s.sharePriceUsd} per share` : ""}.`,
    ...s.weights.map(
      (w) => `${w.symbol}: ${(w.actualBps / 100).toFixed(2)}% vs target ${(w.targetBps / 100).toFixed(2)}% (drift ${w.driftBps >= 0 ? "+" : ""}${w.driftBps} bps${w.outsideBand ? ", outside the band" : ""}).`,
    ),
    s.needsRebalance ? "A leg is outside the drift band: the next rebalance will trade." : `Every leg is inside the ${s.driftBandBps} bps band.`,
  ];
  const a = s.automation;
  lines.push(
    a.status === "off"
      ? "Automation is off."
      : a.status === "orphaned"
        ? "Automation is on but no run is booked: call book_next_run."
        : a.status === "past_due"
          ? `The booked run is ${-a.secondsUntil!}s past due; the network has not executed it yet.`
          : `Next scheduled run in ${Math.round(a.secondsUntil! / 60)} min.`,
  );
  lines.push(`Fuel ${s.fuel.fuelHbar} HBAR covers about ${s.fuel.runsCovered} runs${s.fuel.daysCovered === null ? "" : ` (${s.fuel.daysCovered} days)`}.`);
  if (!s.oracle.fresh) lines.push(s.oracle.note);
  return lines.join("\n");
}
