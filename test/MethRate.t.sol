// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {MethRate} from "../src/MethRate.sol";
import {MethRateAdapter} from "../src/adapters/MethRateAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MethRateTest is Test {
    MethRate rateStore;
    address keeper = makeAddr("keeper");
    address other = makeAddr("other");
    uint256 constant WAD = 1e18;

    function setUp() public {
        rateStore = new MethRate(keeper, 109e16); // 1.09 ETH per mETH
    }

    // --- Rate store ---

    function test_constructor_bounds() public {
        vm.expectRevert(bytes("zero keeper"));
        new MethRate(address(0), 11e17);
        vm.expectRevert(bytes("rate range"));
        new MethRate(keeper, 9e17); // < 1.0
        vm.expectRevert(bytes("rate range"));
        new MethRate(keeper, 2e18); // >= 2.0
    }

    function test_mETHToETH_marksAtRate() public view {
        assertEq(rateStore.mETHToETH(10e18), (10e18 * 109e16) / WAD); // 10.9 ETH
        assertEq(rateStore.mETHToETH(0), 0);
    }

    function test_setRate_onlyKeeper_andBounds() public {
        vm.prank(other);
        vm.expectRevert(bytes("not keeper"));
        rateStore.setRate(11e17);

        vm.startPrank(keeper);
        vm.expectRevert(bytes("rate range"));
        rateStore.setRate(9e17);
        vm.expectRevert(bytes("rate range"));
        rateStore.setRate(2e18);
        vm.expectRevert(bytes("rate step")); // > 5% from 1.09 in one push
        rateStore.setRate(120e16);
        rateStore.setRate(112e16);
        vm.stopPrank();
        assertEq(rateStore.rate(), 112e16);
    }

    function test_transferKeeper() public {
        vm.prank(keeper);
        rateStore.transferKeeper(other);
        assertEq(rateStore.keeper(), other);
        vm.prank(keeper);
        vm.expectRevert(bytes("not keeper"));
        rateStore.setRate(11e17);
    }

    function test_rateAge() public {
        assertEq(rateStore.rateAge(), 0);
        vm.warp(block.timestamp + 3600);
        assertEq(rateStore.rateAge(), 3600);
        vm.prank(keeper);
        rateStore.setRate(110e16);
        assertEq(rateStore.rateAge(), 0);
    }

    // --- Integration: vault NAV tracks the keeper-pushed rate via MethRateAdapter ---

    function test_integration_navTracksPushedRate() public {
        address operator = makeAddr("operator");
        address depositor = makeAddr("depositor");

        AgentIdentity identity = new AgentIdentity();
        vm.prank(operator);
        uint256 agentId = identity.register();
        MockERC20 meth = new MockERC20();
        AdapterRegistry registry = new AdapterRegistry();
        AgentVault vault = new AgentVault(address(meth), agentId, address(identity), address(registry));
        MethRateAdapter adapter = new MethRateAdapter(address(meth), address(vault), address(rateStore));
        registry.approveAdapter(address(adapter));
        vm.prank(operator);
        vault.approveStrategy(address(adapter));

        meth.mint(depositor, 100e18);
        vm.startPrank(depositor);
        meth.approve(address(vault), type(uint256).max);
        vault.deposit(100e18);
        vm.stopPrank();
        vm.prank(operator);
        vault.deployToStrategy(address(adapter), 80e18);

        // At 1.09: totalAssets = 20 idle + 80*1.09 mark = 107.2 -> nav 1.072
        uint256 navBefore = vault.nav();
        assertEq(navBefore, (1072e17 * WAD) / 100e18);

        // Keeper pushes a higher L1 rate -> NAV rises with no balance change (within the step cap).
        vm.prank(keeper);
        rateStore.setRate(114e16); // 1.14 (+4.6% from 1.09, under the 5% cap)
        assertGt(vault.nav(), navBefore);
        assertEq(vault.nav(), ((20e18 + (80e18 * 114e16) / WAD) * WAD) / 100e18);
    }
}
