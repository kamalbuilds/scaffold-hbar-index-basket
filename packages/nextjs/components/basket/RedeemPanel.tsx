import { useState } from "react";
import { AssociationWarning } from "./AssociationWarning";
import { type PlannedStep, TxSteps } from "./TxSteps";
import { WalletGate } from "./WalletGate";
import { formatUnits } from "viem";
import { useAssociations } from "~~/hooks/basket/useAssociations";
import { type RunnableStep, useTx, useWalletReady } from "~~/hooks/basket/useTx";
import type { Snapshot } from "~~/hooks/basket/useVault";
import { ERC20_ABI, GAS_FLOOR, SHARE_DECIMALS, VAULT_ABI, VAULT_ADDRESS } from "~~/utils/basket/constants";
import { fmtUnits, fmtUsd, parseAmount } from "~~/utils/basket/format";

export function RedeemPanel({ snap }: { snap: Snapshot }) {
  const { vault, cfg, lv } = snap;
  const ready = useWalletReady();
  const tx = useTx();
  const [input, setInput] = useState("");
  const associations = useAssociations(
    ready.address,
    cfg.tokens.map(t => t.address),
  );

  const balance = vault.shares.data?.balance;
  const allowance = vault.shares.data?.allowance;
  const shares = parseAmount(input, SHARE_DECIMALS);
  const valid = shares !== null && shares > 0n && balance !== undefined && shares <= balance;

  // In-kind payout: the same fraction of every token the vault holds as the fraction of supply being burned.
  const payout =
    shares !== null && lv.supply > 0n
      ? lv.holdings.map((h, i) => ({ token: cfg.tokens[i], amount: (h.balance * shares) / lv.supply }))
      : null;
  const payoutWhbar =
    shares !== null && lv.supply > 0n
      ? lv.holdings.reduce((sum, h) => sum + (h.valueWhbar * shares) / lv.supply, 0n)
      : null;
  const payoutUsd =
    payoutWhbar !== null && lv.hbarUsd !== undefined ? (payoutWhbar * lv.hbarUsd) / 10n ** 8n : undefined;

  const unknown = associations.find(a => a.state.kind === "unknown");
  const allKnown = associations.every(a => ["associated", "auto", "needs"].includes(a.state.kind));
  const needsApprove = valid && (allowance === undefined || allowance < shares);

  const problem = (() => {
    if (!cfg.shareToken) return "The vault has not created its share token yet.";
    if (input && shares === null) return `Enter a share amount with at most ${SHARE_DECIMALS} decimals.`;
    if (shares !== null && shares > 0n && balance !== undefined && shares > balance)
      return "That is more shares than you hold.";
    return null;
  })();

  const steps: PlannedStep[] = [
    ...associations.map((a, i) => ({
      id: `assoc-${i}`,
      label: `Associate ${cfg.tokens[i].symbol} with your account`,
      hint: "Redemption pays this token out to you, so your account must be associated with it.",
      needed: a.state.kind === "needs",
    })),
    {
      id: "approve",
      label: `Let the vault take ${cfg.shareSymbol ?? "your shares"}`,
      hint: "An approval for exactly the shares you redeem.",
      needed: needsApprove,
    },
    {
      id: "redeem",
      label: shares ? `Redeem ${input} ${cfg.shareSymbol ?? "shares"}` : "Redeem shares",
      hint: "Burns the shares and sends you your slice of every token.",
      needed: true,
    },
  ];

  const canSend = valid && !problem && allKnown && !tx.running && !!cfg.shareToken;

  const submit = async () => {
    if (!canSend || !cfg.shareToken || shares === null) return;
    const queue: RunnableStep[] = [];
    associations.forEach((a, i) => {
      if (a.state.kind === "needs") queue.push(tx.associateStep(a.token, `assoc-${i}`));
    });
    if (needsApprove) {
      queue.push({
        id: "approve",
        send: () =>
          tx.call(
            { address: cfg.shareToken!, abi: ERC20_ABI, functionName: "approve", args: [VAULT_ADDRESS, shares] },
            GAS_FLOOR.approve,
          ),
      });
    }
    queue.push({
      id: "redeem",
      send: () =>
        tx.call({ address: VAULT_ADDRESS, abi: VAULT_ABI, functionName: "redeem", args: [shares] }, GAS_FLOOR.redeem),
    });
    if (await tx.run(queue)) setInput("");
  };

  return (
    <div className="flex flex-col gap-5">
      <label className="flex flex-col gap-2">
        <span className="flex items-baseline justify-between text-sm font-medium">
          Shares to redeem
          <span className="text-xs font-normal text-base-content/60">
            You hold{" "}
            <span className="font-mono tabular-nums">
              {balance !== undefined ? fmtUnits(balance, SHARE_DECIMALS, 4) : "n/a"}
            </span>
          </span>
        </span>
        <div className="join w-full">
          <input
            inputMode="decimal"
            className="input join-item w-full font-mono tabular-nums"
            placeholder="0.0"
            value={input}
            onChange={e => setInput(e.target.value)}
            aria-invalid={!!input && shares === null}
          />
          <button
            type="button"
            className="btn join-item"
            disabled={!balance}
            onClick={() => balance && setInput(formatUnits(balance, SHARE_DECIMALS))}
          >
            Max
          </button>
        </div>
      </label>

      <div>
        <p className="m-0 mb-2 text-sm font-medium">You receive, in kind</p>
        {payout && valid ? (
          <dl className="m-0 grid grid-cols-[1fr_auto] gap-x-4 gap-y-2 text-sm">
            {payout.map(p => (
              <div key={p.token.address} className="contents">
                <dt className="text-base-content/70">{p.token.symbol}</dt>
                <dd className="m-0 text-right font-mono tabular-nums">{fmtUnits(p.amount, p.token.decimals, 6)}</dd>
              </div>
            ))}
            <dt className="text-base-content/70">Worth about</dt>
            <dd className="m-0 text-right font-mono tabular-nums">
              {payoutUsd !== undefined ? fmtUsd(payoutUsd) : "n/a"}
            </dd>
          </dl>
        ) : (
          <p className="m-0 text-sm text-base-content/60">
            {lv.supply === 0n
              ? "Nothing to redeem yet. Shares exist after the first deposit."
              : "Enter a share amount to see how much of each token it pays out."}
          </p>
        )}
      </div>

      <p className="m-0 text-xs text-base-content/60">
        Redemption reads no price, so it works even while Chainlink is stale. The payout is each token as it stands in
        the vault when the transaction lands.
      </p>

      <AssociationWarning state={unknown?.state} />
      {problem && (
        <p className="m-0 text-sm text-error" role="alert">
          {problem}
        </p>
      )}

      <TxSteps steps={steps} runs={tx.runs} />

      <WalletGate ready={ready}>
        <button type="button" className="btn btn-primary w-full" disabled={!canSend} onClick={submit}>
          {tx.running ? "Working" : "Redeem"}
        </button>
      </WalletGate>
    </div>
  );
}
