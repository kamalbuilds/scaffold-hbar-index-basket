#!/usr/bin/env bash
# Runs every BasketVault flow once on Hedera testnet and prints a HashScan link per transaction:
# deploy, initialize, deposit, rebalance, fuel + startAutomation, a network-triggered run, redeem.
#
#   DEPLOYER_PRIVATE_KEY=0x... in packages/foundry/.env (ECDSA, funded from https://portal.hedera.com/faucet)
#   yarn foundry:live            # deploys a fresh vault
#   VAULT=0x... yarn foundry:live # reuses a deployed vault
set -euo pipefail
cd "$(dirname "$0")/.."
set -a
# shellcheck disable=SC1091
source .env
set +a
: "${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY in packages/foundry/.env}"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

RPC=${HEDERA_RPC_URL:-https://testnet.hashio.io/api}
MIRROR=https://testnet.mirrornode.hedera.com/api/v1
DEPOSIT_HBAR=${DEPOSIT_HBAR:-10}
INTERVAL=${INTERVAL:-120}
WHBAR=0x0000000000000000000000000000000000003aD2
SAUCE=0x0000000000000000000000000000000000120f46
USDC=0x0000000000000000000000000000000000001549
ME=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")

# cast prints "123 [1.23e2]"; keep the exact value.
num() { cast call "$@" --rpc-url "$RPC" | awk '{print $1}'; }

send() {
  local label=$1
  shift
  local out status hash
  out=$(cast send --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$RPC" --legacy --json "$@")
  status=$(jq -r .status <<<"$out")
  hash=$(jq -r .transactionHash <<<"$out")
  printf '%-28s %s  gas=%d  https://hashscan.io/testnet/transaction/%s\n' \
    "$label" "$([ "$status" = 0x1 ] && echo OK || echo FAILED)" "$(jq -r .gasUsed <<<"$out")" "$hash"
  [ "$status" = 0x1 ] || exit 1
}

associated() {
  local id
  id=$(printf '0.0.%d' "$1")
  curl -s "$MIRROR/accounts/$ME/tokens?token.id=$id" | jq -e '.tokens | length > 0' >/dev/null
}

associate() {
  if associated "$2"; then
    echo "$1 already associated"
  else
    send "associate $1" "$2" "associate()" --gas-limit 1000000
  fi
}

echo "Deployer $ME, $(cast balance "$ME" --rpc-url "$RPC" --ether) HBAR"

if [ -z "${VAULT:-}" ]; then
  mkdir -p deployments
  forge script script/Deploy.s.sol --rpc-url "$RPC" --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast --slow --legacy >/dev/null
  node scripts-js/generateTsAbis.js >/dev/null
  VAULT=$(jq -r '[to_entries[] | select(.value == "BasketVault") | .key] | last' deployments/296.json)
  echo "Deployed BasketVault $VAULT  https://hashscan.io/testnet/contract/$VAULT"
  # Token creation fee comes out of the value sent; the rest stays in the vault as fuel.
  send "initialize" "$VAULT" "initialize(string,string)" "Index Basket Share" "IBSK" --value 30ether --gas-limit 3000000
fi

SHARE=$(cast call "$VAULT" "shareToken()(address)" --rpc-url "$RPC")
echo "Share token $SHARE  https://hashscan.io/testnet/token/$(printf '0.0.%d' "$SHARE")"

associate share "$SHARE"
send "deposit ${DEPOSIT_HBAR} HBAR" "$VAULT" "deposit(uint256)" 1 --value "${DEPOSIT_HBAR}ether" --gas-limit 4000000
cast call "$VAULT" "holdings()((address,uint256,uint256,uint16)[])" --rpc-url "$RPC"
echo "NAV $(cast call "$VAULT" "nav()(uint256)" --rpc-url "$RPC") tinybar, $(cast call "$VAULT" "navUsd()(uint256)" --rpc-url "$RPC") USD e8"

send "rebalance" "$VAULT" "rebalance()" --gas-limit 4000000

if [ "$(num "$VAULT" "rebalanceInterval()(uint256)")" = 0 ]; then
  send "fuel 10 HBAR" "$VAULT" --value 10ether --gas-limit 100000
  send "startAutomation ${INTERVAL}s" "$VAULT" "startAutomation(uint256)" "$INTERVAL" --gas-limit 3000000
fi
NEXT=$(num "$VAULT" "nextRunAt()(uint256)")
echo "Next run booked for $NEXT, schedule $(cast call "$VAULT" "pendingSchedule()(address)" --rpc-url "$RPC")"

echo "Waiting for the network to run it..."
deadline=$((NEXT + 120))
while [ "$(date +%s)" -lt "$deadline" ]; do
  sleep 15
  now=$(num "$VAULT" "nextRunAt()(uint256)")
  if [ "$now" != "$NEXT" ]; then
    echo "Scheduled run executed; successor booked for $now"
    curl -s "$MIRROR/contracts/$VAULT/results?order=desc&limit=3" |
      jq -r '.results[] | "  \(.result)  from=\(.from)  https://hashscan.io/testnet/transaction/\(.hash)"'
    break
  fi
done
[ "$(num "$VAULT" "nextRunAt()(uint256)")" != "$NEXT" ] || {
  echo "FAILED: no scheduled run by $deadline"
  exit 1
}

associate WHBAR "$WHBAR"
associate SAUCE "$SAUCE"
associate USDC "$USDC"
SHARES=$(num "$SHARE" "balanceOf(address)(uint256)" "$ME")
HALF=$((SHARES / 2))
send "approve shares" "$SHARE" "approve(address,uint256)" "$VAULT" "$HALF" --gas-limit 1000000
send "redeem $HALF shares" "$VAULT" "redeem(uint256)" "$HALF" --gas-limit 3000000
echo "Shares left $(cast call "$SHARE" "balanceOf(address)(uint256)" "$ME" --rpc-url "$RPC")"
