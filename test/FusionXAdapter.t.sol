// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FusionXAdapter} from "../src/adapters/FusionXAdapter.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Router} from "./mocks/MockV2Router.sol";

/// @notice Proves the FusionX strategy adapter's deploy -> mark-to-market -> recall loop
/// against a deterministic AMM: NAV tracks the real position value, market moves change it,
/// and recall always hands the vault the exact amount it asked for (capped at the position).
/// This test contract plays the role of the vault.
contract FusionXAdapterTest is Test {
    MockERC20 asset; // vault asset (stable)
    MockERC20 long; // volatile market token
    MockV2Router router;
    FusionXAdapter adapter;

    function setUp() public {
        asset = new MockERC20();
        long = new MockERC20();
        router = new MockV2Router(address(asset), address(long), 2e18); // 1 asset -> 2 long
        adapter = new FusionXAdapter(address(asset), address(long), address(router), address(this), 300);
        // Fund the router so it can pay out both sides of swaps.
        asset.mint(address(router), 1_000_000e18);
        long.mint(address(router), 1_000_000e18);
        // The vault (this) holds asset to deploy.
        asset.mint(address(this), 1_000e18);
    }

    function _deploy(uint256 amount) internal {
        // Mimic AgentVault.deployToStrategy: transfer asset to the adapter, then deploy.
        asset.transfer(address(adapter), amount);
        adapter.deploy(amount);
    }

    function test_deploy_buysLong_navMatchesAtFlatPrice() public {
        _deploy(100e18);
        assertEq(long.balanceOf(address(adapter)), 200e18); // 100 asset * 2
        assertEq(adapter.totalUnderlying(), 100e18); // marked back to asset at the same price
    }

    function test_nav_movesWithMarket() public {
        _deploy(100e18);
        // Long appreciates: price drops to 1 asset -> 1 long (each long now worth 2x in asset).
        router.setPrice(1e18);
        assertEq(adapter.totalUnderlying(), 200e18); // 200 long now marks to 200 asset (+100 gain)
        // Long depreciates: 1 asset -> 4 long (each long worth half).
        router.setPrice(4e18);
        assertEq(adapter.totalUnderlying(), 50e18); // 200 long marks to 50 asset (loss)
    }

    function test_recall_returnsExactAmount_toVault() public {
        _deploy(100e18);
        router.setPrice(1e18); // position now worth 200 asset
        uint256 before = asset.balanceOf(address(this));
        uint256 got = adapter.recall(50e18);
        assertEq(got, 50e18);
        assertEq(asset.balanceOf(address(this)) - before, 50e18); // vault got exactly 50
        assertApproxEqAbs(adapter.totalUnderlying(), 150e18, 1); // ~150 asset of position left
    }

    function test_recall_capsAtPositionValue() public {
        _deploy(100e18); // worth 100 asset at flat price
        uint256 got = adapter.recall(1_000e18); // ask for more than the position holds
        assertApproxEqAbs(got, 100e18, 2); // capped at ~the position value
        assertEq(long.balanceOf(address(adapter)), 0); // sold the whole position
    }

    function test_deploy_onlyVault() public {
        MockV2Router r2 = new MockV2Router(address(asset), address(long), 2e18);
        FusionXAdapter a2 = new FusionXAdapter(address(asset), address(long), address(r2), address(0xBEEF), 300);
        vm.expectRevert(bytes("not vault"));
        a2.deploy(1e18);
    }

    /// End-to-end: a real AgentVault's NAV is driven by the live DEX position value.
    function test_vault_navDrivenByRealDexPosition() public {
        address operator = makeAddr("operator");
        address depositor = makeAddr("depositor");
        AgentIdentity identity = new AgentIdentity();
        AdapterRegistry registry = new AdapterRegistry();

        vm.prank(operator);
        uint256 agentId = identity.register();
        AgentVault vault = new AgentVault(address(asset), agentId, address(identity), address(registry));
        FusionXAdapter ad = new FusionXAdapter(address(asset), address(long), address(router), address(vault), 300);
        registry.approveAdapter(address(ad));
        vm.prank(operator);
        vault.approveStrategy(address(ad));

        // Depositor puts 100 asset in; operator deploys it all into the DEX position.
        asset.mint(depositor, 100e18);
        vm.startPrank(depositor);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(100e18);
        vm.stopPrank();
        assertEq(vault.nav(), 1e18); // 1.0 at entry

        vm.prank(operator);
        vault.deployToStrategy(address(ad), 100e18); // swaps 100 asset -> 200 long
        assertApproxEqAbs(vault.totalAssets(), 100e18, 1); // marked back at flat price

        // Market moves: long appreciates 2x -> the vault's NAV rises with the real position.
        router.setPrice(1e18);
        assertApproxEqAbs(vault.totalAssets(), 200e18, 1);
        assertApproxEqAbs(vault.nav(), 2e18, 1e9); // NAV doubled, driven by the DEX mark

        // Depositor withdraws half their shares -> vault recalls from the DEX (sells long).
        uint256 before = asset.balanceOf(depositor);
        vm.prank(depositor);
        vault.withdraw(50e18); // 50 of 100 shares; ~100 asset at nav 2.0
        assertApproxEqAbs(asset.balanceOf(depositor) - before, 100e18, 1e15);
    }

    function test_constructor_rejectsZeroAndHighSlippage() public {
        vm.expectRevert(bytes("zero addr"));
        new FusionXAdapter(address(0), address(long), address(router), address(this), 300);
        vm.expectRevert(bytes("slippage too high"));
        new FusionXAdapter(address(asset), address(long), address(router), address(this), 6000);
    }
}
