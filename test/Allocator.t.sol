// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {Allocator} from "../src/Allocator.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {ReputationBond} from "../src/ReputationBond.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract AllocatorTest is Test {
    AgentIdentity identity;
    Allocator allocator;
    AdapterRegistry registry;
    ReputationBond bond;
    MockERC20 token;

    AgentVault vaultA;
    AgentVault vaultB;
    AgentVault vaultC;
    uint256 idA;
    uint256 idB;
    uint256 idC;
    address opA;
    uint256 opAPk;
    address opB;
    uint256 opBPk;
    address opC;
    uint256 opCPk;

    address alice = makeAddr("alice");
    uint256 constant WAD = 1e18;

    bytes32 constant RECEIPT_TYPEHASH =
        keccak256("Receipt(uint256 agentId,uint256 seq,bytes32 evidenceHash,int256 claimedDelta,uint64 period)");

    function setUp() public {
        (opA, opAPk) = makeAddrAndKey("opA");
        (opB, opBPk) = makeAddrAndKey("opB");
        (opC, opCPk) = makeAddrAndKey("opC");
        identity = new AgentIdentity();
        token = new MockERC20();
        registry = new AdapterRegistry();
        bond = new ReputationBond(address(token), address(identity), address(this), 1e18, 10e18, 1 days);
        allocator = new Allocator(address(token), address(identity), address(bond));

        idA = _register(opA);
        idB = _register(opB);
        idC = _register(opC);
        vaultA = _vault(idA, opA);
        vaultB = _vault(idB, opB);
        vaultC = _vault(idC, opC);
        allocator.addVault(address(vaultA));
        allocator.addVault(address(vaultB));
        allocator.addVault(address(vaultC));

        token.mint(alice, 1_000e18);
        vm.prank(alice);
        token.approve(address(allocator), type(uint256).max);
    }

    // --- Mandates / registry ---

    function test_constructor_seedsOpenMandate() public view {
        assertEq(allocator.mandateCount(), 1);
        (string memory name, uint256 minTrust, uint256 cap) = allocator.mandates(0);
        assertEq(name, "Open");
        assertEq(minTrust, 0);
        assertEq(cap, 10_000);
        assertEq(allocator.activeMandate(), 0);
    }

    function test_addMandate_onlyGovernor_andValidates() public {
        vm.prank(alice);
        vm.expectRevert(bytes("not governor"));
        allocator.addMandate("X", 0, 5000);

        vm.expectRevert(bytes("trust"));
        allocator.addMandate("X", WAD + 1, 5000);
        vm.expectRevert(bytes("bps"));
        allocator.addMandate("X", 0, 0);
        vm.expectRevert(bytes("bps"));
        allocator.addMandate("X", 0, 10_001);

        uint256 id = allocator.addMandate("Conservative", 7e17, 4000);
        assertEq(id, 1);
        assertEq(allocator.mandateCount(), 2);
    }

    function test_setActiveMandate_bounds_onlyGovernor() public {
        allocator.addMandate("Balanced", 5e17, 5000);
        vm.prank(alice);
        vm.expectRevert(bytes("not governor"));
        allocator.setActiveMandate(1);
        vm.expectRevert(bytes("no mandate"));
        allocator.setActiveMandate(2);
        allocator.setActiveMandate(1);
        assertEq(allocator.activeMandate(), 1);
    }

    function test_addVault_wrongAsset_and_onlyGovernor_and_once() public {
        MockERC20 other = new MockERC20();
        uint256 idX = _register(makeAddr("opX"));
        AgentVault wrong = new AgentVault(address(other), idX, address(identity), address(registry));
        vm.expectRevert(bytes("wrong asset"));
        allocator.addVault(address(wrong));

        vm.prank(alice);
        vm.expectRevert(bytes("not governor"));
        allocator.addVault(address(vaultA));

        vm.expectRevert(bytes("registered"));
        allocator.addVault(address(vaultA));
    }

    // --- Trust score (on-chain) ---

    function test_trustScore_fullMarks_forTopBondedFreshAgent() public {
        _giveRep(vaultA, opAPk, 8e18); // top reputation, fresh receipt, nav == hwm
        _bondAgent(idA, opA, 50e18);
        // rep component = 1 (cohort max), freshness = 1 (just published), drawdown = 1, bond = 1
        assertEq(allocator.trustScoreOf(address(vaultA)), WAD);
    }

    function test_trustScore_neverActiveAgent_isDrawdownComponentOnly() public view {
        // No receipt (freshness 0), no reputation, no bond. Empty vault: nav == hwm == 1e18 -> dd = 1.
        // Score = W_DD/10_000 * WAD = 0.2 * WAD.
        assertEq(allocator.trustScoreOf(address(vaultC)), 2e17);
    }

    function test_trustScore_decaysWithReceiptAge() public {
        _giveRep(vaultA, opAPk, 8e18);
        _bondAgent(idA, opA, 50e18);
        uint256 fresh = allocator.trustScoreOf(address(vaultA));
        vm.warp(block.timestamp + 12 hours); // half the freshness window
        uint256 aged = allocator.trustScoreOf(address(vaultA));
        assertLt(aged, fresh);
        vm.warp(block.timestamp + 13 hours); // > 24h total -> freshness component 0
        uint256 stale = allocator.trustScoreOf(address(vaultA));
        // freshness fully gone: lost 0.2 * WAD vs fully-fresh full marks
        assertEq(stale, WAD - 2e17);
    }

    function test_trustScoreOf_unknownVault_reverts() public {
        vm.expectRevert(bytes("unknown vault"));
        allocator.trustScoreOf(address(0xdead));
    }

    // --- Allocation ---

    function test_rebalance_trustWeighted_ordersByScore() public {
        _giveRep(vaultA, opAPk, 8e18);
        _giveRep(vaultB, opBPk, 2e18);
        _bondAgent(idA, opA, 50e18);
        _bondAgent(idB, opB, 50e18);
        // C: never active -> lowest score but still qualifies under Open mandate (min 0)
        vm.prank(alice);
        allocator.deposit(300e18);
        allocator.rebalance();

        uint256 eA = _exposure(vaultA);
        uint256 eB = _exposure(vaultB);
        uint256 eC = _exposure(vaultC);
        assertGt(eA, eB);
        assertGt(eB, eC);
        // Open mandate (cap 100%) deploys all capital.
        assertApproxEqAbs(eA + eB + eC, 300e18, 1e6);
    }

    function test_mandate_qualificationExcludesLowTrust() public {
        _giveRep(vaultA, opAPk, 8e18);
        _bondAgent(idA, opA, 50e18); // A -> full marks (WAD)
        _giveRep(vaultB, opBPk, 1e18);
        _bondAgent(idB, opB, 50e18); // B -> mid score, below a 0.9 bar
        uint256 mid = allocator.addMandate("Elite", 9e17, 10_000); // only A (WAD) qualifies
        allocator.setActiveMandate(mid);

        vm.prank(alice);
        allocator.deposit(300e18);
        allocator.rebalance();
        assertApproxEqAbs(_exposure(vaultA), 300e18, 1e6); // A takes all
        assertEq(_exposure(vaultB), 0);
        assertEq(_exposure(vaultC), 0);
    }

    function test_concentrationCap_redistributesToOthers() public {
        _giveRep(vaultA, opAPk, 8e18);
        _giveRep(vaultB, opBPk, 2e18);
        _giveRep(vaultC, opCPk, 1e18);
        _bondAgent(idA, opA, 50e18);
        _bondAgent(idB, opB, 50e18);
        _bondAgent(idC, opC, 50e18);
        uint256 m = allocator.addMandate("Capped", 0, 4000); // 40% per-agent cap
        allocator.setActiveMandate(m);

        vm.prank(alice);
        allocator.deposit(300e18);
        allocator.rebalance();

        // A would exceed 40% on raw trust weight -> clamped to the cap; excess flows to B & C.
        assertApproxEqAbs(_exposure(vaultA), 120e18, 1e16); // 40% of 300
        assertGt(_exposure(vaultB), 0);
        assertGt(_exposure(vaultC), 0);
        assertApproxEqAbs(_exposure(vaultA) + _exposure(vaultB) + _exposure(vaultC), 300e18, 1e15);
    }

    function test_concentrationCap_residualStaysIdle() public {
        _giveRep(vaultA, opAPk, 8e18);
        _bondAgent(idA, opA, 50e18);
        _giveRep(vaultB, opBPk, 6e18);
        _bondAgent(idB, opB, 50e18);
        // Bar excludes the never-active C; cap 20% with only 2 qualifiers -> max 40% deployed.
        uint256 m = allocator.addMandate("TwoCapped", 5e17, 2000);
        allocator.setActiveMandate(m);

        vm.prank(alice);
        allocator.deposit(300e18);
        allocator.rebalance();

        assertApproxEqAbs(_exposure(vaultA), 60e18, 1e15); // 20%
        assertApproxEqAbs(_exposure(vaultB), 60e18, 1e15); // 20%
        assertEq(_exposure(vaultC), 0);
        // 60% stays idle in the allocator as a redemption buffer.
        assertApproxEqAbs(token.balanceOf(address(allocator)), 180e18, 2e15);
    }

    function test_previewTargets_matchesRebalance() public {
        _giveRep(vaultA, opAPk, 8e18);
        _giveRep(vaultB, opBPk, 3e18);
        _bondAgent(idA, opA, 50e18);
        _bondAgent(idB, opB, 50e18);
        vm.prank(alice);
        allocator.deposit(300e18);

        (address[] memory vs,, bool[] memory qualified, uint256[] memory targets) = allocator.previewTargets();
        allocator.rebalance();
        for (uint256 i = 0; i < vs.length; i++) {
            assertTrue(qualified[i]); // Open mandate qualifies all
            assertApproxEqAbs(_exposure(AgentVault(vs[i])), targets[i], 1e15);
        }
    }

    // --- Deposit / withdraw ---

    function test_deposit_firstIsOneToOne_andWithdrawRoundtrips() public {
        vm.prank(alice);
        uint256 shares = allocator.deposit(100e18);
        assertEq(shares, 100e18);
        assertEq(allocator.totalShares(), 100e18);

        vm.prank(alice);
        uint256 got = allocator.withdraw(shares);
        assertApproxEqAbs(got, 100e18, 1);
        assertEq(allocator.totalShares(), 0);
    }

    function test_withdraw_pullsFromVaults() public {
        _giveRep(vaultA, opAPk, 5e18);
        _bondAgent(idA, opA, 50e18);
        vm.prank(alice);
        allocator.deposit(200e18);
        allocator.rebalance();
        assertLt(token.balanceOf(address(allocator)), 200e18); // capital deployed

        uint256 beforeBal = token.balanceOf(alice);
        uint256 aliceShares = allocator.balanceOf(alice);
        vm.prank(alice);
        allocator.withdraw(aliceShares);
        assertGt(token.balanceOf(alice), beforeBal);
        assertApproxEqAbs(token.balanceOf(alice) - beforeBal, 200e18, 1e15);
    }

    function test_pause_blocksDepositAndRebalance_notWithdraw() public {
        vm.prank(alice);
        allocator.deposit(100e18);
        allocator.pause();

        vm.prank(alice);
        vm.expectRevert(bytes("paused"));
        allocator.deposit(1e18);
        vm.expectRevert(bytes("paused"));
        allocator.rebalance();

        // Withdrawals are never gated — capital can't be trapped.
        uint256 aliceShares = allocator.balanceOf(alice);
        vm.prank(alice);
        uint256 got = allocator.withdraw(aliceShares);
        assertApproxEqAbs(got, 100e18, 1);
    }

    // --- Helpers ---

    function _register(address op) internal returns (uint256 id) {
        vm.prank(op);
        id = identity.register();
    }

    function _vault(uint256 id, address op) internal returns (AgentVault v) {
        v = new AgentVault(address(token), id, address(identity), address(registry));
        vm.prank(op);
        identity.setReputationSource(id, address(v));
    }

    function _bondAgent(uint256 id, address op, uint256 amt) internal {
        token.mint(op, amt);
        vm.prank(op);
        token.approve(address(bond), type(uint256).max);
        vm.prank(op);
        bond.postBond(id, amt);
    }

    function _exposure(AgentVault v) internal view returns (uint256) {
        uint256 vs = allocator.vaultShares(address(v));
        return vs > 0 ? (vs * v.nav()) / 1e18 : 0;
    }

    function _giveRep(AgentVault v, uint256 opPk, uint256 repAmount) internal {
        token.mint(address(this), 1e18);
        token.approve(address(v), 1e18);
        v.deposit(1e18);
        token.mint(address(v), repAmount);
        uint256 seq = v.nextReceiptSeq();
        bytes32 evidence = keccak256(abi.encode("rep", address(v), seq));
        bytes32 structHash = keccak256(abi.encode(RECEIPT_TYPEHASH, v.agentId(), seq, evidence, int256(0), uint64(60)));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", v.domainSeparator(), structHash));
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(opPk, digest);
        v.publishReceipt(seq, evidence, int256(0), uint64(60), abi.encodePacked(r, s, vv));
    }
}
