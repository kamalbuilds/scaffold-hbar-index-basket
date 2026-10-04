import { fmtUnits, fmtUsd, parseAmount } from "./format";
import { evmToEntityId, hashscan } from "./hedera";
import { describe, expect, it } from "vitest";

describe("parseAmount", () => {
  it("parses HBAR to 8-decimal tinybar and SAUCE or USDC to 6-decimal units", () => {
    expect(parseAmount("10", 8)).toBe(1_000_000_000n);
    expect(parseAmount("0.00000001", 8)).toBe(1n);
    expect(parseAmount("1.5", 6)).toBe(1_500_000n);
    expect(parseAmount(".5", 6)).toBe(500_000n);
    expect(parseAmount("  2.25 ", 8)).toBe(225_000_000n);
  });

  it("refuses precision finer than the token has", () => {
    expect(parseAmount("0.000000001", 8)).toBeNull();
    expect(parseAmount("1.0000001", 6)).toBeNull();
  });

  it("refuses empty and malformed input", () => {
    for (const bad of ["", " ", ".", "-1", "1e5", "1,5", "abc", "1.2.3"]) expect(parseAmount(bad, 8)).toBeNull();
  });
});

describe("fmtUnits", () => {
  it("shows 8-decimal and 6-decimal balances", () => {
    expect(fmtUnits(123_456_789n, 8)).toBe("1.2346");
    expect(fmtUnits(1_500_000n, 6)).toBe("1.5");
    expect(fmtUnits(1_234_567_890_000n, 6)).toBe("1,234,567.89");
  });

  it("rounds half up on the bigint", () => {
    expect(fmtUnits(12_345_000n, 8, 4)).toBe("0.1235");
    expect(fmtUnits(12_344_999n, 8, 4)).toBe("0.1234");
  });

  it("marks a nonzero amount that rounds to nothing and prints a true zero as 0", () => {
    expect(fmtUnits(1n, 8)).toBe("<0.0001");
    expect(fmtUnits(0n, 8)).toBe("0");
  });

  it("prints 8-decimal USD with a dollar sign", () => {
    expect(fmtUsd(20_000_000n)).toBe("$0.20");
    expect(fmtUsd(123_456_789_000n)).toBe("$1,234.57");
  });
});

describe("evmToEntityId", () => {
  it("reads shard.realm.num out of a long-zero address", () => {
    expect(evmToEntityId("0x0000000000000000000000000000000000A5B211")).toBe("0.0.10859025");
    expect(evmToEntityId("0x0000000000000000000000000000000000001549")).toBe("0.0.5449");
  });

  it("builds HashScan token links from the address", () => {
    expect(hashscan.token("0x0000000000000000000000000000000000001549")).toBe(
      "https://hashscan.io/testnet/token/0.0.5449",
    );
  });
});
