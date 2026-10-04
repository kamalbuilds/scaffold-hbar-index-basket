import { LIVE_LOGS, VAULT, jsonResponse } from "./__fixtures__";
import { MIRROR_URL, MirrorError, type MirrorLog, fetchVaultEvents } from "./mirror";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const stubLogs = (logs: MirrorLog[]) => {
  const mock = vi.fn(async () => jsonResponse({ logs, links: { next: null } }));
  vi.stubGlobal("fetch", mock);
  return mock;
};

afterEach(() => vi.unstubAllGlobals());

describe("fetchVaultEvents on the live vault's logs", () => {
  beforeEach(() => void stubLogs(LIVE_LOGS));

  it("decodes all 15 captured logs, newest first", async () => {
    expect(LIVE_LOGS).toHaveLength(15);
    const events = await fetchVaultEvents(VAULT);
    expect(events).toHaveLength(15);
    const times = events.map(e => e.at);
    expect(times).toEqual([...times].sort((a, b) => b - a));
    const counts = events.reduce<Record<string, number>>((n, e) => ({ ...n, [e.name]: (n[e.name] ?? 0) + 1 }), {});
    expect(counts).toEqual({ Rebalanced: 4, Redeemed: 1, Deposited: 1, Swapped: 4, ScheduledRun: 3, RunBooked: 2 });
  });

  it("decodes the Deposited event's arguments to the chain's values", async () => {
    const deposited = (await fetchVaultEvents(VAULT)).find(e => e.name === "Deposited")!;
    expect(deposited.args).toEqual({
      account: "0x1565aF2C2eF52b4A89180684a47C5260c716AbD1",
      hbarIn: 100_000_000n,
      valueAdded: 99_818_448n,
      shares: 95_837_174n,
    });
    expect(deposited.at).toBe(1791134547);
    expect(deposited.hash).toMatch(/^0xe7b119be9f8c/);
  });

  it("decodes the Redeemed event's in-kind leg amounts", async () => {
    const redeemed = (await fetchVaultEvents(VAULT)).find(e => e.name === "Redeemed")!;
    expect(redeemed.args).toMatchObject({ shares: 5_000_000n, whbarOut: 2_072_910n, legAmounts: [607_824n, 29_234n] });
  });

  it("gives two events of one transaction distinct ids", async () => {
    const ids = (await fetchVaultEvents(VAULT)).map(e => e.id);
    expect(new Set(ids).size).toBe(ids.length);
  });

  it("asks the mirror node for the vault's newest logs first", async () => {
    const mock = stubLogs(LIVE_LOGS);
    await fetchVaultEvents(VAULT, 15);
    expect(mock).toHaveBeenCalledWith(`${MIRROR_URL}/api/v1/contracts/${VAULT}/results/logs?order=desc&limit=15`, {
      headers: { Accept: "application/json" },
    });
  });
});

describe("fetchVaultEvents edge cases", () => {
  it("gives a log that is not one of the vault's events no row", async () => {
    const foreign: MirrorLog = { ...LIVE_LOGS[0], topics: [`0x${"ab".repeat(32)}`] };
    stubLogs([foreign, ...LIVE_LOGS]);
    expect(await fetchVaultEvents(VAULT)).toHaveLength(15);
  });

  it("throws a MirrorError carrying the status on a failed request", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({}, 503)),
    );
    await expect(fetchVaultEvents(VAULT)).rejects.toMatchObject({ status: 503 });
    await expect(fetchVaultEvents(VAULT)).rejects.toBeInstanceOf(MirrorError);
  });
});
