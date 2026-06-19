# Reef — 2-Minute Demo Video Script

**Project:** Reef — the transaction-risk gate and proof layer for autonomous financial agents on Mantle.
**Hackathon:** Mantle Turing Test 2026 — AI × RWA track.
**Award targeted:** 20 Project Deployment Award (>= 2 min, walks the core use case + shows verifiable on-chain *writes*, not just dashboards).
**Live:** https://reef.gudman.xyz · proof page https://reef.gudman.xyz/transparency · dApp https://reef.gudman.xyz/app

**The thesis in one line:** "Can this exact agent execute this exact transaction right now?" Reef makes that answer an on-chain primitive: policy verdict, signed receipt, reputation signal, and a TrustOracle any Mantle protocol can read.

**Why this script is sharp:** every beat serves one takeaway — Reef is not another yield bot; it is the guardrail between autonomous agents and capital. Read-only views are supporting context only.

Target runtime: **2:05–2:25.**

---

## Shot-by-shot

| Time | [SCREEN] | [VOICEOVER] |
|---|---|---|
| **0:00-0:12** | Landing page `reef.gudman.xyz`. Pan the hero and live status pills, but do not dwell on index metrics. | "Autonomous agents can move money, but wallets and protocols still need one hard answer before capital moves: should this exact transaction be allowed right now? Reef is that risk gate on Mantle." |
| **0:12-0:24** | Cut to `/app`. Hover one agent's Trust Score badge and show the ReefGuard status. | "Each agent has an ERC-8004 identity, posted bond, decision history, and a TrustOracle score. The score is not a production credit rating; it is the input Reef uses to make policy decisions visible and verifiable." |
| **0:24-0:30** | Lower-third over the leaderboard. | "Honest scope: this is a hackathon prototype on testnet, with a demo-scale mainnet custody proof. The product claim is authorization and evidence, not proven alpha." |
| **HERO 1 — 0:30-0:55** | **Gate the proposed action.** Open `reef.gudman.xyz/api/proofbound.json`. Highlight one agent's `action`, `guard.allowed`, `guard.reason`, `sizeBps`, `moveStatus`, and `receiptTx`. Open the receipt tx on Sepolia Mantlescan. | "Here is the live loop. The agent proposes an action, ReefGuard evaluates it before execution, and the result is written into a receipt. In this run the action is allowed with reason `ok`; oversized actions are blocked and surfaced with the exact policy reason." |
| **HERO 2 — 0:55-1:25** | **Verify the proof.** Open `reef.gudman.xyz/api/proofs.json`. Pick `proofStatus: "matched"`, highlight `reasoning`, `rationaleHash`, `evidenceHash`, and `txHash`. Run or show `python -m agents.scripts.verify_proof`, then open the vault's `lastReceiptEvidenceHash` on Mantlescan. | "Do not trust the dashboard. This verifier recomputes the published rationale hash and checks it against the on-chain vault receipt. If a v2 evidence envelope is present, the same verifier checks the full envelope hash instead. Either way, the page cannot invent a proof after the fact." |
| **HERO 3 — 1:25-1:55** | **Judge-triggered writes on the live dApp.** On `/app`, connect wallet and auto-switch to Mantle Sepolia. Click **"Get 1,000 test USDY"**, then **"Approve + deposit"**, then **"Run rebalance"**. Open each Mantlescan tx link as it appears. | "Now a judge can trigger the capital path live. Mint test USDY, deposit into the index, and run rebalance. Those are real Sepolia transactions, and allocation is driven by Reef's on-chain TrustOracle rather than a private backend." |
| **1:55-2:10** | Quick read-only montage: agent passport `/agent?id=N` showing ERC-8004 link; then the mainnet mETH vault row showing `nav() ≈ 1.0747`. Lower-third: "Mantle mainnet · real mETH · demo-scale · deposit-paused · unaudited." | "The RWA proof is deliberately small: a verified Mantle mainnet vault custodies real mETH and marks NAV from the staking rate. It is deposit-paused and unaudited, so it proves custody plumbing, not TVL readiness." |
| **2:10-2:20** | Back to landing / transparency. End card: "Reef — transaction safety for autonomous AI capital on Mantle. reef.gudman.xyz." | "Reef is the layer that makes autonomous financial agents controllable: identity, policy, receipts, risk scores, and proof. Without the gate, the agent can bypass capital controls. With Reef, the transaction has to clear first." |

---

## Honesty guardrails (must not be contradicted on screen or in VO)

- **Testnet leaderboard** uses a freely-mintable mock asset (`MockUSDY`) with simulated / accruing yield — say "test" / "simulated," never "real returns."
- **Mainnet mETH vault** (`0x76f129…cFA5`) is a *real-RWA-custody proof*: demo-scale (~0.0007 mETH, a few dollars), **deposit-paused**, single-depositor, and **unaudited**. Never imply it accepts deposits or holds meaningful TVL.
- **The "human"** in the Human-vs-AI seasons is a **passive buy-and-hold baseline** (`Seasons.sol`), not a fleet of live humans competing.
- **The Trust Score is prototype risk infrastructure**, not an external lending rating. It is useful for demos and integrations, but do not claim it is audit-grade or default-calibrated.
- **The live AI is intermittent**: on a free LLM tier it falls back to a deterministic rule, recorded as `source: "fallback"` / `model: "deterministic-fallback"`. If the feed shows a fallback record while filming, narrate it honestly or wait for a `glm` record.
- **Only matched proof records demonstrate rationale binding**: in the submitted live deployment, `proofStatus: "matched"` means `keccak256(reasoning)` == the vault's `lastReceiptEvidenceHash`. In v2 envelope records, the envelope hash is checked too. `proofStatus: "liveness-only"` means the receipt is a cadence/liveness record, not a rationale proof.
- Every contract address / number spoken must match the repo (`deployments/*.json`, `README.md`, `SECURITY.md`).

## Grounded facts cited (source of truth)

- Live network: **Mantle Sepolia, chain 5003** (mainnet 5000). RPC `rpc.sepolia.mantle.xyz`.
- AI model: **Z.ai GLM `glm-4.7-flash`** via `agents/shared/brain.py`; fallback = `deterministic-fallback`.
- Live proof-bound feeds: `/api/proofbound.json` exposes per-agent `source, model, action, moveStatus, rationale, seq, evidenceHash, receiptTx, proofStatus: "bound"`; `/api/proofs.json` exposes verifier-friendly `reasoning, evidenceHash, txHash, proofStatus: "matched"`. Both are written by the sole-publisher `agents/scripts/proofbound_rebalance.py` every ~10 min. (`/api/executions.json` is the legacy FusionX-swap feed and is no longer the live path — do not point judges at it.)
- 6th agent is BYOA: deployed via `create-reef-agent/`, registered + index-listed (`getAllocation()` returns 6 agents), runs on the `reef-byoa@6.timer` runtime, and serves its own proof-bound feed at `/api/byoa/6/proofbound-agent.json`.
- Trust Score weights: reputation 40% / freshness 20% / drawdown 20% / bond 20% (`README.md`, `ROADMAP.md`).
- Sepolia hardened addresses (`deployments/mantle-sepolia.json`, redeploy #2, 2026-06-14):
  - AgentIdentity `0xe6D6320a3647a4b21Abe1654C30E848318D161DD`
  - AgentIndex / rINDEX `0xf847D0d2c3E4DBED7cd02eB729e48d0aAEfB8C54`
  - Index asset (MockUSDY, the faucet token) `0xbc17D7F8f265d069781ed765914ED092989d92e7`
  - AgentVault (agent 1) `0xfEB9E7903CA909cC04aF18e2CcE08211c7ef8a67`
  - 5 seeded vaults, weights 526 / 1052 / 1578 / 2631 / 4210 bps
- Mantle mainnet RWA proof (`deployments/mantle-mainnet.json`, `README.md`): AgentVault (mETH) `0x76f129D56a4BE538f7E3bd44DAC70b23BcDFcFA5`, MethRateAdapter `0xb7Ceedf6BDC4Cf8bdBE8610EAe1D1f962E35a90A`, MethRate `0xf765d02A7F04bFDB8f72d97D5584d80475dF6b4E`, observed `nav() ≈ 1.0747`, deposit-paused, ~0.0007 mETH.
- ERC-8004: agents registered in Mantle's **official** ERC-8004 Identity Registry singleton `0x8004A818BFB912233c491871b3d84c89A494BD9e` (Trust Scores published to the official Reputation Registry).
- UI write handlers (`ui/app.html`): faucet `doFaucet()` → `mint(account, 1000e18)`; `doDeposit()` → approve + `deposit`; `doRebalance()` → permissionless `rebalance()`; connect auto-`switchChain(MANTLE_SEPOLIA)`.

---

## Pre-record checklist (have these open / ready before hitting record)

1. **Wallet (MetaMask) funded with Sepolia MNT** for gas — use `faucet.sepolia.mantle.xyz`. Confirm it's NOT already on Mantle Sepolia, so the auto-switch is visible on camera.
2. **Browser tabs pre-loaded:** `reef.gudman.xyz` (landing), `/app`, `/transparency`, `/api/proofbound.json`, `/api/proofs.json`, and a Sepolia Mantlescan tab (`sepolia.mantlescan.xyz`).
3. **Confirm the agent feed is fresh:** refresh `/api/proofbound.json` and verify the newest record has a non-null `receiptTx` and `proofStatus: "bound"`. Prefer a `glm` record if one is available; if the latest record is `fallback`, narrate it honestly.
4. **Pre-test the keccak binding** for Hero 2 — pull an agent record with `proofStatus: "matched"` from `reef.gudman.xyz/api/proofs.json`, compute `keccak256(reasoning)`, and confirm it equals that agent's vault `lastReceiptEvidenceHash` (Read Contract on `sepolia.mantlescan.xyz`) *before* recording, so the side-by-side match lands on camera.
5. **Pre-stage Hero 3:** wallet disconnected at the start so the connect → auto-switch flow is captured; have the deposit amount typed but not submitted; know which button is which (`Get 1,000 test USDY`, `Approve + deposit`, `Run rebalance`).
6. **Mantlescan link discipline:** after each Hero-3 tx, click through to the tx on Mantlescan once so judges see a confirmed on-chain write, not just a UI toast.
7. **Mainnet tab** open to the mETH vault on `mantlescan.xyz` to show `nav() ≈ 1.0747` for the read-only RWA beat — with the "demo-scale / paused / unaudited" lower-third ready.
8. **Screen hygiene:** hide seed phrases, private keys, and `.env`; use a throwaway demo wallet; close unrelated tabs/notifications.
9. **Timer overlay** to stay inside 2:05–2:25 and guarantee the >= 2:00 deployment-award threshold.
