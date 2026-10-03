# Testnet evidence

Every transaction below is on Hedera testnet, read from the mirror node and Hashio on 2026-10-03. Each row says what it proves and carries a command that re-checks the post-condition. A transaction hash proves the network accepted a call. The check beside it reads the state the call was supposed to produce.

Vault A and vault B are earlier deployments of `BasketVault`. Their transactions evidence the Hedera mechanics the contract is built on: HTS share mint and burn, in-kind payouts, SaucerSwap V2 swaps and HIP-1215 self-scheduling. The current contract adds an owner-or-self `rebalance`, `redeemExcept`, a permissionless `rearm`, factory-verified pools and a per-swap `maxTradeBps` cap; those paths are covered by the Foundry suite described in [architecture.md](architecture.md#invariants-and-the-tests-that-enforce-them).

`yarn foundry:live` runs the same flows from a fresh deploy and prints a HashScan link per step.

## Setup for every command

```bash
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
RPC=https://testnet.hashio.io/api
M=https://testnet.mirrornode.hedera.com/api/v1
V=0x1af34177Be9371490e96cE5420C71D8D95c97EaB       # vault B, contract 0.0.10837826
VID=0.0.10837826
SHARE=0x0000000000000000000000000000000000A55f44   # IBSK, token 0.0.10837828
POOL_USDC=0x914B98992d7eD602D1f5d9084ECe8160Fc0e741a
n() { awk '{print $1}'; }                           # cast prints "123 [1.23e2]"; keep the exact value

# gas, result, block and charged fee (tinybar, 1 HBAR = 1e8) of one transaction hash
tx() {
  local ts; ts=$(curl -s "$M/contracts/results/$1" | jq -r .timestamp)
  curl -s "$M/contracts/results/$1" | jq -c '{gas_used,result,block_number,amount}'
  curl -s "$M/transactions?timestamp=$ts" | jq -c '.transactions[0]|{name,result,scheduled,charged_tx_fee}'
}

# event logs of a contract by event signature; the mirror needs a timestamp range when it filters by topic
logs() {
  curl -s "$M/contracts/${2:-$VID}/results/logs?topic0=$(cast keccak "$1")&order=asc&limit=100&timestamp=gte:1791006000&timestamp=lte:1791099999"
}
```

| Actor | EVM address | Hedera id |
| --- | --- | --- |
| Vault B (canonical, drift band 0.5%, 6h automation) | `0x1af34177Be9371490e96cE5420C71D8D95c97EaB` | [0.0.10837826](https://hashscan.io/testnet/contract/0x1af34177Be9371490e96cE5420C71D8D95c97EaB) |
| IBSK share token of vault B | `0x0000000000000000000000000000000000A55f44` | [0.0.10837828](https://hashscan.io/testnet/token/0.0.10837828) |
| Owner EOA (`owner()` of both vaults) | `0x1565aF2C2eF52b4A89180684a47C5260c716AbD1` | 0.0.4729347 |
| Wallet used for the UI flows | `0x7010221487DbB73Bf5417b11EC07E1b24b6aB013` | 0.0.10838073 |
| Vault A (first run, 5% band, 120s interval) | `0x3eb867B0CB445cFe0D5a4E6A8748D3d1cfe2E769` | 0.0.10837642 |

Basket of vault B: 40% WHBAR, 30% SAUCE, 30% USDC. `scheduledGas` 4,000,000, slippage 3%, Chainlink staleness limit 25h.

## 1. Setup of vault B

| Step | What it proves | Gas | Fee (HBAR) | Link |
| --- | --- | --- | --- | --- |
| Deploy | The constructor accepts two SaucerSwap V2 pools paired with WHBAR and weights that leave 40% for WHBAR | 3,663,119 | 3.0770 | [tx](https://hashscan.io/testnet/transaction/0x33c6379ef484fe18a3dd354445e9d49dfb559d271cab681618c02e9e1bc94df0) |
| `initialize` | The vault associates WHBAR, SAUCE and USDC and creates the HTS share token with itself as treasury and supply key, in one call | 2,319,199 | 13.7212 | [tx](https://hashscan.io/testnet/transaction/0x48be3fac85e38fd15d40c3c5ff4b8a6efe3fdb947b2d1a22f70e3b82c7f101ee) |
| Owner associates IBSK | The depositor-side HIP-719 association that precedes the first deposit | 726,488 | 0.6102 | [tx](https://hashscan.io/testnet/transaction/0x411622c384cdd17646ba8e05a3d7beb5680156e77ac9255f7c929d8a4a8f29a8) |

Re-check:

```bash
# the share token exists, the vault is its treasury, 8 decimals
cast call $V "shareToken()(address)" --rpc-url $RPC
curl -s $M/tokens/0.0.10837828 | jq '{symbol,decimals,treasury_account_id,supply_type,memo}'

# the vault holds the three basket tokens as associated tokens
curl -s $M/accounts/$VID/tokens | jq -c '.tokens[]|.token_id'

# gas, result and fee of the initialize transaction
tx 0x48be3fac85e38fd15d40c3c5ff4b8a6efe3fdb947b2d1a22f70e3b82c7f101ee
```

Expected: `treasury_account_id` is `0.0.10837826`, `symbol` is `IBSK`, and the vault lists tokens `0.0.5449`, `0.0.15058`, `0.0.1183558` and `0.0.10837828`.

## 2. Deposits

| Step | What it proves | Gas | Fee (HBAR) | Link |
| --- | --- | --- | --- | --- |
| First deposit, 20 HBAR | 20 HBAR becomes 19.95683597 IBSK: 6 WHBAR bought 239.400499 SAUCE and 6 WHBAR bought 11.37978 USDC at SaucerSwap, 100,000 shares locked as `DEAD_SHARES`. Includes the one-time HTS approval of WHBAR to the router | 1,137,106 | 0.9552 | [tx](https://hashscan.io/testnet/transaction/0x166dbdf605c53460968ffec8becd0ee5ed30eeb0e395bfb3b2b1708ed5beb102) |
| Rebalance, nothing drifted | `rebalance()` is a no-op inside the band and reports `traded=false` | 121,408 | 0.1020 | [tx](https://hashscan.io/testnet/transaction/0xdd9beb6769ce51dde656f632de15f580259bf858d332cdd40a0a0a52df2be062) |

The share arithmetic of the first deposit is worked through in [architecture.md](architecture.md#worked-example-the-first-deposit-of-vault-b).

Re-check:

```bash
# Deposited(account, hbarIn, valueAdded, shares), decoded
logs "Deposited(address,uint256,uint256,uint256)" | jq -r '.logs[]|"\(.timestamp) \(.data)"' |
  while read ts d; do echo "$ts $(cast abi-decode 'f()(uint256,uint256,uint256)' $d | tr '\n' ' ')"; done
# 1791007474.118220104 2000000000 1995783597 1995683597
# 1791009633.195828683 500000000 499061415 499048386      (the UI deposit, section 5)

# the vault itself holds the 100,000 dead shares
cast call $SHARE "balanceOf(address)(uint256)" $V --rpc-url $RPC

# current holdings: token, balance, value in WHBAR tinybar, target weight in bps
cast call $V "holdings()((address,uint256,uint256,uint16)[])" --rpc-url $RPC
```

The share ledger balances to the unit: the three holders below sum to `totalSupply()`.

```bash
tot=$(cast call $SHARE "totalSupply()(uint256)" --rpc-url $RPC | n); sum=0
for a in 0x1565aF2C2eF52b4A89180684a47C5260c716AbD1 0x7010221487DbB73Bf5417b11EC07E1b24b6aB013 $V; do
  b=$(cast call $SHARE "balanceOf(address)(uint256)" $a --rpc-url $RPC | n); echo "$a $b"; sum=$((sum+b))
done
echo "sum=$sum totalSupply=$tot"
# sum=1296990185 totalSupply=1296990185
```

## 3. Redeems

| Step | What it proves | Gas | Fee (HBAR) | Link |
| --- | --- | --- | --- | --- |
| Approve shares | The HTS allowance the redeem pulls against. An approval made by an account costs about 727k gas | 727,032 | 0.6107 | [tx](https://hashscan.io/testnet/transaction/0xd0577d8130e84f3f56684eab0fde805f6c70fb3758ebab502efc4b85d1add0c8) |
| Redeem 9.9784 IBSK | Burns the shares and pays 3.9998 WHBAR, 119.6943 SAUCE and 5.6896 USDC in kind, with no price read | 142,321 | 0.1195 | [tx](https://hashscan.io/testnet/transaction/0x4c33133b1fb8caf8d9e3f8b28a68543f1edef4551dd8bc83b9a51af1e5534328) |

The payout equals `balance * shares / supply` for every token. Redeem burned 997,841,798 of a 1,995,783,597 supply (49.9975%) while the vault held 800,000,000 WHBAR, 239,400,499 SAUCE and 11,379,780 USDC raw units:

| Token | Held | Held x 997,841,798 / 1,995,783,597 | Paid on chain |
| --- | --- | --- | --- |
| WHBAR | 800,000,000 | 399,979,957 | 399,979,957 |
| SAUCE | 239,400,499 | 119,694,251 | 119,694,251 |
| USDC | 11,379,780 | 5,689,604 | 5,689,604 |

```bash
logs "Redeemed(address,uint256,uint256,uint256[])" | jq -r '.logs[]|"\(.timestamp) \(.data)"' |
  while read ts d; do echo "$ts $(cast abi-decode 'f()(uint256,uint256,uint256[])' $d | tr '\n' ' ')"; done
# 1791007711.214826886 997841798 399979957 [119694251, 5689604]
# 1791009752.836819994 200000000 80076975 [23985553, 1143176]   (the UI redeem, section 5)

# the pro rata formula, evaluated in the shell against the first redeem
python3 -c "print(800000000*997841798//1995783597, 239400499*997841798//1995783597, 11379780*997841798//1995783597)"
```

## 4. Automation of vault B: runs the network started

| Step | What it proves | Gas | Fee (HBAR) | Link |
| --- | --- | --- | --- | --- |
| Fuel 10 HBAR | Native HBAR sent to the vault is fuel for scheduled runs, not basket value | 21,055 | 0.0177 | [tx](https://hashscan.io/testnet/transaction/0x1441846009e435af9371bbf9073a1e46e496574c4a5d7194600d8b4919c2bbbb) |
| `startAutomation(180)` | The vault books its first schedule through the Schedule Service at 0x16b: `RunBooked` and `AutomationStarted(180)` | 1,509,051 | 1.2676 | [tx](https://hashscan.io/testnet/transaction/0x7923a7852a6441465dbd9a16f5a7f3ae3a890d2f205b39791951615aba745f6f) |
| `stopAutomation` | Deletes the pending schedule and zeroes `nextRunAt` | 99,452 | 0.0835 | [tx](https://hashscan.io/testnet/transaction/0xea8aef1bc9e216162c4c0b38d3595b351e2627115c269d879ef2fc43edbdaaf4) |
| Fuel 60 HBAR | Funds the long-interval runway | 21,055 | 0.0177 | [tx](https://hashscan.io/testnet/transaction/0xf1b6c00151690cc22132b7018f094fbd887c9c48dabf67228ef741c3fc453ece) |
| `startAutomation(21600)` | The production 6h cadence is armed; `nextRunAt` is 1791029735 | 1,509,063 | 1.2676 | [tx](https://hashscan.io/testnet/transaction/0x96b05647da9cdb7620227139ceb0bf20d2c7d8625b692e0ce7f1e093ee81a66f) |

### Three scheduled executions, no human transaction

Hedera ran the vault's own schedules at their expiry second. The pool was moved by the owner EOA between runs so the basket had something to correct.

| Run | Schedule | Executed at (consensus) | Result | Gas (limit 4,000,000) | Charged to the vault (HBAR) | Link |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 0.0.10837837 | 1791007678.005532228 | `ScheduledRun(traded=false)`, basket inside the band | 1,553,578 | 1.3050 | [tx](https://hashscan.io/testnet/transaction/1791007678.005532228) |
| setup | owner EOA swaps 150 WHBAR for USDC on the WHBAR/USDC pool, tick 39629 to 39970 (USDC up 3.5%) | | | 139,879 | 0.1175 | [tx](https://hashscan.io/testnet/transaction/0x05e4db83cdb523b4b46760697cf292029ea833fa6caea288e37d5c8fb55e7509) |
| 2 | 0.0.10837869 | 1791007856.060140104 | `ScheduledRun(traded=true)`, USDC overweight, SELL: 0.128852 USDC for 0.06991741 WHBAR | 2,370,784 | 1.9915 | [tx](https://hashscan.io/testnet/transaction/1791007856.060140104) |
| back | owner EOA swaps USDC back, tick 39970 to 39602 | | | 143,683 | 0.1207 | [tx](https://hashscan.io/testnet/transaction/0x821077eaa53e28cb1c9b6eb32f263e7f39e36ffc2c495046aed48e6c58de408c) |
| 3 | 0.0.10837889 | 1791008035.035022208 | `ScheduledRun(traded=true)`, USDC underweight, BUY: 0.07639555 WHBAR for 0.145183 USDC | 1,661,662 | 1.3958 | [tx](https://hashscan.io/testnet/transaction/1791008035.035022208) |

Run 2 costs 0.6 HBAR more than run 3 because it carries the one-time HTS approval of USDC to the router (the run's child records include a `CRYPTOAPPROVEALLOWANCE`). Afterwards the allowance reads `totalSupply() - 128852`, the supply minus what run 2 sold.

#### The basket before and after each run

`holdings()` and the pool's `slot0()` read at the block before and the block of each execution (block numbers come from the mirror):

| Run | Block | USDC pool tick | WHBAR / SAUCE / USDC weight | NAV (HBAR) |
| --- | --- | --- | --- | --- |
| 2 before | 41293211 | 39970 | 39.65% / 29.66% / 30.70% | 10.0893 |
| 2 after | 41293212 | 39970 | 40.34% / 29.66% / 30.00% | 10.0890 |
| 3 before | 41293298 | 39602 | 40.78% / 29.98% / 29.23% | 9.9799 |
| 3 after | 41293299 | 39602 | 40.02% / 29.98% / 30.00% | 9.9797 |

The band is 0.5%: USDC sat 0.70 points over target before run 2 and 0.77 points under before run 3, and each run returned it to 30.00%. The two runs trade in opposite directions on the same leg.

```bash
# the three executed schedules of vault B, with the traded flag of each run
logs "ScheduledRun(bool)" | jq -r '.logs[]|"\(.timestamp) traded=\(.data|endswith("1"))"'
# 1791007678.005532228 traded=false
# 1791007856.060140104 traded=true
# 1791008035.035022208 traded=true

# the swap each trading run made (tokenIn, tokenOut indexed; amountIn, amountOut in the data)
logs "Swapped(address,address,uint256,uint256)" | jq -r '.logs[]|"\(.timestamp) \(.data)"' | sed -n 3,4p |
  while read ts d; do echo "$ts $(cast abi-decode 'f()(uint256,uint256)' $d | tr '\n' ' ')"; done
# 1791007856.060140104 128852 6991741       (USDC raw in, WHBAR raw out)
# 1791008035.035022208 7639555 145183       (WHBAR raw in, USDC raw out)

# NAV before and after each run from the Rebalanced event (WHBAR tinybar)
logs "Rebalanced(uint256,uint256,bool)" | jq -r '.logs[]|"\(.timestamp) \(.data)"' |
  while read ts d; do echo "$ts $(cast abi-decode 'f()(uint256,uint256,bool)' $d | tr '\n' ' ')"; done

# basket state at the blocks around run 2 (use block_number from `tx <hash>`)
for b in 41293211 41293212; do
  cast call $V "holdings()((address,uint256,uint256,uint16)[])" --block $b --rpc-url $RPC
  cast call $POOL_USDC "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)" --block $b --rpc-url $RPC | sed -n 2p
done

# setup swap: the pool tick moves at the swap's own block
bn=$(cast receipt 0x05e4db83cdb523b4b46760697cf292029ea833fa6caea288e37d5c8fb55e7509 blockNumber --rpc-url $RPC)
for b in $((bn-1)) $bn; do cast call $POOL_USDC "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)" --block $b --rpc-url $RPC | sed -n 2p; done
# 39629 then 39970
```

### How to see that the network started a run

Three records agree, none of them a transaction a person signed.

**1. The schedule record names the vault as payer and carries the execution timestamp.**

```bash
curl -s $M/schedules/0.0.10837869 | jq '{schedule_id,creator_account_id,payer_account_id,consensus_timestamp,expiration_time,executed_timestamp,wait_for_expiry}'
```

```json
{
  "schedule_id": "0.0.10837869",
  "creator_account_id": "0.0.7314364",
  "payer_account_id": "0.0.10837826",
  "consensus_timestamp": "1791007678.005532229",
  "expiration_time": "1791007856.000000000",
  "executed_timestamp": "1791007856.060140104",
  "wait_for_expiry": true
}
```

`payer_account_id` is the vault. The schedule was created at `1791007678.005532229`, one nanosecond after run 1 executed, by run 1 itself: each run books the next. `executed_timestamp` is the consensus timestamp of run 2. `creator_account_id` is the account of the transaction id the whole chain inherits (`0.0.7314364-1791007493-460025934`, the `startAutomation` transaction), and the first schedule of the chain, `0.0.10837837`, shows the owner account `0.0.4729347`.

**2. The executed transaction is flagged `scheduled` and its fee is debited from the vault.**

```bash
curl -s "$M/transactions?timestamp=1791007856.060140104" |
  jq '.transactions[0]|{consensus_timestamp,name,result,scheduled,charged_tx_fee,debited:[.transfers[]|select(.amount<-100000000)]}'
```

Expected: `name` `CONTRACTCALL`, `result` `SUCCESS`, `scheduled` `true`, `charged_tx_fee` `199145856`, and the only large debit is `0.0.10837826` (the vault) for `-199145856`. Every execution of vault B is listed by one filter:

```bash
curl -s "$M/transactions?account.id=$VID&timestamp=gte:1791007600&timestamp=lte:1791008300&order=asc&limit=100" |
  jq -r '.transactions[]|select(.scheduled==true)|"\(.consensus_timestamp) \(.name) \(.result) fee=\(.charged_tx_fee)"'
# 1791007678.005532228 CONTRACTCALL SUCCESS fee=130500552
# 1791007856.060140104 CONTRACTCALL SUCCESS fee=199145856
# 1791008035.035022208 CONTRACTCALL SUCCESS fee=139579608
```

**3. No account signed anything at those timestamps.** The owner EOA's own transaction list for the same window contains its swaps, approve and redeem, and nothing at the three execution timestamps. The control is the same query one window earlier, which returns the setup transactions, so an empty answer cannot come from a broken filter.

```bash
# owner EOA activity from 1791007600 to 1791008100: approve, redeem, setup swap, swap back. Nothing at ...678, ...856 or ...035
curl -s "$M/transactions?account.id=0.0.4729347&timestamp=gte:1791007600&timestamp=lte:1791008100&order=asc" |
  jq -r '.transactions[]|select(.name=="ETHEREUMTRANSACTION")|"\(.consensus_timestamp) \(.name)"'
# 1791007703.505467586, 1791007711.214826886, 1791007736.375866104, 1791007743.095360104,
# 1791007747.814828755, 1791007941.374871104, 1791007945.994786104

# control: the same filter around startAutomation returns the owner's transactions
curl -s "$M/transactions?account.id=0.0.4729347&timestamp=gte:1791007440&timestamp=lte:1791007520&order=asc" |
  jq -r '.transactions[]|select(.name=="ETHEREUMTRANSACTION")|.consensus_timestamp'

# the vault's call list holds only transactions that carry a `from` EOA; the three executions are absent from it
curl -s "$M/contracts/$VID/results?limit=100&order=asc" | jq -r '.results[].timestamp' | grep -c -e 1791007678 -e 1791007856 -e 1791008035
# 0
```

Each execution also carries exactly one `SCHEDULECREATE` child, the successor, so a run never books twice:

```bash
curl -s "$M/transactions?timestamp=gte:1791007856.000000000&timestamp=lt:1791007857.000000000&limit=100" |
  jq '[.transactions[]|select(.transaction_id=="0.0.7314364-1791007493-460025934" and .name=="SCHEDULECREATE")]|length'
# 1
```

A call to the entry point from any account is refused. `runScheduled()` is reachable only with `msg.sender == address(this)`, which is how the network calls it:

```bash
cast call $V "runScheduled()" --rpc-url $RPC
# execution reverted ... data: "0x14d4a4e8"      (OnlySelf())
cast sig "OnlySelf()"
# 0x14d4a4e8
```

### The chain keeps advancing

`RunBooked` lists every schedule the vault has booked: id, the second it was booked and the second it will run. On vault B, which books without the booking offset the current contract adds, successive expiries differ by `interval - 2` seconds because a scheduled call reads a consensus clock about two seconds behind (see [hedera-gotchas.md](hedera-gotchas.md#scheduled-calls-read-a-clock-about-two-seconds-early)).

```bash
logs "RunBooked(address,uint256)" | jq -r '.logs[]|"\(.timestamp) \(.topics[1]) \(.data)"' |
  while read ts s e; do echo "booked_at=$ts schedule=0.0.$(cast to-dec $s) expiry=$(cast to-dec $e)"; done
# booked_at=1791007499.979120104 schedule=0.0.10837837 expiry=1791007678
# booked_at=1791007678.005532228 schedule=0.0.10837869 expiry=1791007856
# booked_at=1791007856.060140104 schedule=0.0.10837889 expiry=1791008035
# booked_at=1791008035.035022208 schedule=0.0.10837928 expiry=1791008213   (deleted by stopAutomation)
# booked_at=1791008136.244806658 schedule=0.0.10837952 expiry=1791029735   (6h cadence, pending)

# the pending run: the contract and the mirror agree
cast call $V "nextRunAt()(uint256)" --rpc-url $RPC | n
cast call $V "pendingSchedule()(address)" --rpc-url $RPC
curl -s $M/schedules/0.0.10837952 | jq '{payer_account_id,expiration_time,executed_timestamp,deleted}'
```

`nextRunAt` equals the schedule's `expiration_time`. When the second passes, `executed_timestamp` fills in, a `RunBooked` for the successor appears and `nextRunAt` advances by 21600.

The deleted schedule shows what `stopAutomation` does on the network:

```bash
curl -s $M/schedules/0.0.10837928 | jq '{deleted,executed_timestamp,expiration_time}'
# {"deleted": true, "executed_timestamp": null, "expiration_time": "1791008213.000000000"}
```

## 5. UI-driven wallet flows

The Next.js app drove a wallet (0.0.10838073, unlimited automatic token association) through a deposit and a redeem. The previews on screen match the chain.

| Step | What it proves | Gas | Fee (HBAR) | Link |
| --- | --- | --- | --- | --- |
| Deposit 5 HBAR | UI estimate 4.9999 IBSK, minimum 4.8499 after 3% slippage; the vault minted 4.99048386 IBSK. Router already approved, so 429k gas against 1.14M for the first deposit | 429,187 | 0.3605 | [tx](https://hashscan.io/testnet/transaction/0x2fcdac89a903e2bd9377df92aea9e9c447bd2d2a800a69e059b3f16a0c588d5a) |
| Redeem 2 IBSK (approve, then redeem) | Paid 0.80076975 WHBAR, 23.985553 SAUCE and 1.143176 USDC, exactly the preview the UI showed | 142,309 | 0.1195 | [tx](https://hashscan.io/testnet/transaction/0x156e6b815067557710804a9c1d8f824cdbbf74417857377057063c8cb7eb8feb) |

```bash
tx 0x2fcdac89a903e2bd9377df92aea9e9c447bd2d2a800a69e059b3f16a0c588d5a
tx 0x156e6b815067557710804a9c1d8f824cdbbf74417857377057063c8cb7eb8feb

# the wallet's share balance: 499048386 minted - 200000000 redeemed
cast call $SHARE "balanceOf(address)(uint256)" 0x7010221487DbB73Bf5417b11EC07E1b24b6aB013 --rpc-url $RPC
# 299048386

# the wallet associated the share token and the three basket tokens on first receipt
curl -s $M/accounts/0.0.10838073/tokens | jq -c '.tokens[]|{token_id,automatic_association}'
```

## 6. Vault A: the loop and its retirement

Vault A ran first, with a 5% band and a 120 second interval, to prove the loop before vault B. Its share token is 0.0.10837646.

| Step | What it proves | Gas | Fee (HBAR) | Link |
| --- | --- | --- | --- | --- |
| `initialize` | Token creation fee included in the 13.7 HBAR | 2,319,199 | 13.7423 | [tx](https://hashscan.io/testnet/transaction/0xc1c18652226a369830e706b5ef79aa4f1e2600c9c4a80127b2a6bde65c1fa2be) |
| First deposit, 10 HBAR | Buys SAUCE and USDC, mints shares, approves WHBAR to the router once | 1,136,144 | 0.9544 | [tx](https://hashscan.io/testnet/transaction/0xf7a97c2c972c3e8a02a010828b68d46af23fa869bfc0295dc6b15c1a768f438c) |
| Rebalance, no-op | Inside the band | 121,408 | 0.1020 | [tx](https://hashscan.io/testnet/transaction/0x804c6b279f3671b73b96987f583bad81fa74262005969a9f3a8ffb0ce8460a0b) |
| Fuel 10 HBAR | Native fuel | 21,055 | 0.0177 | [tx](https://hashscan.io/testnet/transaction/0x4eeb06e4bf50256b1e0b7516716360ce78ef23b34bbd34c8c5a3556261f9096b) |
| `startAutomation(120)` | First schedule booked | 1,509,051 | 1.2676 | [tx](https://hashscan.io/testnet/transaction/0x869b3a4c2f8cb719535ff5621ddca8a5455972f434d1c847b0f809f0a1882e89) |
| Second deposit, 5 HBAR | The router is already approved, so no approval cost: 429k gas against 1.14M | 429,078 | 0.3604 | [tx](https://hashscan.io/testnet/transaction/0x85e4c5a2458a0d34080db22133b181eea05fbd563266bb9f07b78af0b5e50ce7) |
| Redeem | Pays out in kind | 142,321 | 0.1195 | [tx](https://hashscan.io/testnet/transaction/0xc323f9422034df8302ec965d680e7ae5cbbe790b51f41ad94db84d89d33cdfcb) |
| `stopAutomation` | Includes `deleteSchedule` of the pending run | 99,452 | 0.0835 | [tx](https://hashscan.io/testnet/transaction/0x513e8e45a824055abf395f4393a8a56565103d98a085805e1a32dd52897a43a8) |
| `withdrawFuel` | Returns the unspent native HBAR to the owner | 31,143 | 0.0262 | [tx](https://hashscan.io/testnet/transaction/0x17e4c2680b8a0933b7614d3225fd9b0b7c8343d828d96241d565881c40404ac2) |

### 13 network-triggered runs

The mirror lists 13 `ScheduledRun` events for vault A, from `1791006680.001599104` to `1791008100.014769208`, one every 118 seconds, each a `CONTRACTCALL` with result `SUCCESS` and `scheduled=true`, each charged 130,500,552 tinybar (1.3050 HBAR) to the vault. The first two are [1791006680.001599104](https://hashscan.io/testnet/transaction/1791006680.001599104) (schedule 0.0.10837660) and [1791007035.034493895](https://hashscan.io/testnet/transaction/1791007035.034493895) (schedule 0.0.10837725).

```bash
VA=0.0.10837642
# 13 ScheduledRun events, and the fee and flag of the transaction behind each
logs "ScheduledRun(bool)" $VA | jq '.logs|length'
logs "ScheduledRun(bool)" $VA | jq -r '.logs[].timestamp' | while read ts; do
  curl -s "$M/transactions?timestamp=$ts" | jq -r '.transactions[0]|"\(.consensus_timestamp) \(.result) scheduled=\(.scheduled) fee=\(.charged_tx_fee) payer=\(.transfers[]|select(.amount<-100000000)|.account)"'
done

# the schedule record of the first run: payer is vault A
curl -s $M/schedules/0.0.10837660 | jq '{schedule_id,payer_account_id,executed_timestamp,expiration_time}'
# {"schedule_id":"0.0.10837660","payer_account_id":"0.0.10837642","executed_timestamp":"1791006680.001599104","expiration_time":"1791006680.000000000"}
```

Retirement is on chain too: after `stopAutomation` the last schedule is deleted and no `ScheduledRun` follows `1791008100.014769208`.

```bash
logs "AutomationStopped()" $VA | jq -r '.logs[].timestamp'
# 1791008106.141053086
```

## 7. State right now

```bash
cast call $V "holdings()((address,uint256,uint256,uint16)[])" --rpc-url $RPC
cast call $V "nav()(uint256)" --rpc-url $RPC | n             # WHBAR tinybar
cast call $V "navUsd()(uint256)" --rpc-url $RPC | n          # USD, 8 decimals
cast call $V "sharePriceUsd()(uint256)" --rpc-url $RPC | n   # USD per whole share, 8 decimals
cast call $V "rebalanceInterval()(uint256)" --rpc-url $RPC | n   # 21600
cast call $V "driftBps()(uint256)" --rpc-url $RPC | n            # 50
curl -s $M/accounts/$VID | jq .balance.balance                 # fuel, tinybar
```

Fuel is 83.53 HBAR at the last read, the last measured run cost 1.396 HBAR, and the runway is about 58 runs (formula in [hedera-gotchas.md](hedera-gotchas.md#the-payer-needs-the-full-gas-reservation-not-the-gas-a-run-burns)).
