# Reef — Roadmap

Phased plan from "win the hackathon" to "decentralized protocol." Each phase is gated by the one before it. Phases 3 and 4 introduce real custody and execution risk — see the risk note at the bottom.

## Where we are today

- Contracts complete and **verified on Mantlescan**: `AgentIdentity` (ERC-8004), `AgentVault`, `AgentIndex` (ERC-20), `SignalMarket`, `ReputationBond`, `UsdyAdapter`, `MethAdapter`, `MockYieldAdapter`.
- 87 unit tests + 2 live-mainnet fork tests passing (`forge test`).
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

- **Real NAV** — ✅ *demonstrated on testnet*: `MockYieldAdapter` (linear-accruing, mints realized yield on recall) is deployed and wired into a live AgentVault on Sepolia, so vault + index NAV now read adapter-reported, time-growing balances instead of simulated deltas (tests cover accrual + yield realization). Remaining: the mainnet path (reconcile share price against real held USDY / mETH yield).
- **Resilience** — ✅ RPC failover (`get_w3` takes a comma-separated RPC list) + retry-with-backoff on idempotent reads (`rpc_read`) in `agents/shared/client.py`; receipt-gap safety is enforced on-chain (strict-sequence `publishReceipt` + fresh `nextReceiptSeq` read each cycle); dashboard degrades gracefully when a feed is down.
- **Operational hygiene** — ✅ health check (`agents/scripts/health.py`: per-vault stale-receipt detection, non-zero exit for cron alerting) + ops runbook (`deploy/RUNBOOK.md`: systemd units, cron keepers, restart/recovery).

## Phase 3 — Protocol

Move from paper-mode demonstration to a real on-chain product. **Introduces real custody and execution risk — audit required before mainnet TVL.**

- **Real execution** — route strategy capital through real venues (e.g. Byreal / RealClaw) instead of simulated decisions.
- **More adapters** — fBTC, MI4 (Securitize basket), USDe, broadening the RWA/yield substrate beyond USDY / mETH.
- **Mainnet readiness** — 🟡 *scaffolded*: `script/DeployMainnet.s.sol` deploys the full system wired to the **real Ondo USDY** adapter on Mantle mainnet (chain 5000); `deployments/mantle-mainnet.json` pins the real asset addresses. One funded mainnet key away from a real-yield instance — but **unaudited**, so no real TVL until the Phase 4 must-fixes + a third-party audit (`SECURITY.md`).
- **Slashable reputation bonds + dispute layer** — ✅ *done*: `ReputationBond` — operators post a bond (operator verified via ERC-8004 `AgentIdentity`); challengers stake to open a dispute within a window; an arbiter resolves (upheld → slash to challenger; rejected → stake forfeited into the bond; expired → challenger refunded). 9 tests. Deployed + Mantlescan-verified on Sepolia (`0xed8d41bC0569bBe3D9EBe36022B4326FDBFFa323`); full post→dispute→uphold→slash cycle demonstrated on-chain. **Now wired into the index**: `AgentIndex.setReputationBond(bond, minBond)` gates allocation on skin-in-the-game — unbonded/under-bonded (e.g. slashed) agents are excluded from allocation even with positive reputation (test-verified; backward-compatible, gate off by default).
- **Tradeable index token** — ✅ *done*: `AgentIndex` is now a full ERC-20 (transfer/approve/transferFrom + mint/burn Transfer events over the index shares). 7 new tests incl. transferee-can-redeem. Deployed + Mantlescan-verified on Sepolia (`rINDEX`, `0x94FA04326448230aFf7da510ce3E393438cF12cE`); a live share transfer between addresses was demonstrated on-chain. The "S&P 500 of AI yield agents" is now a composable token.

## Phase 4 — Decentralize

Remove trusted operators and open the system up. **Highest custody/execution risk surface — audit and safety primitives are prerequisites for mainnet TVL.**

- **Audit + safety primitives** — 🟡 *in progress*: internal security review done (`SECURITY.md`, 10 findings). **Fixed**: vault-only reputation access control (#1 — `giveFeedback` gated to an agent-designated source; SignalMarket no longer credits reputation), NAV-derived reputation (#4 — `publishReceipt` credits the real on-chain per-share NAV delta, not the operator's claimed figure), reentrancy guards + checks-effects-interactions across vault/index/market (#5), SignalMarket self-dealing + zero-price + guard (#8). Reputation is now both authorized and earned. **Remaining must-fix before mainnet TVL**: rebalance NAV trust + protocol adapter allowlist (#3 — the last reputation-integrity item), first-deposit inflation (#2), ReputationBond dispute/arbiter hardening (#6/#10), SafeERC20 (#7), plus a third-party audit + `withdrawPool`/circuit breakers. A **third-party audit** and `withdrawPool`/circuit breakers remain prerequisites for real TVL.
- **Permissionless onboarding + keeper network** — anyone can register an agent; a decentralized keeper network runs rebalances and receipt publishing instead of a single operator.
- **ERC-8004 cross-chain reputation** — make agent identity and reputation portable across chains, not just Mantle.
- **Recurring Human-vs-AI seasons** — run the public leaderboard as repeating, time-boxed seasons with fresh cohorts and resets.

---

## Risk note

Phases 1 and 2 operate in paper-mode with small demo amounts and document an unaudited risk surface. **Phases 3 and 4 carry real smart-contract and custody risk** — real execution, transferable index value, bonded/slashable funds, and permissionless capital. A third-party security audit and the safety primitives in Phase 4 (`withdrawPool`, circuit breakers) are prerequisites before holding meaningful mainnet TVL. Contracts are immutable hackathon code today; nothing in Phases 3-4 should custody user funds on mainnet until audited.
