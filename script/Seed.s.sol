// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentIndex} from "../src/AgentIndex.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {IAgentVault} from "../src/interfaces/IAgentVault.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockStrategyAdapter} from "../test/mocks/MockStrategyAdapter.sol";

/// @notice Seed a deployed Reef index with demo AgentVaults so the leaderboard and
/// AgentIndex.rebalance() produce a non-trivial, reputation-weighted allocation.
/// Registers 5 agents (all owned by the deployer wallet), deploys a vault per agent,
/// authorizes each vault as its agent's reputation source, gives each vault a real,
/// differentiated on-chain NAV gain (deposit 1e18 principal + donate the target delta),
/// then publishes a receipt — reputation is NAV-derived (#4), so the credited weight
/// comes from the actual nav() change, not a claimed figure. Then calls rebalance().
///
/// Required env: PRIVATE_KEY, ASSET (mintable demo token), IDENTITY, INDEX.
/// The deployer must be the AgentIndex governor (it is when Deploy.s.sol set it).
/// Usage:
///   forge script script/Seed.s.sol --rpc-url <rpc> --broadcast
contract Seed is Script {
    bytes32 constant RECEIPT_TYPEHASH =
        keccak256(
            "Receipt(uint256 agentId,uint256 seq,bytes32 evidenceHash,bytes32 contextHash,uint64 decisionTimestamp,uint64 validUntil,uint64 period,uint256 decisionBlock,int256 claimedDelta)"
        );
    bytes32 constant EVIDENCE_URI_HASH = keccak256("ipfs://reef-seed-evidence");

    function _receipt(AgentVault vault, uint256 agentId, bytes32 evidence, int256 delta)
        internal
        view
        returns (IAgentVault.Receipt memory receipt)
    {
        uint64 period = 86_400;
        receipt = IAgentVault.Receipt({
            agentId: agentId,
            seq: vault.nextReceiptSeq(),
            evidenceHash: evidence,
            actionHash: keccak256(abi.encode("seed-action", address(vault))),
            policyHash: keccak256(abi.encode("seed-policy", address(vault))),
            executionHash: keccak256(abi.encode("seed-execution", address(vault))),
            postStateHash: keccak256(abi.encode("seed-post-state", address(vault))),
            outcomeHash: keccak256(abi.encode("seed-outcome", address(vault))),
            evidenceUriHash: EVIDENCE_URI_HASH,
            decisionTimestamp: uint64(block.timestamp),
            validUntil: uint64(block.timestamp + period),
            period: period,
            decisionBlock: block.number,
            claimedDelta: delta
        });
    }

    /// EIP-712-sign a receipt for `vault` with key `pk` (operator).
    function _sign(uint256 pk, AgentVault vault, IAgentVault.Receipt memory receipt)
        internal
        view
        returns (bytes memory)
    {
        bytes32 contextHash = keccak256(
            abi.encode(
                receipt.actionHash,
                receipt.policyHash,
                receipt.executionHash,
                receipt.postStateHash,
                receipt.outcomeHash,
                receipt.evidenceUriHash
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                RECEIPT_TYPEHASH,
                receipt.agentId,
                receipt.seq,
                receipt.evidenceHash,
                contextHash,
                receipt.decisionTimestamp,
                receipt.validUntil,
                receipt.period,
                receipt.decisionBlock,
                receipt.claimedDelta
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// Register an agent, deploy + authorize its vault, manufacture a differentiated
    /// per-share NAV gain (deposit 1e18 + donate `delta`), then submit an operator-signed
    /// NAV-derived receipt so reputation accrues to `delta`.
    function _seedAgent(
        MockERC20 asset,
        AgentIdentity identity,
        AgentIndex index,
        AdapterRegistry registry,
        uint256 pk,
        uint256 i,
        int256 delta
    ) internal {
        uint256 agentId = identity.register();
        AgentVault vault = new AgentVault(address(asset), agentId, address(identity), address(registry));
        identity.setReputationSource(agentId, address(vault)); // vault-only reputation (#1)
        index.addVault(address(vault));

        asset.mint(vm.addr(pk), 1e18);
        asset.approve(address(vault), 1e18);
        vault.deposit(1e18);

        // Donation-proof reputation: deploy the principal into a strategy and realize `delta` of
        // yield ON THE STRATEGY (mint to the adapter, not the vault), so reputableNav() rises by
        // exactly delta per share. A bare vault donation no longer credits reputation (#15).
        MockStrategyAdapter adapter = new MockStrategyAdapter(address(asset), address(vault));
        registry.approveAdapter(address(adapter));
        vault.approveStrategy(address(adapter));
        vault.deployToStrategy(address(adapter), 1e18);
        asset.mint(address(adapter), uint256(delta)); // strategy yield (unrealized mark)
        vault.recallFromStrategy(address(adapter), 1e18 + uint256(delta)); // realize it (cost basis)

        bytes32 evidence = keccak256(abi.encode("seed", i));
        IAgentVault.Receipt memory receipt = _receipt(vault, agentId, evidence, delta);
        vault.publishReceipt(receipt, _sign(pk, vault, receipt));
        console.log("agent", agentId, "vault", address(vault));
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        MockERC20 asset = MockERC20(vm.envAddress("ASSET"));
        AgentIdentity identity = AgentIdentity(vm.envAddress("IDENTITY"));
        AgentIndex index = AgentIndex(vm.envAddress("INDEX"));
        address deployer = vm.addr(pk);

        // Differentiated NAV deltas (18-decimal) → differentiated reputation weights.
        int256[5] memory navDeltas = [int256(1e18), int256(2e18), int256(3e18), int256(5e18), int256(8e18)];
        uint256 deposit = 1_000e18;

        vm.startBroadcast(pk);

        // Capital for the index to allocate.
        asset.mint(deployer, deposit);
        asset.approve(address(index), deposit);

        // Per-vault adapter allowlist (each demo vault deploys into a mock strategy that realizes
        // its seeded yield, so reputation comes from reputableNav growth, not a vault donation).
        AdapterRegistry registry = new AdapterRegistry();

        for (uint256 i = 0; i < navDeltas.length; i++) {
            _seedAgent(asset, identity, index, registry, pk, i, navDeltas[i]);
        }

        index.deposit(deposit);
        index.rebalance();

        vm.stopBroadcast();

        AgentIndex.Allocation[] memory alloc = index.getAllocation();
        console.log("=== Reef seeded ===");
        console.log("Vaults        :", index.vaultCount());
        console.log("Index assets  :", index.totalAssets());
        for (uint256 i = 0; i < alloc.length; i++) {
            console.log("  agent", alloc[i].agentId, "weightBps", alloc[i].weightBps);
        }
    }
}
