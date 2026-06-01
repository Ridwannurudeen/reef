// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {UsdeAdapter} from "../src/adapters/UsdeAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract UsdeAdapterTest is Test {
    UsdeAdapter adapter;
    MockERC20 usde;
    address vault = makeAddr("vault");
    address stranger = makeAddr("stranger");

    function setUp() public {
        usde = new MockERC20();
        adapter = new UsdeAdapter(address(usde), vault);
    }

    function test_constructor_setsAsset_andVault() public {
        assertEq(adapter.asset(), address(usde));
        assertEq(adapter.vault(), vault);
    }

    function test_constructor_rejectsZero() public {
        vm.expectRevert(bytes("zero addr"));
        new UsdeAdapter(address(0), vault);
        vm.expectRevert(bytes("zero addr"));
        new UsdeAdapter(address(usde), address(0));
    }

    function test_deploy_recordsPrincipal_onlyVault() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("not vault"));
        adapter.deploy(100e18);

        usde.mint(address(adapter), 100e18);
        vm.prank(vault);
        uint256 d = adapter.deploy(100e18);
        assertEq(d, 100e18);
        assertEq(adapter.cumulativePrincipal(), 100e18);
        assertEq(adapter.totalUnderlying(), 100e18);
    }

    function test_recall_returnsToken_decrementsPrincipal() public {
        usde.mint(address(adapter), 100e18);
        vm.prank(vault);
        adapter.deploy(100e18);
        vm.prank(vault);
        uint256 r = adapter.recall(40e18);
        assertEq(r, 40e18);
        assertEq(usde.balanceOf(vault), 40e18);
        assertEq(adapter.cumulativePrincipal(), 60e18);
    }

    function test_recall_capsAtBalance() public {
        usde.mint(address(adapter), 100e18);
        vm.prank(vault);
        adapter.deploy(100e18);
        usde.mint(address(adapter), 3e18); // simulated yield
        vm.prank(vault);
        uint256 r = adapter.recall(200e18);
        assertEq(r, 103e18);
        assertEq(adapter.cumulativePrincipal(), 0);
    }
}
