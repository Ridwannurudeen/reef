// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentIndex} from "../src/AgentIndex.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {MockYieldAdapter} from "../src/adapters/MockYieldAdapter.sol";
import {ReputationBond} from "../src/ReputationBond.sol";
import {Seasons} from "../src/Seasons.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Bring a seeded Reef instance to full on-chain parity with the source:
/// (1) wire a MockYieldAdapter into one vault so vault/index NAV grows on-chain
/// (Phase 2 "Real NAV"); (2) deploy a ReputationBond, post bonds for every indexed
/// agent, and activate the index bond-gate (Phase 3); (3) deploy Seasons, open a
/// season and enroll every agent on a Human/AI side (Phase 4). Run once against a
/// fresh seeded instance (not idempotent).
///
/// Required env: PRIVATE_KEY, ASSET (mintable mock), IDENTITY, INDEX, REGISTRY,
/// YIELD_VAULT. Deployer must be the index governor, registry governor, and operator
/// of every indexed agent.
contract DeployParity is Script {
    uint256 constant SLASH = 10e18;
    uint256 constant STAKE = 5e18;
    uint256 constant BOND = 50e18;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        address yield_ = _wireYield();
        address bond = _deployBonds(pk);
        address seasons = _deploySeasons();
        vm.stopBroadcast();

        console.log("=== Reef parity deployed ===");
        console.log("MockYieldAdapter :", yield_);
        console.log("ReputationBond   :", bond);
        console.log("Seasons          :", seasons);
    }

    /// Phase 2: live time-growing NAV via a MockYieldAdapter (2000 bps APR).
    function _wireYield() internal returns (address) {
        MockERC20 asset = MockERC20(vm.envAddress("ASSET"));
        AdapterRegistry registry = AdapterRegistry(vm.envAddress("REGISTRY"));
        AgentVault vault = AgentVault(vm.envAddress("YIELD_VAULT"));
        MockYieldAdapter yield_ = new MockYieldAdapter(address(asset), address(vault), 2000);
        registry.approveAdapter(address(yield_));
        vault.approveStrategy(address(yield_));
        uint256 idle = asset.balanceOf(address(vault));
        if (idle > 0) vault.deployToStrategy(address(yield_), idle / 2);
        return address(yield_);
    }

    /// Phase 3: ReputationBond + bond every indexed agent, then activate the gate.
    function _deployBonds(uint256 pk) internal returns (address) {
        MockERC20 asset = MockERC20(vm.envAddress("ASSET"));
        AgentIndex index = AgentIndex(vm.envAddress("INDEX"));
        ReputationBond bond =
            new ReputationBond(address(asset), vm.envAddress("IDENTITY"), vm.addr(pk), STAKE, SLASH, 1 days);
        uint256 n = index.vaultCount();
        asset.mint(vm.addr(pk), BOND * n);
        asset.approve(address(bond), BOND * n);
        for (uint256 i = 0; i < n; i++) {
            bond.postBond(AgentVault(address(index.vaults(i))).agentId(), BOND);
        }
        index.setReputationBond(address(bond), SLASH);
        return address(bond);
    }

    /// Phase 4: open a 7-day season and enroll every agent (alternating sides).
    function _deploySeasons() internal returns (address) {
        AgentIndex index = AgentIndex(vm.envAddress("INDEX"));
        Seasons seasons = new Seasons(vm.envAddress("IDENTITY"));
        uint256 id = seasons.startSeason(7 days);
        uint256 n = index.vaultCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 aid = AgentVault(address(index.vaults(i))).agentId();
            seasons.enroll(id, aid, aid % 2 == 0 ? Seasons.Side.AI : Seasons.Side.Human);
        }
        return address(seasons);
    }
}
