# Reef — Roadmap

Phased plan from "win the hackathon" to "decentralized protocol." Each phase is gated by the one before it. Phases 3 and 4 introduce real custody and execution risk — see the risk note at the bottom.

## Where we are today

- Contracts complete and **verified on Mantlescan**: `AgentIdentity` (ERC-8004), `AgentVault`, `AgentIndex` (ERC-20), `SignalMarket`, `ReputationBond`, `AdapterRegistry`, `Seasons`, `UsdyAdapter`, `MethAdapter`, `MockYieldAdapter`.
- 139 unit tests + 3 fuzz/invariant suites + 4 live-mainnet fork tests passing (146 total, `forge test`). The invariants prove ReputationBond fund-solvency (balance == Σ bonds + Σ open stakes across the full dispute lifecycle) and AgentVault share-conservation + redemption-solvency under fuzzed deposits/withdrawals/donations (the virtual-offset inflation defense).
- **Redeployed & seeded on Mantle Sepolia** (chain 5003, 2026-06-01) with the current post-Phase-3/4 code: AgentIdentity `0x4a037330bd05ca443C25f7b41Ed86BaeB2F43147`, AgentIndex (rINDEX) `0x94ea17aEA0415c86d16c85D788803917BA7E3C60`, AdapterRegistry `0xaf68d79c2f10854c54536cc7a65d6838fa7dd380`; 5 AgentVaults with a reputation-weighted allocation (526/1052/1578/2631/4210 bps) — all Mantlescan-verified. Now at **full on-chain parity** — also deployed + Mantlescan-verified and wired in: `MockYieldAdapter` `0xAD8bD5DE927c144C1110D1fD020009164a4266Fe` (live time-growing NAV on agent 2's vault), `ReputationBond` `0xD93b92165D0FD92640A084FB42D0f35176958d9c` (all 5 agents bonded, index bond-gate active), and `Seasons` `0xaC0949e257b7898a4890761179B6B853e8c69024` (season 0 open, all agents enrolled). UNAUDITED. Dashboard at https://reef.gudman.xyz reads these live.
- **Live site**: https://reef.gudman.xyz (dashboard auto-loads on-chain data) + `/slides.html`.
- **Phase 1 is essentially complete** — only the demo video and final submission remain (both gated on the user).

## Phase 1 — Win the hackathon

Get a complete, honest, demoable submission on Mantle Sepolia.

- **Verify** — `forge test` green; run the fork tests against a Mantle mainnet RPC; final read-through of `SUBMISSION.md` for accuracy.
- **Deploy** — run `script/Deploy.s.sol` with a funded Sepolia key; write real addresses into `deployments/mantle-sepolia.json`.
- **Seed agents** — register reference AgentVaults via `AgentIdentity`, fund them, run the Python reference agents to publish initial EIP-712 receipts.
- **Live receipts** — confirm `ReceiptPublished` events show on the explorer; the dashboard reads NAV/reputation from chain.
- **Scoreboard polish** — `ui/index.html`: AgentIndex stats, leaderboard sorted by reputation, AI-vs-Human twin toggle, deposit/withdraw, rebalance button.
- **Submit** — record the demo video against the live deployment; submit only after explicit approval.

## Phase 2 — Demo Day hardening

Make the live system robust enough to run unattended in front of judges.

- **Real NAV** — ✅ *demonstrated on testnet*: `MockYieldAdapter` (linear-accruing, mints realized yield on recall) is deployed and wired into a live AgentVault on Sepolia, so vault + index NAV now read adapter-reported, time-growing balances instead of simulated deltas (tests cover accrual + yield realization). Remaining: the mainnet path (reconcile share price against real held USDY / mETH yield).
- **Resilience** — ✅ RPC failover (`get_w3` takes a comma-separated RPC list) + retry-with-backoff on idempotent reads (`rpc_read`) in `agents/shared/client.py`; receipt-gap safety is enforced on-chain (strict-sequence `publishReceipt` + fresh `nextReceiptSeq` read each cycle); dashboard degrades gracefully when a feed is down.
- **Operational hygiene** — ✅ health check (`agents/scripts/health.py`: per-vault stale-receipt detection, non-zero exit for cron alerting) + ops runbook (`deploy/RUNBOOK.md`: systemd units, cron keepers, restart/recovery).

## Phase 3 — Protocol

Move from paper-mode demonstration to a real on-chain product. **Introduces real custody and execution risk — audit required before mainnet TVL.**

- **Real execution** — 🟢 *adapter done (mainnet deploy pending)*: `FusionXAdapter` is a real Uniswap-V2 strategy adapter (FusionX V2 on Mantle) — a vault deploys capital into a live market position and its **NAV is the on-chain mark-to-market** of that position, with `recall` selling just enough to honor exact withdrawals. Unit-tested + an end-to-end AgentVault integration test (vault NAV doubles with the position; withdraw recalls from the DEX), **plus a mainnet-fork test against the live FusionX V2 router and real USDC/WMNT pool** (deploy → mark-to-market → partial recall over real reserves/fees/price-impact; router + factory RPC-verified, pinned in `deployments/mantle-mainnet.json`). Intended for deep mainnet pools (testnet pools are too thin to custody real NAV), so the live Sepolia demo still uses `MockYieldAdapter`. (Byreal/RealClaw was evaluated and dropped — Solana/Hyperliquid only, not Mantle/EVM.)
- **More adapters** — ✅ *done (fBTC + USDe + MI4)*: `FbtcAdapter` (Ignition FBTC), `UsdeAdapter` (Ethena USDe) and `Mi4Adapter` (Mantle Index Four, the Securitize basket) added (15 unit tests; real Mantle-mainnet addresses on-chain-verified and pinned in `deployments`), broadening the RWA/yield substrate beyond USDY/mETH. Remaining: mainnet deploy of the adapters (gated on audit + real funds).
- **Mainnet readiness** — 🟡 *scaffolded*: `script/DeployMainnet.s.sol` deploys the full system wired to the **real Ondo USDY** adapter on Mantle mainnet (chain 5000); `deployments/mantle-mainnet.json` pins the real asset addresses. One funded mainnet key away from a real-yield instance — but **unaudited**, so no real TVL until the Phase 4 must-fixes + a third-party audit (`SECURITY.md`).
- **Slashable reputation bonds + dispute layer** — ✅ *done*: `ReputationBond` — operators post a bond (operator verified via ERC-8004 `AgentIdentity`); challengers stake to open a dispute within a window; an arbiter resolves (upheld → slash to challenger; rejected → stake forfeited into the bond; expired → challenger refunded). 9 tests. Deployed + Mantlescan-verified on Sepolia (`0xed8d41bC0569bBe3D9EBe36022B4326FDBFFa323`); full post→dispute→uphold→slash cycle demonstrated on-chain. **Now wired into the index**: `AgentIndex.setReputationBond(bond, minBond)` gates allocation on skin-in-the-game — unbonded/under-bonded (e.g. slashed) agents are excluded from allocation even with positive reputation (test-verified; backward-compatible, gate off by default).
- **Tradeable index token** — ✅ *done*: `AgentIndex` is now a full ERC-20 (transfer/approve/transferFrom + mint/burn Transfer events over the index shares). 7 new tests incl. transferee-can-redeem. Deployed + Mantlescan-verified on Sepolia (`rINDEX`, `0x94FA04326448230aFf7da510ce3E393438cF12cE`); a live share transfer between addresses was demonstrated on-chain. The "S&P 500 of AI yield agents" is now a composable token.

## Phase 4 — Decentralize

Remove trusted operators and open the system up. **Highest custody/execution risk surface — audit and safety primitives are prerequisites for mainnet TVL.**

- **Audit + safety primitives** — 🟢 *code complete (audit pending)*: internal security review done (`SECURITY.md`, 10 findings) — **all addressed in code**: vault-only reputation access control (#1), NAV-derived reputation (#4), reentrancy + CEI (#5), SignalMarket hardening (#8), protocol adapter allowlist (#3 — `AdapterRegistry`), first-deposit/donation inflation (#2 — virtual-offset share math), ReputationBond self-challenge + single-dispute (#6/#10), SafeERC20 (#7 — `SafeTransferLib`). **Safety primitives now added**: circuit breaker (`src/utils/Pausable.sol` — guardian can halt deposits/rebalance/deploy while withdrawals stay open, so a pause never traps funds) and a `withdrawPool` reserve (`AgentIndex.reserveBps` keeps idle liquidity for redemptions). A **fuzz/invariant suite** (`test/invariant/`) now machine-checks the two highest-risk accounting surfaces — ReputationBond fund-solvency and AgentVault redemption-solvency — across thousands of randomized lifecycle sequences (mutation-verified to catch a deliberately broken ledger). **The only remaining prerequisite before mainnet TVL is a third-party audit** — Reef is hackathon code and must not custody real TVL until externally audited.
- **Permissionless onboarding + keeper network** — ✅ *on-chain enablers + runnable keeper done*: agent registration is permissionless (`AgentIdentity.register`); vaults self-list into the index gated on a `ReputationBond` (`AgentIndex.selfListVault` — skin-in-the-game instead of governor curation); `rebalance()` is permissionless, and `agents/scripts/keeper.py` is a runnable keeper (cron one-shot or `--loop` daemon, RPC failover) that drives it. Remaining: a decentralized multi-operator fleet + keeper incentives on top.
- **Rotatable arbiter** — ✅ *done*: `ReputationBond`'s arbiter is no longer immutable — a 2-step `transferArbiter`/`acceptArbiter` handoff lets it move to a multisig/timelock post-deploy.
- **Recurring Human-vs-AI seasons** — ✅ *done*: `src/Seasons.sol` runs time-boxed, on-chain seasons (governor opens; operators enroll an agent on the Human/AI side; reputation is snapshotted at entry and frozen at `finalize`; `scoreOf`/`winner` rank by in-season reputation earned). Replaces the client-side sim.
- **ERC-8004 cross-chain reputation** — ⏳ *deferred (external dependency)*: portable identity/reputation across chains needs a cross-chain messaging layer (e.g. LayerZero/CCIP) and a second chain — not buildable or verifiable on a single testnet, so intentionally left as future work rather than shipped as an untestable stub.

---

## Risk note

Phases 1 and 2 operate in paper-mode with small demo amounts and document an unaudited risk surface. **Phases 3 and 4 carry real smart-contract and custody risk** — real execution, transferable index value, bonded/slashable funds, and permissionless capital. A third-party security audit and the safety primitives in Phase 4 (`withdrawPool`, circuit breakers) are prerequisites before holding meaningful mainnet TVL. Contracts are immutable hackathon code today; nothing in Phases 3-4 should custody user funds on mainnet until audited.
