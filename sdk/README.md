# @reef/sdk

Zero-dependency client for the **ReefGuard** policy gate and the **Agent Passport API** on Mantle.

Reef is the trust, risk, and capital-allocation layer for autonomous AI agents on Mantle. This
SDK is how a protocol or app integrates it:

- **On-chain** — gate any agent-driven function behind ReefGuard's policy.
- **Off-chain** — read an agent's trust score, ReefGuard verdict, allocation, and latest decision.

No build step, no dependencies. The JS client uses global `fetch` + `TextDecoder` (browser / Node ≥ 18).

## JS / TS

```js
import { ReefClient } from "@reef/sdk";

const reef = new ReefClient({
  rpcUrl: "https://rpc.sepolia.mantle.xyz",
  guardAddress: "0xe84E84D7e2E588aa8F88d1D1ADF2bdc70365a02b", // ReefGuard (Sepolia)
  apiBase: "https://reef.gudman.xyz/api",
});

// On-chain policy check (free, read-only)
const { allowed, reason } = await reef.canExecute(1, "0xbc17…92e7", 1000);
if (!allowed) throw new Error(`agent blocked: ${reason}`);

// Public agent passport
const p = await reef.passport(1);   // { trustScore, rating, reefGuard, allocation, latestDecision, … }
await reef.score(1);                // 65
await reef.latestReceipt(1);        // latest decision/receipt
```

### API

| Method | Returns |
|---|---|
| `canExecute(agentId, asset, sizeBps)` | `{ allowed, reason }` — raw `eth_call` to `ReefGuard.canExecute` |
| `passport(agentId)` | full passport JSON — `GET /api/agent/<id>.json` |
| `score(agentId)` | the agent's Reef Trust Score (0–100) |
| `latestReceipt(agentId)` | the agent's latest recorded decision |

`encodeCanExecute` / `decodeCanExecute` are exported for advanced use (e.g. multicall).

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

See `MockProtocol` (deployed + Mantlescan-verified) for a live reference integration, and
[`INTEGRATION.md`](../INTEGRATION.md) for the full guide.

## Addresses (Mantle Sepolia, chain 5003)

| Contract | Address |
|---|---|
| ReefGuard | `0xe84E84D7e2E588aa8F88d1D1ADF2bdc70365a02b` |
| MockProtocol (example) | `0x9ef3Feb3C404651C8d240c529969B99b743dE8D0` |

> Unaudited testnet code. See `SECURITY.md` before any mainnet TVL.
