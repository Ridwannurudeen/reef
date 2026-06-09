// Reef SDK — zero-dependency client for the ReefGuard policy gate + Agent Passport API.
//
// Works in the browser and in Node (>=18, for global fetch/TextDecoder). No build step, no
// dependencies: canExecute() is a raw eth_call against ReefGuard; passport()/score()/
// latestReceipt() fetch the public Agent Passport JSON. This is the read side of the SDK;
// the Solidity side is `src/ReefGuarded.sol` (inherit + the `onlyCleared` modifier).
//
//   import { ReefClient } from "./reef.js";
//   const reef = new ReefClient({
//     rpcUrl: "https://rpc.sepolia.mantle.xyz",
//     guardAddress: "0xe84E84D7e2E588aa8F88d1D1ADF2bdc70365a02b",
//     apiBase: "https://reef.gudman.xyz/api",
//   });
//   await reef.canExecute(1, "0xbc17...92e7", 1000); // { allowed: true, reason: "ok" }
//   await reef.passport(1);                          // full agent passport JSON

const CAN_EXECUTE_SELECTOR = "0x1907e986"; // canExecute(uint256,address,uint256)

function pad32(hexNo0x) {
  return hexNo0x.padStart(64, "0");
}
function uintWord(n) {
  return pad32(BigInt(n).toString(16));
}
function addrWord(addr) {
  return pad32(String(addr).toLowerCase().replace(/^0x/, ""));
}

/** ABI-encode calldata for canExecute(uint256 agentId, address asset, uint256 sizeBps). */
export function encodeCanExecute(agentId, asset, sizeBps) {
  return (
    CAN_EXECUTE_SELECTOR +
    uintWord(agentId) +
    addrWord(asset) +
    uintWord(sizeBps)
  );
}

function hexToUtf8(hexNo0x) {
  const bytes = new Uint8Array(hexNo0x.length / 2);
  for (let i = 0; i < bytes.length; i++)
    bytes[i] = parseInt(hexNo0x.substr(i * 2, 2), 16);
  return new TextDecoder().decode(bytes);
}

/** Decode an ABI-encoded (bool, string) return into { allowed, reason }. */
export function decodeCanExecute(hex) {
  const h = String(hex).replace(/^0x/, "");
  const allowed = BigInt("0x" + h.slice(0, 64)) !== 0n;
  const off = Number(BigInt("0x" + h.slice(64, 128))) * 2; // byte offset -> hex-char offset
  const len = Number(BigInt("0x" + h.slice(off, off + 64)));
  const reason = hexToUtf8(h.slice(off + 64, off + 64 + len * 2));
  return { allowed, reason };
}

export class ReefClient {
  constructor({ rpcUrl, guardAddress, apiBase } = {}) {
    this.rpcUrl = rpcUrl;
    this.guardAddress = guardAddress;
    this.apiBase = (apiBase || "").replace(/\/$/, "");
  }

  /** On-chain policy check via ReefGuard.canExecute. Returns { allowed, reason }. */
  async canExecute(agentId, asset, sizeBps) {
    if (!this.rpcUrl || !this.guardAddress)
      throw new Error("rpcUrl and guardAddress required");
    const data = encodeCanExecute(agentId, asset, sizeBps);
    const res = await fetch(this.rpcUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "eth_call",
        params: [{ to: this.guardAddress, data }, "latest"],
      }),
    });
    const json = await res.json();
    if (json.error)
      throw new Error("eth_call failed: " + JSON.stringify(json.error));
    return decodeCanExecute(json.result);
  }

  /** GET /api/agent/<id>.json — the full agent passport. */
  async passport(agentId) {
    if (!this.apiBase) throw new Error("apiBase required");
    const res = await fetch(`${this.apiBase}/agent/${agentId}.json`, {
      cache: "no-store",
    });
    if (!res.ok) throw new Error(`passport ${agentId}: HTTP ${res.status}`);
    return res.json();
  }

  /** The agent's Reef Trust Score (0-100). */
  async score(agentId) {
    return (await this.passport(agentId)).trustScore;
  }

  /** The agent's latest recorded decision/receipt. */
  async latestReceipt(agentId) {
    return (await this.passport(agentId)).latestDecision;
  }
}

export default ReefClient;
