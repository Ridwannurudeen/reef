// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockYieldAdapter} from "../src/adapters/MockYieldAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MockYieldAdapterTest is Test {
    MockYieldAdapter adapter;
    MockERC20 token;
    address vault = makeAddr("vault");
    address stranger = makeAddr("stranger");
    uint256 constant APR_BPS = 1000; // 10% annual

    function setUp() public {
        token = new MockERC20();
        adapter = new MockYieldAdapter(address(token), vault, APR_BPS);
    }

    function _deploy(uint256 amount) internal {
        token.mint(address(adapter), amount); // vault transfers in before calling deploy
        vm.prank(vault);
        adapter.deploy(amount);
    }

    function test_constructor_setsFields_rejectsZero() public {
        assertEq(adapter.asset(), address(token));
        assertEq(adapter.vault(), vault);
        assertEq(adapter.aprBps(), APR_BPS);
        vm.expectRevert(bytes("zero addr"));
        new MockYieldAdapter(address(0), vault, APR_BPS);
        vm.expectRevert(bytes("zero addr"));
        new MockYieldAdapter(address(token), address(0), APR_BPS);
    }

    function test_deploy_onlyVault() public {
        token.mint(address(adapter), 100e18);
        vm.prank(stranger);
        vm.expectRevert(bytes("not vault"));
        adapter.deploy(100e18);
    }

    function test_deploy_setsPrincipal_noYieldAtT0() public {
        _deploy(100e18);
        assertEq(adapter.principal(), 100e18);
        assertEq(adapter.totalUnderlying(), 100e18);
    }

    /// The core "real NAV" property: marked value grows with time.
    function test_totalUnderlying_accruesLinearly() public {
        _deploy(100e18);
        vm.warp(block.timestamp + 365 days);
        assertEq(adapter.totalUnderlying(), 110e18); // +10%
        vm.warp(block.timestamp + 365 days);
        assertEq(adapter.totalUnderlying(), 120e18); // +20% total (linear on principal)
    }

    function test_recall_realizesYield_byMinting() public {
        _deploy(100e18);
        vm.warp(block.timestamp + 365 days);
        uint256 marked = adapter.totalUnderlying(); // 110e18
        assertEq(marked, 110e18);

        vm.prank(vault);
        uint256 r = adapter.recall(marked);
        assertEq(r, 110e18);
        assertEq(token.balanceOf(vault), 110e18); // 100 principal + 10 minted yield
        assertEq(adapter.principal(), 0);
        assertEq(adapter.totalUnderlying(), 0);
    }

    function test_recall_capsAtMarkedValue() public {
        _deploy(100e18);
        vm.warp(block.timestamp + 365 days);
        vm.prank(vault);
        uint256 r = adapter.recall(1_000e18); // ask for more than marked
        assertEq(r, 110e18);
        assertEq(adapter.principal(), 0);
    }

    function test_recall_partial_leavesAccruingRemainder() public {
        _deploy(100e18);
        vm.warp(block.timestamp + 365 days); // marked = 110e18
        vm.prank(vault);
        adapter.recall(50e18);
        assertEq(adapter.principal(), 60e18); // 110 - 50
        // remainder keeps accruing from here
        vm.warp(block.timestamp + 365 days);
        assertEq(adapter.totalUnderlying(), 66e18); // 60 + 10%
    }

    function test_secondDeploy_foldsAccruedYieldIntoPrincipal() public {
        _deploy(100e18);
        vm.warp(block.timestamp + 365 days); // marked = 110e18
        _deploy(40e18); // principal = 110 + 40
        assertEq(adapter.principal(), 150e18);
        assertEq(adapter.totalUnderlying(), 150e18); // freshly checkpointed, no elapsed time
    }
}
