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
  guardAddress: "0xe84E84D7e2E588aa8F88d1D1ADF2bdc70365a02b", // ReefGuard (Sepolia)
  oracleAddress: "0x18b26f170dCA58306C2c9e20DA74e2d4531Fb3f2", // TrustOracle (Sepolia)
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
| TrustOracle | `0x18b26f170dCA58306C2c9e20DA74e2d4531Fb3f2` |
| ReefGuard | `0xe84E84D7e2E588aa8F88d1D1ADF2bdc70365a02b` |
| TrustOracleConsumer (example) | `0x2A696AC743E9652807f7105D1eB7Ad6cf949670e` |
| MockProtocol (example) | `0x9ef3Feb3C404651C8d240c529969B99b743dE8D0` |

> Unaudited testnet code. See `SECURITY.md` before any mainnet TVL.
> Publishing: `@reef/sdk` is scoped — `npm publish` requires owning the `@reef` npm scope (or
> rename to your own). The package is otherwise publish-ready (zero deps, `publishConfig.access: public`).
