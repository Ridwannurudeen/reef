// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {ReputationBond} from "../src/ReputationBond.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract ReputationBondTest is Test {
    AgentIdentity identity;
    ReputationBond bond;
    MockERC20 token;

    address arbiter = makeAddr("arbiter");
    address operator = makeAddr("operator");
    address challenger = makeAddr("challenger");
    address stranger = makeAddr("stranger");

    uint256 constant STAKE = 10e18;
    uint256 constant SLASH = 50e18;
    uint64 constant WINDOW = 1 days;

    uint256 agentId;

    function setUp() public {
        identity = new AgentIdentity();
        token = new MockERC20();
        bond = new ReputationBond(address(token), address(identity), arbiter, STAKE, SLASH, WINDOW);

        vm.prank(operator);
        agentId = identity.register();

        token.mint(operator, 1_000e18);
        token.mint(challenger, 1_000e18);
        vm.prank(operator);
        token.approve(address(bond), type(uint256).max);
        vm.prank(challenger);
        token.approve(address(bond), type(uint256).max);
    }

    function _post(uint256 amount) internal {
        vm.prank(operator);
        bond.postBond(agentId, amount);
    }

    function _open() internal returns (uint256 id) {
        vm.prank(challenger);
        id = bond.openDispute(agentId, keccak256("evidence"));
    }

    function test_postBond_onlyOperator_transfersIn() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("not operator"));
        bond.postBond(agentId, 100e18);

        _post(100e18);
        assertEq(bond.bondOf(agentId), 100e18);
        assertEq(token.balanceOf(address(bond)), 100e18);
    }

    function test_withdrawBond_returnsFunds() public {
        _post(100e18);
        vm.prank(operator);
        bond.withdrawBond(agentId, 40e18);
        assertEq(bond.bondOf(agentId), 60e18);
        assertEq(token.balanceOf(operator), 1_000e18 - 60e18);
    }

    function test_openDispute_requiresBond_andStakes() public {
        _post(10e18); // < SLASH
        vm.prank(challenger);
        vm.expectRevert(bytes("underbonded"));
        bond.openDispute(agentId, keccak256("e"));

        _post(90e18); // now 100 >= SLASH
        uint256 id = _open();
        assertEq(id, 0);
        assertEq(bond.activeDisputes(agentId), 1);
        assertEq(token.balanceOf(address(bond)), 100e18 + STAKE);
    }

    function test_openDispute_zeroEvidence_reverts() public {
        _post(100e18);
        vm.prank(challenger);
        vm.expectRevert(bytes("zero evidence"));
        bond.openDispute(agentId, bytes32(0));
    }

    function test_openDispute_rejectsSelfChallenge() public {
        _post(100e18);
        vm.prank(operator);
        vm.expectRevert(bytes("self challenge"));
        bond.openDispute(agentId, keccak256("e"));
    }

    function test_openDispute_oneActivePerAgent() public {
        _post(100e18);
        _open();
        vm.prank(challenger);
        vm.expectRevert(bytes("dispute active"));
        bond.openDispute(agentId, keccak256("e2"));
    }

    function test_openDispute_allowedAgain_afterResolve() public {
        _post(100e18);
        uint256 id = _open();
        vm.prank(arbiter);
        bond.resolveDispute(id, false); // bond back to 100 + STAKE, no active disputes
        uint256 id2 = _open();
        assertEq(id2, 1);
        assertEq(bond.activeDisputes(agentId), 1);
    }

    function test_withdraw_blockedDuringDispute_allowedAfter() public {
        _post(100e18);
        uint256 id = _open();
        vm.prank(operator);
        vm.expectRevert(bytes("active dispute"));
        bond.withdrawBond(agentId, 1e18);

        vm.prank(arbiter);
        bond.resolveDispute(id, false);
        vm.prank(operator);
        bond.withdrawBond(agentId, 1e18);
        assertEq(bond.activeDisputes(agentId), 0);
    }

    function test_resolve_uphold_slashesToChallenger() public {
        _post(100e18);
        uint256 id = _open();
        uint256 cbBefore = token.balanceOf(challenger);

        vm.prank(arbiter);
        bond.resolveDispute(id, true);

        assertEq(bond.bondOf(agentId), 50e18); // 100 - SLASH
        assertEq(token.balanceOf(challenger), cbBefore + STAKE + SLASH); // stake back + reward
        assertEq(bond.activeDisputes(agentId), 0);
    }

    function test_resolve_reject_forfeitsStakeIntoBond() public {
        _post(100e18);
        uint256 id = _open();
        vm.prank(arbiter);
        bond.resolveDispute(id, false);
        assertEq(bond.bondOf(agentId), 100e18 + STAKE);
    }

    function test_resolve_onlyArbiter() public {
        _post(100e18);
        uint256 id = _open();
        vm.prank(stranger);
        vm.expectRevert(bytes("not arbiter"));
        bond.resolveDispute(id, true);
    }

    function test_arbiterRotation_twoStep() public {
        address newArbiter = makeAddr("newArbiter");

        vm.prank(arbiter);
        bond.transferArbiter(newArbiter);
        assertEq(bond.pendingArbiter(), newArbiter);
        assertEq(bond.arbiter(), arbiter); // not yet effective

        vm.prank(newArbiter);
        bond.acceptArbiter();
        assertEq(bond.arbiter(), newArbiter);
        assertEq(bond.pendingArbiter(), address(0));

        // New arbiter can now resolve; the old one cannot.
        _post(100e18);
        uint256 id = _open();
        vm.prank(arbiter);
        vm.expectRevert(bytes("not arbiter"));
        bond.resolveDispute(id, true);
        vm.prank(newArbiter);
        bond.resolveDispute(id, true);
        assertEq(bond.bondOf(agentId), 50e18);
    }

    function test_transferArbiter_onlyArbiter() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("not arbiter"));
        bond.transferArbiter(stranger);
    }

    function test_acceptArbiter_onlyPending() public {
        vm.prank(arbiter);
        bond.transferArbiter(makeAddr("newArbiter"));
        vm.prank(stranger);
        vm.expectRevert(bytes("not pending"));
        bond.acceptArbiter();
    }

    function test_claimExpiredStake_afterWindowOnly() public {
        _post(100e18);
        uint256 id = _open();
        vm.prank(challenger);
        vm.expectRevert(bytes("window open"));
        bond.claimExpiredStake(id);

        vm.warp(block.timestamp + WINDOW + 1);
        uint256 cb = token.balanceOf(challenger);
        vm.prank(challenger);
        bond.claimExpiredStake(id);
        assertEq(token.balanceOf(challenger), cb + STAKE);
        assertEq(bond.activeDisputes(agentId), 0);
    }
}
