# Reef — 2-Minute Demo Video Script

**Project:** Reef — the trust, risk, and capital-allocation layer for autonomous AI agents on Mantle.
**Hackathon:** Mantle Turing Test 2026 — AI × RWA track.
**Award targeted:** 20 Project Deployment Award (>= 2 min, walks the core use case + shows verifiable on-chain *writes*, not just dashboards).
**Live:** https://reef.gudman.xyz · proof page https://reef.gudman.xyz/transparency · dApp https://reef.gudman.xyz/app

**The thesis in one line:** "Which autonomous AI agents can you trust with capital?" Reef makes that answer an on-chain primitive — portable ERC-8004 identity, EIP-712-signed decision receipts, NAV-derived reputation, and a public 0–100 Trust Score any Mantle protocol can read.

**Why this script is write-centric:** the three hero beats below each show a *real on-chain write* — the AI writing, the proof you can recompute yourself, and a judge triggering writes live. Read-only views (leaderboard, mainnet RWA vault, ERC-8004 identity) are shown only as supporting context.

Target runtime: **2:05–2:25.**

---

## Shot-by-shot

| Time | [SCREEN] | [VOICEOVER] |
|---|---|---|
| **0:00–0:12** | Landing page `reef.gudman.xyz`. Pan the hero: "trust, risk, and capital-allocation layer for autonomous AI agents on Mantle," "Live on Mantle Sepolia" pill. | "Autonomous AI agents are starting to manage capital. The missing piece is trust. Reef is the layer that answers one question on-chain: which AI agents can you trust with money? Built for the Mantle Turing Test, AI-by-RWA track." |
| **0:12–0:22** | Cut to `/app` leaderboard. Hover one agent's Trust Score badge — tooltip shows the on-chain `scoreOnChain` and the off-chain parity delta. | "Every agent has a Trust Score from zero to a hundred — forty percent reputation, twenty each for receipt freshness, drawdown, and bond. This badge is read live from the on-chain TrustOracle, not asserted by the page." |
| **0:22–0:25** | Honesty title card or lower-third over the leaderboard. | "Honest scope: this testnet leaderboard runs on a mock asset with simulated yield. Now the real point — the writes." |
| **HERO 1 — 0:25–0:50** | **The AI writing on-chain.** Open `reef.gudman.xyz/api/executions.json` in the browser (raw JSON). Highlight the newest record: `source: "glm"`, `model: "glm-4.7-flash"`, the `reasoning` rationale text, and `execution.txHash`. Then copy that `txHash` and open it on Sepolia Mantlescan — show the confirmed swap transaction. | "Here's a live decision feed. A VPS cron runs a real GLM model — glm-4.7-flash — over live market signals and the vault's on-chain NAV. It returns an action and a plain-English rationale. When it chose to increase exposure, it executed a real swap on FusionX, a Mantle-native DEX. Here's that transaction hash — and here it is, confirmed on Mantlescan. That's an autonomous AI agent making a real on-chain write." |
| **HERO 2 — 0:50–1:20** | **Verify-it-yourself: the words are bound to the chain.** Open `reef.gudman.xyz/api/proofs.json`. Highlight one agent's `reasoning` text and its `rationaleHash`. (a) Drop that exact `reasoning` string into a keccak256 tool and show the hash. (b) Open that agent's vault on Mantlescan → **Read Contract** → call **`lastReceiptEvidenceHash`** (bytes32). (c) Hold them side by side: `keccak256(reasoning)` == `lastReceiptEvidenceHash`. Same for any of the 5 agents. | "Don't trust the dashboard — verify it yourself. Here's an agent's decision rationale from the proofs feed. I take those exact words, hash them with keccak256… and that hash is identical to the `lastReceiptEvidenceHash` this agent committed on-chain. The words and the chain are cryptographically bound — for all five agents. Honest note: that bound rationale might be a live GLM decision or a deterministic fallback — the `source` and `model` fields tell you which — and the binding holds either way." |
| **HERO 3 — 1:20–1:55** | **Judge-triggered writes on the live dApp.** On `/app`, click Connect Wallet → wallet pops, approve → page auto-switches the wallet to Mantle Sepolia. Then: (a) click **"Get 1,000 test USDY"** → confirm tx → toast "minted 1,000 USDY." (b) Click **"Approve + deposit"** → confirm the approve, then the deposit tx → balance updates. (c) Click **"Run rebalance"** → confirm tx → allocation updates. Each tx hash flashes as a Mantlescan link. | "Now you try it. Connect a wallet — Reef auto-switches you to Mantle Sepolia. Click 'Get 1,000 test USDY' — that's a real mint transaction. Approve and deposit into the reputation-weighted index — two more real transactions. Then 'Run rebalance' — it's permissionless, anyone can trigger it, and it reallocates capital across agents by their on-chain Trust Score. Four writes, anyone can make them, all verifiable." |
| **1:55–2:10** | Quick read-only montage: agent passport `/agent?id=N` showing ERC-8004 link; then the mainnet mETH vault row showing `nav() ≈ 1.0747`. Lower-third: "Mantle mainnet · real mETH · demo-scale · deposit-paused · unaudited." | "Identity is portable — every agent lives in Mantle's official ERC-8004 registry. And on Mantle mainnet, a real vault custodies real mETH; its NAV reflects genuine staking yield, around 1.07. Being honest: that position is demo-scale, deposit-paused, and unaudited — it's a real-RWA custody proof, not a product." |
| **2:10–2:25** | Back to landing / transparency. End card: "Reef — trust for autonomous AI capital on Mantle. reef.gudman.xyz." | "Reef makes AI agents legible — real identity, signed decisions, reputation you can recompute, and a Trust Score any protocol can read. That's the trust layer for AI capital on Mantle. Thanks for watching." |

---

## Honesty guardrails (must not be contradicted on screen or in VO)

- **Testnet leaderboard** uses a freely-mintable mock asset (`MockUSDY`) with simulated / accruing yield — say "test" / "simulated," never "real returns."
- **Mainnet mETH vault** (`0x76f129…cFA5`) is a *real-RWA-custody proof*: demo-scale (~0.0007 mETH, a few dollars), **deposit-paused**, single-depositor, and **unaudited**. Never imply it accepts deposits or holds meaningful TVL.
- **The "human"** in the Human-vs-AI seasons is a **passive buy-and-hold baseline** (`Seasons.sol`), not a fleet of live humans competing.
- **The Trust Score is gameable** (freshness leg farmable, cohort-relative) and is a sound internal ranking, not yet safe for an external lender — don't claim it's audit-grade.
- **The live AI is intermittent**: on a free LLM tier it falls back to a deterministic rule, recorded as `source: "fallback"` / `model: "deterministic-fallback"`. If the feed shows a fallback record while filming, narrate it honestly or wait for a `glm` record.
- **The keccak rationale↔receipt binding covers GLM and fallback rationales equally**: `keccak256(reasoning)` == the vault's `lastReceiptEvidenceHash` whether the bound rationale came from a live GLM decision or the deterministic fallback — don't claim the bound rationale is always GLM. Unaudited testnet.
- Every contract address / number spoken must match the repo (`deployments/*.json`, `README.md`, `SECURITY.md`).

## Grounded facts cited (source of truth)

- Live network: **Mantle Sepolia, chain 5003** (mainnet 5000). RPC `rpc.sepolia.mantle.xyz`.
- AI model: **Z.ai GLM `glm-4.7-flash`** via `agents/shared/brain.py`; fallback = `deterministic-fallback`.
- Executions feed `/api/executions.json` record fields: `agent, action, navDeltaBps, reasoning, source, model, execution.txHash, ts` (`agents/scripts/execute_decision.py`).
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
2. **Browser tabs pre-loaded:** `reef.gudman.xyz` (landing), `/app`, `/transparency`, `/api/executions.json`, and a Sepolia Mantlescan tab (`sepolia.mantlescan.xyz`).
3. **Confirm the AI feed is fresh:** refresh `/api/executions.json` and verify the newest record is `source: "glm"` with a non-null `execution.txHash` (the swap fires on an `increase`/`decrease`). If only `fallback` records show, wait for the next cron cycle or narrate the fallback honestly.
4. **Pre-test the keccak binding** for Hero 2 — pull an agent's `reasoning` from `reef.gudman.xyz/api/proofs.json`, compute `keccak256(reasoning)`, and confirm it equals that agent's vault `lastReceiptEvidenceHash` (Read Contract on `sepolia.mantlescan.xyz`) *before* recording, so the side-by-side match lands on camera.
5. **Pre-stage Hero 3:** wallet disconnected at the start so the connect → auto-switch flow is captured; have the deposit amount typed but not submitted; know which button is which (`Get 1,000 test USDY`, `Approve + deposit`, `Run rebalance`).
6. **Mantlescan link discipline:** after each Hero-3 tx, click through to the tx on Mantlescan once so judges see a confirmed on-chain write, not just a UI toast.
7. **Mainnet tab** open to the mETH vault on `mantlescan.xyz` to show `nav() ≈ 1.0747` for the read-only RWA beat — with the "demo-scale / paused / unaudited" lower-third ready.
8. **Screen hygiene:** hide seed phrases, private keys, and `.env`; use a throwaway demo wallet; close unrelated tabs/notifications.
9. **Timer overlay** to stay inside 2:05–2:25 and guarantee the >= 2:00 deployment-award threshold.
