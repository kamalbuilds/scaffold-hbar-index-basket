/**
 * Ask an LLM to operate the Index Basket through the Hedera Agent Kit (Vercel AI SDK adapter).
 *
 *   OPENAI_API_KEY=...    npx tsx examples/ask.ts "Is the basket due a rebalance, and when is the next run?"
 *   ANTHROPIC_API_KEY=... MODEL=anthropic:claude-sonnet-4-5 npx tsx examples/ask.ts "Preview a 2 HBAR deposit"
 *
 * MODEL is provider:model (openai or anthropic; any other AI SDK provider is one import away).
 * Without MODEL the provider is chosen by whichever API key is set.
 * With DEPLOYER_PRIVATE_KEY the agent signs and sends (AUTONOMOUS). Without it, or with --bytes,
 * write tools return unsigned transaction bytes for a human or wallet to sign (RETURN_BYTES).
 * Keys come from the environment or packages/foundry/.env; they are never printed.
 */
import { AgentMode, type Context } from "@hashgraph/hedera-agent-kit";
import { coreTokenPlugin } from "@hashgraph/hedera-agent-kit/plugins";
import { HederaAIToolkit } from "@hashgraph/hedera-agent-kit-ai-sdk";
import { Client, PrivateKey } from "@hiero-ledger/sdk";
import { anthropic } from "@ai-sdk/anthropic";
import { openai } from "@ai-sdk/openai";
import { generateText, stepCountIs } from "ai";
import { config as loadEnv } from "dotenv";
import { fileURLToPath } from "node:url";
import { createIndexBasketPlugin, indexBasketToolNames } from "../src";
import { VaultChain } from "../src/chain";
import { configFromEnv } from "../src/config";

loadEnv({ path: fileURLToPath(new URL("../../packages/foundry/.env", import.meta.url)), quiet: true });
loadEnv({ quiet: true });

function pickModel() {
  const spec = process.env.MODEL?.trim() || (process.env.ANTHROPIC_API_KEY ? "anthropic:claude-sonnet-4-5" : process.env.OPENAI_API_KEY ? "openai:gpt-4o" : "");
  const [provider, ...rest] = spec.split(":");
  const id = rest.join(":");
  if (provider === "anthropic" && id) return anthropic(id);
  if (provider === "openai" && id) return openai(id);
  throw new Error("Set OPENAI_API_KEY or ANTHROPIC_API_KEY, or MODEL=openai:<model> / MODEL=anthropic:<model>.");
}

const args = process.argv.slice(2);
const bytesOnly = args.includes("--bytes");
const prompt = args.filter((a) => !a.startsWith("--")).join(" ") || "Show me the state of the basket: NAV, how far each leg has drifted, when the next run is, and how long the fuel lasts.";

const cfg = configFromEnv();
const chain = new VaultChain(cfg);
const key = process.env.DEPLOYER_PRIVATE_KEY?.trim();
const client = Client.forTestnet();
let accountId = process.env.HEDERA_ACCOUNT_ID?.trim() || undefined;
if (key) {
  const priv = PrivateKey.fromStringECDSA(key);
  accountId ||= (await chain.account(`0x${priv.publicKey.toEvmAddress()}`)).accountId;
  client.setOperator(accountId, priv);
}

const context: Context = key && !bytesOnly ? { mode: AgentMode.AUTONOMOUS, accountId } : { mode: AgentMode.RETURN_BYTES, accountId: accountId ?? "0.0.4729347" };
const toolkit = new HederaAIToolkit({
  client,
  configuration: {
    plugins: [createIndexBasketPlugin(cfg, chain), coreTokenPlugin],
    // The basket tools, plus the kit's own associate_token_tool: deposits and redemptions tell the agent to use it.
    tools: [...Object.values(indexBasketToolNames), "associate_token_tool"],
    context,
  },
});

console.log(`mode ${context.mode}, account ${context.accountId ?? "none"}, tools: ${Object.keys(toolkit.getTools()).join(", ")}\n`);
const { text, steps } = await generateText({
  model: pickModel(),
  tools: toolkit.getTools(),
  stopWhen: stepCountIs(8),
  system:
    "You operate the Index Basket fund on Hedera testnet through tools. Read get_basket_state before advising. Preview a deposit before making one. Report transaction links verbatim. Never invent numbers: every figure comes from a tool result.",
  prompt,
});
for (const step of steps) for (const call of step.toolCalls) console.log(`tool call: ${call.toolName}(${JSON.stringify(call.input)})`);
console.log(`\n${text}`);
client.close();
