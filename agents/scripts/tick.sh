#!/usr/bin/env bash
# Reef paper-mode receipt loop.
# Publishes one strict-sequence receipt per seeded AgentVault so the dashboard
# shows continuous on-chain AI activity. NAV deltas are simulated (paper-mode);
# the operator (deployer) signs each receipt, reputation accrues on-chain.
#
# Usage (from repo root, with .env holding PRIVATE_KEY + MANTLE_SEPOLIA_RPC):
#   set -a; . ./.env; set +a
#   bash agents/scripts/tick.sh
# Cron (every 10 min):
#   */10 * * * * cd /path/to/reef && set -a && . ./.env && set +a && bash agents/scripts/tick.sh >> tick.log 2>&1
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CAST="${CAST:-$HOME/.foundry/bin/cast.exe}"
RPC="${MANTLE_SEPOLIA_RPC:?set MANTLE_SEPOLIA_RPC}"
: "${PRIVATE_KEY:?set PRIVATE_KEY}"
DEPLOY="$ROOT/deployments/mantle-sepolia.json"

mapfile -t VAULTS < <(jq -r '.seeded.vaults[].vault' "$DEPLOY" | tr -d '\r')
mapfile -t AGENTS < <(jq -r '.seeded.vaults[].agentId' "$DEPLOY" | tr -d '\r')

for i in "${!VAULTS[@]}"; do
  vault="${VAULTS[$i]}"
  agent="${AGENTS[$i]}"
  seq=$("$CAST" call "$vault" 'nextReceiptSeq()(uint256)' --rpc-url "$RPC" | tr -d '\r ')
  evidence=$("$CAST" keccak "reef-tick-${vault}-${seq}" | tr -d '\r ')
  # paper-mode positive NAV delta (0.1-token granularity), varies by agent + seq
  factor=$(( agent + seq + 1 ))
  navDelta="${factor}00000000000000000"
  payload=$("$CAST" abi-encode 'r(uint256,bytes32,int256,uint64)' "$seq" "$evidence" "$navDelta" 86400 | tr -d '\r ')
  "$CAST" send "$vault" 'publishReceipt(bytes)' "$payload" \
    --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null
  echo "agent $agent vault $vault -> receipt seq $seq (navDelta ${navDelta})"
done
echo "tick complete: ${#VAULTS[@]} receipts published"
