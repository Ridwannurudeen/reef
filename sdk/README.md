# @reef/sdk

Zero-dependency client for the Reef **TrustOracle**, the **ReefGuard** policy gate, and the
**Agent Passport API** on Mantle.

Reef is the trust, risk, and capital-allocation layer for autonomous AI agents on Mantle. This
SDK is how a protocol or app integrates it:

- **TrustOracle** — read an agent's on-chain Trust Score (0–100) and a one-call trust verdict.
- **ReefGuard** — gate any agent-driven function behind ReefGuard's policy.
- **Agent Passport** — read an agent's full off-chain profile (trust, verdict, allocation, decisions).

No build step, no dependencies. The JS client uses global `fetch` + `TextDecoder` (browser / Node ≥ 18).

## JS / TS

```js
import { ReefClient } from "@reef/sdk";

const reef = new ReefClient({
  rpcUrl: "https://rpc.sepolia.mantle.xyz",
  guardAddress: "0x108411e3AA1fA2D3643b86A0B52Fd5bE12FDfe3f", // ReefGuard (Sepolia)
  oracleAddress: "0x9C7db1eF649095d5c543aF66538a5E36A04d6598", // TrustOracle (Sepolia)
  apiBase: "https://reef.gudman.xyz/api",
});

// On-chain Trust Score (free, read-only) — the single number capital cares about
await reef.trustScoreOf(5); // 99.9

// One-call verdict: score + rating + live ReefGuard policy check
const r = await reef.report(5, "0xbc17…92e7", 1000);
// { score: 99.9, rating: "AAA", guardCleared: true, guardReason: "ok" }

// Just the policy gate
const { allowed, reason } = await reef.canExecute(1, "0xbc17…92e7", 1000);
if (!allowed) throw new Error(`agent blocked: ${reason}`);

// Public agent passport
const p = await reef.passport(1);   // { trustScore, rating, reefGuard, allocation, latestDecision, … }
```

### API

| Method | Returns |
|---|---|
| `trustScoreOf(agentId)` | on-chain Trust Score 0–100 — `eth_call` to `TrustOracle.scoreOf` |
| `report(agentId, asset, sizeBps)` | `{ score, rating, guardCleared, guardReason }` — `TrustOracle.report` |
| `canExecute(agentId, asset, sizeBps)` | `{ allowed, reason }` — raw `eth_call` to `ReefGuard.canExecute` |
| `passport(agentId)` | full passport JSON — `GET /api/agent/<id>.json` |
| `score(agentId)` | the agent's Reef Trust Score (0–100), from the passport API |
| `latestReceipt(agentId)` | the agent's latest recorded decision |

`encodeCanExecute` / `decodeCanExecute` / `encodeScoreOf` / `encodeReport` / `decodeReport` /
`wadToScore` are exported for advanced use (e.g. multicall).

## Solidity

Inherit `ReefGuarded` (`src/ReefGuarded.sol`) and gate any entrypoint with one modifier — the call
reverts with ReefGuard's exact policy reason if the agent isn't cleared:

```solidity
import {ReefGuarded} from "reef/src/ReefGuarded.sol";

contract MyProtocol is ReefGuarded {
    constructor(address reefGuard) ReefGuarded(reefGuard) {}

    function act(uint256 agentId, address asset, uint256 sizeBps, uint256 amount)
        external
        onlyCleared(agentId, asset, sizeBps) // reverts "insufficient bond" / "agent under dispute" / …
    {
        // ... your execution logic; the agent is verified to be allowed.
    }
}
```

To **size** capital by trust (not just gate it), read `TrustOracle.scoreOf` (0..1e18):

```solidity
interface ITrustOracle { function scoreOf(uint256 agentId) external view returns (uint256); }

// limit scales with the agent's on-chain Trust Score; disqualify below the bar
uint256 score = ITrustOracle(oracle).scoreOf(agentId);   // 1e18 == 100/100
require(score >= minScore, "trust below threshold");
uint256 limit = baseLimit * score / 1e18;
```

See `MockProtocol` (ReefGuard gate) and `TrustOracleConsumer` (trust-weighted credit) — both
deployed + Mantlescan-verified — for live reference integrations, and
[`INTEGRATION.md`](../INTEGRATION.md) for the full guide.

## Addresses (Mantle Sepolia, chain 5003)

| Contract | Address |
|---|---|
| TrustOracle | `0x9C7db1eF649095d5c543aF66538a5E36A04d6598` |
| ReefGuard | `0x108411e3AA1fA2D3643b86A0B52Fd5bE12FDfe3f` |
| TrustOracleConsumer (example) | `0xF4fcd1A79d2D95Ae86257be385d8b5FFCd403830` |
| MockProtocol (example) | `0x44E2324BBd1A645c776c442DCa418b791E93fbb2` |

> Unaudited testnet code. See `SECURITY.md` before any mainnet TVL.
> Publishing: `@reef/sdk` is scoped — `npm publish` requires owning the `@reef` npm scope (or
> rename to your own). The package is otherwise publish-ready (zero deps, `publishConfig.access: public`).
