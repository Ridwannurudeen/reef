// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ReputationBond} from "../../src/ReputationBond.sol";
import {AgentIdentity} from "../../src/AgentIdentity.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Drives a fixed set of operators/challengers/arbiter through the full
/// post -> dispute -> resolve/expire lifecycle with fuzzed inputs. Reverting calls are
/// fine (they just don't advance state); the goal is broad reachable coverage.
contract BondHandler is Test {
    ReputationBond public bond;
    MockERC20 public asset;
    uint256[3] public agentIds;
    address[3] public operators;
    address[2] public challengers;
    address public arbiter;

    constructor(
        ReputationBond bond_,
        MockERC20 asset_,
        uint256[3] memory agentIds_,
        address[3] memory operators_,
        address[2] memory challengers_,
        address arbiter_
    ) {
        bond = bond_;
        asset = asset_;
        agentIds = agentIds_;
        operators = operators_;
        challengers = challengers_;
        arbiter = arbiter_;
    }

    function postBond(uint256 agentSeed, uint256 amount) external {
        uint256 i = agentSeed % 3;
        amount = bound(amount, 1, 1_000_000e18);
        asset.mint(operators[i], amount);
        vm.startPrank(operators[i]);
        asset.approve(address(bond), amount);
        bond.postBond(agentIds[i], amount);
        vm.stopPrank();
    }

    function withdrawBond(uint256 agentSeed, uint256 amount) external {
        uint256 i = agentSeed % 3;
        uint256 held = bond.bondOf(agentIds[i]);
        if (held == 0 || bond.activeDisputes(agentIds[i]) != 0) return;
        amount = bound(amount, 1, held);
        vm.prank(operators[i]);
        bond.withdrawBond(agentIds[i], amount);
    }

    function openDispute(uint256 agentSeed, uint256 chSeed, bytes32 evidence) external {
        uint256 i = agentSeed % 3;
        if (bond.bondOf(agentIds[i]) < bond.slashAmount() || bond.activeDisputes(agentIds[i]) != 0) return;
        if (evidence == bytes32(0)) evidence = bytes32(uint256(1));
        address ch = challengers[chSeed % 2];
        uint256 stake = bond.challengeStake();
        asset.mint(ch, stake);
        vm.startPrank(ch);
        asset.approve(address(bond), stake);
        bond.openDispute(agentIds[i], evidence);
        vm.stopPrank();
    }

    function resolveDispute(uint256 idSeed, bool uphold) external {
        uint256 n = bond.disputeCount();
        if (n == 0) return;
        uint256 id = idSeed % n;
        (,,,, ReputationBond.Status status,) = bond.disputes(id);
        if (status != ReputationBond.Status.Open) return;
        vm.prank(arbiter);
        bond.resolveDispute(id, uphold);
    }

    function claimExpiredStake(uint256 idSeed, uint256 warp) external {
        uint256 n = bond.disputeCount();
        if (n == 0) return;
        uint256 id = idSeed % n;
        (, address challenger,, uint64 deadline, ReputationBond.Status status,) = bond.disputes(id);
        if (status != ReputationBond.Status.Open) return;
        warp = bound(warp, uint256(deadline) + 1, uint256(deadline) + 30 days);
        vm.warp(warp);
        vm.prank(challenger);
        bond.claimExpiredStake(id);
    }
}

/// @notice Invariant: ReputationBond is always solvent — its asset balance equals the sum of
/// every agent's posted bond plus the staked deposits of all still-open disputes. Funds never
/// leak, get double-counted, or get stranded across the post/dispute/slash/forfeit/expire paths.
contract ReputationBondInvariantTest is Test {
    ReputationBond bond;
    MockERC20 asset;
    AgentIdentity identity;
    BondHandler handler;
    uint256[3] agentIds;

    function setUp() public {
        asset = new MockERC20();
        identity = new AgentIdentity();
        address arbiter = makeAddr("arbiter");
        bond = new ReputationBond(address(asset), address(identity), arbiter, 10e18, 50e18, 1 days);

        address[3] memory operators = [makeAddr("operator0"), makeAddr("operator1"), makeAddr("operator2")];
        address[2] memory challengers = [makeAddr("challenger0"), makeAddr("challenger1")];
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(operators[i]);
            agentIds[i] = identity.register();
        }

        handler = new BondHandler(bond, asset, agentIds, operators, challengers, arbiter);
        targetContract(address(handler));
    }

    function invariant_solventBondLedger() public view {
        uint256 accounted;
        for (uint256 i = 0; i < 3; i++) {
            accounted += bond.bondOf(agentIds[i]);
        }
        uint256 n = bond.disputeCount();
        for (uint256 id = 0; id < n; id++) {
            (,, uint256 stake,, ReputationBond.Status status,) = bond.disputes(id);
            if (status == ReputationBond.Status.Open) accounted += stake;
        }
        assertEq(asset.balanceOf(address(bond)), accounted, "bond ledger insolvent");
    }
}
