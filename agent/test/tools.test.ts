import { AgentMode, type Context } from "@hashgraph/hedera-agent-kit";
import { ContractExecuteTransaction, Client, Transaction } from "@hiero-ledger/sdk";
import { HederaAIToolkit } from "@hashgraph/hedera-agent-kit-ai-sdk";
import { encodeFunctionData } from "viem";
import { beforeAll, describe, expect, it, vi } from "vitest";
import { vaultAbi } from "../src/abi";
import { configFromEnv } from "../src/config";
import { createIndexBasketPlugin, indexBasketToolNames as T } from "../src/plugin";
import { OWNER, STRANGER, state, stubChain } from "./fixture";

const ctx: Context = { mode: AgentMode.RETURN_BYTES, accountId: "0.0.4729347" };
let client: Client;
beforeAll(() => {
  client = Client.forTestnet();
  vi.spyOn(console, "error").mockImplementation(() => {});
});

const tool = (chain: ReturnType<typeof stubChain>, method: string, context: Context = ctx) => {
  const t = createIndexBasketPlugin(configFromEnv({}), chain).tools(context).find((x) => x.method === method);
  if (!t) throw new Error(`no tool ${method}`);
  return (params: unknown) => t.execute(client, context, params);
};
/** The unsigned contract call a RETURN_BYTES tool produced. */
const decode = (out: { bytes: Uint8Array }) => {
  const tx = Transaction.fromBytes(out.bytes) as ContractExecuteTransaction;
  return { tx, data: `0x${Buffer.from(tx.functionParameters!).toString("hex")}` };
};
const drifted = () => {
  const s = state();
  return state({ holdings: [s.holdings[0]!, s.holdings[1]!, { ...s.holdings[2]!, valueWhbar: 420_000_000n }] });
};

describe("plugin", () => {
  it("exposes the six tools, query and transaction typed, each with a zod object schema", () => {
    const tools = createIndexBasketPlugin(configFromEnv({}), stubChain()).tools(ctx);
    expect(tools.map((t) => t.method)).toEqual(["get_basket_state", "preview_deposit", "deposit_hbar", "redeem_shares", "book_next_run", "rebalance_now"]);
    expect(tools.map((t) => t.toolType)).toEqual(["query", "query", "transaction", "transaction", "transaction", "transaction"]);
    for (const t of tools) expect(t.description.length).toBeGreaterThan(80);
  });

  it("loads into the Agent Kit AI SDK toolkit and runs a tool through the adapter", async () => {
    const toolkit = new HederaAIToolkit({ client, configuration: { plugins: [createIndexBasketPlugin(configFromEnv({}), stubChain())], context: ctx } });
    expect(Object.keys(toolkit.getTools())).toEqual(expect.arrayContaining(["get_basket_state", "deposit_hbar", "rebalance_now"]));
    const t = toolkit.getTools().get_basket_state!;
    const out = (await t.execute!({}, { toolCallId: "1", messages: [] } as never)) as { raw: { navHbar: string }; humanMessage: string };
    expect(out.raw.navHbar).toBe("12.43737");
    expect(out.humanMessage).toContain("NAV 12.43737 HBAR");
  });
});

describe("get_basket_state", () => {
  it("returns the shaped state and the account's position", async () => {
    const out = await tool(stubChain(), T.state)({});
    expect(out.raw).toMatchObject({ status: "SUCCESS", navHbar: "12.43737", needsRebalance: false, automation: { status: "scheduled" }, fuel: { runsCovered: 55 } });
    expect(out.raw.position).toMatchObject({ account: "0.0.4729347", shares: "10" });
  });

  it("rejects a malformed account instead of querying it", async () => {
    const out = await tool(stubChain(), T.state)({ account: "bob" });
    expect(out.raw.status).toBe("ERROR");
  });
});

describe("preview_deposit", () => {
  it("floors minShares on the simulated amount", async () => {
    const out = await tool(stubChain({ simulated: 95_863_465n }), T.preview)({ hbar: "1", slippageBps: 300 });
    expect(out.raw).toMatchObject({ canDeposit: true, simulatedShares: "0.95863465", estimatedShares: "0.96011485", minShares: "0.92987561", minSharesBasis: "eth_call of deposit" });
  });

  it("falls back to the formula when the node cannot simulate", async () => {
    const out = await tool(stubChain({ simulated: null }), T.preview)({ hbar: "1" });
    expect(out.raw).toMatchObject({ simulatedShares: null, estimatedShares: "0.96011485", minShares: "0.9313114" });
  });

  it("blocks on a stale oracle and on a missing share association", async () => {
    const stale = await tool(stubChain({ state: state({ oracle: { fresh: false, reason: "StaleOracle" } }) }), T.preview)({ hbar: "1" });
    expect(stale.raw).toMatchObject({ canDeposit: false, valueUsd: null });
    expect(stale.raw.blockers[0]).toContain("stale");
    const unassoc = await tool(stubChain({ associated: false }), T.preview)({ hbar: "1" });
    expect(unassoc.raw).toMatchObject({ canDeposit: false, simulatedShares: null });
    expect(unassoc.raw.blockers[0]).toContain("not associated");
  });

  it("refuses zero and over-precise amounts", async () => {
    for (const hbar of ["0", "0.123456789"]) expect((await tool(stubChain(), T.preview)({ hbar })).raw.status).toBe("ERROR");
  });
});

describe("deposit_hbar", () => {
  it("builds the payable deposit(minShares) call, floored from the simulation", async () => {
    const out = await tool(stubChain({ simulated: 95_863_465n }), T.deposit)({ hbar: "1" });
    const { tx, data } = decode(out);
    expect(tx.payableAmount!.toTinybars().toString()).toBe("100000000");
    expect(tx.gas!.toString()).toBe("4000000");
    expect(data).toBe(encodeFunctionData({ abi: vaultAbi, functionName: "deposit", args: [92_987_561n] }));
    expect(out.plan).toMatchObject({ hbar: "1", minShares: "0.92987561" });
  });

  it("sends nothing when the share token is not associated", async () => {
    const out = await tool(stubChain({ associated: false }), T.deposit)({ hbar: "1" });
    expect(out.bytes).toBeUndefined();
    expect(out.raw).toMatchObject({ status: "ERROR", blocked: true });
    expect(out.raw.reasons[0]).toContain("associate_token_tool");
  });

  it("sends nothing when the balance cannot cover the amount plus the gas reservation", async () => {
    const out = await tool(stubChain({ hbarBalance: 4n * 10n ** 18n }), T.deposit)({ hbar: "1" });
    expect(out.raw).toMatchObject({ status: "ERROR", blocked: true });
    expect(out.raw.reasons[0]).toContain("gas reservation");
    expect((await tool(stubChain({ hbarBalance: 5n * 10n ** 18n }), T.deposit)({ hbar: "1" })).bytes).toBeDefined();
  });

  it("sends nothing against a stale oracle", async () => {
    const out = await tool(stubChain({ state: state({ oracle: { fresh: false, reason: "StaleOracle" } }) }), T.deposit)({ hbar: "1" });
    expect(out.raw.blocked).toBe(true);
  });

  it("validates input even when called directly, without the adapter", async () => {
    for (const hbar of ["0", "-3", "abc"]) expect((await tool(stubChain(), T.deposit)({ hbar })).raw.status).toBe("ERROR");
  });
});

describe("redeem_shares", () => {
  it("builds redeemExcept with the skip mask and returns the approval first when the allowance is short", async () => {
    const out = await tool(stubChain({ allowance: 0n }), T.redeem)({ shares: "1", skipLegs: ["USDC"] });
    expect(out.nextStep).toContain("Approve 1 IBSK");
    expect(out.plan).toMatchObject({ shares: "1", skippedLegs: ["USDC"] });
    const { tx } = decode(out);
    expect(tx.contractId!.toString()).toBe("0.0.10839906");
    expect(tx.gas!.toString()).toBe("1000000");
  });

  it("builds the redeem itself once the allowance covers it", async () => {
    const out = await tool(stubChain(), T.redeem)({ shares: "1", skipLegs: ["USDC"] });
    const { data } = decode(out);
    expect(data).toBe(encodeFunctionData({ abi: vaultAbi, functionName: "redeemExcept", args: [100_000_000n, 2n] }));
  });

  it("blocks when the account is not associated with a token it would receive, and says which", async () => {
    const out = await tool(stubChain({ associated: false }), T.redeem)({ shares: "1" });
    expect(out.raw).toMatchObject({ status: "ERROR", blocked: true });
    expect(out.raw.missingAssociations).toHaveLength(3);
    expect(out.raw.reasons[0]).toContain("USDC");
  });

  it("only checks WHBAR when every other leg is skipped", async () => {
    const out = await tool(stubChain({ associated: false }), T.redeem)({ shares: "1", skipLegs: [0, 1] });
    expect(out.raw.missingAssociations).toEqual(["0x0000000000000000000000000000000000003aD2"]);
  });

  it("redeems the whole balance for all, and refuses more than the balance", async () => {
    const all = await tool(stubChain({ shares: 250_000_000n }), T.redeem)({ shares: "all" });
    expect(all.plan.shares).toBe("2.5");
    const over = await tool(stubChain({ shares: 250_000_000n }), T.redeem)({ shares: "2.5000001" });
    expect(over.raw.reasons[0]).toContain("less than");
    expect((await tool(stubChain({ shares: 0n }), T.redeem)({ shares: "all" })).raw.blocked).toBe(true);
  });

  it("refuses to skip WHBAR or an unknown leg", async () => {
    const out = await tool(stubChain(), T.redeem)({ shares: "1", skipLegs: ["WHBAR"] });
    expect(out.raw.reasons[0]).toContain("basket legs are 0=SAUCE, 1=USDC");
  });
});

describe("book_next_run", () => {
  const orphaned = (over = {}) => state({ pendingSchedule: "0x0000000000000000000000000000000000000000", nextRunAt: 0n, ...over });

  it("does nothing while a run is booked", async () => {
    const out = await tool(stubChain(), T.book)({});
    expect(out.raw).toMatchObject({ status: "SUCCESS", noop: true });
    expect(out.raw.reason).toContain("RunAlreadyPending");
  });

  it("does nothing while automation is off", async () => {
    const out = await tool(stubChain({ state: state({ interval: 0n, pendingSchedule: "0x0000000000000000000000000000000000000000" }) }), T.book)({});
    expect(out.raw).toMatchObject({ noop: true });
    expect(out.raw.reason).toContain("off");
  });

  it("builds rearm() when automation is on and nothing is pending", async () => {
    const out = await tool(stubChain({ state: orphaned() }), T.book)({});
    expect(decode(out).data).toBe(encodeFunctionData({ abi: vaultAbi, functionName: "rearm" }));
  });

  it("blocks when the vault's fuel is below the gas reservation", async () => {
    const out = await tool(stubChain({ state: orphaned({ fuelWeibar: 10n ** 18n }) }), T.book)({});
    expect(out.raw).toMatchObject({ status: "ERROR", blocked: true });
    expect(out.raw.reasons[0]).toContain("gas reservation");
  });
});

describe("rebalance_now", () => {
  it("is owner only: a stranger is blocked before anything is built", async () => {
    const out = await tool(stubChain({ evm: STRANGER, state: drifted() }), T.rebalance)({});
    expect(out.bytes).toBeUndefined();
    expect(out.raw).toMatchObject({ status: "ERROR", blocked: true, owner: OWNER });
    expect(out.raw.reasons[0]).toContain("Only the vault owner");
  });

  it("builds rebalance() for the owner when a leg is outside the band", async () => {
    const out = await tool(stubChain({ state: drifted() }), T.rebalance)({});
    expect(decode(out).data).toBe(encodeFunctionData({ abi: vaultAbi, functionName: "rebalance" }));
    expect(out.plan.weightsBefore.some((w: { outsideBand: boolean }) => w.outsideBand)).toBe(true);
  });

  it("skips a rebalance nothing needs, unless forced", async () => {
    const quiet = await tool(stubChain(), T.rebalance)({});
    expect(quiet.raw).toMatchObject({ status: "SUCCESS", noop: true });
    expect((await tool(stubChain(), T.rebalance)({ force: true })).bytes).toBeDefined();
  });

  it("blocks against a stale oracle", async () => {
    const out = await tool(stubChain({ state: state({ oracle: { fresh: false, reason: "BadOraclePrice" } }) }), T.rebalance)({ force: true });
    expect(out.raw.blocked).toBe(true);
  });
});
