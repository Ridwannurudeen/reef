import assert from "node:assert/strict";
import test from "node:test";

import {
  ReefClient,
  encodeApproveAdapter,
  encodeApproveStrategy,
  decodeCanExecuteAction,
  encodeCanExecuteAction,
  encodeDeployVault,
  encodeErc20Approve,
  encodePostBond,
  encodePublishReceipt,
  encodeRegisterAgent,
  encodeSelfListVault,
  encodeSetReputationSource,
} from "./reef.js";

const A = "0x00000000000000000000000000000000000000a1";
const B = "0x00000000000000000000000000000000000000b2";
const C = "0x00000000000000000000000000000000000000c3";
const FROM = "0x0000000000000000000000000000000000000f00";

function word(n) {
  return BigInt(n).toString(16).padStart(64, "0");
}

test("encodes Reef write calls with verified selectors", () => {
  assert.equal(encodeRegisterAgent(), "0x1aa3a008");
  assert.equal(encodeSetReputationSource(7, A).slice(0, 10), "0xaf2a5652");
  assert.equal(encodeApproveAdapter(A).slice(0, 10), "0xc0e2ffc4");
  assert.equal(encodeApproveStrategy(A).slice(0, 10), "0x3b8ae397");
  assert.equal(encodePostBond(7, 10n ** 18n).slice(0, 10), "0x184fed04");
  assert.equal(encodeSelfListVault(A).slice(0, 10), "0xaefca159");
  assert.equal(encodeErc20Approve(A, 123n).slice(0, 10), "0x095ea7b3");
});

test("encodes publishReceipt dynamic signature bytes", () => {
  const evidence = "0x" + "ab".repeat(32);
  const signature = "0x" + "12".repeat(65);
  const data = encodePublishReceipt(1, evidence, -5, 600, signature);
  assert.equal(data.slice(0, 10), "0xcda9e6ad");
  assert.equal(data.slice(10 + 64 * 4, 10 + 64 * 5), "0".repeat(61) + "0a0");
  assert.equal(data.slice(10 + 64 * 5, 10 + 64 * 6), "0".repeat(62) + "41");
  assert.equal(data.length, 2 + 8 + 64 * 9);
});

test("encodes and decodes canExecuteAction", () => {
  const actionData = encodeErc20Approve(B, 123n);
  const data = encodeCanExecuteAction(7, {
    target: A,
    value: 0,
    data: actionData,
    asset: A,
    portfolioValue: 1000n,
  });
  assert.equal(data.slice(0, 10), "0x7e056c47");
  assert.equal(data.slice(10, 74), word(7));
  assert.equal(data.slice(74, 138), word(64)); // dynamic Action tuple offset
  assert.equal(data.slice(138, 202), A.slice(2).padStart(64, "0"));
  assert.equal(data.slice(202 + 64, 202 + 128), word(160)); // bytes field offset inside tuple

  const okReturn =
    "0x" +
    word(1) +
    word(128) +
    word(123) +
    word(456) +
    word(2) +
    Buffer.from("ok").toString("hex").padEnd(64, "0");
  assert.deepEqual(decodeCanExecuteAction(okReturn), {
    allowed: true,
    reason: "ok",
    amount: 123n,
    sizeBps: 456,
  });
});

test("builds AgentVault deployment data", () => {
  const data = encodeDeployVault("0x6000", A, 9, B, C);
  assert.equal(data.slice(0, 6), "0x6000");
  assert.equal(data.length, 2 + 4 + 64 * 4);
});

test("sends write helpers through an EIP-1193 provider", async () => {
  const calls = [];
  const provider = {
    async request(payload) {
      calls.push(payload);
      return "0xtx";
    },
  };
  const client = new ReefClient({
    provider,
    account: FROM,
    identityAddress: A,
    indexAddress: B,
    bondAddress: C,
  });

  assert.equal(await client.registerAgent(), "0xtx");
  assert.deepEqual(calls[0], {
    method: "eth_sendTransaction",
    params: [{ from: FROM, data: "0x1aa3a008", to: A }],
  });

  await client.selfListVault({ vault: A });
  assert.equal(calls[1].params[0].to, B);
  assert.equal(calls[1].params[0].data.slice(0, 10), "0xaefca159");

  await client.requestTransaction({
    from: FROM,
    data: "0x1234",
    value: "1000000000000000000",
    gas: 21000,
  });
  assert.equal(calls[2].params[0].value, "0xde0b6b3a7640000");
  assert.equal(calls[2].params[0].gas, "0x5208");
});

test("validates deployVault addresses before sending", async () => {
  const client = new ReefClient({
    provider: { async request() {} },
    account: FROM,
  });

  await assert.rejects(
    () => client.deployVault({ bytecode: "0x6000", asset: A, agentId: 1 }),
    /identityAddress required/,
  );
});
