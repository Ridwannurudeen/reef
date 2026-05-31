// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {AgentIndex} from "../src/AgentIndex.sol";
import {ReputationBond} from "../src/ReputationBond.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract AgentIndexTest is Test {
    AgentIdentity identity;
    AgentIndex index;
    AgentVault vaultA;
    AgentVault vaultB;
    MockERC20 token;

    address opA = makeAddr("opA");
    address opB = makeAddr("opB");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 idA;
    uint256 idB;

    function setUp() public {
        identity = new AgentIdentity();
        token = new MockERC20();
        index = new AgentIndex(address(token), address(identity));

        vm.prank(opA);
        idA = identity.register();
        vm.prank(opB);
        idB = identity.register();

        vaultA = new AgentVault(address(token), idA, address(identity));
        vaultB = new AgentVault(address(token), idB, address(identity));

        index.addVault(address(vaultA));
        index.addVault(address(vaultB));

        // Seed depositors and approve the index
        token.mint(alice, 1_000e18);
        token.mint(bob, 1_000e18);
        vm.prank(alice);
        token.approve(address(index), type(uint256).max);
        vm.prank(bob);
        token.approve(address(index), type(uint256).max);
    }

    // --- Registry ---

    function test_addVault_onlyGovernor_andOnce() public {
        AgentVault other = new AgentVault(address(token), idA, address(identity));
        vm.prank(alice);
        vm.expectRevert(bytes("not governor"));
        index.addVault(address(other));

        index.addVault(address(other));
        vm.expectRevert(bytes("registered"));
        index.addVault(address(other));
    }

    function test_addVault_rejectsWrongAsset() public {
        MockERC20 otherToken = new MockERC20();
        vm.prank(opA);
        uint256 idX = identity.register();
        AgentVault otherVault = new AgentVault(address(otherToken), idX, address(identity));
        vm.expectRevert(bytes("wrong asset"));
        index.addVault(address(otherVault));
    }

    // --- Deposit / Withdraw ---

    function test_deposit_firstShares_oneToOne() public {
        vm.prank(alice);
        uint256 s = index.deposit(100e18);
        assertEq(s, 100e18);
        assertEq(index.totalShares(), 100e18);
        assertEq(index.totalAssets(), 100e18);
    }

    function test_deposit_secondDepositor_proRata() public {
        vm.prank(alice);
        index.deposit(100e18);
        vm.prank(bob);
        uint256 s = index.deposit(50e18);
        assertEq(s, 50e18);
        assertEq(index.totalShares(), 150e18);
    }

    function test_withdraw_returnsAssets() public {
        vm.prank(alice);
        index.deposit(100e18);
        vm.prank(alice);
        uint256 got = index.withdraw(40e18);
        assertEq(got, 40e18);
        assertEq(index.balanceOf(alice), 60e18);
    }

    // --- Rebalance ---

    function test_rebalance_equalWeight_whenNoReputation() public {
        vm.prank(alice);
        index.deposit(100e18);
        index.rebalance();

        // 100 idle → 50 to each vault
        AgentIndex.Allocation[] memory alloc = index.getAllocation();
        assertEq(alloc.length, 2);
        assertEq(alloc[0].deployed, 50e18);
        assertEq(alloc[1].deployed, 50e18);
        assertEq(alloc[0].weightBps, 5000);
        assertEq(alloc[1].weightBps, 5000);
    }

    function test_rebalance_weightsByReputation() public {
        vm.prank(alice);
        index.deposit(100e18);

        // Give vaultA's agent a positive cumulative score via a receipt
        vm.prank(opA);
        vaultA.publishReceipt(abi.encode(uint256(0), keccak256("ev"), int256(3e18), uint64(60)));
        // vaultB stays at 0

        index.rebalance();
        AgentIndex.Allocation[] memory alloc = index.getAllocation();
        // vaultA has all the positive rep → 100% allocation
        assertEq(alloc[0].deployed, 100e18);
        assertEq(alloc[1].deployed, 0);
        assertEq(alloc[0].weightBps, 10000);
    }

    function test_rebalance_redistributes_whenReputationChanges() public {
        vm.prank(alice);
        index.deposit(100e18);
        // first: A gets all rep
        vm.prank(opA);
        vaultA.publishReceipt(abi.encode(uint256(0), keccak256("ev1"), int256(2e18), uint64(60)));
        index.rebalance();
        assertEq(index.getAllocation()[0].deployed, 100e18);

        // now B catches up: A=2, B=6 → A=25%, B=75%
        vm.prank(opB);
        vaultB.publishReceipt(abi.encode(uint256(0), keccak256("ev2"), int256(6e18), uint64(60)));
        index.rebalance();
        AgentIndex.Allocation[] memory alloc = index.getAllocation();
        assertEq(alloc[0].weightBps, 2500);
        assertEq(alloc[1].weightBps, 7500);
    }

    function test_rebalance_revertsWithNoVaults() public {
        AgentIndex empty = new AgentIndex(address(token), address(identity));
        vm.expectRevert(bytes("no vaults"));
        empty.rebalance();
    }

    function test_rebalance_permissionless() public {
        vm.prank(alice);
        index.deposit(100e18);
        // stranger can call rebalance
        vm.prank(bob);
        index.rebalance();
        assertGt(index.getAllocation()[0].deployed, 0);
    }

    // --- Withdraw with auto-pull from vaults ---

    function test_withdraw_pullsFromVaults_whenIdleInsufficient() public {
        vm.prank(alice);
        index.deposit(100e18);
        index.rebalance(); // 50 to each vault, 0 idle

        vm.prank(alice);
        uint256 got = index.withdraw(30e18);
        assertEq(got, 30e18);
        assertEq(token.balanceOf(alice), 1_000e18 - 100e18 + 30e18);
    }

    function test_getAllocation_includesAgentIds() public view {
        AgentIndex.Allocation[] memory alloc = index.getAllocation();
        assertEq(alloc[0].agentId, idA);
        assertEq(alloc[1].agentId, idB);
        assertEq(alloc[0].vault, address(vaultA));
        assertEq(alloc[1].vault, address(vaultB));
    }

    // --- ERC-20 share token (tradeable index) ---

    function test_erc20_metadata() public view {
        assertEq(index.name(), "Reef AI Yield Index");
        assertEq(index.symbol(), "rINDEX");
        assertEq(index.decimals(), 18);
    }

    function test_erc20_depositMints_totalSupplyTracks() public {
        vm.prank(alice);
        index.deposit(100e18);
        assertEq(index.totalSupply(), 100e18);
        assertEq(index.balanceOf(alice), 100e18);
    }

    function test_erc20_transfer_movesShares_keepsSupply() public {
        vm.prank(alice);
        index.deposit(100e18);
        vm.prank(alice);
        assertTrue(index.transfer(bob, 40e18));
        assertEq(index.balanceOf(alice), 60e18);
        assertEq(index.balanceOf(bob), 40e18);
        assertEq(index.totalSupply(), 100e18);
    }

    function test_erc20_transfer_revertsInsufficient() public {
        vm.prank(alice);
        index.deposit(10e18);
        vm.prank(alice);
        vm.expectRevert(bytes("balance"));
        index.transfer(bob, 11e18);
    }

    function test_erc20_approve_transferFrom_decrementsAllowance() public {
        vm.prank(alice);
        index.deposit(100e18);
        vm.prank(alice);
        index.approve(bob, 30e18);
        assertEq(index.allowance(alice, bob), 30e18);
        vm.prank(bob);
        index.transferFrom(alice, bob, 30e18);
        assertEq(index.balanceOf(bob), 30e18);
        assertEq(index.balanceOf(alice), 70e18);
        assertEq(index.allowance(alice, bob), 0);
    }

    function test_erc20_transferFrom_revertsOverAllowance() public {
        vm.prank(alice);
        index.deposit(100e18);
        vm.prank(alice);
        index.approve(bob, 10e18);
        vm.prank(bob);
        vm.expectRevert(bytes("allowance"));
        index.transferFrom(alice, bob, 11e18);
    }

    /// Composability payoff: whoever holds the index token can redeem the basket.
    function test_erc20_transferee_canRedeem() public {
        vm.prank(alice);
        index.deposit(100e18);
        vm.prank(alice);
        index.transfer(bob, 100e18);
        vm.prank(bob);
        uint256 got = index.withdraw(100e18);
        assertEq(got, 100e18);
        assertEq(index.balanceOf(bob), 0);
        assertEq(index.totalSupply(), 0);
    }

    // --- Skin-in-the-game bond gate ---

    function _bondGate() internal returns (ReputationBond rb) {
        rb = new ReputationBond(address(token), address(identity), address(this), 1e18, 10e18, 1 days);
        token.mint(opA, 100e18);
        vm.prank(opA);
        token.approve(address(rb), type(uint256).max);
        vm.prank(opA);
        rb.postBond(idA, 50e18); // opA bonded; opB not
        index.setReputationBond(address(rb), 10e18);
    }

    function test_bondGate_equalWeight_excludesUnbonded() public {
        _bondGate();
        vm.prank(alice);
        index.deposit(100e18);
        index.rebalance();
        // no reputation yet → equal weight among BONDED vaults only → A=100%, B=0
        AgentIndex.Allocation[] memory alloc = index.getAllocation();
        assertEq(alloc[0].deployed, 100e18);
        assertEq(alloc[1].deployed, 0);
    }

    function test_bondGate_repWeight_excludesUnbonded() public {
        _bondGate();
        vm.prank(alice);
        index.deposit(100e18);
        // both earn equal reputation, but only A is bonded
        vm.prank(opA);
        vaultA.publishReceipt(abi.encode(uint256(0), keccak256("a"), int256(5e18), uint64(60)));
        vm.prank(opB);
        vaultB.publishReceipt(abi.encode(uint256(0), keccak256("b"), int256(5e18), uint64(60)));
        index.rebalance();
        AgentIndex.Allocation[] memory alloc = index.getAllocation();
        assertEq(alloc[0].weightBps, 10000); // A gets all
        assertEq(alloc[1].deployed, 0); // B excluded — no bond
    }
}
