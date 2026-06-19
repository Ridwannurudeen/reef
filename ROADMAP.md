# Reef — Roadmap

Phased plan from "win the hackathon" to "decentralized protocol." Each phase is gated by the one before it. Phases 3 and 4 introduce real custody and execution risk — see the risk note at the bottom.

> Source of truth for addresses is `deployments/mantle-sepolia.json` and the live proof page at https://reef.gudman.xyz/transparency (it reads the chain directly). Addresses below are the current Sepolia core; the full set — adapters, Trust Engine, arena, A2A, allocators — is in the deployments file.
> v2 product architecture is tracked in [`docs/REEF_V2_ARCHITECTURE.md`](docs/REEF_V2_ARCHITECTURE.md).

## Where we are today

Reef is **the risk, authorization, evidence, and capital-allocation layer for autonomous financial agents on Mantle** — and it is live, verified, and reproducible end to end on Mantle Sepolia.

- **Contracts complete and verified on Mantlescan** — core: `AgentIdentity` (ERC-8004), `AgentVault`, `AgentIndex` (ERC-20 `rINDEX`), `AdapterRegistry`, `ReputationBond`, `Seasons`, `SignalMarket`. Trust/risk layer: `ReefGuard` (on-chain policy gate), `ReefGuarded` (integration base) + `@reef/sdk`, `MockProtocol` (reference external caller), `Allocator` (trust-weighted mandates, plus a permissioned/KYC variant). Adapters: `UsdyAdapter`, `MethAdapter`, `MockYieldAdapter`, `FusionXAdapter`, `FbtcAdapter`, `UsdeAdapter`, `Mi4Adapter`. Utilities: `Pausable`, `ReentrancyGuard`, `SafeTransferLib`.
- **263 tests passing, 1 skipped** (`forge test`) — unit + fuzz/invariant tests + live-mainnet fork tests. The invariants machine-check the two highest-risk accounting surfaces (ReputationBond fund-solvency; AgentVault share-conservation + redemption-solvency under fuzzed deposit/withdraw/donation), mutation-verified to catch a deliberately broken ledger.
- **Live core on Mantle Sepolia (chain 5003)** — `AgentIdentity` `0xe6D6320a3647a4b21Abe1654C30E848318D161DD`, `AgentIndex` (rINDEX) `0xf847D0d2c3E4DBED7cd02eB729e48d0aAEfB8C54`, `AdapterRegistry` `0xa19323f17e7c28a3E88d407499595A31e0E28bE4`; 5 reputation-weighted AgentVaults (526/1052/1578/2631/4210 bps) with a live time-growing-NAV adapter, the index bond-gate active, and Season 0 open — all Mantlescan-verified. UNAUDITED.
- **Registered in Mantle's canonical ERC-8004 registries** — every Reef agent is registered in Mantle's *official* ERC-8004 Identity Registry on Sepolia (`0x8004A818BFB912233c491871b3d84c89A494BD9e`, agents #197–#201), with each agent's Trust Score published to the official Reputation Registry. The reputation Reef computes is portable: any Mantle protocol can read it from the canonical registry without touching a Reef contract.
- **Autonomous, data-grounded agents run unattended** — a VPS cron runs source-labelled Z.ai GLM or deterministic-fallback decisions grounded in live signals (CoinGecko price/momentum, Allora ETH prediction, Nansen smart-money flow), publishes matched rationale proofs when the next receipt binds a decision, and executes real swaps on FusionX V2 (a Mantle-native DEX) in both directions. Feeds at `/api/executions.json`, `/api/proofs.json`, `/api/reef.json`, `/api/risk.json`.
- **Live site** — https://reef.gudman.xyz (institutional redesign): landing `/`, dashboard `/app`, on-chain proof `/transparency`, per-agent passport `/agent?id=N`, plus `/slides.html`.
- **Phase 1 is essentially complete** — only the demo video and final submission remain (both gated on the user).

## The Trust Engine (delivered)

The capital-allocation layer on top of identity — built and live on Sepolia:

- **Trust Score** — a prototype 0–100 score + T1-T5 risk tier per agent from four on-chain components (absolute-target reputation 40%, decision-time receipt freshness 20%, drawdown 20%, bond 20%); `/api/scores.json`, surfaced on the leaderboard and passport. Recomputed on-chain inside the Allocator (`trustScoreOf`) so allocation is verifiable, not asserted. This is not yet a calibrated production credit rating.
- **Agent Passport** — `/agent?id=N`: an institutional per-agent profile (Trust Score + breakdown, on-chain stats, ReefGuard verdict, allocation under the active mandate, source-labelled decisions, v2 evidence-envelope receipts, canonical ERC-8004 link).
- **ReefGuard** — a pure-view on-chain policy gate: `canExecuteAction(agentId, action) -> (allowed, reason, amount, sizeBps)` derives size from standard native/ERC-20 calldata and checks registration, reputation, bond, open disputes, asset allowlist, optional TrustOracle score, and action size. `ReefSafeGuard` applies that check at the Safe transaction boundary for configured Safes.
- **Allocator mandates** — LPs deposit one asset; `rebalance()` allocates across the seeded vaults weighted by on-chain Trust Score, but only to agents that clear the active mandate (qualification bar + per-agent concentration cap). A permissioned variant adds a depositor allowlist for compliance-sensitive flows (real on-chain access control; withdrawals never gated).
- **Agent-to-agent economy** — `SignalMarket`: provider agents list priced signals; consumer agents buy them; per-provider and global sales/revenue tracked on-chain (no log scanning). An autonomous trader keeps the volume growing.
- **Benchmarks** — a 5-persona strategy arena scored on directional accuracy, an on-chain head-to-head NAV/reputation duel, an Allora prediction-accuracy benchmark, and a per-strategy ROI/drawdown track record.

## Phase 1 — Win the hackathon

Get a complete, honest, demoable submission on Mantle Sepolia.

- **Verify** — done: `forge test` green (263 passing, 1 skipped); fork tests run against live Mantle mainnet; `SUBMISSION.md` reflects the true live + verified state.
- **Deploy + seed** — ✅ full system deployed and seeded on Sepolia; reference AgentVaults registered via `AgentIdentity`, funded, publishing live EIP-712 receipts; `ReceiptPublished` events visible on Mantlescan; dashboard reads NAV/reputation from chain.
- **Scoreboard polish** — ✅ live leaderboard (Trust Score), AI-vs-Human Seasons, deposit/withdraw, permissionless rebalance, live AI decision feed.
- **Submit** — ⏳ **user-gated**: record the demo video against the live deployment (script ready) and submit on DoraHacks + post the X thread, only after explicit approval.

## Phase 2 — Demo Day hardening

Make the live system robust enough to run unattended in front of judges.

- **Real NAV** — ✅ *demonstrated on testnet*: `MockYieldAdapter` (linear-accruing) is wired into a live vault, so vault + index NAV read adapter-reported, time-growing balances. Remaining: the mainnet path (reconcile share price against real held USDY / mETH yield).
- **Resilience** — ✅ RPC failover + retry-with-backoff on idempotent reads (`agents/shared/client.py`); on-chain receipt-gap safety (strict-sequence `publishReceipt`); dashboard degrades gracefully when a feed is down.
- **Operational hygiene** — ✅ health check (`agents/scripts/health.py`, cron-alertable) + ops runbook (`deploy/RUNBOOK.md`). The full autonomous loop (receipts, keeper, risk manager, snapshots, canonical feedback) runs on cron.

## Phase 3 — Protocol

Move from reference-mode to a real on-chain product. **Introduces real custody and execution risk — audit required before mainnet TVL.**

- **Real execution** — 🟢 *adapter done (mainnet deploy pending)*: `FusionXAdapter` is a real Uniswap-V2 strategy adapter whose **NAV is the on-chain mark-to-market** of a live position, with `recall` selling just enough to honor exact withdrawals. Unit + end-to-end integration tests, plus a mainnet-fork test against the live FusionX V2 router and real USDC/WMNT pool. A standalone DEX-NAV demo vault is live on Sepolia (real AMM mark-to-market, not simulated yield); deep mainnet pools are the production target. (Byreal/RealClaw was evaluated and dropped — Solana/Hyperliquid only.)
- **More adapters** — ✅ *done (fBTC + USDe + MI4)*: `FbtcAdapter`, `UsdeAdapter`, `Mi4Adapter` added (real Mantle-mainnet addresses on-chain-verified and pinned in `deployments`), broadening the RWA/yield substrate beyond USDY/mETH. Remaining: mainnet deploy of the adapters (audit + funds).
- **Mainnet readiness** — 🟡 *scaffolded*: `script/DeployMainnet.s.sol` deploys the full system wired to the real Ondo USDY / rebasing mUSD adapter on Mantle mainnet; `deployments/mantle-mainnet.json` pins the real asset addresses and the Ondo price oracle. One funded mainnet key away — but **unaudited**, and the RWA token itself must be sourced (Ondo KYC mint or a bridge), so no real instance until audited.
- **Slashable reputation bonds + dispute layer** — ✅ *done*: `ReputationBond` (post → challenge → arbiter resolve → slash/forfeit/refund), wired into the index bond-gate; full slash cycle demonstrated on-chain.
- **Tradeable index token** — ✅ *done*: `AgentIndex` is a full ERC-20 (`rINDEX`); a live share transfer was demonstrated on-chain. The reputation-weighted index is composable.

## Phase 4 — Decentralize

Remove trusted operators and open the system up. **Highest custody/execution risk surface — audit and safety primitives are prerequisites for mainnet TVL.**

- **Audit + safety primitives** — 🟢 *code complete (audit pending)*: internal security review (`SECURITY.md`) — all findings addressed in code (vault-only + NAV-derived reputation, reentrancy/CEI, adapter allowlist, first-deposit/donation virtual-offset, ReputationBond self-challenge/single-dispute, SafeERC20). Safety primitives added: circuit breaker (`Pausable` — withdrawals never gated) + `withdrawPool` reserve. A fuzz/invariant suite machine-checks the riskiest accounting. **The only remaining prerequisite before mainnet TVL is a third-party audit.**
- **Permissionless onboarding + keeper** — ✅ *enablers + runnable keeper done*: permissionless registration (`AgentIdentity.register`), bonded self-listing (`AgentIndex.selfListVault`), permissionless `rebalance()` driven by `agents/scripts/keeper.py`. Remaining: a decentralized multi-operator keeper **fleet** + keeper **incentives** (incentives are a tokenomics design decision — reward source/amount/anti-spam — needing direction before building).
- **Rotatable arbiter** — ✅ *done*: 2-step `transferArbiter`/`acceptArbiter` handoff to a multisig/timelock post-deploy.
- **Recurring Human-vs-AI seasons** — ✅ *done*: `Seasons.sol` runs time-boxed on-chain seasons (enroll on Human/AI side, snapshot at entry, freeze at finalize), replacing the client-side sim.
- **Canonical / cross-chain reputation** — 🟢 *canonical done on one chain; cross-chain deferred*: agents are registered in Mantle's official ERC-8004 registries with portable Trust Scores (single-chain, done). True cross-chain portability needs a messaging layer (LayerZero/CCIP) + a second chain, so it stays future work rather than an untestable stub.

## What's actually left

1. **Demo video + submission** (user-gated) — the only thing between Reef and a complete Phase-1 submission.
2. **Third-party audit** (external) — the single gate before any real mainnet TVL.
3. **Mainnet instance** (external) — funded mainnet key + audit + RWA token sourcing; then deploy the real-USDY system + adapters and reconcile real-yield NAV.
4. **Decentralization tail** — multi-operator keeper fleet + keeper incentives (needs tokenomics direction); ERC-8004 cross-chain reputation (needs a bridge + second chain).

Everything else in this roadmap is built, tested, and live on Sepolia.

---

## Risk note

Phases 1 and 2 operate in reference-mode with small demo amounts and document an unaudited risk surface. **Phases 3 and 4 carry real smart-contract and custody risk** — real execution, transferable index value, bonded/slashable funds, and permissionless capital. A third-party security audit and the Phase 4 safety primitives (`withdrawPool`, circuit breakers — both built) are prerequisites before holding meaningful mainnet TVL. Contracts are immutable hackathon code today; nothing in Phases 3–4 should custody user funds on mainnet until audited.
