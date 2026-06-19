// Reef SDK — zero-dependency client for the ReefGuard policy gate + Agent Passport API.
//
// Works in the browser and in Node (>=18, for global fetch/TextDecoder). No build step, no
// dependencies: canExecute() is a raw eth_call against ReefGuard; passport()/score()/
// latestReceipt() fetch the public Agent Passport JSON. Write helpers return/send raw
// transaction data through an injected EIP-1193 wallet; the SDK never owns private keys.
// The Solidity side is `src/ReefGuarded.sol` (inherit + the `onlyCleared` modifier).
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
const CAN_EXECUTE_ACTION_SELECTOR = "0x7e056c47"; // canExecuteAction(uint256,(address,uint256,bytes,address,uint256))
const SCORE_OF_SELECTOR = "0x752821e9"; // scoreOf(uint256)
const REPORT_SELECTOR = "0x282470f5"; // report(uint256,address,uint256)
const REGISTER_SELECTOR = "0x1aa3a008"; // register()
const SET_REPUTATION_SOURCE_SELECTOR = "0xaf2a5652"; // setReputationSource(uint256,address)
const APPROVE_ADAPTER_SELECTOR = "0xc0e2ffc4"; // approveAdapter(address)
const APPROVE_STRATEGY_SELECTOR = "0x3b8ae397"; // approveStrategy(address)
const POST_BOND_SELECTOR = "0x184fed04"; // postBond(uint256,uint256)
const SELF_LIST_VAULT_SELECTOR = "0xaefca159"; // selfListVault(address)
const PUBLISH_RECEIPT_SELECTOR = "0xcda9e6ad"; // publishReceipt(uint256,bytes32,int256,uint64,bytes)
const ERC20_APPROVE_SELECTOR = "0x095ea7b3"; // approve(address,uint256)

function pad32(hexNo0x) {
  return hexNo0x.padStart(64, "0");
}
function uintWord(n) {
  const x = BigInt(n);
  if (x < 0n || x >= 1n << 256n) throw new Error("uint256 out of range");
  return pad32(x.toString(16));
}
function intWord(n) {
  let x = BigInt(n);
  if (x < -(1n << 255n) || x >= 1n << 255n)
    throw new Error("int256 out of range");
  if (x < 0n) x = (1n << 256n) + x;
  return pad32(x.toString(16));
}
function addrWord(addr) {
  const h = String(addr).toLowerCase().replace(/^0x/, "");
  if (!/^[0-9a-f]{40}$/.test(h)) throw new Error("invalid address");
  return pad32(h);
}
function bytes32Word(value) {
  const h = String(value).toLowerCase().replace(/^0x/, "");
  if (!/^[0-9a-f]{64}$/.test(h)) throw new Error("invalid bytes32");
  return h;
}
function hexBytes(value) {
  const h = String(value || "")
    .toLowerCase()
    .replace(/^0x/, "");
  if (h.length % 2 !== 0 || !/^[0-9a-f]*$/.test(h))
    throw new Error("invalid bytes");
  return h;
}
function bytesTail(value) {
  const h = hexBytes(value);
  const paddedLen = Math.ceil(h.length / 64) * 64;
  return uintWord(h.length / 2) + h.padEnd(paddedLen, "0");
}
function normalizeBytecode(bytecode) {
  const h = hexBytes(bytecode);
  if (!h) throw new Error("bytecode required");
  return "0x" + h;
}
function quantityHex(value) {
  if (typeof value === "bigint") return "0x" + value.toString(16);
  if (typeof value === "number") return "0x" + BigInt(value).toString(16);
  const s = String(value);
  return s.startsWith("0x") ? s : "0x" + BigInt(s).toString(16);
}
function requiredAddress(value, label) {
  if (!value) throw new Error(`${label} required`);
  addrWord(value);
  return value;
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

/** ABI-encode calldata for canExecuteAction(uint256,Action). */
export function encodeCanExecuteAction(agentId, action) {
  const dataTail = bytesTail(action.data || "0x");
  return (
    CAN_EXECUTE_ACTION_SELECTOR +
    uintWord(agentId) +
    uintWord(64) +
    addrWord(action.target) +
    uintWord(action.value || 0) +
    uintWord(160) +
    addrWord(action.asset) +
    uintWord(action.portfolioValue) +
    dataTail
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

/** Decode canExecuteAction() return into { allowed, reason, amount, sizeBps }. */
export function decodeCanExecuteAction(hex) {
  const h = String(hex).replace(/^0x/, "");
  const allowed = BigInt("0x" + h.slice(0, 64)) !== 0n;
  const reason = readStringAt(h, 64);
  const amount = BigInt("0x" + h.slice(128, 192));
  const sizeBps = Number(BigInt("0x" + h.slice(192, 256)));
  return { allowed, reason, amount, sizeBps };
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

/** ABI-encode calldata for AgentIdentity.register(). */
export function encodeRegisterAgent() {
  return REGISTER_SELECTOR;
}

/** ABI-encode calldata for AgentIdentity.setReputationSource(uint256,address). */
export function encodeSetReputationSource(agentId, source) {
  return SET_REPUTATION_SOURCE_SELECTOR + uintWord(agentId) + addrWord(source);
}

/** ABI-encode calldata for AdapterRegistry.approveAdapter(address). */
export function encodeApproveAdapter(adapter) {
  return APPROVE_ADAPTER_SELECTOR + addrWord(adapter);
}

/** ABI-encode calldata for AgentVault.approveStrategy(address). */
export function encodeApproveStrategy(adapter) {
  return APPROVE_STRATEGY_SELECTOR + addrWord(adapter);
}

/** ABI-encode calldata for ERC20.approve(address,uint256). */
export function encodeErc20Approve(spender, amount) {
  return ERC20_APPROVE_SELECTOR + addrWord(spender) + uintWord(amount);
}

/** ABI-encode calldata for ReputationBond.postBond(uint256,uint256). */
export function encodePostBond(agentId, amount) {
  return POST_BOND_SELECTOR + uintWord(agentId) + uintWord(amount);
}

/** ABI-encode calldata for AgentIndex.selfListVault(address). */
export function encodeSelfListVault(vault) {
  return SELF_LIST_VAULT_SELECTOR + addrWord(vault);
}

/** ABI-encode calldata for AgentVault.publishReceipt(uint256,bytes32,int256,uint64,bytes). */
export function encodePublishReceipt(
  seq,
  evidenceHash,
  claimedDelta,
  period,
  signature,
) {
  return (
    PUBLISH_RECEIPT_SELECTOR +
    uintWord(seq) +
    bytes32Word(evidenceHash) +
    intWord(claimedDelta) +
    uintWord(period) +
    uintWord(160) +
    bytesTail(signature)
  );
}

/** Build AgentVault deployment data from Foundry bytecode + constructor args. */
export function encodeDeployVault(
  bytecode,
  asset,
  agentId,
  identity,
  registry,
) {
  return (
    normalizeBytecode(bytecode) +
    addrWord(asset) +
    uintWord(agentId) +
    addrWord(identity) +
    addrWord(registry)
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
  constructor({
    rpcUrl,
    guardAddress,
    oracleAddress,
    identityAddress,
    indexAddress,
    bondAddress,
    registryAddress,
    apiBase,
    provider,
    account,
  } = {}) {
    this.rpcUrl = rpcUrl;
    this.guardAddress = guardAddress;
    this.oracleAddress = oracleAddress;
    this.identityAddress = identityAddress;
    this.indexAddress = indexAddress;
    this.bondAddress = bondAddress;
    this.registryAddress = registryAddress;
    this.apiBase = (apiBase || "").replace(/\/$/, "");
    this.provider = provider;
    this.account = account;
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

  /** On-chain action inspection via ReefGuard.canExecuteAction. */
  async canExecuteAction(agentId, action) {
    if (!this.guardAddress) throw new Error("guardAddress required");
    const out = await this._ethCall(
      this.guardAddress,
      encodeCanExecuteAction(agentId, action),
    );
    return decodeCanExecuteAction(out);
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

  /** Send one EIP-1193 eth_sendTransaction request. Returns the wallet's tx hash. */
  async requestTransaction({ to, data, value, from, provider, gas } = {}) {
    const wallet = provider || this.provider;
    if (!wallet || typeof wallet.request !== "function")
      throw new Error("provider required");
    const sender = from || this.account;
    if (!sender) throw new Error("from required");
    if (!data) throw new Error("data required");
    const tx = { from: sender, data };
    if (to) tx.to = to;
    if (value != null) tx.value = quantityHex(value);
    if (gas != null) tx.gas = quantityHex(gas);
    return wallet.request({ method: "eth_sendTransaction", params: [tx] });
  }

  async registerAgent({ identityAddress, from, provider } = {}) {
    return this.requestTransaction({
      to: requiredAddress(
        identityAddress || this.identityAddress,
        "identityAddress",
      ),
      data: encodeRegisterAgent(),
      from,
      provider,
    });
  }

  async setReputationSource({
    identityAddress,
    agentId,
    source,
    from,
    provider,
  }) {
    return this.requestTransaction({
      to: requiredAddress(
        identityAddress || this.identityAddress,
        "identityAddress",
      ),
      data: encodeSetReputationSource(agentId, source),
      from,
      provider,
    });
  }

  async deployVault({
    bytecode,
    asset,
    agentId,
    identityAddress,
    registryAddress,
    from,
    provider,
  }) {
    return this.requestTransaction({
      data: encodeDeployVault(
        bytecode,
        asset,
        agentId,
        requiredAddress(
          identityAddress || this.identityAddress,
          "identityAddress",
        ),
        requiredAddress(
          registryAddress || this.registryAddress,
          "registryAddress",
        ),
      ),
      from,
      provider,
    });
  }

  async approveAdapter({ registryAddress, adapter, from, provider }) {
    return this.requestTransaction({
      to: requiredAddress(
        registryAddress || this.registryAddress,
        "registryAddress",
      ),
      data: encodeApproveAdapter(adapter),
      from,
      provider,
    });
  }

  async approveStrategy({ vaultAddress, adapter, from, provider }) {
    return this.requestTransaction({
      to: requiredAddress(vaultAddress, "vaultAddress"),
      data: encodeApproveStrategy(adapter),
      from,
      provider,
    });
  }

  async approveToken({ tokenAddress, spender, amount, from, provider }) {
    return this.requestTransaction({
      to: requiredAddress(tokenAddress, "tokenAddress"),
      data: encodeErc20Approve(spender, amount),
      from,
      provider,
    });
  }

  async postBond({ bondAddress, agentId, amount, from, provider }) {
    return this.requestTransaction({
      to: requiredAddress(bondAddress || this.bondAddress, "bondAddress"),
      data: encodePostBond(agentId, amount),
      from,
      provider,
    });
  }

  async selfListVault({ indexAddress, vault, from, provider }) {
    return this.requestTransaction({
      to: requiredAddress(indexAddress || this.indexAddress, "indexAddress"),
      data: encodeSelfListVault(vault),
      from,
      provider,
    });
  }

  async publishReceipt({
    vaultAddress,
    seq,
    evidenceHash,
    claimedDelta,
    period,
    signature,
    from,
    provider,
  }) {
    return this.requestTransaction({
      to: requiredAddress(vaultAddress, "vaultAddress"),
      data: encodePublishReceipt(
        seq,
        evidenceHash,
        claimedDelta,
        period,
        signature,
      ),
      from,
      provider,
    });
  }
}

export default ReefClient;
