import {
  type Address,
  BaseError,
  ContractFunctionRevertedError,
  type Hex,
  createPublicClient,
  decodeErrorResult,
  decodeEventLog,
  http,
  toEventSelector,
} from "viem";
import { hederaTestnet } from "viem/chains";
import { erc20Abi, vaultAbi } from "./abi";
import type { Holding, Leg } from "./analysis";
import type { VaultConfig } from "./config";
import { entityRef } from "./links";
import { WEIBAR_PER_TINYBAR } from "./units";

export type Association = "associated" | "auto" | "needs";

/** Everything a state read returns, as raw chain values. `shapeState` turns it into the tool result. */
export type RawState = {
  vault: Address;
  owner: Address;
  shareToken: Address;
  shareSymbol: string;
  supply: bigint;
  deadShares: bigint;
  nav: bigint;
  /** null while the Chainlink answer is stale or not positive: deposits and rebalances revert then, redeems do not. */
  oracle: { fresh: true; hbarUsd: bigint; navUsd: bigint } | { fresh: false; reason: string };
  driftBps: bigint;
  guardLeg: bigint;
  maxDeviationBps: bigint;
  interval: bigint;
  pendingSchedule: Address;
  nextRunAt: bigint;
  scheduledGas: bigint;
  holdings: Holding[];
  legs: Leg[];
  symbols: Record<string, string>;
  decimals: Record<string, number>;
  fuelWeibar: bigint;
  gasPriceWeibar: bigint;
  lastRunFeeTinybar: bigint | null;
  nowSeconds: number;
};

export type MirrorLog = { address: string; data: Hex; topics: Hex[]; index: number };
export type ContractResult = {
  result: string;
  hash: string;
  gas_used: number;
  error_message: string | null;
  logs: MirrorLog[];
};

/** What the tools need from the chain. `VaultChain` is the live implementation; tests pass a stub. */
export interface ChainReader {
  readonly cfg: VaultConfig;
  readState(): Promise<RawState>;
  balanceOf(token: Address, account: Address): Promise<bigint>;
  allowance(token: Address, owner: Address, spender: Address): Promise<bigint>;
  account(idOrAddress: string): Promise<{ accountId: string; evmAddress: Address }>;
  associations(accountId: string, tokens: readonly Address[]): Promise<Record<string, Association>>;
  simulateDeposit(from: Address, tinybar: bigint): Promise<bigint | null>;
  waitForResult(txId: string): Promise<ContractResult>;
  readBooking(): Promise<{ pendingSchedule: Address; nextRunAt: bigint }>;
  /** Native HBAR balance in weibar (18 decimals), as JSON-RPC reports it. */
  hbarBalance(account: Address): Promise<bigint>;
}

export class MirrorError extends Error {
  constructor(
    readonly status: number,
    path: string,
  ) {
    super(`Mirror node answered ${status} for ${path}`);
  }
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/** The vault's custom error behind a failed call, or null when the error carries no revert data. */
export function revertName(error: unknown): string | null {
  if (!(error instanceof BaseError)) return null;
  const hit = error.walk((e) => e instanceof ContractFunctionRevertedError);
  return hit instanceof ContractFunctionRevertedError ? (hit.data?.errorName ?? hit.reason ?? null) : null;
}

/** Decodes the revert bytes the mirror node stores for a failed call, e.g. `OnlyOwnerOrSelf()`. */
export function decodeRevert(data: string | null | undefined): { name: string; args: string[] } | null {
  if (!data || data === "0x") return null;
  try {
    const decoded = decodeErrorResult({ abi: vaultAbi, data: data as Hex });
    return { name: decoded.errorName, args: (decoded.args ?? []).map((a) => String(a)) };
  } catch {
    return null;
  }
}

export class VaultChain implements ChainReader {
  private readonly rpc;

  constructor(readonly cfg: VaultConfig) {
    this.rpc = createPublicClient({ chain: hederaTestnet, transport: http(cfg.rpcUrl, { retryCount: 3, retryDelay: 400 }) });
  }

  async mirror<T>(path: string): Promise<T> {
    const res = await fetch(`${this.cfg.mirrorUrl}/api/v1${path}`, { headers: { Accept: "application/json" } });
    if (!res.ok) throw new MirrorError(res.status, path);
    return (await res.json()) as T;
  }

  private read<T>(address: Address, abi: typeof vaultAbi | typeof erc20Abi, functionName: string, args: unknown[] = []) {
    return this.rpc.readContract({ address, abi, functionName, args } as never) as Promise<T>;
  }

  async readState(): Promise<RawState> {
    const v = this.cfg.vault;
    const vr = <T>(fn: string) => this.read<T>(v, vaultAbi, fn);
    const [owner, shareToken, nav, interval, pendingSchedule, nextRunAt, scheduledGas, driftBps, guardLeg, maxDeviationBps, deadShares] =
      await Promise.all([
        vr<Address>("owner"),
        vr<Address>("shareToken"),
        vr<bigint>("nav"),
        vr<bigint>("rebalanceInterval"),
        vr<Address>("pendingSchedule"),
        vr<bigint>("nextRunAt"),
        vr<bigint>("scheduledGas"),
        vr<bigint>("driftBps"),
        vr<bigint>("guardLeg"),
        vr<bigint>("maxDeviationBps"),
        vr<bigint>("DEAD_SHARES"),
      ]);
    const [holdings, legs, fuelWeibar, gasPriceWeibar, supply, shareSymbol, lastRunFeeTinybar] = await Promise.all([
      vr<readonly Holding[]>("holdings"),
      vr<readonly Leg[]>("legs"),
      this.rpc.getBalance({ address: v }),
      this.rpc.getGasPrice(),
      this.read<bigint>(shareToken, erc20Abi, "totalSupply"),
      this.read<string>(shareToken, erc20Abi, "symbol"),
      this.lastRunFee(),
    ]);
    const tokens = holdings.map((h) => h.token);
    const meta = await Promise.all(
      tokens.map(async (t) => [t, await this.read<string>(t, erc20Abi, "symbol"), await this.read<number>(t, erc20Abi, "decimals")] as const),
    );
    const symbols: Record<string, string> = { [shareToken.toLowerCase()]: shareSymbol };
    const decimals: Record<string, number> = {};
    for (const [t, s, d] of meta) {
      symbols[t.toLowerCase()] = s;
      decimals[t.toLowerCase()] = Number(d);
    }
    let oracle: RawState["oracle"];
    try {
      const [hbarUsd, navUsd] = await Promise.all([vr<bigint>("hbarUsd"), vr<bigint>("navUsd")]);
      oracle = { fresh: true, hbarUsd, navUsd };
    } catch (error) {
      const name = revertName(error);
      if (name !== "StaleOracle" && name !== "BadOraclePrice") throw error;
      oracle = { fresh: false, reason: name };
    }
    return {
      vault: v,
      owner,
      shareToken,
      shareSymbol,
      supply,
      deadShares,
      nav,
      oracle,
      driftBps,
      guardLeg,
      maxDeviationBps,
      interval,
      pendingSchedule,
      nextRunAt,
      scheduledGas,
      holdings: holdings.map((h) => ({ ...h })),
      legs: legs.map((l) => ({ ...l })),
      symbols,
      decimals,
      fuelWeibar,
      gasPriceWeibar,
      lastRunFeeTinybar,
      nowSeconds: Math.floor(Date.now() / 1000),
    };
  }

  /** What the vault's newest scheduled run was charged, in tinybar, or null if none ran in the last six days. */
  private async lastRunFee(): Promise<bigint | null> {
    const now = Math.floor(Date.now() / 1000);
    const topic0 = toEventSelector("ScheduledRun(bool)");
    const { logs } = await this.mirror<{ logs: { timestamp: string }[] }>(
      `/contracts/${this.cfg.vault}/results/logs?topic0=${topic0}&timestamp=gte:${now - 6 * 86_400}&timestamp=lte:${now}&order=desc&limit=1`,
    );
    if (logs.length === 0) return null;
    const { transactions } = await this.mirror<{ transactions: { charged_tx_fee: number }[] }>(`/transactions?timestamp=${logs[0]!.timestamp}`);
    return transactions.length > 0 ? BigInt(transactions[0]!.charged_tx_fee) : null;
  }

  balanceOf(token: Address, account: Address) {
    return this.read<bigint>(token, erc20Abi, "balanceOf", [account]);
  }

  allowance(token: Address, owner: Address, spender: Address) {
    return this.read<bigint>(token, erc20Abi, "allowance", [owner, spender]);
  }

  hbarBalance(account: Address) {
    return this.rpc.getBalance({ address: account });
  }

  async readBooking() {
    const [pendingSchedule, nextRunAt] = await Promise.all([
      this.read<Address>(this.cfg.vault, vaultAbi, "pendingSchedule"),
      this.read<bigint>(this.cfg.vault, vaultAbi, "nextRunAt"),
    ]);
    return { pendingSchedule, nextRunAt };
  }

  /** Accepts 0.0.N or an EVM address; returns both forms from the mirror node. */
  async account(idOrAddress: string) {
    const info = await this.mirror<{ account: string; evm_address: Address }>(`/accounts/${idOrAddress}`);
    return { accountId: info.account, evmAddress: info.evm_address };
  }

  /** Whether `accountId` can receive each token. A failed lookup throws; it is never reported as associated. */
  async associations(accountId: string, tokens: readonly Address[]) {
    const out: Record<string, Association> = {};
    let auto: boolean | undefined;
    for (const token of tokens) {
      const id = entityRef(token);
      const rel = await this.mirror<{ tokens: { token_id: string }[] }>(`/accounts/${accountId}/tokens?token.id=${id}`);
      if (rel.tokens.some((t) => t.token_id === id)) {
        out[token.toLowerCase()] = "associated";
        continue;
      }
      if (auto === undefined) auto = (await this.mirror<{ max_automatic_token_associations: number }>(`/accounts/${accountId}`)).max_automatic_token_associations === -1;
      out[token.toLowerCase()] = auto ? "auto" : "needs";
    }
    return out;
  }

  /** The shares a deposit would mint right now, from an eth_call of the real `deposit`. Null when the node cannot simulate it. */
  async simulateDeposit(from: Address, tinybar: bigint) {
    try {
      const { result } = await this.rpc.simulateContract({
        address: this.cfg.vault,
        abi: vaultAbi,
        functionName: "deposit",
        args: [0n],
        account: from,
        value: tinybar * WEIBAR_PER_TINYBAR,
        gas: 4_000_000n,
      });
      return result;
    } catch (error) {
      if (revertName(error) || error instanceof BaseError) return null;
      throw error;
    }
  }

  /** Polls the mirror node until the transaction's contract result is there. Throws after ~45 s. */
  async waitForResult(txId: string): Promise<ContractResult> {
    for (let attempt = 0; attempt < 30; attempt++) {
      try {
        return await this.mirror<ContractResult>(`/contracts/results/${txId}`);
      } catch (error) {
        if (!(error instanceof MirrorError) || error.status !== 404) throw error;
      }
      await sleep(1500);
    }
    throw new Error(`The mirror node has not recorded ${txId} after 45 s. Look it up on HashScan.`);
  }
}

/** The vault events in a contract result's logs, decoded. Logs of other contracts and unknown events are skipped. */
export function vaultEvents(result: ContractResult, vault: Address) {
  return result.logs
    .filter((l) => l.address.toLowerCase() === vault.toLowerCase())
    .flatMap((l) => {
      try {
        const e = decodeEventLog({ abi: vaultAbi, data: l.data, topics: l.topics as [Hex, ...Hex[]] });
        return [{ name: e.eventName as string, args: e.args as unknown as Record<string, unknown> }];
      } catch {
        return [];
      }
    });
}
