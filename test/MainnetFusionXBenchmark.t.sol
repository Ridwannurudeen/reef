// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeployMainnetFusionX} from "../script/DeployMainnetFusionX.s.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {FusionXAdapter} from "../src/adapters/FusionXAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Router} from "./mocks/MockV2Router.sol";

/// @notice Exercises the REAL DeployMainnetFusionX.deployBenchmark() wiring against a
/// deterministic AMM (not a copy of the loop). Proves the 4-agent benchmark is wired exactly
/// as the mainnet deploy will wire it: sequential agent ids, each adapter vetted in the
/// registry AND set as its vault's strategy, each vault bound as its agent's reputation source,
/// the registry two-key gate biting, and a real deposit->deploy round-trip marking NAV.
contract MainnetFusionXBenchmarkTest is Test {
    DeployMainnetFusionX dep;
    MockERC20 asset; // stands in for USDC
    MockERC20 long; // stands in for WMNT
    MockV2Router router;

    uint256 constant COUNT = 4;
    uint256 constant SLIPPAGE_BPS = 150;

    function setUp() public {
        dep = new DeployMainnetFusionX();
        asset = new MockERC20();
        long = new MockERC20();
        router = new MockV2Router(address(asset), address(long), 2e18); // 1 asset -> 2 long
        asset.mint(address(router), 1_000_000e18);
        long.mint(address(router), 1_000_000e18);
    }

    function _build()
        internal
        returns (AgentIdentity identity, AdapterRegistry registry, DeployMainnetFusionX.Pair[] memory pairs)
    {
        return dep.deployBenchmark(address(asset), address(long), address(router), COUNT, SLIPPAGE_BPS);
    }

    function test_wiring_allPairsRegisteredAndWired() public {
        (AgentIdentity identity, AdapterRegistry registry, DeployMainnetFusionX.Pair[] memory pairs) = _build();

        assertEq(pairs.length, COUNT, "pair count");
        assertEq(identity.nextAgentId(), COUNT + 1, "ids 1..COUNT registered");

        for (uint256 i = 0; i < COUNT; i++) {
            DeployMainnetFusionX.Pair memory p = pairs[i];
            assertEq(p.agentId, i + 1, "sequential agent id");
            // adapter vetted in the registry (protocol key)
            assertTrue(registry.isApproved(address(p.adapter)), "adapter registry-approved");
            // adapter wired as the vault's strategy (operator key)
            assertTrue(p.vault.approvedStrategies(address(p.adapter)), "strategy approved on vault");
            // vault bound as the agent's reputation source (vault-only reputation)
            assertEq(identity.reputationSource(p.agentId), address(p.vault), "reputation source = vault");
        }
    }

    function test_gate_unregisteredAdapterCannotBeWired() public {
        (, AdapterRegistry registry, DeployMainnetFusionX.Pair[] memory pairs) = _build();
        AgentVault vault = pairs[0].vault;

        // A fresh adapter that was never approved in the registry must be rejected by the
        // vault's two-key gate, even when the operator tries to wire it.
        FusionXAdapter rogue = new FusionXAdapter(address(asset), address(long), address(router), address(vault), 150);
        assertFalse(registry.isApproved(address(rogue)), "rogue not registry-approved");

        vm.prank(address(dep)); // operator = the registrant (dep)
        vm.expectRevert();
        vault.approveStrategy(address(rogue));
    }

    function test_e2e_depositDeployMarksNav() public {
        (,, DeployMainnetFusionX.Pair[] memory pairs) = _build();
        AgentVault vault = pairs[0].vault;
        FusionXAdapter adapter = pairs[0].adapter;

        uint256 amt = 1_000e18;
        asset.mint(address(dep), amt);

        vm.startPrank(address(dep)); // dep is the agent wallet => vault operator
        asset.approve(address(vault), amt);
        vault.deposit(amt);
        vault.deployToStrategy(address(adapter), 800e18); // deploy 80% into the WMNT long
        vm.stopPrank();

        assertGt(long.balanceOf(address(adapter)), 0, "adapter holds the long position");
        // Flat-price round-trip: NAV stays ~1.0 (mark-to-market via the router quote).
        assertApproxEqRel(vault.nav(), 1e18, 0.01e18, "nav marked ~1.0 at flat price");
        assertApproxEqRel(vault.totalAssets(), amt, 0.01e18, "total assets preserved at flat price");
    }
}
