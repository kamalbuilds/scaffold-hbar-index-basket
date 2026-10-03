import { type Hex, decodeErrorResult } from "viem";
import { useNow } from "~~/hooks/basket/useNow";
import type { Snapshot } from "~~/hooks/basket/useVault";
import { useVaultEvents } from "~~/hooks/basket/useVaultEvents";
import { SHARE_DECIMALS, VAULT_ABI, WHBAR_DECIMALS } from "~~/utils/basket/constants";
import { fmtAgo, fmtDuration, fmtUnits, shortAddress } from "~~/utils/basket/format";
import { evmToEntityId, hashscan } from "~~/utils/basket/hedera";
import type { VaultEvent } from "~~/utils/basket/mirror";

type Args = Record<string, any>;

const FAILURES = new Set(["ScheduledRunFailed", "BookingFailed"]);

function revertText(reason: Hex): string {
  try {
    return decodeErrorResult({ abi: VAULT_ABI, data: reason }).errorName;
  } catch {
    return reason.length > 10 ? `${reason.slice(0, 10)}…` : "no revert data";
  }
}

function describe(ev: VaultEvent, snap: Snapshot): React.ReactNode {
  const a = ev.args as Args;
  const { tokens } = snap.cfg;
  const share = snap.cfg.shareSymbol ?? "shares";
  const bySymbol = new Map(tokens.map(t => [t.address.toLowerCase(), t]));
  const tok = (address: string, amount: bigint) => {
    const t = bySymbol.get(address.toLowerCase());
    return t ? `${fmtUnits(amount, t.decimals, 4)} ${t.symbol}` : `${amount} of ${shortAddress(address)}`;
  };

  switch (ev.name) {
    case "Deposited":
      return `${shortAddress(a.account)} deposited ${fmtUnits(a.hbarIn, 8, 4)} HBAR and received ${fmtUnits(a.shares, SHARE_DECIMALS, 4)} ${share}`;
    case "Redeemed": {
      const parts = [
        `${fmtUnits(a.whbarOut, WHBAR_DECIMALS, 4)} ${tokens[0]?.symbol ?? "WHBAR"}`,
        ...(a.legAmounts as bigint[]).map((amount, i) =>
          tokens[i + 1] ? `${fmtUnits(amount, tokens[i + 1].decimals, 4)} ${tokens[i + 1].symbol}` : `${amount}`,
        ),
      ];
      return `${shortAddress(a.account)} redeemed ${fmtUnits(a.shares, SHARE_DECIMALS, 4)} ${share} for ${parts.join(", ")}`;
    }
    case "Swapped":
      return `Swapped ${tok(a.tokenIn, a.amountIn)} for ${tok(a.tokenOut, a.amountOut)}`;
    case "Rebalanced":
      return `NAV ${fmtUnits(a.navBefore, WHBAR_DECIMALS, 4)} to ${fmtUnits(a.navAfter, WHBAR_DECIMALS, 4)} HBAR. ${a.traded ? "Traded back to target." : "Nothing had drifted past the band."}`;
    case "RunBooked":
      return (
        <>
          Booked the next rebalance for {new Date(Number(a.expiry) * 1000).toLocaleString()} on schedule{" "}
          <a className="link link-primary" href={hashscan.schedule(a.schedule)} target="_blank" rel="noreferrer">
            {evmToEntityId(a.schedule)}
          </a>
        </>
      );
    case "ScheduledRun":
      return a.traded
        ? "Scheduled rebalance ran and traded."
        : "Scheduled rebalance ran. Nothing had drifted past the band.";
    case "ScheduledRunFailed":
      return `Scheduled rebalance failed: ${revertText(a.reason)}. The next run is still booked.`;
    case "BookingFailed":
      return `Booking the next run failed with Hedera response code ${a.responseCode}.`;
    case "AutomationStarted":
      return `Automation started, one rebalance every ${fmtDuration(Number(a.interval))}.`;
    case "AutomationStopped":
      return "Automation stopped and the pending schedule was deleted.";
    case "Initialized":
      return "Share token created.";
    default:
      return ev.name;
  }
}

export function ActivityFeed({ snap }: { snap: Snapshot }) {
  const events = useVaultEvents();
  const now = useNow(10_000);

  return (
    <section className="rounded-box border border-base-300 bg-base-100 p-6 lg:p-8" aria-labelledby="activity-title">
      <div className="flex items-baseline justify-between gap-4">
        <h2 id="activity-title" className="m-0 text-xl font-semibold">
          Activity
        </h2>
        <span className="text-xs text-base-content/60">Decoded from the Hedera mirror node, refreshed every 15s</span>
      </div>

      {events.isLoading && <p className="m-0 mt-6 text-sm text-base-content/60">Reading the vault logs.</p>}
      {events.isError && (
        <p className="m-0 mt-6 text-sm text-error" role="alert">
          The mirror node did not answer.{" "}
          <button type="button" className="link" onClick={() => events.refetch()}>
            Retry
          </button>
        </p>
      )}
      {events.data && events.data.length === 0 && (
        <p className="m-0 mt-6 text-sm text-base-content/70">
          No deposits yet. The first deposit sets the share price at 1 share per HBAR of value.
        </p>
      )}
      {events.data && events.data.length > 0 && (
        <ul className="m-0 mt-4 list-none divide-y divide-base-300 p-0">
          {events.data.map(ev => (
            <li
              key={ev.id}
              className="flex flex-col gap-1 py-3 sm:grid sm:grid-cols-[6rem_11rem_1fr_auto] sm:items-baseline sm:gap-x-4"
            >
              <time
                className="font-mono text-xs tabular-nums text-base-content/60"
                dateTime={new Date(ev.at * 1000).toISOString()}
                title={new Date(ev.at * 1000).toLocaleString()}
              >
                {now === null ? "" : fmtAgo(Math.max(0, now - ev.at))}
              </time>
              <span className={`font-mono text-xs ${FAILURES.has(ev.name) ? "text-error" : "text-base-content/70"}`}>
                {ev.name}
              </span>
              <span className={`text-sm ${FAILURES.has(ev.name) ? "text-error" : ""}`}>{describe(ev, snap)}</span>
              <a className="link link-primary text-xs" href={hashscan.tx(ev.hash)} target="_blank" rel="noreferrer">
                HashScan
              </a>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
