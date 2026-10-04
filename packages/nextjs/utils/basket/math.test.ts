import {
  estimateShares,
  hbarToUsd8,
  isPaidOut,
  minSharesFor,
  redeemPayout,
  redeemPayoutWhbar,
  skipMaskOf,
  tinybarToWeibar,
  weibarToTinybar,
} from "./math";
import { parseEther } from "viem";
import { describe, expect, it } from "vitest";

const DEAD = 100_000n; // BasketVault.DEAD_SHARES

describe("estimateShares", () => {
  it("returns null with no amount", () => {
    expect(estimateShares(null, 1_000n, 1_000n, DEAD)).toBeNull();
    expect(estimateShares(0n, 1_000n, 1_000n, DEAD)).toBeNull();
  });

  it("mints one share unit per tinybar on the first deposit, less the dead shares", () => {
    expect(estimateShares(1_000_000_000n, 0n, 0n, DEAD)).toBe(999_900_000n);
  });

  it("mints nothing when the first deposit does not cover the dead shares", () => {
    expect(estimateShares(DEAD, 0n, 0n, DEAD)).toBe(0n);
    expect(estimateShares(DEAD - 1n, 0n, 0n, DEAD)).toBe(0n);
    expect(estimateShares(DEAD + 1n, 0n, 0n, DEAD)).toBe(1n);
  });

  it("prices later deposits at value x supply / NAV, rounded down", () => {
    expect(estimateShares(500n, 1_000n, 2_000n, DEAD)).toBe(250n);
    expect(estimateShares(10n, 3n, 7n, DEAD)).toBe(4n);
  });

  it("does not subtract dead shares once the vault has supply", () => {
    expect(estimateShares(1_000_000n, 1_000_000n, 1_000_000n, DEAD)).toBe(1_000_000n);
  });

  it("returns null when there is supply but no NAV to divide by", () => {
    expect(estimateShares(1_000n, 1_000n, 0n, DEAD)).toBeNull();
  });

  it("matches the live vault: the preview of its 1 HBAR deposit stays inside the default 3% slippage", () => {
    // Deposited(hbarIn 100000000, valueAdded 99818448, shares 95837174) on testnet: supply / NAV = shares / valueAdded.
    const preview = estimateShares(100_000_000n, 95_837_174n, 99_818_448n, DEAD)!;
    expect(preview).toBe(96_011_484n);
    expect(preview).toBeGreaterThan(95_837_174n); // pool fees and price impact cost the depositor shares
    expect(minSharesFor(preview, 300)).toBeLessThanOrEqual(95_837_174n); // so the deposit would not have reverted
    expect(minSharesFor(preview, 10)).toBeGreaterThan(95_837_174n); // and a 0.1% floor would have
  });
});

describe("minSharesFor", () => {
  it("takes the slippage off the estimate in basis points", () => {
    expect(minSharesFor(1_000_000n, 300)).toBe(970_000n);
    expect(minSharesFor(1_000_000n, 100)).toBe(990_000n);
    expect(minSharesFor(1_000_000n, 500)).toBe(950_000n);
  });

  it("rounds down so the floor is never above the estimate", () => {
    expect(minSharesFor(999n, 300)).toBe(969n);
    expect(minSharesFor(1n, 300)).toBe(0n);
  });

  it("is the estimate at 0 bps and zero at 100%", () => {
    expect(minSharesFor(123_456n, 0)).toBe(123_456n);
    expect(minSharesFor(123_456n, 10_000)).toBe(0n);
  });
});

describe("skip mask", () => {
  it("is zero with nothing skipped", () => {
    expect(skipMaskOf({}, 3)).toBe(0n);
    expect(skipMaskOf({ 0: false, 1: false }, 3)).toBe(0n);
  });

  it("sets bit i for skipped leg i", () => {
    expect(skipMaskOf({ 0: true }, 3)).toBe(1n);
    expect(skipMaskOf({ 1: true }, 3)).toBe(2n);
    expect(skipMaskOf({ 2: true }, 3)).toBe(4n);
    expect(skipMaskOf({ 0: true, 2: true }, 3)).toBe(5n);
    expect(skipMaskOf({ 0: true, 1: true, 2: true }, 3)).toBe(7n);
  });

  it("ignores a skip flag past the last leg, which the vault would reject as BadSkipMask", () => {
    expect(skipMaskOf({ 3: true }, 3)).toBe(0n);
  });

  it("maps leg i to token i + 1 and always pays WHBAR, token 0", () => {
    const skipped = { 0: true };
    expect(isPaidOut(skipped, 0)).toBe(true);
    expect(isPaidOut(skipped, 1)).toBe(false);
    expect(isPaidOut(skipped, 2)).toBe(true);
  });
});

describe("in-kind redeem payout", () => {
  // WHBAR, SAUCE, USDC held by a vault with 1,000,000 share units outstanding.
  const holdings = [
    { balance: 4_000_000_000n, valueWhbar: 4_000_000_000n },
    { balance: 1_234_567n, valueWhbar: 3_000_000_000n },
    { balance: 7_654_321n, valueWhbar: 3_000_000_000n },
  ];
  const supply = 1_000_000n;

  it("pays the burned fraction of every token the vault holds", () => {
    const rows = redeemPayout(holdings, 250_000n, supply, {})!;
    expect(rows.map(r => r.amount)).toEqual([1_000_000_000n, 308_641n, 1_913_580n]);
    expect(rows.every(r => !r.skipped)).toBe(true);
  });

  it("rounds each token down", () => {
    const rows = redeemPayout(holdings, 1n, supply, {})!;
    expect(rows.map(r => r.amount)).toEqual([4_000n, 1n, 7n]);
  });

  it("flags a skipped leg and leaves WHBAR and the other leg paid", () => {
    const rows = redeemPayout(holdings, 250_000n, supply, { 0: true })!;
    expect(rows.map(r => r.skipped)).toEqual([false, true, false]);
    const rowsUsdc = redeemPayout(holdings, 250_000n, supply, { 1: true })!;
    expect(rowsUsdc.map(r => r.skipped)).toEqual([false, false, true]);
  });

  it("values the paid slice in WHBAR and drops a skipped leg's value from it", () => {
    expect(redeemPayoutWhbar(holdings, 250_000n, supply, {})).toBe(2_500_000_000n);
    expect(redeemPayoutWhbar(holdings, 250_000n, supply, { 0: true })).toBe(1_750_000_000n);
    expect(redeemPayoutWhbar(holdings, 250_000n, supply, { 0: true, 1: true })).toBe(1_000_000_000n);
  });

  it("has no payout before the first deposit", () => {
    expect(redeemPayout(holdings, 1n, 0n, {})).toBeNull();
    expect(redeemPayoutWhbar(holdings, 1n, 0n, {})).toBeNull();
  });

  it("reproduces the live vault's Redeemed leg amounts from pro-rata holdings", () => {
    // Redeemed(shares 5000000, whbarOut 2072910, legAmounts [607824, 29234]) on testnet, against a supply of 20x the burn.
    const live = [
      { balance: 2_072_910n * 20n, valueWhbar: 2_072_910n * 20n },
      { balance: 607_824n * 20n, valueWhbar: 0n },
      { balance: 29_234n * 20n, valueWhbar: 0n },
    ];
    const rows = redeemPayout(live, 5_000_000n, 100_000_000n, {})!;
    expect(rows.map(r => r.amount)).toEqual([2_072_910n, 607_824n, 29_234n]);
  });
});

describe("unit conversions", () => {
  it("counts 10 HBAR as 1e9 tinybar and 1e19 weibar", () => {
    expect(tinybarToWeibar(1_000_000_000n)).toBe(parseEther("10"));
    expect(weibarToTinybar(parseEther("10"))).toBe(1_000_000_000n);
  });

  it("drops sub-tinybar dust going back from weibar", () => {
    expect(weibarToTinybar(9_999_999_999n)).toBe(0n);
    expect(weibarToTinybar(10_000_000_001n)).toBe(1n);
  });

  it("prices HBAR in 8-decimal USD", () => {
    expect(hbarToUsd8(100_000_000n, 20_000_000n)).toBe(20_000_000n); // 1 HBAR at $0.20
    expect(hbarToUsd8(2_500_000_000n, 20_000_000n)).toBe(500_000_000n); // 25 HBAR is $5.00
  });
});
