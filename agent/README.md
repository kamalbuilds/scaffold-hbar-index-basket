# Index Basket agent plugin

A [Hedera Agent Kit](https://github.com/hashgraph/hedera-agent-kit-js) plugin that lets an AI agent operate the Index Basket fund. The fund already runs itself: the Hedera network executes its rebalances from a schedule the vault booked. This plugin gives an agent the other half, a typed set of tools to read the fund, enter it, exit it and keep its automation alive.

It is a standalone folder with its own `package.json`. It is not a workspace of the scaffold, so `yarn install` at the repo root never touches it.

## Tools

| Tool | Kind | What the agent gets |
| --- | --- | --- |
| `get_basket_state` | query | NAV in HBAR and USD, share price, each leg's weight against its target and drift in basis points, whether a rebalance is due, the next scheduled run, how many runs the vault's fuel covers, and an account's position. Every figure comes from contract views, the JSON-RPC relay and the mirror node. |
| `preview_deposit` | query | The shares an HBAR deposit would mint: the value x supply / NAV estimate, an `eth_call` of the real `deposit` when the account can make it, the `minShares` floor at the chosen slippage, the USD value, and every blocker (stale oracle, share token not associated). |
| `deposit_hbar` | transaction | One payable `deposit(minShares)`. `minShares` comes from the simulation or the estimate and `slippageBps`. Checks association, balance plus the gas reservation, and oracle freshness before sending, then proves the `Deposited` event and the new share balance agree. |
| `redeem_shares` | transaction | `redeemExcept(shares, skipLegsMask)` in kind. `shares` is an amount or `"all"`; `skipLegs` names legs by symbol or index. Checks the account is associated with every token it will receive, approves the shares to the vault when the allowance is short, then proves the `Redeemed` event and the burned balance agree. |
| `book_next_run` | transaction | `rearm()` when automation is on and nothing is pending. Reports a no-op when a run is booked or automation is off, and blocks when the vault's fuel is below the gas reservation. Proves a pending schedule and `nextRunAt` exist afterwards. |
| `rebalance_now` | transaction | Owner only. Checks the agent's account is `owner()` before building anything, skips a rebalance no leg needs unless `force` is set, and proves the `Rebalanced` event. |

Every input is a zod schema (decimal strings with at most 8 places, bounded slippage, `0.0.N` or EVM addresses), parsed again inside the tool so a direct call is checked the same as an LLM call. Every result is `{ raw, humanMessage }` with decimal strings instead of bigints and HashScan links for the transaction, vault, share token and schedule.

A refused write returns `raw.status: "ERROR"` with `raw.blocked: true` and the reasons, and sends nothing. A reverted write returns the vault's own error name decoded from the mirror node (`OnlyOwnerOrSelf`, `InsufficientShares`, `StaleOracle`).

### Transaction modes

Write tools follow the Agent Kit's `AgentMode`. In `AUTONOMOUS` the operator key signs and the tool waits for the mirror node and checks the post-condition. In `RETURN_BYTES` the tool returns the frozen, unsigned transaction for a wallet or a human to sign, along with the plan it built. When a redeem needs an approval first, the approval bytes come back first.

## Run it

```bash
cd agent
npm install
npm test                 # 77 unit tests, no network
npm run typecheck
```

### Without an LLM

```bash
npx tsx examples/direct.ts                       # read-only: state, deposit preview, the deposit and rebalance built as unsigned bytes
npx tsx examples/direct.ts --deposit 1        # deposit 1 HBAR through deposit_hbar
npx tsx examples/direct.ts --redeem 0.05      # approve and redeem through redeem_shares
npx tsx examples/direct.ts --rearm            # book_next_run
npx tsx examples/direct.ts --rebalance force  # rebalance_now (owner only)
```

It targets vault C `0xe72FbF68536D29d3A9e0D897C2aE813B7B279058` on Hedera testnet. Write flags run only when `DEPLOYER_PRIVATE_KEY` is set in the environment or in `packages/foundry/.env`; the key is never printed. The recorded read-only output is in [examples/direct-readonly.txt](examples/direct-readonly.txt).

### With an LLM

```bash
OPENAI_API_KEY=... npx tsx examples/ask.ts "Is a rebalance due, and when does the fuel run out?"
ANTHROPIC_API_KEY=... MODEL=anthropic:claude-sonnet-4-5 npx tsx examples/ask.ts "Preview a 2 HBAR deposit"
npx tsx examples/ask.ts --bytes "Deposit 1 HBAR"      # the agent builds the transaction, you sign it
```

[examples/ask.ts](examples/ask.ts) loads the plugin into `HederaAIToolkit` from `@hashgraph/hedera-agent-kit-ai-sdk` next to the kit's own `associate_token_tool`, so an agent told to associate a token first can do it. Any AI SDK language model works; OpenAI and Anthropic are wired through `MODEL`.

### In your own agent

```ts
import { createIndexBasketPlugin } from "./src";

const toolkit = new HederaAIToolkit({
  client,
  configuration: { plugins: [createIndexBasketPlugin()], context: { mode: AgentMode.AUTONOMOUS } },
});
```

`createIndexBasketPlugin(config?, chain?)` reads `BASKET_VAULT`, `HEDERA_RPC_URL` and `HEDERA_MIRROR_URL` by default and targets vault C on testnet when they are unset.

## Proof on Hedera testnet

`examples/direct.ts` against vault C, signed by the burner account 0.0.4729347 through the tools, each result checked against the chain by the tool and again by hand on the mirror node:

| Tool call | Result | HashScan |
| --- | --- | --- |
| `deposit_hbar` 1 HBAR | 0.95837174 IBSK minted, equal to the `preview_deposit` simulation; share balance 9.97841756 to 10.9367893 | [transaction](https://hashscan.io/testnet/transaction/0.0.4729347-1791134539-501782816) |
| `redeem_shares` 0.05 IBSK | approved, then paid 0.0207291 WHBAR, 0.607824 SAUCE, 0.029234 USDC | [approval](https://hashscan.io/testnet/transaction/0.0.4729347-1791134634-937695611), [redeem](https://hashscan.io/testnet/transaction/0.0.4729347-1791134640-646067407) |
| `rebalance_now` with `force` | `Rebalanced(traded=false)`, NAV unchanged at 13.38388879 HBAR | [transaction](https://hashscan.io/testnet/transaction/0.0.4729347-1791134715-292725423) |
| `book_next_run` | no-op: run `0.0.10859025` already booked | [schedule](https://hashscan.io/testnet/schedule/0.0.10859025) |

Re-check the deposit: `curl -s https://testnet.mirrornode.hedera.com/api/v1/contracts/results/0.0.4729347-1791134539-501782816 | jq '{result,gas_used,amount}'` returns `SUCCESS`, 419001 gas and 100000000 tinybar.

## Layout

| Path | Role |
| --- | --- |
| `src/tools.ts` | The six tools, built on the kit's `BaseQueryTool` and `BaseTransactionTool` |
| `src/plugin.ts` | `createIndexBasketPlugin`, the kit `Plugin` |
| `src/chain.ts` | Contract views over viem, mirror node reads, revert decoding. A `ChainReader` interface lets tests run the tools without a network |
| `src/analysis.ts`, `src/units.ts`, `src/shape.ts` | Pure functions: drift, fuel runway, skip masks, share estimates, result shaping |
| `src/schemas.ts` | zod input schemas |
| `test/` | vitest: input validation, result shaping, every tool's blocked, no-op and build paths, toolkit loading |
