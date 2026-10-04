import { ContractExecuteTransaction, ContractId, Hbar, type Client } from "@hiero-ledger/sdk";
import type { Context } from "@hashgraph/hedera-agent-kit";
import { type Address, type Hex, hexToBytes } from "viem";
import type { ChainReader } from "./chain";
import { entityNum } from "./links";

/** Gas limits per call, as the app uses them: Hedera bills gas used but checks the payer against the whole limit. */
export const GAS = { deposit: 4_000_000, redeem: 3_000_000, rebalance: 4_000_000, rearm: 2_000_000, approve: 1_000_000 } as const;

export function toContractId(address: Address): ContractId {
  const num = entityNum(address);
  return num === null ? ContractId.fromEvmAddress(0, 0, address) : ContractId.fromString(`0.0.${num}`);
}

/** A ContractExecuteTransaction for already-encoded calldata, optionally carrying HBAR (in tinybar). */
export function contractCall(target: Address, data: Hex, gas: number, tinybar?: bigint): ContractExecuteTransaction {
  const tx = new ContractExecuteTransaction()
    .setContractId(toContractId(target))
    .setGas(gas)
    .setFunctionParameters(hexToBytes(data))
    .setMaxTransactionFee(new Hbar(15));
  if (tinybar !== undefined) tx.setPayableAmount(Hbar.fromTinybars(tinybar.toString()));
  return tx;
}

/** The account the agent acts as: the Context account (return-bytes setups), else the client's operator, else null. */
export function defaultAccount(client: Client, context: Context): string | null {
  return context.accountId ?? client.operatorAccountId?.toString() ?? null;
}

export async function requireOperator(chain: ChainReader, client: Client, context: Context) {
  const id = defaultAccount(client, context);
  if (!id) throw new Error("This tool signs as the agent's account, but the client has no operator and the context has no accountId.");
  return chain.account(id);
}
