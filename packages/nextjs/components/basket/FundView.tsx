"use client";

import { ActivityFeed } from "./ActivityFeed";
import { AutomationCard } from "./AutomationCard";
import { Composition } from "./CompositionBar";
import { StatStrip } from "./StatStrip";
import { TradePanel } from "./TradePanel";
import { useVault } from "~~/hooks/basket/useVault";
import { VAULT_ADDRESS } from "~~/utils/basket/constants";
import { hashscan } from "~~/utils/basket/hedera";

const joinNames = (names: string[]) =>
  names.length <= 1 ? names.join("") : `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}`;

const Notice = ({ title, children }: { title: string; children: React.ReactNode }) => (
  <div className="panel panel-xl p-8">
    <h2 className="m-0 text-[22px] font-medium tracking-[-0.02em]">{title}</h2>
    <div className="mt-2 max-w-xl text-sm text-base-content/70">{children}</div>
  </div>
);

export function FundView() {
  const vault = useVault();
  const { config, live } = vault;
  const symbols = config.data ? config.data.tokens.map(t => t.symbol) : [];

  return (
    <div className="mx-auto flex w-full max-w-7xl flex-col gap-6 px-5 pb-20 pt-10 sm:px-6 lg:gap-8 lg:px-8 lg:pb-24 lg:pt-14">
      <header className="grid items-end gap-5 lg:grid-cols-[minmax(0,1.6fr)_minmax(0,1fr)] lg:gap-16">
        <h1 className="m-0 text-4xl font-semibold leading-[1.08] tracking-[-0.035em] md:text-6xl md:tracking-[-0.04em]">
          One share, a slice of every token in the basket.
        </h1>
        <p className="m-0 max-w-md text-base leading-relaxed text-base-content/70 lg:pb-1">
          Deposit HBAR and the vault buys {symbols.length ? joinNames(symbols) : "the basket"} on SaucerSwap at their
          target weights. A Hedera schedule rebalances it. Redeem and take your slice in kind.
          {vault.deployed && (
            <>
              {" "}
              <a className="link link-primary" href={hashscan.contract(VAULT_ADDRESS)} target="_blank" rel="noreferrer">
                Vault on HashScan
              </a>
            </>
          )}
        </p>
      </header>

      {!vault.deployed && (
        <Notice title="No vault address for Hedera Testnet">
          <p className="m-0">
            Deploy with <code className="font-mono">yarn foundry:deploy --network hedera_testnet</code>. The deploy
            writes the address and ABI to deployedContracts.ts, and this page reads the vault from there.
          </p>
        </Notice>
      )}

      {vault.deployed && (config.isError || live.isError) && (
        <Notice title="Hedera Testnet did not answer">
          <p className="m-0">
            The vault could not be read through the RPC.{" "}
            <button
              type="button"
              className="link link-primary"
              onClick={() => {
                void config.refetch();
                void live.refetch();
              }}
            >
              Retry
            </button>
          </p>
        </Notice>
      )}

      {vault.deployed && !(config.isError || live.isError) && (!config.data || !live.data) && (
        <div className="flex flex-col gap-8" aria-busy="true" aria-label="Reading the vault">
          <div className="panel h-28 animate-pulse" />
          <div className="panel panel-xl h-80 animate-pulse" />
        </div>
      )}

      {config.data && live.data && <Loaded snap={{ vault, cfg: config.data, lv: live.data }} />}
    </div>
  );
}

function Loaded({ snap }: { snap: Parameters<typeof StatStrip>[0]["snap"] }) {
  return (
    <>
      <StatStrip snap={snap} />
      <Composition snap={snap} />
      <div className="grid grid-cols-1 gap-6 lg:grid-cols-[minmax(0,1fr)_26rem] lg:items-start lg:gap-8">
        <div className="lg:sticky lg:top-20 lg:order-2">
          <TradePanel snap={snap} />
        </div>
        <div className="flex min-w-0 flex-col gap-6 lg:gap-8">
          <AutomationCard snap={snap} />
          <ActivityFeed snap={snap} />
        </div>
      </div>
    </>
  );
}
