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
//     guardAddress: "0x108411e3AA1fA2D3643b86A0B52Fd5bE12FDfe3f",
//     oracleAddress: "0x9C7db1eF649095d5c543aF66538a5E36A04d6598",
//     apiBase: "https://reef.gudman.xyz/api",
//   });
//   await reef.canExecute(1, "0xbc17...92e7", 1000); // { allowed: true, reason: "ok" }
//   await reef.trustScoreOf(5);                       // 99.9  (on-chain Trust Score, 0-100)
//   await reef.report(5, "0xbc17...92e7", 1000);      // { score, rating, guardCleared, guardReason }
//   await reef.passport(1);                           // full agent passport JSON

const CAN_EXECUTE_SELECTOR = "0x1907e986"; // canExecute(uint256,address,uint256)
const SCORE_OF_SELECTOR = "0x752821e9"; // scoreOf(uint256)
const REPORT_SELECTOR = "0x282470f5"; // report(uint256,address,uint256)

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

/** Read a dynamic `string` whose head word sits at hex-char position `headPos`. */
function readStringAt(h, headPos) {
  const off = Number(BigInt("0x" + h.slice(headPos, headPos + 64))) * 2; // byte offset -> hex chars
  const len = Number(BigInt("0x" + h.slice(off, off + 64)));
  return hexToUtf8(h.slice(off + 64, off + 64 + len * 2));
}

/** WAD (1e18 = 100/100) -> Trust Score on a 0-100 scale, rounded to 1 decimal. */
export function wadToScore(wadHexOrBig) {
  const wad =
    typeof wadHexOrBig === "bigint" ? wadHexOrBig : BigInt(wadHexOrBig);
  return Number((wad * 1000n) / 10n ** 18n) / 10; // 0-100, 1 decimal
}

/** ABI-encode calldata for scoreOf(uint256 agentId). */
export function encodeScoreOf(agentId) {
  return SCORE_OF_SELECTOR + uintWord(agentId);
}

/** ABI-encode calldata for report(uint256 agentId, address asset, uint256 sizeBps). */
export function encodeReport(agentId, asset, sizeBps) {
  return (
    REPORT_SELECTOR + uintWord(agentId) + addrWord(asset) + uintWord(sizeBps)
  );
}

/** Decode report() return (uint256 score, string rating, bool guardCleared, string guardReason). */
export function decodeReport(hex) {
  const h = String(hex).replace(/^0x/, "");
  const score = wadToScore(BigInt("0x" + h.slice(0, 64)));
  const rating = readStringAt(h, 64); // word 1 = offset to rating string
  const guardCleared = BigInt("0x" + h.slice(128, 192)) !== 0n; // word 2
  const guardReason = readStringAt(h, 192); // word 3 = offset to guardReason string
  return { score, rating, guardCleared, guardReason };
}

export class ReefClient {
  constructor({ rpcUrl, guardAddress, oracleAddress, apiBase } = {}) {
    this.rpcUrl = rpcUrl;
    this.guardAddress = guardAddress;
    this.oracleAddress = oracleAddress;
    this.apiBase = (apiBase || "").replace(/\/$/, "");
  }

  /** Raw eth_call against `to` with `data`, returns the result hex (throws on RPC error). */
  async _ethCall(to, data) {
    if (!this.rpcUrl) throw new Error("rpcUrl required");
    const res = await fetch(this.rpcUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "eth_call",
        params: [{ to, data }, "latest"],
      }),
    });
    const json = await res.json();
    if (json.error)
      throw new Error("eth_call failed: " + JSON.stringify(json.error));
    return json.result;
  }

  /** On-chain policy check via ReefGuard.canExecute. Returns { allowed, reason }. */
  async canExecute(agentId, asset, sizeBps) {
    if (!this.guardAddress) throw new Error("guardAddress required");
    const out = await this._ethCall(
      this.guardAddress,
      encodeCanExecute(agentId, asset, sizeBps),
    );
    return decodeCanExecute(out);
  }

  /** On-chain Trust Score via TrustOracle.scoreOf. Returns a number 0-100. */
  async trustScoreOf(agentId) {
    if (!this.oracleAddress) throw new Error("oracleAddress required");
    const out = await this._ethCall(this.oracleAddress, encodeScoreOf(agentId));
    return wadToScore(BigInt(out));
  }

  /** One-call trust verdict via TrustOracle.report: { score, rating, guardCleared, guardReason }. */
  async report(agentId, asset, sizeBps) {
    if (!this.oracleAddress) throw new Error("oracleAddress required");
    const out = await this._ethCall(
      this.oracleAddress,
      encodeReport(agentId, asset, sizeBps),
    );
    return decodeReport(out);
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
