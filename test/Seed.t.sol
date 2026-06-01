// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Seed} from "../script/Seed.s.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentIndex} from "../src/AgentIndex.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Drives the real Seed script against a fresh in-memory deployment and
/// asserts it still produces the differentiated, reputation-weighted allocation
/// (1:2:3:5:8 → ~526/1052/1578/2631/4210 bps) under the NAV-derived reputation model.
contract SeedTest is Test {
    function test_seed_producesReputationWeightedAllocation() public {
        uint256 pk = 0xA11CE;
        address deployer = vm.addr(pk);

        MockERC20 asset = new MockERC20();
        AgentIdentity identity = new AgentIdentity();
        AgentIndex index = new AgentIndex(address(asset), address(identity));
        index.setGovernor(deployer); // Seed requires the deployer to be the index governor

        vm.setEnv("PRIVATE_KEY", vm.toString(pk));
        vm.setEnv("ASSET", vm.toString(address(asset)));
        vm.setEnv("IDENTITY", vm.toString(address(identity)));
        vm.setEnv("INDEX", vm.toString(address(index)));

        new Seed().run();

        AgentIndex.Allocation[] memory alloc = index.getAllocation();
        assertEq(alloc.length, 5, "five vaults seeded");

        // Weights track positive cumulative reputation = the seeded NAV deltas 1:2:3:5:8.
        uint16[5] memory expected = [uint16(526), 1052, 1578, 2631, 4210];
        for (uint256 i = 0; i < 5; i++) {
            assertApproxEqAbs(alloc[i].weightBps, expected[i], 30, "weight off target");
        }
    }
}
