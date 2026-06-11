# Reef — X submission thread (#MantleAIHackathon)

> Draft. Post only after the demo video is recorded and you've approved submission.
> Replace `[demo video]` with the uploaded video/link before posting.
> Verify the Allora/Nansen/Z.ai X handles before tagging (only @Mantle_Official is confirmed here).

**1/**
Autonomous AI agents want to manage capital. Today, "trust me" means screenshots.

Reef is the trust, risk & capital-allocation layer for AI agents on @Mantle_Official — reputation computed from receipts, not claims. Live, verified, open source. 🧵

**2/**
Every Reef agent has:
• an ERC-8004 identity — registered in Mantle's OFFICIAL canonical registry (agents #131–#135 at the 0x8004… singleton)
• a sovereign vault (operator never custodies)
• an EIP-712 signed receipt for every decision

Reputation = per-share NAV growth above the all-time high-water mark, written only by the agent's own vault.

**3/**
The agents are genuinely autonomous — and genuinely grounded.

Each cycle they read 3 live signals (CoinGecko momentum, Allora ETH prediction, Nansen smart-money flow), decide via Z.ai's GLM, and execute REAL swaps on FusionX. The model's rationale hashes to the on-chain evidence: keccak(rationale) == receipt hash.

**4/**
Trust isn't a dashboard number — it gates capital, on-chain:

• Trust Score (0–100) recomputed inside the Allocator contract
• ReefGuard: one view call any Mantle protocol makes before letting an agent act — canExecute(agent, asset, size) → allowed/denied + reason
• Mandates: Conservative = only agents above Trust 70, 35% cap. Enforced by the contract, proven live.

**5/**
And the reputation is PORTABLE. Reef publishes each agent's Trust Score to Mantle's official ERC-8004 Reputation Registry — any protocol can read it from the canonical registry without touching a single Reef contract.

That's the difference between an app and infrastructure.

**6/**
Live on Mantle Sepolia (not a mockup):
🔗 https://reef.gudman.xyz — leaderboard, allocator, agent passports
🔗 /transparency — every contract verified on Mantlescan
AgentIndex (rINDEX): 0xC10eCcC78492395f12a8455C8A13471990c53047
191 Foundry tests · fuzz/invariant + live mainnet-fork suites

**7/**
Honest scope: testnet, simulated yield on Sepolia, unaudited — one third-party audit away from real RWA capital (USDY/mETH adapters are mainnet-ready and fork-tested against live Ondo USDY).

Open source 👉 https://github.com/Ridwannurudeen/reef
Built for the Mantle Turing Test Hackathon — AI × RWA track.

[demo video]

#MantleAIHackathon @Mantle_Official
