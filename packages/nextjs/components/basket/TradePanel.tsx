import { useState } from "react";
import { DepositPanel } from "./DepositPanel";
import { RedeemPanel } from "./RedeemPanel";
import type { Snapshot } from "~~/hooks/basket/useVault";

export function TradePanel({ snap }: { snap: Snapshot }) {
  const [tab, setTab] = useState<"deposit" | "redeem">("deposit");
  return (
    <section className="panel p-6" aria-label="Deposit or redeem">
      <div role="tablist" className="mb-6 inline-flex gap-1 rounded-full bg-base-200 p-1">
        {(["deposit", "redeem"] as const).map(name => (
          <button
            key={name}
            role="tab"
            type="button"
            aria-selected={tab === name}
            className={`min-h-9 rounded-full px-4 text-sm font-medium capitalize transition-colors ${tab === name ? "bg-base-300 text-base-content" : "text-base-content/70 hover:text-base-content"}`}
            onClick={() => setTab(name)}
          >
            {name}
          </button>
        ))}
      </div>
      {tab === "deposit" ? <DepositPanel snap={snap} /> : <RedeemPanel snap={snap} />}
    </section>
  );
}
