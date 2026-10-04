# Runbook: operate the deployed vault

Day-two operations for a deployed `BasketVault`: read its health, keep its fuel up, start, stop and rearm the automation, hand over ownership, turn the price guard on, redeploy, and re-read the evidence. Every command is a single `cast` or `yarn` call against Hedera testnet, and each says what to read afterwards to prove it worked.

The examples use vault C, the canonical deployment. Swap `V` for your own vault.

```bash
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
set -a; source packages/foundry/.env; set +a            # DEPLOYER_PRIVATE_KEY, never echoed
RPC=${HEDERA_RPC_URL:-https://testnet.hashio.io/api}
M=https://testnet.mirrornode.hedera.com/api/v1
V=0xe72FbF68536D29d3A9e0D897C2aE813B7B279058            # vault C, contract 0.0.10839904
n() { awk '{print $1}'; }                                # cast prints "123 [1.23e2]"; keep the exact value
own() { cast send "$V" "$@" --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$RPC" --legacy; }   # owner calls
```

The owner calls need `DEPLOYER_PRIVATE_KEY` to be the key of `owner()`. Read-only calls need nothing.

## 1. Health at a glance

```bash
cast call $V "owner()(address)" --rpc-url $RPC
cast call $V "nav()(uint256)" --rpc-url $RPC | n                       # WHBAR tinybar, 1e8 = 1 HBAR
cast call $V "navUsd()(uint256)" --rpc-url $RPC | n                    # USD e8; reverts when Chainlink is stale
cast call $V "holdings()((address,uint256,uint256,uint16)[])" --rpc-url $RPC
cast call $V "rebalanceInterval()(uint256)" --rpc-url $RPC | n         # 0 = automation off
cast call $V "pendingSchedule()(address)" --rpc-url $RPC               # 0x0 with automation on = nothing booked
N=$(cast call $V "nextRunAt()(uint256)" --rpc-url $RPC | n); date -u -d @$N 2>/dev/null || date -u -r $N
cast balance $V --rpc-url $RPC --ether                                 # native HBAR fuel
```

The same numbers, with drift per leg and the fuel runway worked out, come from the agent plugin: `cd agent && npx tsx examples/direct.ts`.

## 2. Top up fuel

Scheduled runs are paid from the vault's native HBAR. Hedera checks the payer against the whole gas reservation (`scheduledGas` x gas price, about 3.5 HBAR on testnet), and a run is charged what it burns, about 1.3 HBAR. Keep at least the reservation plus a few runs.

```bash
RESERVE=$(( $(cast call $V "scheduledGas()(uint256)" --rpc-url $RPC | n) * $(cast gas-price --rpc-url $RPC) ))
echo "reservation $(cast --from-wei $RESERVE) HBAR"
cast send $V --value 20ether --gas-limit 150000 --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url $RPC --legacy   # 20 HBAR; anyone may send it
cast balance $V --rpc-url $RPC --ether                                 # rose by 20
```

`ether` here means 18-decimal JSON-RPC HBAR. Take fuel back out with `own "withdrawFuel(address,uint256)" $TO 500000000 --gas-limit 200000`: this argument is **tinybar** (8 decimals), so 500000000 is 5 HBAR. Only native HBAR can leave; basket tokens are out of its reach.

## 3. Start, stop and rearm automation

```bash
own "startAutomation(uint256)" 21600 --gas-limit 3000000               # every 6 h; interval 60 s to 60 days
cast call $V "pendingSchedule()(address)" --rpc-url $RPC               # non-zero now
cast call $V "nextRunAt()(uint256)" --rpc-url $RPC | n                 # about now + interval + 0 to 29 s of jitter

own "stopAutomation()" --gas-limit 500000                              # deletes the pending schedule
cast call $V "rebalanceInterval()(uint256)" --rpc-url $RPC | n         # 0
```

`startAutomation` reverts with `AutomationActive` when it is already on and with `BadInterval` outside the range. After `stopAutomation`, the `ScheduleDeleted(schedule, responseCode)` log carries the Schedule Service's answer.

A booking can be lost when the probed seconds are full or the fuel is short. The interval stays on and the vault emits `BookingFailed`. Anyone can book the next run, no owner key needed:

```bash
cast send $V "rearm()" --gas-limit 2000000 --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url $RPC --legacy
```

`rearm` reverts with `NotAutomated` when automation is off and `RunAlreadyPending` when a run is booked. The agent plugin's `book_next_run` makes the same call after checking both and the fuel. The fund page's automation card shows "No run booked" with a button for it.

A rebalance on demand, owner only: `own "rebalance()" --gas-limit 4000000`. It returns `traded=false` when every leg sits inside the drift band. Any other caller gets `OnlyOwnerOrSelf`.

## 4. Rotate the owner

`BasketVault` is OpenZeppelin `Ownable`: the transfer takes effect at once, so check the new address first and prefer an address you control.

```bash
NEW=0x...                                                              # the new owner EOA
own "transferOwnership(address)" $NEW --gas-limit 200000
cast call $V "owner()(address)" --rpc-url $RPC                         # == $NEW
```

The owner is only needed for `startAutomation`, `stopAutomation`, `withdrawFuel` and an on-demand `rebalance`. The scheduled runs are called by the vault itself and keep working through the handover. The share token's treasury and supply key stay the vault. Point the evidence check at the new owner with `EXPECT_OWNER=$NEW bash scripts/verify-evidence.sh`.

## 5. Enable the price guard

The guard compares a stablecoin pool's implied HBAR/USD with Chainlink and refuses deposits and rebalances when they differ by more than the tolerance. It is set in the constructor, so a vault carries it from deployment. Vault D is the deployment that has it on (leg 1, 300 bps); `scripts/verify-evidence.sh` shows its refusal on chain.

```bash
cast call $V "guardLeg()(uint256)" --rpc-url $RPC | n                  # 2^256-1 = off, otherwise the leg index
cast call $V "maxDeviationBps()(uint256)" --rpc-url $RPC | n
```

To run with it on, redeploy (next section) with `GUARD_LEG=1 MAX_DEVIATION_BPS=300`. `GUARD_LEG` is the index in `legs()` of a USD stablecoin (USDC is 1 in the shipped basket). The constructor rejects a guard with `MAX_DEVIATION_BPS=0`. Holders of the old vault leave with `redeem`, which reads no price, and deposit into the new one.

## 6. Redeploy

```bash
# DEPLOYER_PRIVATE_KEY in packages/foundry/.env, funded
GUARD_LEG=1 MAX_DEVIATION_BPS=300 DRIFT_BPS=50 yarn foundry:live      # deploy, initialize, deposit, rebalance, automation, run, redeem
```

Leave the variables out for the defaults (guard off, `DRIFT_BPS=500`, `MAX_TRADE_BPS=2000`). The script prints a HashScan link per step and the new vault address, also written to `packages/foundry/deployments/296.json`. `packages/nextjs/contracts/deployedContracts.ts` is regenerated from it, so restart `yarn next:dev` and the fund page shows the new vault. `VAULT=0x... yarn foundry:live` reruns the flows against a vault that already exists.

Verify the source on Sourcify so anyone can match it to the bytecode:

```bash
yarn foundry:verify:testnet <new vault address> contracts/BasketVault.sol:BasketVault
curl -s https://sourcify.dev/server/v2/contract/296/<new vault address> | jq '{match,runtimeMatch,verifiedAt}'
```

Change nothing under `packages/foundry/contracts` when you only need a different basket: tokens, pools and weights live in `script/Deploy.s.sol`.

## 7. Read the evidence

```bash
bash scripts/verify-evidence.sh
```

It reads the chain and prints PASS or FAIL per claim in `docs/testnet-evidence.md`: bytecode size, owner, share token supply and treasury, dead shares, scheduled runs and how many traded, the Sourcify match, and the guard refusal on vault D. It needs `curl`, `jq` and `cast`, no key. Point it at a different deployment with the overrides in its header, for example:

```bash
EXPECT_OWNER=$NEW MIN_SCHEDULED=12 MIN_TRADED=3 bash scripts/verify-evidence.sh
```

A transaction hash only shows the network accepted a call. After any operation above, read the state it was meant to change: `rebalanceInterval`, `pendingSchedule`, `nextRunAt`, `owner`, `cast balance`, or the log it emits.

## 8. If a leg stops paying out

`redeem` never reads a price, so a stale oracle or a broken pool cannot trap a holder. If a token's issuer freezes the vault or the redeemer, the payout of that token reverts and holds up every other leg. `redeemExcept(shares, skipLegsMask)` leaves it out: bit `i` of the mask skips `legs()[i]`, and the skipped slice stays in the vault for the remaining holders.

```bash
cast send $V "redeemExcept(uint256,uint256)" $SHARES 2 --gas-limit 3000000 --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url $RPC --legacy   # skip leg 1 (USDC)
```

The share allowance to the vault and the redeemer's association with WHBAR and each paid leg come first; the fund page walks a user through both, and the agent plugin's `redeem_shares` checks them.
