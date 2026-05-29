// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {UsdyAdapter} from "../src/adapters/UsdyAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract UsdyAdapterTest is Test {
    UsdyAdapter adapter;
    MockERC20 usdy;
    address vault = makeAddr("vault");
    address stranger = makeAddr("stranger");

    function setUp() public {
        usdy = new MockERC20();
        adapter = new UsdyAdapter(address(usdy), vault);
    }

    function test_constructor_setsAsset_andVault() public {
        assertEq(adapter.asset(), address(usdy));
        assertEq(adapter.vault(), vault);
        assertEq(adapter.cumulativePrincipal(), 0);
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(bytes("zero addr"));
        new UsdyAdapter(address(0), vault);
        vm.expectRevert(bytes("zero addr"));
        new UsdyAdapter(address(usdy), address(0));
    }

    function test_deploy_recordsPrincipal_onlyVault() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("not vault"));
        adapter.deploy(100e18);

        usdy.mint(address(adapter), 100e18);
        vm.prank(vault);
        uint256 deployed = adapter.deploy(100e18);
        assertEq(deployed, 100e18);
        assertEq(adapter.cumulativePrincipal(), 100e18);
        assertEq(adapter.totalUnderlying(), 100e18);
    }

    function test_recall_movesUsdy_andUpdatesPrincipal() public {
        usdy.mint(address(adapter), 100e18);
        vm.prank(vault);
        adapter.deploy(100e18);

        vm.prank(vault);
        uint256 recalled = adapter.recall(40e18);
        assertEq(recalled, 40e18);
        assertEq(usdy.balanceOf(vault), 40e18);
        assertEq(adapter.cumulativePrincipal(), 60e18);
        assertEq(adapter.totalUnderlying(), 60e18);
    }

    function test_recall_capsAtBalance_clampsPrincipalToZero() public {
        usdy.mint(address(adapter), 100e18);
        vm.prank(vault);
        adapter.deploy(100e18);

        // Simulate accrued yield: more USDY appears than principal (e.g. via top-up by Ondo)
        usdy.mint(address(adapter), 5e18);

        vm.prank(vault);
        uint256 recalled = adapter.recall(200e18); // requested more than balance
        assertEq(recalled, 105e18); // capped at full balance
        assertEq(adapter.cumulativePrincipal(), 0);
        assertEq(adapter.totalUnderlying(), 0);
    }

    function test_recall_onlyVault() public {
        usdy.mint(address(adapter), 100e18);
        vm.prank(vault);
        adapter.deploy(100e18);
        vm.prank(stranger);
        vm.expectRevert(bytes("not vault"));
        adapter.recall(10e18);
    }

    function test_multipleDeploys_accumulatePrincipal() public {
        usdy.mint(address(adapter), 100e18);
        vm.prank(vault);
        adapter.deploy(60e18);
        vm.prank(vault);
        adapter.deploy(40e18);
        assertEq(adapter.cumulativePrincipal(), 100e18);
    }
}
