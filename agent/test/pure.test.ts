import { describe, expect, it } from "vitest";
import { fuelRunway, nextRun, resolveSkipMask, weightRows } from "../src/analysis";
import { decodeRevert } from "../src/chain";
import { configFromEnv } from "../src/config";
import { entityNum, linkBuilder, mirrorTxId } from "../src/links";
import { bookNextRunSchema, depositHbarSchema, previewDepositSchema, rebalanceNowSchema, redeemSharesSchema } from "../src/schemas";
import { shapeState } from "../src/shape";
import { applySlippage, estimateShares, parseAmount } from "../src/units";
import { SAUCE, USDC, WHBAR, state } from "./fixture";

describe("amounts", () => {
  it("parses plain decimals to 8-decimal integers", () => {
    expect(parseAmount("1")).toBe(100_000_000n);
    expect(parseAmount("0.00000001")).toBe(1n);
    expect(parseAmount("12.5")).toBe(1_250_000_000n);
  });

  it.each(["0", "0.0", "-1", "1e3", "1.123456789", "", "abc", "1,5", " ", "0x10"])("refuses %j", (bad) => {
    expect(() => parseAmount(bad)).toThrow();
  });

  it("estimates shares as value x supply / NAV, from vault C's real numbers", () => {
    expect(estimateShares(100_000_000n, 1_194_130_370n, 1_243_395_846n, 100_000n)).toBe(96_037_828n);
  });

  it("prices the first deposit as value minus the dead shares, and refuses a deposit that does not cover them", () => {
    expect(estimateShares(1_000_000_000n, 0n, 0n, 100_000n)).toBe(999_900_000n);
    expect(estimateShares(100_000n, 0n, 0n, 100_000n)).toBe(0n);
  });

  it("cannot price against a zero NAV once shares exist", () => {
    expect(estimateShares(1n, 5n, 0n, 100_000n)).toBeNull();
  });

  it("applies slippage in basis points, rounding down", () => {
    expect(applySlippage(96_037_828n, 300)).toBe(93_156_693n);
    expect(applySlippage(1_000n, 1)).toBe(999n);
  });
});

describe("weights and drift", () => {
  const s = state();
  const rows = weightRows(s.holdings, s.nav, s.driftBps, s.symbols, s.decimals);

  it("reports each leg against its target in basis points of NAV", () => {
    expect(rows.map((r) => [r.symbol, r.targetBps, r.actualBps, r.driftBps])).toEqual([
      ["WHBAR", 4000, 3978, -22],
      ["SAUCE", 3000, 2987, -13],
      ["USDC", 3000, 3034, 34],
    ]);
    expect(rows.map((r) => r.legIndex)).toEqual([null, 0, 1]);
  });

  it("flags no leg inside the 50 bps band", () => {
    expect(rows.some((r) => r.outsideBand)).toBe(false);
  });

  it("flags a leg once it is further than the band from target, on the sell side and the buy side", () => {
    const over = state({ holdings: [s.holdings[0]!, s.holdings[1]!, { ...s.holdings[2]!, valueWhbar: 420_000_000n }] });
    const sell = weightRows(over.holdings, over.nav, over.driftBps, over.symbols, over.decimals);
    expect(sell.map((r) => r.outsideBand)).toEqual([false, false, true]);
    const under = state({ holdings: [s.holdings[0]!, { ...s.holdings[1]!, valueWhbar: 300_000_000n }, s.holdings[2]!] });
    const buy = weightRows(under.holdings, under.nav, under.driftBps, under.symbols, under.decimals);
    expect(buy.map((r) => r.outsideBand)).toEqual([false, true, false]);
  });

  it("uses the contract's strict boundary: exactly the band is inside, one tinybar more is outside", () => {
    const at = (value: bigint) => {
      const x = state({ holdings: [s.holdings[0]!, s.holdings[1]!, { ...s.holdings[2]!, valueWhbar: value }] });
      return weightRows(x.holdings, x.nav, x.driftBps, x.symbols, x.decimals)[2]!.outsideBand;
    };
    const target = (s.nav * 3000n) / 10_000n;
    const band = (s.nav * 50n) / 10_000n;
    expect([at(target + band), at(target + band + 1n), at(target - band), at(target - band - 1n)]).toEqual([false, true, false, true]);
  });

  it("never marks WHBAR, the residual leg, as traded directly", () => {
    const far = state({ holdings: [{ ...s.holdings[0]!, valueWhbar: 900_000_000n }, s.holdings[1]!, s.holdings[2]!] });
    expect(weightRows(far.holdings, far.nav, far.driftBps, far.symbols, far.decimals)[0]!.outsideBand).toBe(false);
  });

  it("formats token balances with their own decimals", () => {
    expect(rows[1]!.balance).toBe("14513.1258");
    expect(rows[2]!.balance).toBe("6.988607");
  });
});

describe("automation and fuel", () => {
  const pending = "0x0000000000000000000000000000000000A5B211" as const;
  const none = "0x0000000000000000000000000000000000000000" as const;

  it("tells off, scheduled, past due and orphaned apart", () => {
    expect(nextRun(0n, none, 0n, 1000).status).toBe("off");
    expect(nextRun(21_600n, pending, 2_000n, 1000)).toMatchObject({ status: "scheduled", secondsUntil: 1000 });
    expect(nextRun(21_600n, pending, 900n, 1000)).toMatchObject({ status: "past_due", secondsUntil: -100 });
    expect(nextRun(21_600n, none, 0n, 1000).status).toBe("orphaned");
  });

  it("counts runs the way the app does: (fuel - reservation) / cost per run + 1", () => {
    const f = fuelRunway(73_370_888_950_000_000_000n, 4_000_000n, 870_000_000_000n, 128_996_442n, 21_600n);
    expect(f).toMatchObject({ fuelHbar: "73.37088895", reservationHbar: "3.48", lastRunCostHbar: "1.28996442", runsCovered: 55, basis: "last-run-cost" });
    expect(f.daysCovered).toBe(13.75);
  });

  it("falls back to fuel / reservation when no run has been charged yet, and reports zero below the reservation", () => {
    expect(fuelRunway(3_480n * 10n ** 15n * 4n, 4_000_000n, 870_000_000_000n, null, 21_600n)).toMatchObject({ runsCovered: 4, basis: "reservation-only" });
    expect(fuelRunway(10n ** 18n, 4_000_000n, 870_000_000_000n, 128_996_442n, 21_600n).runsCovered).toBe(0);
  });

  it("has no day count while automation is off", () => {
    expect(fuelRunway(10n ** 20n, 4_000_000n, 870_000_000_000n, null, 0n).daysCovered).toBeNull();
  });
});

describe("skip legs", () => {
  const legs = ["SAUCE", "USDC"];
  it("maps symbols and indexes to the contract's bitmask", () => {
    expect(resolveSkipMask(["usdc"], legs)).toEqual({ mask: 2n, skipped: ["USDC"] });
    expect(resolveSkipMask([0, "USDC", "1"], legs)).toEqual({ mask: 3n, skipped: ["SAUCE", "USDC"] });
    expect(resolveSkipMask([], legs).mask).toBe(0n);
  });
  it("refuses WHBAR, unknown names and out-of-range indexes", () => {
    for (const bad of ["WHBAR", "DOGE", 2, -1, 1.5]) expect(() => resolveSkipMask([bad], legs), String(bad)).toThrow(/cannot skip/);
  });
});

describe("links and ids", () => {
  it("converts the SDK transaction id to the mirror and HashScan form", () => {
    expect(mirrorTxId("0.0.4729347@1791134539.501782816")).toBe("0.0.4729347-1791134539-501782816");
    expect(() => mirrorTxId("0xabc")).toThrow();
    expect(linkBuilder("https://hashscan.io/testnet").tx("0.0.4729347@1791134539.501782816")).toBe("https://hashscan.io/testnet/transaction/0.0.4729347-1791134539-501782816");
  });
  it("turns long-zero addresses into entity ids and leaves aliases alone", () => {
    expect(entityNum("0x0000000000000000000000000000000000A56762")).toBe(10_839_906);
    expect(entityNum("0xe72FbF68536D29d3A9e0D897C2aE813B7B279058")).toBeNull();
    expect(linkBuilder("h").token("0x0000000000000000000000000000000000A56762")).toBe("h/token/0.0.10839906");
  });
});

describe("revert decoding", () => {
  it("names the vault's custom errors", () => {
    expect(decodeRevert("0x11d9f091")).toEqual({ name: "OnlyOwnerOrSelf", args: [] });
    expect(decodeRevert("0xcb1d8bba00000000000000000000000000000000000000000000000000000000000000050000000000000000000000000000000000000000000000000000000000000009")).toEqual({
      name: "InsufficientShares",
      args: ["5", "9"],
    });
  });
  it("returns null for empty or unknown data", () => {
    expect(decodeRevert("0x")).toBeNull();
    expect(decodeRevert(null)).toBeNull();
    expect(decodeRevert("0xdeadbeef")).toBeNull();
  });
});

describe("tool input schemas", () => {
  it("accepts numbers and strings for amounts, defaulting slippage to 3%", () => {
    expect(depositHbarSchema.parse({ hbar: "1.5" })).toEqual({ hbar: "1.5", slippageBps: 300 });
    expect(depositHbarSchema.parse({ hbar: 2 }).hbar).toBe("2");
    expect(depositHbarSchema.parse({ hbar: 0.25, slippageBps: 100 })).toEqual({ hbar: "0.25", slippageBps: 100 });
  });

  it.each([{ hbar: "0" }, { hbar: "-1" }, { hbar: "1.123456789" }, { hbar: "ten" }, { hbar: "" }, {}, { hbar: "1", slippageBps: 0 }, { hbar: "1", slippageBps: 5000 }, { hbar: "1", slippageBps: 1.5 }])(
    "refuses deposit input %j",
    (input) => {
      expect(depositHbarSchema.safeParse(input).success).toBe(false);
    },
  );

  it("validates the preview account as 0.0.N or an EVM address", () => {
    expect(previewDepositSchema.safeParse({ hbar: "1", account: "0.0.4729347" }).success).toBe(true);
    expect(previewDepositSchema.safeParse({ hbar: "1", account: "0x1565aF2C2eF52b4A89180684a47C5260c716AbD1" }).success).toBe(true);
    expect(previewDepositSchema.safeParse({ hbar: "1", account: "alice" }).success).toBe(false);
    expect(previewDepositSchema.safeParse({ hbar: "1", account: "0x123" }).success).toBe(false);
  });

  it("takes all or a positive amount of shares, and skip legs by name or index", () => {
    expect(redeemSharesSchema.parse({ shares: "all" })).toEqual({ shares: "all", skipLegs: [] });
    expect(redeemSharesSchema.parse({ shares: 0.05, skipLegs: ["USDC", 0] })).toEqual({ shares: "0.05", skipLegs: ["USDC", 0] });
    for (const bad of [{ shares: "0" }, { shares: "everything" }, { shares: "1", skipLegs: [-1] }, { shares: "1", skipLegs: [""] }, {}]) {
      expect(redeemSharesSchema.safeParse(bad).success, JSON.stringify(bad)).toBe(false);
    }
  });

  it("gives the no-argument tools their defaults", () => {
    expect(bookNextRunSchema.parse({})).toEqual({});
    expect(rebalanceNowSchema.parse({})).toEqual({ force: false });
    expect(rebalanceNowSchema.safeParse({ force: "yes" }).success).toBe(false);
  });
});

describe("result shaping", () => {
  const cfg = configFromEnv({});
  const out = shapeState(state(), cfg);

  it("shapes NAV, share price and supply as decimal strings, never bigints", () => {
    expect(out).toMatchObject({ navHbar: "12.43737", navUsd: "1.26877541", hbarUsd: "0.10201316", sharePriceUsd: "0.10625099" });
    expect(out.share).toEqual({ token: "0x0000000000000000000000000000000000A56762", symbol: "IBSK", totalSupply: "11.9413037" });
    expect(() => JSON.stringify(out)).not.toThrow();
  });

  it("carries HashScan links for the vault, share token and pending schedule", () => {
    expect(out.links).toEqual({
      vault: "https://hashscan.io/testnet/contract/0xe72FbF68536D29d3A9e0D897C2aE813B7B279058",
      shareToken: "https://hashscan.io/testnet/token/0.0.10839906",
      owner: "https://hashscan.io/testnet/account/0x1565aF2C2eF52b4A89180684a47C5260c716AbD1",
      pendingSchedule: "https://hashscan.io/testnet/schedule/0.0.10859025",
    });
  });

  it("reports the price guard as off for the testnet deploy and on when a leg is guarded", () => {
    expect(out.priceGuard).toEqual({ enabled: false, maxDeviationBps: null });
    expect(shapeState(state({ guardLeg: 1n }), cfg).priceGuard).toEqual({ enabled: true, maxDeviationBps: 300 });
  });

  it("drops USD figures and says why while the oracle is stale, but still reports NAV in HBAR", () => {
    const stale = shapeState(state({ oracle: { fresh: false, reason: "StaleOracle" } }), cfg);
    expect(stale).toMatchObject({ navUsd: null, hbarUsd: null, sharePriceUsd: null, navHbar: "12.43737" });
    expect(stale.oracle).toMatchObject({ fresh: false, reason: "StaleOracle" });
  });

  it("flags a rebalance as due when a leg is outside the band", () => {
    const s = state();
    const drifted = shapeState(state({ holdings: [s.holdings[0]!, s.holdings[1]!, { ...s.holdings[2]!, valueWhbar: 420_000_000n }] }), cfg);
    expect(out.needsRebalance).toBe(false);
    expect(drifted.needsRebalance).toBe(true);
  });

  it("names the three tokens by symbol", () => {
    expect(out.weights.map((w) => w.token.toLowerCase())).toEqual([WHBAR, SAUCE, USDC].map((t) => t.toLowerCase()));
  });
});
