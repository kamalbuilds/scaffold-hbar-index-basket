/**
 * Calls the Index Basket tools directly, no LLM in the loop, against the vault in BASKET_VAULT
 * (default: vault C on Hedera testnet).
 *
 *   npx tsx examples/direct.ts                       read-only: state, a deposit preview, and the deposit built as unsigned bytes
 *   npx tsx examples/direct.ts --deposit 1        deposit 1 HBAR (needs DEPLOYER_PRIVATE_KEY)
 *   npx tsx examples/direct.ts --redeem all       redeem shares, "all" or an amount
 *   npx tsx examples/direct.ts --rearm            book the next run if automation is on and none is pending
 *   npx tsx examples/direct.ts --rebalance        owner only; add "force" to send it when no leg has drifted
 *
 * Write actions run only when their flag is given AND DEPLOYER_PRIVATE_KEY is set (read from the
 * environment or packages/foundry/.env). Nothing is printed from the key.
 */
import { AgentMode, type Context } from "@hashgraph/hedera-agent-kit";
import { Client, PrivateKey } from "@hiero-ledger/sdk";
import { config as loadEnv } from "dotenv";
import { fileURLToPath } from "node:url";
import { createIndexBasketPlugin, indexBasketToolNames as T } from "../src";
import { VaultChain } from "../src/chain";
import { configFromEnv } from "../src/config";

loadEnv({ path: fileURLToPath(new URL("../../packages/foundry/.env", import.meta.url)), quiet: true });
loadEnv({ quiet: true });

const args = process.argv.slice(2);
const flag = (name: string) => args.indexOf(`--${name}`);
const value = (name: string) => (flag(name) >= 0 ? args[flag(name) + 1] : undefined);

const cfg = configFromEnv();
const chain = new VaultChain(cfg);
const key = process.env.DEPLOYER_PRIVATE_KEY?.trim();
const client = Client.forTestnet();
let accountId = process.env.HEDERA_ACCOUNT_ID?.trim() || "0.0.4729347";

if (key) {
  const priv = PrivateKey.fromStringECDSA(key);
  accountId = process.env.HEDERA_ACCOUNT_ID?.trim() || (await chain.account(`0x${priv.publicKey.toEvmAddress()}`)).accountId;
  client.setOperator(accountId, priv);
}

const plugin = createIndexBasketPlugin(cfg, chain);
const toolsFor = (context: Context) => Object.fromEntries(plugin.tools(context).map((t) => [t.method, t]));

async function run(label: string, tool: { execute: (c: Client, ctx: Context, p: unknown) => Promise<any> }, ctx: Context, params: unknown) {
  console.log(`\n== ${label}`);
  const out = await tool.execute(client, ctx, params);
  if (out.bytes) {
    // RETURN_BYTES mode: the kit returns the frozen, unsigned transaction itself.
    const { bytes, ...rest } = out;
    console.log(`Unsigned ${rest.type} ready: ${(bytes as Uint8Array).length} bytes, payer ${rest.payerAccountId}, valid until ${rest.expiresAt}. Not sent.`);
    console.log(JSON.stringify(rest, null, 2));
    return out;
  }
  console.log(out.humanMessage);
  console.log(JSON.stringify(out.raw, null, 2));
  return out;
}

const readCtx: Context = { mode: AgentMode.RETURN_BYTES, accountId };
const read = toolsFor(readCtx);
console.log(`vault ${cfg.vault}  rpc ${cfg.rpcUrl}  acting as ${accountId}  write flags ${key ? "available (DEPLOYER_PRIVATE_KEY set)" : "off (no DEPLOYER_PRIVATE_KEY)"}`);

await run(T.state, read[T.state]!, readCtx, {});
await run(T.preview, read[T.preview]!, readCtx, { hbar: "1" });

const writes = ["deposit", "redeem", "rearm", "rebalance"].filter((f) => flag(f) >= 0);
if (writes.length === 0) {
  // Return-bytes mode builds and freezes the transaction without signing or sending it.
  await run(`${T.deposit} (RETURN_BYTES, not sent)`, read[T.deposit]!, readCtx, { hbar: "1" });
  await run(`${T.rebalance} (RETURN_BYTES, not sent)`, read[T.rebalance]!, readCtx, {});
  console.log("\nRead-only run complete. Add --deposit 1, --redeem all, --rearm or --rebalance with DEPLOYER_PRIVATE_KEY set to send.");
} else if (!key) {
  console.error(`\nWrite flags (${writes.map((w) => `--${w}`).join(", ")}) need DEPLOYER_PRIVATE_KEY in the environment. Nothing was sent.`);
  process.exitCode = 1;
} else {
  const ctx: Context = { mode: AgentMode.AUTONOMOUS, accountId };
  const live = toolsFor(ctx);
  if (flag("deposit") >= 0) await run(T.deposit, live[T.deposit]!, ctx, { hbar: value("deposit") ?? "1" });
  if (flag("redeem") >= 0) await run(T.redeem, live[T.redeem]!, ctx, { shares: value("redeem") ?? "all" });
  if (flag("rearm") >= 0) await run(T.book, live[T.book]!, ctx, {});
  if (flag("rebalance") >= 0) await run(T.rebalance, live[T.rebalance]!, ctx, { force: value("rebalance") === "force" });
}
client.close();
