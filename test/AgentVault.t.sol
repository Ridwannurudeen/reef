// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategyAdapter} from "./mocks/MockStrategyAdapter.sol";

contract AgentVaultTest is Test {
    AgentIdentity identity;
    AgentVault vault;
    MockERC20 token;
    MockStrategyAdapter strategy;

    address operator = makeAddr("operator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint256 agentId;

    function setUp() public {
        identity = new AgentIdentity();
        token = new MockERC20();

        vm.prank(operator);
        agentId = identity.register();

        vault = new AgentVault(address(token), agentId, address(identity));
        strategy = new MockStrategyAdapter(address(token), address(vault));

        // Approve strategy on the vault
        vm.prank(operator);
        vault.approveStrategy(address(strategy));

        // Seed depositors
        token.mint(alice, 1_000e18);
        token.mint(bob, 1_000e18);
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);
    }

    // --- Deposit / Withdraw ---

    function test_deposit_mintsSharesOneToOne_first() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(100e18);
        assertEq(shares, 100e18);
        assertEq(vault.balanceOf(alice), 100e18);
        assertEq(vault.totalShares(), 100e18);
        assertEq(token.balanceOf(address(vault)), 100e18);
    }

    function test_deposit_secondDepositor_pro_rata() public {
        vm.prank(alice);
        vault.deposit(100e18);
        vm.prank(bob);
        uint256 shares = vault.deposit(50e18);
        assertEq(shares, 50e18); // NAV is still 1.0
        assertEq(vault.totalShares(), 150e18);
    }

    function test_deposit_revertsZero() public {
        vm.prank(alice);
        vm.expectRevert(bytes("zero assets"));
        vault.deposit(0);
    }

    function test_withdraw_returnsAssets() public {
        vm.prank(alice);
        vault.deposit(100e18);
        vm.prank(alice);
        uint256 got = vault.withdraw(40e18);
        assertEq(got, 40e18);
        assertEq(vault.balanceOf(alice), 60e18);
        assertEq(token.balanceOf(alice), 1_000e18 - 100e18 + 40e18);
    }

    function test_withdraw_revertsInsufficientShares() public {
        vm.prank(alice);
        vault.deposit(100e18);
        vm.prank(alice);
        vm.expectRevert(bytes("insufficient shares"));
        vault.withdraw(200e18);
    }

    // --- Strategy ---

    function test_approveStrategy_onlyOperator() public {
        MockStrategyAdapter other = new MockStrategyAdapter(address(token), address(vault));
        vm.prank(alice);
        vm.expectRevert(bytes("not operator"));
        vault.approveStrategy(address(other));
    }

    function test_deployToStrategy_movesFunds() public {
        vm.prank(alice);
        vault.deposit(100e18);
        vm.prank(operator);
        vault.deployToStrategy(address(strategy), 80e18);
        assertEq(token.balanceOf(address(vault)), 20e18);
        assertEq(token.balanceOf(address(strategy)), 80e18);
        assertEq(vault.currentStrategy(), address(strategy));
        assertEq(vault.totalAssets(), 100e18);
    }

    function test_recallFromStrategy_pullsBack_andClearsSlot() public {
        vm.prank(alice);
        vault.deposit(100e18);
        vm.prank(operator);
        vault.deployToStrategy(address(strategy), 100e18);
        vm.prank(operator);
        vault.recallFromStrategy(address(strategy), 100e18);
        assertEq(token.balanceOf(address(vault)), 100e18);
        assertEq(vault.currentStrategy(), address(0));
    }

    function test_withdraw_autoRecallsFromStrategy() public {
        vm.prank(alice);
        vault.deposit(100e18);
        vm.prank(operator);
        vault.deployToStrategy(address(strategy), 80e18); // 20 idle, 80 deployed
        vm.prank(alice);
        uint256 got = vault.withdraw(60e18); // needs 40 more than idle
        assertEq(got, 60e18);
        assertEq(token.balanceOf(alice), 1_000e18 - 100e18 + 60e18);
    }

    // --- Receipts ---

    function test_publishReceipt_strictSeq_updatesReputation() public {
        bytes32 evidence = keccak256("ev1");
        bytes memory r = abi.encode(uint256(0), evidence, int256(5e17), uint64(3600));

        vm.prank(operator);
        vault.publishReceipt(r);

        assertEq(vault.nextReceiptSeq(), 1);
        assertEq(vault.lastReceiptEvidenceHash(), evidence);
        (int256 cum, uint256 count) = identity.getSummary(agentId);
        assertEq(cum, 5e17);
        assertEq(count, 1);
    }

    function test_publishReceipt_badSeq_reverts() public {
        bytes memory r = abi.encode(uint256(1), keccak256("ev"), int256(1), uint64(60));
        vm.prank(operator);
        vm.expectRevert(bytes("bad seq"));
        vault.publishReceipt(r);
    }

    function test_publishReceipt_onlyOperator() public {
        bytes memory r = abi.encode(uint256(0), keccak256("ev"), int256(1), uint64(60));
        vm.prank(alice);
        vm.expectRevert(bytes("not operator"));
        vault.publishReceipt(r);
    }

    // --- Views ---

    function test_nav_oneInitially() public {
        assertEq(vault.nav(), 1e18);
    }

    function test_snapshot_reflectsState() public {
        vm.prank(alice);
        vault.deposit(100e18);
        vm.prank(operator);
        vault.deployToStrategy(address(strategy), 60e18);
        AgentVault.VaultView memory v = vault.snapshot();
        assertEq(v.agentId, agentId);
        assertEq(v.asset, address(token));
        assertEq(v.totalAssets, 100e18);
        assertEq(v.totalShares, 100e18);
        assertEq(v.idle, 40e18);
        assertEq(v.outstanding, 60e18);
    }
}
