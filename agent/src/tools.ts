import {
  BaseQueryTool,
  BaseTransactionTool,
  type Context,
  type RawTransactionResponse,
  handleTransaction,
  isReturnBytesMode,
  transactionToolOutputParser,
  untypedQueryOutputParser,
} from "@hashgraph/hedera-agent-kit";
import type { Client, Transaction } from "@hiero-ledger/sdk";
import { type Address, encodeFunctionData } from "viem";
import type { z } from "zod";
import { vaultAbi, erc20Abi } from "./abi";
import { resolveSkipMask } from "./analysis";
import { type ChainReader, decodeRevert, vaultEvents } from "./chain";
import { linkBuilder, mirrorTxId } from "./links";
import {
  bookNextRunSchema,
  depositHbarSchema,
  getBasketStateSchema,
  previewDepositSchema,
  rebalanceNowSchema,
  redeemSharesSchema,
} from "./schemas";
import { describeState, shapeState } from "./shape";
import { GAS, contractCall, defaultAccount, requireOperator } from "./tx";
import { WEIBAR_PER_TINYBAR, applySlippage, estimateShares, fmt8, parseAmount } from "./units";
import { formatDecimals } from "./analysis";

export const TOOL_NAMES = {
  state: "get_basket_state",
  preview: "preview_deposit",
  deposit: "deposit_hbar",
  redeem: "redeem_shares",
  book: "book_next_run",
  rebalance: "rebalance_now",
} as const;

type Envelope = { raw: Record<string, unknown>; humanMessage: string };
/** A write tool's plan: the transaction to send, an optional approval to send first, and how to prove it worked. */
type TxPlan = {
  tx: Transaction;
  summary: Record<string, unknown>;
  pre?: { tx: Transaction; label: string; verify: () => Promise<void> };
  finish: (txId: string) => Promise<Envelope>;
};
const isPlan = (r: Envelope | TxPlan): r is TxPlan => "tx" in r;

const ok = (raw: Record<string, unknown>, humanMessage: string): Envelope => ({ raw: { status: "SUCCESS", ...raw }, humanMessage });
/** A refused write: nothing was sent. status is ERROR so callers classify it as a failure, `blocked` says why. */
const blocked = (reasons: string[], raw: Record<string, unknown> = {}): Envelope => ({
  raw: { status: "ERROR", blocked: true, reasons, ...raw },
  humanMessage: `Not sent: ${reasons.join(" ")}`,
});
const noop = (reason: string, raw: Record<string, unknown> = {}): Envelope => ({ raw: { status: "SUCCESS", noop: true, reason, ...raw }, humanMessage: reason });

abstract class VaultQueryTool extends BaseQueryTool {
  outputParser = untypedQueryOutputParser;
  constructor(protected readonly chain: ChainReader) {
    super();
  }
  async shouldSecondaryAction() {
    return false;
  }
}

abstract class VaultTxTool extends BaseTransactionTool {
  outputParser = transactionToolOutputParser;
  constructor(protected readonly chain: ChainReader) {
    super();
  }
  protected get links() {
    return linkBuilder(this.chain.cfg.hashscanUrl);
  }
  async shouldSecondaryAction(result: Envelope | TxPlan) {
    return isPlan(result);
  }

  async secondaryAction(plan: TxPlan, client: Client, context: Context) {
    const bytesMode = isReturnBytesMode(context.mode);
    if (plan.pre) {
      const pre = await handleTransaction(plan.pre.tx, client, context);
      if (bytesMode) {
        return { ...(pre as object), plan: plan.summary, nextStep: `${plan.pre.label} first. Sign and submit these bytes, then call ${this.method} again for the transaction itself.` };
      }
      const preRaw = (pre as { raw: RawTransactionResponse }).raw;
      await this.chain.waitForResult(mirrorTxId(preRaw.transactionId));
      await plan.pre.verify();
    }
    const res = await handleTransaction(plan.tx, client, context);
    if (bytesMode) return { ...(res as object), plan: plan.summary };
    const done = await plan.finish((res as { raw: RawTransactionResponse }).raw.transactionId);
    return done;
  }

  /** A failed receipt carries only a status code. Read the mirror node for the vault's own revert reason. */
  async handleError(error: unknown, context: Context) {
    const base = await super.handleError(error, context);
    const txId = base?.raw?.transactionId;
    if (!txId || base.raw.errorCode === undefined) return base;
    try {
      const result = await this.chain.waitForResult(mirrorTxId(txId));
      const revert = decodeRevert(result.error_message);
      const raw = { ...base.raw, links: { tx: this.links.tx(txId) }, ...(revert ? { revert } : {}), mirrorResult: result.result };
      return { raw, humanMessage: `${base.humanMessage}${revert ? ` Vault revert: ${revert.name}(${revert.args.join(", ")}).` : ""} ${this.links.tx(txId)}` };
    } catch (lookup) {
      return { ...base, raw: { ...base.raw, links: { tx: this.links.tx(txId) }, revertLookupError: String(lookup) } };
    }
  }
}

// ------------------------------------------------------------------ get_basket_state

export class GetBasketState extends VaultQueryTool {
  method = TOOL_NAMES.state;
  name = "Get basket state";
  description = `Read the Index Basket fund from the chain: NAV in HBAR and USD, share price, each leg's weight against its target and its drift, whether a rebalance is due, the next scheduled run, and how many runs the vault's fuel covers. Optionally includes one account's share position. Read-only, no signature needed.`;
  parameters = getBasketStateSchema;

  async normalizeParams(params: unknown, _c: Context, _cl: Client) {
    return getBasketStateSchema.parse(params);
  }

  async coreAction(p: z.infer<typeof getBasketStateSchema>, context: Context, client: Client): Promise<Envelope> {
    const raw = await this.chain.readState();
    const state = shapeState(raw, this.chain.cfg);
    const who = p.account ?? defaultAccount(client, context);
    let position: Record<string, unknown> | null = null;
    if (who) {
      const acct = await this.chain.account(who);
      const shares = await this.chain.balanceOf(raw.shareToken, acct.evmAddress);
      const valueWhbar = raw.supply === 0n ? 0n : (shares * raw.nav) / raw.supply;
      position = {
        account: acct.accountId,
        evmAddress: acct.evmAddress,
        shares: fmt8(shares),
        valueHbar: fmt8(valueWhbar),
        valueUsd: raw.oracle.fresh ? fmt8((valueWhbar * raw.oracle.hbarUsd) / 10n ** 8n) : null,
        ofFundPercent: raw.supply === 0n ? "0" : ((Number((shares * 1_000_000n) / raw.supply)) / 10_000).toString(),
      };
    }
    return ok({ ...state, position }, describeState(state) + (position ? `\nPosition of ${position.account}: ${position.shares} ${state.share.symbol} worth ${position.valueHbar} HBAR.` : ""));
  }
}

// ------------------------------------------------------------------ preview_deposit

export class PreviewDeposit extends VaultQueryTool {
  method = TOOL_NAMES.preview;
  name = "Preview deposit";
  description = `Estimate what an HBAR deposit into the Index Basket would mint right now, before sending anything. Returns the share estimate (value x supply / NAV), the shares an eth_call of the real deposit returns when the account can make it, the minShares floor for the chosen slippage, the USD value, and anything that would block the deposit (stale oracle, share token not associated). Read-only.`;
  parameters = previewDepositSchema;

  async normalizeParams(params: unknown, _c: Context, _cl: Client) {
    return previewDepositSchema.parse(params);
  }

  async coreAction(p: z.infer<typeof previewDepositSchema>, context: Context, client: Client): Promise<Envelope> {
    const tiny = parseAmount(p.hbar, "hbar");
    const s = await this.chain.readState();
    const blockers: string[] = [];
    if (!s.oracle.fresh) blockers.push(`Chainlink HBAR/USD is stale (${s.oracle.reason}); deposits revert until it updates.`);
    const estimate = estimateShares(tiny, s.supply, s.nav, s.deadShares);
    if (estimate === null) blockers.push("The fund's NAV reads zero, so shares cannot be priced.");
    if (estimate === 0n) blockers.push("That amount does not cover the dead shares the first deposit locks in.");

    const who = p.account ?? defaultAccount(client, context);
    let simulated: bigint | null = null;
    let account: { accountId: string; evmAddress: Address } | null = null;
    if (who) {
      account = await this.chain.account(who);
      const assoc = (await this.chain.associations(account.accountId, [s.shareToken]))[s.shareToken.toLowerCase()];
      if (assoc === "needs") blockers.push(`${account.accountId} is not associated with ${s.shareSymbol} (${s.shareToken}). Associate it first, for example with the Agent Kit associate_token_tool.`);
      else if (blockers.length === 0) simulated = await this.chain.simulateDeposit(account.evmAddress, tiny);
    }
    const basis = simulated ?? estimate;
    const minShares = basis === null ? null : applySlippage(basis, p.slippageBps);
    const costBps = simulated !== null && estimate && estimate > 0n ? Number(((estimate - simulated) * 10_000n) / estimate) : null;
    const usd = s.oracle.fresh ? fmt8((tiny * s.oracle.hbarUsd) / 10n ** 8n) : null;
    const raw = {
      hbar: p.hbar,
      account: account?.accountId ?? null,
      estimatedShares: estimate === null ? null : fmt8(estimate),
      simulatedShares: simulated === null ? null : fmt8(simulated),
      minShares: minShares === null ? null : fmt8(minShares),
      minSharesBasis: simulated !== null ? "eth_call of deposit" : "value x supply / NAV (before pool fees and price impact)",
      slippageBps: p.slippageBps,
      priceImpactAndFeesBps: costBps,
      valueUsd: usd,
      shareSymbol: s.shareSymbol,
      canDeposit: blockers.length === 0,
      blockers,
      links: { vault: linkBuilder(this.chain.cfg.hashscanUrl).contract(s.vault) },
    };
    const msg = blockers.length
      ? `Depositing ${p.hbar} HBAR would be refused: ${blockers.join(" ")}`
      : `${p.hbar} HBAR${usd ? ` ($${usd})` : ""} mints about ${fmt8(basis ?? 0n)} ${s.shareSymbol}${simulated === null ? " (estimate)" : " (simulated)"}; floor ${fmt8(minShares ?? 0n)} at ${p.slippageBps} bps slippage.`;
    return ok(raw, msg);
  }
}

// ------------------------------------------------------------------ deposit_hbar

export class DepositHbar extends VaultTxTool {
  method = TOOL_NAMES.deposit;
  name = "Deposit HBAR";
  description = `Deposit HBAR into the Index Basket from the agent's account. One transaction buys the weighted basket on SaucerSwap V2 and mints share tokens to the account. The tool computes minShares from the current estimate and slippageBps, checks the share token is associated and the balance covers the amount plus the gas reservation, then verifies the Deposited event and the new share balance. Moves real funds.`;
  parameters = depositHbarSchema;

  async normalizeParams(params: unknown, _c: Context, _cl: Client) {
    return depositHbarSchema.parse(params);
  }

  async coreAction(p: z.infer<typeof depositHbarSchema>, context: Context, client: Client): Promise<Envelope | TxPlan> {
    const tiny = parseAmount(p.hbar, "hbar");
    const op = await requireOperator(this.chain, client, context);
    const s = await this.chain.readState();
    const reasons: string[] = [];
    if (!s.oracle.fresh) reasons.push(`Chainlink HBAR/USD is stale (${s.oracle.reason}), so the vault would revert.`);
    const assoc = (await this.chain.associations(op.accountId, [s.shareToken]))[s.shareToken.toLowerCase()];
    if (assoc === "needs") reasons.push(`${op.accountId} is not associated with ${s.shareSymbol} (${s.shareToken}). Associate it first, for example with the Agent Kit associate_token_tool.`);
    const need = tiny * WEIBAR_PER_TINYBAR + BigInt(GAS.deposit) * s.gasPriceWeibar;
    const have = await this.chain.hbarBalance(op.evmAddress);
    if (have < need) reasons.push(`${op.accountId} holds ${fmt8(have / WEIBAR_PER_TINYBAR)} HBAR; the deposit plus the gas reservation needs ${fmt8(need / WEIBAR_PER_TINYBAR)}.`);
    if (reasons.length) return blocked(reasons, { account: op.accountId });

    const estimate = estimateShares(tiny, s.supply, s.nav, s.deadShares);
    if (!estimate) return blocked(["The fund cannot price shares for this amount."], { account: op.accountId });
    const simulated = await this.chain.simulateDeposit(op.evmAddress, tiny);
    const minShares = applySlippage(simulated ?? estimate, p.slippageBps);
    const data = encodeFunctionData({ abi: vaultAbi, functionName: "deposit", args: [minShares] });
    const before = await this.chain.balanceOf(s.shareToken, op.evmAddress);
    const L = this.links;
    return {
      tx: contractCall(s.vault, data, GAS.deposit, tiny),
      summary: { account: op.accountId, hbar: p.hbar, minShares: fmt8(minShares), estimatedShares: fmt8(estimate), simulatedShares: simulated === null ? null : fmt8(simulated) },
      finish: async (txId) => {
        const result = await this.chain.waitForResult(mirrorTxId(txId));
        if (result.result !== "SUCCESS") throw new Error(`Mirror node reports ${result.result} for ${txId}`);
        const dep = vaultEvents(result, s.vault).find((e) => e.name === "Deposited");
        if (!dep) throw new Error(`Transaction ${txId} succeeded but the vault emitted no Deposited event.`);
        const minted = dep.args.shares as bigint;
        const after = await this.chain.balanceOf(s.shareToken, op.evmAddress);
        if (after - before !== minted) throw new Error(`Deposited says ${minted} shares but the balance moved by ${after - before}.`);
        return ok(
          {
            transactionId: txId,
            hash: result.hash,
            account: op.accountId,
            hbarIn: fmt8(dep.args.hbarIn as bigint),
            valueAdded: fmt8(dep.args.valueAdded as bigint),
            sharesReceived: fmt8(minted),
            minShares: fmt8(minShares),
            shareBalanceBefore: fmt8(before),
            shareBalanceAfter: fmt8(after),
            gasUsed: result.gas_used,
            links: { tx: L.tx(txId), shareToken: L.token(s.shareToken), vault: L.contract(s.vault) },
          },
          `Deposited ${p.hbar} HBAR and received ${fmt8(minted)} ${s.shareSymbol}. ${L.tx(txId)}`,
        );
      },
    };
  }
}

// ------------------------------------------------------------------ redeem_shares

export class RedeemShares extends VaultTxTool {
  method = TOOL_NAMES.redeem;
  name = "Redeem shares";
  description = `Redeem Index Basket shares in kind: burns the shares and pays the same fraction of WHBAR and every basket token to the agent's account, with no price read. skipLegs leaves out legs whose issuer froze the vault or the account (the skipped slice stays in the vault). Checks the account is associated with every token it will receive, approves the shares to the vault when the allowance is short, then verifies the Redeemed event. Moves real funds.`;
  parameters = redeemSharesSchema;

  async normalizeParams(params: unknown, _c: Context, _cl: Client) {
    return redeemSharesSchema.parse(params);
  }

  async coreAction(p: z.infer<typeof redeemSharesSchema>, context: Context, client: Client): Promise<Envelope | TxPlan> {
    const op = await requireOperator(this.chain, client, context);
    const s = await this.chain.readState();
    const legSymbols = s.legs.map((l) => s.symbols[l.token.toLowerCase()] ?? l.token);
    let skip;
    try {
      skip = resolveSkipMask(p.skipLegs, legSymbols);
    } catch (e) {
      return blocked([(e as Error).message]);
    }
    const balance = await this.chain.balanceOf(s.shareToken, op.evmAddress);
    const shares = p.shares === "all" ? balance : parseAmount(p.shares, "shares");
    if (shares === 0n) return blocked([`${op.accountId} holds no ${s.shareSymbol}.`]);
    if (shares > balance) return blocked([`${op.accountId} holds ${fmt8(balance)} ${s.shareSymbol}, less than the ${fmt8(shares)} requested.`]);

    const whbar = s.holdings[0]!.token;
    const receiving = [whbar, ...s.legs.filter((_, i) => !(skip.mask & (1n << BigInt(i)))).map((l) => l.token)];
    const assoc = await this.chain.associations(op.accountId, receiving);
    const missing = receiving.filter((t) => assoc[t.toLowerCase()] === "needs");
    if (missing.length)
      return blocked(
        [`${op.accountId} is not associated with ${missing.map((t) => `${s.symbols[t.toLowerCase()]} (${t})`).join(", ")}, so those transfers would fail and revert the whole payout. Associate them first (Agent Kit associate_token_tool), or pass them in skipLegs.`],
        { missingAssociations: missing },
      );

    const expected = receiving.map((t) => {
      const h = s.holdings.find((x) => x.token.toLowerCase() === t.toLowerCase())!;
      return { symbol: s.symbols[t.toLowerCase()], amount: formatDecimals((h.balance * shares) / s.supply, s.decimals[t.toLowerCase()] ?? 8) };
    });
    const allowance = await this.chain.allowance(s.shareToken, op.evmAddress, s.vault);
    const L = this.links;
    const data = encodeFunctionData({ abi: vaultAbi, functionName: "redeemExcept", args: [shares, skip.mask] });
    const supplyBefore = s.supply;
    return {
      tx: contractCall(s.vault, data, GAS.redeem),
      summary: { account: op.accountId, shares: fmt8(shares), skippedLegs: skip.skipped, expectedPayout: expected },
      pre:
        allowance >= shares
          ? undefined
          : {
              tx: contractCall(s.shareToken, encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: [s.vault, shares] }), GAS.approve),
              label: `Approve ${fmt8(shares)} ${s.shareSymbol} to the vault`,
              verify: async () => {
                const now = await this.chain.allowance(s.shareToken, op.evmAddress, s.vault);
                if (now < shares) throw new Error(`The approval went through but the allowance reads ${now}, below ${shares}.`);
              },
            },
      finish: async (txId) => {
        const result = await this.chain.waitForResult(mirrorTxId(txId));
        if (result.result !== "SUCCESS") throw new Error(`Mirror node reports ${result.result} for ${txId}`);
        const ev = vaultEvents(result, s.vault);
        const red = ev.find((e) => e.name === "Redeemed");
        if (!red) throw new Error(`Transaction ${txId} succeeded but the vault emitted no Redeemed event.`);
        const burned = red.args.shares as bigint;
        const legAmounts = red.args.legAmounts as bigint[];
        const paid = [
          { symbol: s.symbols[whbar.toLowerCase()], amount: formatDecimals(red.args.whbarOut as bigint, 8) },
          ...s.legs.map((l, i) => ({ symbol: legSymbols[i], amount: formatDecimals(legAmounts[i] ?? 0n, s.decimals[l.token.toLowerCase()] ?? 8), skipped: !!(skip.mask & (1n << BigInt(i))) })),
        ];
        const after = await this.chain.balanceOf(s.shareToken, op.evmAddress);
        if (balance - after !== burned) throw new Error(`Redeemed says ${burned} shares burned but the balance moved by ${balance - after}.`);
        return ok(
          { transactionId: txId, hash: result.hash, account: op.accountId, sharesBurned: fmt8(burned), shareBalanceAfter: fmt8(after), supplyBefore: fmt8(supplyBefore), paid, skippedLegs: skip.skipped, gasUsed: result.gas_used, links: { tx: L.tx(txId), vault: L.contract(s.vault) } },
          `Redeemed ${fmt8(burned)} ${s.shareSymbol} for ${paid.filter((x) => !("skipped" in x && x.skipped)).map((x) => `${x.amount} ${x.symbol}`).join(", ")}. ${L.tx(txId)}`,
        );
      },
    };
  }
}

// ------------------------------------------------------------------ book_next_run

export class BookNextRun extends VaultTxTool {
  method = TOOL_NAMES.book;
  name = "Book next run";
  description = `Rearm the Index Basket automation. When automation is on but no run is pending (a lost booking leaves exactly that), anyone may call rearm() and the vault's fuel pays for booking the next scheduled rebalance with the Hedera Schedule Service. Does nothing when automation is off or a run is already booked. Verifies a pending schedule and nextRunAt exist afterwards.`;
  parameters = bookNextRunSchema;

  async normalizeParams(params: unknown, _c: Context, _cl: Client) {
    return bookNextRunSchema.parse(params);
  }

  async coreAction(_p: unknown, context: Context, client: Client): Promise<Envelope | TxPlan> {
    await requireOperator(this.chain, client, context);
    const s = await this.chain.readState();
    const state = shapeState(s, this.chain.cfg);
    const a = state.automation;
    if (a.status === "off") return noop("Automation is off, so there is nothing to rearm. The owner starts it with startAutomation(interval).", { automation: a });
    if (a.status !== "orphaned") return noop(`A run is already booked${a.nextRunAt ? ` for ${new Date(a.nextRunAt * 1000).toISOString()}` : ""}; rearm() would revert with RunAlreadyPending.`, { automation: a, links: state.links });
    if (state.fuel.runsCovered === 0) return blocked([`The vault's fuel (${state.fuel.fuelHbar} HBAR) is below the ${state.fuel.reservationHbar} HBAR gas reservation a booking needs. Send native HBAR to ${s.vault} first.`], { fuel: state.fuel });
    const L = this.links;
    return {
      tx: contractCall(s.vault, encodeFunctionData({ abi: vaultAbi, functionName: "rearm" }), GAS.rearm),
      summary: { fuel: state.fuel },
      finish: async (txId) => {
        const result = await this.chain.waitForResult(mirrorTxId(txId));
        if (result.result !== "SUCCESS") throw new Error(`Mirror node reports ${result.result} for ${txId}`);
        const booking = await this.chain.readBooking();
        if (/^0x0{40}$/i.test(booking.pendingSchedule) || booking.nextRunAt === 0n) throw new Error(`rearm() returned but the vault shows no pending schedule.`);
        return ok(
          { transactionId: txId, hash: result.hash, pendingSchedule: booking.pendingSchedule, nextRunAt: Number(booking.nextRunAt), nextRunAtIso: new Date(Number(booking.nextRunAt) * 1000).toISOString(), links: { tx: L.tx(txId), schedule: L.schedule(booking.pendingSchedule), vault: L.contract(s.vault) } },
          `Booked the next run for ${new Date(Number(booking.nextRunAt) * 1000).toISOString()}. ${L.tx(txId)}`,
        );
      },
    };
  }
}

// ------------------------------------------------------------------ rebalance_now

export class RebalanceNow extends VaultTxTool {
  method = TOOL_NAMES.rebalance;
  name = "Rebalance now";
  description = `Owner only. Trade every leg that is outside the drift band back toward its target weight, now, instead of waiting for the scheduled run. The contract refuses any other caller (OnlyOwnerOrSelf), and this tool checks the agent's account is the owner before sending. Skips the call when nothing is outside the band unless force is true. Verifies the Rebalanced event.`;
  parameters = rebalanceNowSchema;

  async normalizeParams(params: unknown, _c: Context, _cl: Client) {
    return rebalanceNowSchema.parse(params);
  }

  async coreAction(p: z.infer<typeof rebalanceNowSchema>, context: Context, client: Client): Promise<Envelope | TxPlan> {
    const op = await requireOperator(this.chain, client, context);
    const s = await this.chain.readState();
    if (op.evmAddress.toLowerCase() !== s.owner.toLowerCase())
      return blocked([`Only the vault owner (${s.owner}) can rebalance on demand; ${op.accountId} is ${op.evmAddress}. The scheduled run rebalances without the owner.`], { owner: s.owner });
    if (!s.oracle.fresh) return blocked([`Chainlink HBAR/USD is stale (${s.oracle.reason}), so the vault would revert.`]);
    const state = shapeState(s, this.chain.cfg);
    if (!state.needsRebalance && !p.force)
      return noop(`Every leg is inside the ${state.driftBandBps} bps drift band; a rebalance would trade nothing. Pass force: true to send it anyway.`, { weights: state.weights });
    const L = this.links;
    return {
      tx: contractCall(s.vault, encodeFunctionData({ abi: vaultAbi, functionName: "rebalance" }), GAS.rebalance),
      summary: { weightsBefore: state.weights },
      finish: async (txId) => {
        const result = await this.chain.waitForResult(mirrorTxId(txId));
        if (result.result !== "SUCCESS") throw new Error(`Mirror node reports ${result.result} for ${txId}`);
        const ev = vaultEvents(result, s.vault).find((e) => e.name === "Rebalanced");
        if (!ev) throw new Error(`Transaction ${txId} succeeded but the vault emitted no Rebalanced event.`);
        const after = shapeState(await this.chain.readState(), this.chain.cfg);
        const traded = ev.args.traded as boolean;
        return ok(
          { transactionId: txId, hash: result.hash, traded, navBeforeHbar: fmt8(ev.args.navBefore as bigint), navAfterHbar: fmt8(ev.args.navAfter as bigint), weightsAfter: after.weights, needsRebalanceAfter: after.needsRebalance, gasUsed: result.gas_used, links: { tx: L.tx(txId), vault: L.contract(s.vault) } },
          `Rebalanced: ${traded ? "traded" : "nothing to trade"}, NAV ${fmt8(ev.args.navBefore as bigint)} to ${fmt8(ev.args.navAfter as bigint)} HBAR. ${L.tx(txId)}`,
        );
      },
    };
  }
}

