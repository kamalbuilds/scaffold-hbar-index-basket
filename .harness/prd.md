# Add a third token leg to the Index Basket

## Goal

The basket holds WHBAR plus two token legs, SAUCE and USDC. Add a third token leg: an HTS token with a SaucerSwap V2
pool against WHBAR. A deposit then buys three tokens, a redeem pays out three tokens plus WHBAR, and the fund page
shows four holdings without a line of UI code changing. This is the edit every developer of this template makes first,
so it has to be done the way `AGENTS.md` describes: the config changes, the contract does not.

## Existing app (preserve)

- `packages/foundry/contracts/BasketVault.sol` and every existing file in `packages/foundry/test/` are unmodified.
  `yarn foundry:test` passes in full, every existing test included.
- The fund UI in `packages/nextjs` keeps building its rows from `holdings()` and `cfg.tokens`. It does not learn the
  new token's name, address or position.
- `README.md` "Deploy to mainnet" and `MainnetConfig.fork.t.sol` are not touched. The new leg is a testnet leg.
- No `.env` file, key or token is committed.

## Feature to implement

1. **The leg in `packages/foundry/script/Deploy.s.sol`.** Grow `legs` to `new BasketVault.LegConfig[](3)` and add
   `legs[2]` with a token, its pool and a weight in basis points.
   - Keep SAUCE (`0.0.1183558`) and USDC (`0.0.5449`). Weights are SAUCE 2500, USDC 2500, new leg 2000, so WHBAR keeps
     3000. Any split is fine if the three weights sum to less than 10,000 and none is zero.
   - The pool is the SaucerSwap V2 factory's own pool for `(token, WHBAR, fee)`. Read it from the factory, never from a
     pool list or an explorer:
     `cast call 0x00000000000000000000000000000000001243eE "getPool(address,address,uint24)(address)" <token> 0x0000000000000000000000000000000000003aD2 <fee> --rpc-url https://testnet.hashio.io/api`
     A known good pair on testnet is KARATE `0.0.3772909` (`0x00000000000000000000000000000000003991eD`, 8 decimals,
     0.30%), whose factory pool is `0x6A32800F4A339D157Cf816eE8FCF965a857cd5e3` with liquidity. Write addresses in EIP-55 checksum case, which solc enforces.
   - Put the token symbol in the trailing comment of the `token:` line, as the other legs do, and update the
     `@notice` line above the contract so its percentages (`NN% HBAR / NN% SAUCE / ...`) describe the new basket.
   - `guardLeg` stays `type(uint256).max` on testnet.
2. **`packages/foundry/script/live-testnet.sh`.** Add the new token beside `SAUCE` and `USDC` and pass it to
   `associate`, so the live flow associates the account before redeeming.
3. **`packages/foundry/test/BasketVaultThirdLeg.t.sol`**, `contract BasketVaultThirdLegTest is BasketVaultBase`.
   Override `setUp` to build the fixture with three legs from the base's helpers: a third `MockHtsToken`, a priced
   `MockPool` registered with the router and the factory, `LegConfig[](3)`, and every user associated with the new
   token. At least:
   - `test_deposit_buysAllThreeLegsAtTargetWeights`: after a deposit, each of the three legs holds a non-zero balance
     and every row of `vault.holdings()` sits within `DRIFT_BPS` of its `targetBps`, WHBAR included.
   - `test_redeem_paysAllThreeLegsAndWhbar`: a redeem pays a non-zero amount of every leg and of WHBAR, pro rata to the
     shares burned.
   The tests must fail if the vault skipped the third leg.
4. **Docs that count.** `README.md` (the intro and Testing) and `AGENTS.md` (Map) print "N tests across M suites". Make them the
   numbers `forge test` reports, and add the new suite to the README breakdown.

## Non-goals

- No change to `BasketVault.sol`, the mocks, `BasketVaultBase.sol` or any existing test.
- No change to the fund UI, and no per-token branch in it.
- No mainnet addresses, no price guard change, no new dependency.
- Do not switch the package manager away from Yarn.

## Acceptance (deterministic)

`.harness/validators/` checks, none needing a secret:

- the whole suite, `forge fmt --check`, ESLint and the type check pass;
- `Deploy.s.sol` declares at least three legs, keeps SAUCE and USDC, sums under 10,000 and describes itself correctly;
- every leg pool is `factory.getPool(token, WHBAR, fee)` on the RPC, pairs the token with WHBAR and has liquidity;
- `live-testnet.sh` associates every leg token;
- the third-leg suite runs at least two tests, all green, one about deposit and one about redeem;
- the printed test and suite totals match forge;
- the UI source holds no token symbol, leg address, fixed leg index or fixed leg count;
- `BasketVault.sol` and the existing tests are unchanged.
