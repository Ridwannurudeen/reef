# Reef — Roadmap

Phased plan from "win the hackathon" to "decentralized protocol." Each phase is gated by the one before it. Phases 3 and 4 introduce real custody and execution risk — see the risk note at the bottom.

## Where we are today

- Contracts complete and **verified on Mantlescan**: `AgentIdentity` (ERC-8004), `AgentVault`, `AgentIndex`, `SignalMarket`, `UsdyAdapter`, `MethAdapter`.
- 58 unit tests + 2 live-mainnet fork tests passing (`forge test`).
- **Deployed & seeded on Mantle Sepolia** (chain 5003): AgentIdentity `0x75Ddb3Ef346C6C4995536D0368EE7C11160eddac`, AgentIndex `0x9071f05834123ed4F71Ce342f1Af8e0a7077215E`; 5 AgentVaults with a reputation-weighted allocation (526/1052/1578/2631/4210 bps). The Nansen reference agent publishes live on-chain receipts (paper-mode; GLM falls back to a deterministic rule when no key is set).
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

- **Real NAV** — ✅ *demonstrated on testnet*: `MockYieldAdapter` (linear-accruing, mints realized yield on recall) is deployed and wired into a live AgentVault on Sepolia, so vault + index NAV now read adapter-reported, time-growing balances instead of simulated deltas. 66 unit tests incl. accrual/realization. Remaining: the mainnet path (reconcile share price against real held USDY / mETH yield).
- **Resilience** — keeper/indexer retry + backoff, RPC failover, receipt-sequence gap detection, dashboard graceful degradation when a feed is down.
- **Operational hygiene** — monitoring on the keeper, alerting on stalled receipts, a runbook for restarting agents.

## Phase 3 — Protocol

Move from paper-mode demonstration to a real on-chain product. **Introduces real custody and execution risk — audit required before mainnet TVL.**

- **Real execution** — route strategy capital through real venues (e.g. Byreal / RealClaw) instead of simulated decisions.
- **More adapters** — fBTC, MI4 (Securitize basket), USDe, broadening the RWA/yield substrate beyond USDY / mETH.
- **Slashable reputation bonds + dispute layer** — agents post a bond; provably bad or dishonest receipts are slashable; a dispute window lets challengers contest outcomes.
- **Tradeable index token** — make the `AgentIndex` share a fully transferable, composable token (the "S&P 500 of AI yield agents" as a real ERC-20).

## Phase 4 — Decentralize

Remove trusted operators and open the system up. **Highest custody/execution risk surface — audit and safety primitives are prerequisites for mainnet TVL.**

- **Audit + safety primitives** — third-party audit; add `withdrawPool` and circuit breakers (pause, rate limits, NAV-deviation guards) before holding meaningful TVL.
- **Permissionless onboarding + keeper network** — anyone can register an agent; a decentralized keeper network runs rebalances and receipt publishing instead of a single operator.
- **ERC-8004 cross-chain reputation** — make agent identity and reputation portable across chains, not just Mantle.
- **Recurring Human-vs-AI seasons** — run the public leaderboard as repeating, time-boxed seasons with fresh cohorts and resets.

---

## Risk note

Phases 1 and 2 operate in paper-mode with small demo amounts and document an unaudited risk surface. **Phases 3 and 4 carry real smart-contract and custody risk** — real execution, transferable index value, bonded/slashable funds, and permissionless capital. A third-party security audit and the safety primitives in Phase 4 (`withdrawPool`, circuit breakers) are prerequisites before holding meaningful mainnet TVL. Contracts are immutable hackathon code today; nothing in Phases 3-4 should custody user funds on mainnet until audited.
