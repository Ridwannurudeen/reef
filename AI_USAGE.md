# AI Usage Disclosure

Reef was built with AI coding assistants in the loop. This document is an honest
account of where AI was used, what was human-directed, and what is *not* AI-generated
hand-waving. It covers two distinct senses of "AI": (1) AI tools used to **build** the
project, and (2) the **autonomous AI agents** that are the product itself.

## 1. AI tools used to build Reef

- **Code generation & refactoring:** an AI assistant wrote and refactored most of the
  Solidity, the Python reference agents/keeper, the viem dashboard, and the docs, under
  continuous human direction (architecture, scope, and review decisions were the human's).
- **What AI did *not* do unchecked:** every contract change was compiled and run against
  the Foundry test suite (`forge test`, 132 tests incl. 2 live-mainnet fork tests) before
  merge; every on-chain deploy was verified by reading the chain back, and every contract
  is source-verified on Mantlescan. Claims in the docs were reconciled against the actual
  source and on-chain state (test counts, addresses, the receipt mechanism).
- **External facts** (Mantle-mainnet token addresses for USDY/mETH/FBTC/USDe/MI4, ERC-8004
  status) were verified on-chain (`cast` against chain 5000) and/or against primary sources,
  not asserted from model memory.

## 2. The autonomous AI agents (the product)

Reef is a benchmark for autonomous AI yield agents, so AI is also a runtime component:

- **Live LLM decisions (real, not paper-mode).** Each cycle the agent brain
  (`agents/shared/brain.py`) sends the vault's on-chain NAV state to **Z.ai GLM**
  (`glm-4.7-flash` by default; any OpenAI-compatible model via `ZAI_BASE_URL`/`ZAI_MODEL`)
  and gets back an allocation action + plain-English rationale. The VPS cron runs this on
  schedule, so the dashboard's decisions are genuinely model-generated. If the model is
  unavailable it falls back to a deterministic rule, recorded honestly as `source:"fallback"`.
- **Verifiable AI on-chain.** Each decision's record is committed on-chain as the EIP-712
  receipt's evidence hash, and the verbatim rationale is published at
  `reef.gudman.xyz/api/decisions.json` — so anyone can recompute `keccak(rationale)` and
  confirm it matches the on-chain commitment (proven: rationales match their evidence hash).
- **What is real on-chain:** ERC-8004 identity, EIP-712-signed (relayable) receipts,
  risk-adjusted (high-water-mark) reputation, the reputation-weighted rINDEX, slashable
  bonds, and time-boxed Human-vs-AI seasons — all deployed and Mantlescan-verified on
  Mantle Sepolia, with a VPS cron driving the live agent loop.
- **Honest scope:** the agents reason about on-chain NAV state (not yet a live external
  market feed or real trade execution); the contribution is the **verifiable trust +
  reputation + capital-allocation layer** that makes any agent's performance legible.

## Summary

AI accelerated the build; humans owned the design and verified every load-bearing claim
against compiler, tests, and chain. The "AI agents managing capital" story is positioned
honestly: the agents are reference/paper-mode today, and Reef's real, audited-pending
contribution is the trust-and-benchmark substrate that makes their performance legible.
