// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentIndex} from "../src/AgentIndex.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Seed a deployed Reef index with demo AgentVaults so the leaderboard and
/// AgentIndex.rebalance() produce a non-trivial, reputation-weighted allocation.
/// Registers 5 agents (all owned by the deployer wallet), deploys a vault per agent,
/// adds them to the index, deposits demo capital, and publishes one receipt per agent
/// with differentiated NAV deltas so reputations diverge. Then calls rebalance().
///
/// Required env: PRIVATE_KEY, ASSET (mintable demo token), IDENTITY, INDEX.
/// The deployer must be the AgentIndex governor (it is when Deploy.s.sol set it).
/// Usage:
///   forge script script/Seed.s.sol --rpc-url <rpc> --broadcast
contract Seed is Script {
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

        // Per-vault adapter allowlist (demo vaults hold the asset idle, no strategy set).
        AdapterRegistry registry = new AdapterRegistry();

        for (uint256 i = 0; i < navDeltas.length; i++) {
            uint256 agentId = identity.register();
            AgentVault vault = new AgentVault(address(asset), agentId, address(identity), address(registry));
            index.addVault(address(vault));
            vault.publishReceipt(abi.encode(uint256(0), keccak256(abi.encode("seed", i)), navDeltas[i], uint64(86_400)));
            console.log("agent", agentId, "vault", address(vault));
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
