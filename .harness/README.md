# Hedera Harness recipe: a third basket leg

This directory is a [hedera-harness](https://github.com/hedera-dev/hedera-harness)
recipe. It asks a coding agent for the edit every developer of this template
makes first: add a third token leg, an HTS token with a SaucerSwap V2 pool
against WHBAR, so a deposit buys three tokens, a redeem pays three tokens plus
WHBAR, and the fund page shows four holdings. `BasketVault.sol` and the fund UI
do not change. The harness, not the agent, decides whether the run passed.

| File | Tier | What it checks |
| --- | --- | --- |
| `prd.md` | n/a | What to build, with the exact names: `legs[2]` in `Deploy.s.sol`, the `live-testnet.sh` association, `BasketVaultThirdLeg.t.sol`, the printed test totals. |
| `validators/static.json` | 0 | The files exist, `Deploy.s.sol` declares `LegConfig[](3)`, the new suite builds three legs and reads `holdings()` and `targetBps`, and the UI still builds its rows from `lv.holdings` and `cfg.tokens`. No `.env`. |
| `validators/yarn.json` | 1 | `yarn install`, the whole Foundry suite, `forge fmt --check`, `next lint`, strict types, then the six checks below. |
| `validators/check.mjs` | 1 | `deploy-legs`: at least 3 legs, SAUCE and USDC kept, weights under 10,000, and the `@notice` percentages match the weights. `factory-pool`: each pool is `factory.getPool(token, WHBAR, fee)` on the testnet RPC, pairs the token with WHBAR and has liquidity. `live-script`: `live-testnet.sh` associates every leg token. `third-leg-test`: the new suite runs at least 2 tests, all green, one on deposit and one on redeem (forge exits 0 when nothing matches, so the tests are counted). `docs-counts`: README and AGENTS print the totals forge reports. `ui-generic`: no token symbol, leg address, fixed leg index or fixed leg count in the fund UI. `protected-paths`: `BasketVault.sol` and the existing tests are unchanged. |

## Running it

```bash
npx hedera-harness doctor     # prerequisites, the recipe, every path it references
npx hedera-harness validate   # Tiers 0 and 1, no agent
npx hedera-harness run        # the full run: agent, repairs, validators
```

No testnet funds or secrets are needed. `factory-pool` makes read-only calls
to `https://testnet.hashio.io/api`; `HEDERA_RPC_URL` overrides it and `cast`
must be on `PATH`. `agent: claude` in `spec.yaml` is the one line to change for
`cursor`. `forbiddenFiles` leaves out `packages/foundry/.env`, which the
foundry postinstall creates from `.env.example` on every `yarn install`.

## Proof in both directions

`hedera-harness validate` ran in a clean copy of the template, once as
committed and once with a minimal reference implementation applied
(`Deploy.s.sol` with KARATE `0.0.3772909` and its factory pool, the
`live-testnet.sh` association, `BasketVaultThirdLeg.t.sol`, the test totals in
README and AGENTS). No coding agent ran.

| Copy | Result | Detail |
| --- | --- | --- |
| Template as committed | `passed=false`, `findings=6` | The new suite and the third leg are absent (4 static findings, plus `deploy-legs` and `third-leg-test`). `yarn install`, `foundry:test` (148 tests), `foundry:lint`, `next:lint`, `next:check-types`, `factory-pool`, `live-script`, `docs-counts`, `ui-generic` and `protected-paths` all exit 0, so none of the 6 is a false alarm. |
| Template with the reference | `passed=true`, `findings=0` | 150 tests across 12 suites, the two new tests green, all three factory pools verified on the RPC, lint, types and the UI check clean. |

Each check also goes red when the rule it guards is broken. Ten deliberate
bugs in the reference, each restored afterwards (red, then green again), and one
real defect the checks caught while the reference was built:

| Bug | Caught by |
| --- | --- |
| KARATE pool set to the pool's long-zero alias, not the factory's address | `factory-pool` |
| Leg weights summing to 10,000 | `deploy-legs` |
| `@notice` still reading 40% HBAR / 30% SAUCE / 30% USDC | `deploy-legs` |
| `deposit` skips the third leg | `third-leg-test`: both tests red |
| `redeemExcept` skips the third leg's payout | `third-leg-test`: redeem test red |
| `associate KARATE` removed from `live-testnet.sh` | `live-script` |
| AGENTS.md printing 148 tests after the suite grew to 150 | `docs-counts` |
| `CompositionBar` cutting rows with `slice(0, 3)` | `ui-generic` |
| A `SAUCE` literal in `FundView.tsx` | `ui-generic` |
| `BasketVault.sol` edited | `protected-paths` |
| The leg's address written in lowercase (solc rejects it, `forge fmt` flags it) | `third-leg-test` and `contracts-lint`, found while building the reference and fixed in `prd.md` |

Blind spot: the reference was written by the recipe author, not by an agent
run, so these checks prove the validators discriminate, not that a particular
agent converges in three attempts.
