# AI Usage Disclosure

Reef was built with AI coding assistants in the loop. This document is an honest
account of where AI was used, what was human-directed, and what is not AI-generated
hand-waving. It covers two distinct senses of "AI": (1) AI tools used to build the
project, and (2) the autonomous AI agents that are the product itself.

## 1. AI tools used to build Reef

- **Code generation and refactoring:** an AI assistant wrote and refactored much of the
  Solidity, the Python reference agents/keeper, the dashboard, SDK, and docs, under
  continuous human direction.
- **What AI did not do unchecked:** every contract change was compiled and run against
  the Foundry test suite (`forge test`, 263 passing / 1 skipped including live-mainnet
  fork tests) before merge; every on-chain deploy was verified by reading the chain back,
  and every contract is source-verified on Mantlescan. Claims in the docs were reconciled
  against the actual source and on-chain state.
- **External facts** (Mantle-mainnet token addresses for USDY/mETH/FBTC/USDe/MI4,
  ERC-8004 status) were verified on-chain (`cast` against chain 5000) and/or against
  primary sources, not asserted from model memory.

## 2. The autonomous AI agents

Reef is a benchmark and underwriting prototype for autonomous financial agents, so AI is
also a runtime component:

- **Live, market-grounded reference decisions.** The agent brain (`agents/shared/brain.py`)
  sends a real market signal (CoinGecko ETH price + 24h momentum,
  `agents/shared/signal.py`) plus the vault's on-chain NAV state to Z.ai GLM
  (`glm-4.7-flash` by default; any OpenAI-compatible model via `ZAI_BASE_URL`/`ZAI_MODEL`)
  and gets back an allocation action plus plain-English rationale. A VPS cron runs one
  rotating agent per cycle; if the model is unavailable it falls back to a deterministic
  rule, recorded honestly as `source:"fallback"`.
- **On-chain execution is demo/reference scope.** Some runs execute a real swap on a
  Mantle-native DEX (FusionX V2) on Sepolia (native MNT <-> USDC, no real funds); those
  agent-level swaps acquire tokens to the operator wallet and are served at
  `reef.gudman.xyz/api/executions.json`. The proof-bound seeded-vault loop can move
  capital through approved vault adapters, but this is still a reference prototype, not a
  production autonomous asset manager.
- **Verifiable evidence-envelope receipts.** Decision records are source-labelled in
  `/api/executions.json`. When the receipt loop binds a recent rationale, `/api/proofs.json`
  marks the record as `proofStatus: "matched"` and exposes the canonical evidence envelope.
  Verifiers recompute `keccak256(canonical envelope)` against the vault's on-chain
  `lastReceiptEvidenceHash`, and separately recompute `keccak(reasoning)` against the
  envelope's `rationaleHash`. This proves envelope integrity only; it does not prove model
  provenance, prompt integrity, input-data authenticity, or runtime attestation. Cadence-only
  receipts prove liveness, not rationale binding.
- **What is real on-chain:** ERC-8004 identity, EIP-712-signed relayable receipts,
  realized-PnL/high-water reputation, the reputation-weighted rINDEX, slashable bonds,
  time-boxed Human-vs-AI seasons, and live agent decision/trade proofs, all deployed and
  Mantlescan-verified on Mantle Sepolia, driven by a VPS cron.

## Summary

AI accelerated the build; humans owned the design and verified every load-bearing claim
against compiler, tests, and chain. The "AI agents managing capital" story is positioned
honestly: the agents are reference operators today, and Reef's real, audited-pending
contribution is the risk, evidence, authorization, and benchmark substrate that makes their
behavior legible and enforceable.
