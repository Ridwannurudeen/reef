// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Mi4Adapter} from "../src/adapters/Mi4Adapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract Mi4AdapterTest is Test {
    Mi4Adapter adapter;
    MockERC20 mi4;
    address vault = makeAddr("vault");
    address stranger = makeAddr("stranger");

    function setUp() public {
        mi4 = new MockERC20();
        adapter = new Mi4Adapter(address(mi4), vault);
    }

    function test_constructor_setsAsset_andVault() public {
        assertEq(adapter.asset(), address(mi4));
        assertEq(adapter.vault(), vault);
    }

    function test_constructor_rejectsZero() public {
        vm.expectRevert(bytes("zero addr"));
        new Mi4Adapter(address(0), vault);
        vm.expectRevert(bytes("zero addr"));
        new Mi4Adapter(address(mi4), address(0));
    }

    function test_deploy_recordsPrincipal_onlyVault() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("not vault"));
        adapter.deploy(100e18);

        mi4.mint(address(adapter), 100e18);
        vm.prank(vault);
        uint256 d = adapter.deploy(100e18);
        assertEq(d, 100e18);
        assertEq(adapter.cumulativePrincipal(), 100e18);
        assertEq(adapter.totalUnderlying(), 100e18);
    }

    function test_recall_returnsToken_decrementsPrincipal() public {
        mi4.mint(address(adapter), 100e18);
        vm.prank(vault);
        adapter.deploy(100e18);
        vm.prank(vault);
        uint256 r = adapter.recall(40e18);
        assertEq(r, 40e18);
        assertEq(mi4.balanceOf(vault), 40e18);
        assertEq(adapter.cumulativePrincipal(), 60e18);
    }

    function test_recall_capsAtBalance() public {
        mi4.mint(address(adapter), 100e18);
        vm.prank(vault);
        adapter.deploy(100e18);
        mi4.mint(address(adapter), 3e18); // simulated yield
        vm.prank(vault);
        uint256 r = adapter.recall(200e18);
        assertEq(r, 103e18);
        assertEq(adapter.cumulativePrincipal(), 0);
    }
}
