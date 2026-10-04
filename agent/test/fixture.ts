import type { Address } from "viem";
import type { Association, ChainReader, ContractResult, RawState } from "../src/chain";
import { configFromEnv } from "../src/config";

export const OWNER: Address = "0x1565aF2C2eF52b4A89180684a47C5260c716AbD1";
export const STRANGER: Address = "0x00000000000000000000000000000000000000dE";
export const SHARE: Address = "0x0000000000000000000000000000000000A56762";
export const WHBAR: Address = "0x0000000000000000000000000000000000003aD2";
export const SAUCE: Address = "0x0000000000000000000000000000000000120f46";
export const USDC: Address = "0x0000000000000000000000000000000000001549";
export const POOL: Address = "0x914B98992d7eD602D1f5d9084ECe8160Fc0e741a";
const VAULT = configFromEnv({}).vault;

/** Vault C as read from testnet on 2026-10-04 (block time 1791134177), with the drift made editable. */
export function state(over: Partial<RawState> = {}): RawState {
  return {
    vault: VAULT,
    owner: OWNER,
    shareToken: SHARE,
    shareSymbol: "IBSK",
    supply: 1_194_130_370n,
    deadShares: 100_000n,
    nav: 1_243_737_000n,
    oracle: { fresh: true, hbarUsd: 10_201_316n, navUsd: 126_877_541n },
    driftBps: 50n,
    guardLeg: (1n << 256n) - 1n,
    maxDeviationBps: 300n,
    interval: 21_600n,
    pendingSchedule: "0x0000000000000000000000000000000000A5B211",
    nextRunAt: 1_791_150_624n,
    scheduledGas: 4_000_000n,
    holdings: [
      { token: WHBAR, balance: 494_797_510n, valueWhbar: 494_797_510n, targetBps: 4000 },
      { token: SAUCE, balance: 14_513_125_800n, valueWhbar: 371_529_731n, targetBps: 3000 },
      { token: USDC, balance: 6_988_607n, valueWhbar: 377_409_759n, targetBps: 3000 },
    ],
    legs: [
      { token: SAUCE, pool: POOL, fee: 3000, tokenIsToken0: true, weightBps: 3000 },
      { token: USDC, pool: POOL, fee: 3000, tokenIsToken0: false, weightBps: 3000 },
    ],
    symbols: { [SHARE.toLowerCase()]: "IBSK", [WHBAR.toLowerCase()]: "WHBAR", [SAUCE.toLowerCase()]: "SAUCE", [USDC.toLowerCase()]: "USDC" },
    decimals: { [WHBAR.toLowerCase()]: 8, [SAUCE.toLowerCase()]: 6, [USDC.toLowerCase()]: 6 },
    fuelWeibar: 73_370_888_950_000_000_000n,
    gasPriceWeibar: 870_000_000_000n,
    lastRunFeeTinybar: 128_996_442n,
    nowSeconds: 1_791_134_177,
    ...over,
  };
}

type Stub = {
  state: RawState;
  /** Address of the acting account. */
  evm: Address;
  shares: bigint;
  allowance: bigint;
  hbarBalance: bigint;
  associated: boolean;
  simulated: bigint | null;
  calls: string[];
};

export function stubChain(over: Partial<Stub> = {}): ChainReader & { calls: string[] } {
  const s: Stub = { state: state(), evm: OWNER, shares: 1_000_000_000n, allowance: 1_000_000_000n, hbarBalance: 100n * 10n ** 18n, associated: true, simulated: 95_000_000n, calls: [], ...over };
  const result = (): ContractResult => ({ result: "SUCCESS", hash: "0x", gas_used: 1, error_message: null, logs: [] });
  return {
    cfg: configFromEnv({}),
    calls: s.calls,
    readState: async () => s.state,
    balanceOf: async () => s.shares,
    allowance: async () => s.allowance,
    account: async (id) => ({ accountId: id.startsWith("0.0.") ? id : "0.0.4729347", evmAddress: id.startsWith("0x") ? (id as Address) : s.evm }),
    associations: async (_id, tokens) => Object.fromEntries(tokens.map((t) => [t.toLowerCase(), (s.associated ? "associated" : "needs") as Association])),
    simulateDeposit: async () => s.simulated,
    waitForResult: async (id) => (s.calls.push(`waitForResult ${id}`), result()),
    readBooking: async () => ({ pendingSchedule: s.state.pendingSchedule, nextRunAt: s.state.nextRunAt }),
    hbarBalance: async () => s.hbarBalance,
  };
}
