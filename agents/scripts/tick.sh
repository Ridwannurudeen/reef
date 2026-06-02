#!/usr/bin/env bash
# Reef receipt loop — publishes one EIP-712-signed strict-sequence receipt per seeded
# AgentVault so the dashboard shows continuous on-chain AI activity and reputation
# accrues (NAV-derived, high-water-mark gated). Receipts are typed-data signed, which
# is impractical in pure bash/cast, so this delegates to the Python receipt loop.
#
# Usage (from repo root, with .env holding PRIVATE_KEY + MANTLE_SEPOLIA_RPC):
#   bash agents/scripts/tick.sh
# Cron (every 10 min):
#   */10 * * * * cd /path/to/reef && python -m agents.scripts.receipt_tick >> tick.log 2>&1
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
[ -f .env ] && { set -a; . ./.env; set +a; }
exec python -m agents.scripts.receipt_tick
