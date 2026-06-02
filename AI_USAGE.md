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

- **Reference agents** (`agents/allora_agent`, `agents/nansen_agent`) consume a market
  signal, ask an LLM (Z.ai GLM-5.1) for an allocation decision, and publish an EIP-712-signed
  receipt on-chain. **Honest scope:** Allora is API-gated and the Nansen signal is a
  deterministic mock in v1; without LLM keys the agents fall back to a deterministic rule.
  So the live demo's "intelligence" is intentionally modest — the contribution is the
  **on-chain verification, reputation, and capital-allocation layer** around agents, not a
  novel trading model.
- **What is real on-chain:** ERC-8004 identity, EIP-712-signed (relayable) receipts,
  risk-adjusted (high-water-mark) reputation, the reputation-weighted rINDEX, slashable
  bonds, and time-boxed Human-vs-AI seasons — all deployed and Mantlescan-verified on
  Mantle Sepolia, with a VPS cron keeping receipts fresh.

## Summary

AI accelerated the build; humans owned the design and verified every load-bearing claim
against compiler, tests, and chain. The "AI agents managing capital" story is positioned
honestly: the agents are reference/paper-mode today, and Reef's real, audited-pending
contribution is the trust-and-benchmark substrate that makes their performance legible.
