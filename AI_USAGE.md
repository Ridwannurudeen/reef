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
  the Foundry test suite (`forge test`, 191 tests incl. live-mainnet fork tests) before
  merge; every on-chain deploy was verified by reading the chain back, and every contract
  is source-verified on Mantlescan. Claims in the docs were reconciled against the actual
  source and on-chain state (test counts, addresses, the receipt mechanism).
- **External facts** (Mantle-mainnet token addresses for USDY/mETH/FBTC/USDe/MI4, ERC-8004
  status) were verified on-chain (`cast` against chain 5000) and/or against primary sources,
  not asserted from model memory.

## 2. The autonomous AI agents (the product)

Reef is a benchmark for autonomous AI yield agents, so AI is also a runtime component:

- **Live, market-grounded LLM decisions (real, not paper-mode).** The agent brain
  (`agents/shared/brain.py`) sends a **real market signal** (CoinGecko ETH price + 24h
  momentum, `agents/shared/signal.py`) plus the vault's on-chain NAV state to **Z.ai GLM**
  (`glm-4.7-flash` by default; any OpenAI-compatible model via `ZAI_BASE_URL`/`ZAI_MODEL`)
  and gets back an allocation action + plain-English rationale grounded in that data — e.g.
  at a drawdown with ETH down ~2.9% it chose `decrease`, citing the momentum. A VPS cron
  runs one rotating agent per cycle (staying under the model's free-tier rate limit); if the
  model is unavailable it falls back to a deterministic rule, recorded honestly as `source:"fallback"`.
- **Real on-chain execution.** When an agent chooses to increase, it executes a **real swap
  on a Mantle-native DEX (FusionX V2)** on Sepolia (native MNT → USDC, no real funds); the
  decision + real swap txHash are served at `reef.gudman.xyz/api/executions.json` and the
  swap is verifiable on Mantlescan. (Honest scope: swaps acquire tokens to the operator
  wallet — agent-level execution; routing into vault NAV via a strategy adapter is a follow-up.)
- **Verifiable AI on-chain.** Decision records are committed on-chain as the EIP-712 receipt's
  evidence hash, so `keccak(record)` can be recomputed and matched against the chain (proven).
- **What is real on-chain:** ERC-8004 identity, EIP-712-signed (relayable) receipts,
  risk-adjusted (high-water-mark) reputation, the reputation-weighted rINDEX, slashable
  bonds, time-boxed Human-vs-AI seasons, and live agent decisions+trades — all deployed and
  Mantlescan-verified on Mantle Sepolia, driven by a VPS cron.

## Summary

AI accelerated the build; humans owned the design and verified every load-bearing claim
against compiler, tests, and chain. The "AI agents managing capital" story is positioned
honestly: the agents are reference/paper-mode today, and Reef's real, audited-pending
contribution is the trust-and-benchmark substrate that makes their performance legible.
