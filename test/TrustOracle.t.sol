// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {ReputationBond} from "../src/ReputationBond.sol";
import {ReefGuard} from "../src/ReefGuard.sol";
import {TrustOracle} from "../src/TrustOracle.sol";
import {Allocator} from "../src/Allocator.sol";
import {TrustOracleConsumer} from "../src/TrustOracleConsumer.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract TrustOracleTest is Test {
    AgentIdentity identity;
    AdapterRegistry registry;
    ReputationBond bond;
    ReefGuard guard;
    TrustOracle oracle;
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
        guard = new ReefGuard(address(identity), address(bond), address(this), int256(0), 10e18, 5000);
        guard.setAssetAllowed(address(token), true);
        oracle = new TrustOracle(address(identity), address(bond), address(guard));

        idA = _register(opA);
        idB = _register(opB);
        idC = _register(opC);
        vaultA = _vault(idA, opA);
        vaultB = _vault(idB, opB);
        vaultC = _vault(idC, opC);
        oracle.registerVault(address(vaultA));
        oracle.registerVault(address(vaultB));
        oracle.registerVault(address(vaultC));
    }

    // --- Registry / governance ---

    function test_registerVault_recordsAgentAndVault() public view {
        assertEq(oracle.vaultCount(), 3);
        assertEq(oracle.vaultOf(idA), address(vaultA));
        assertTrue(oracle.isRegistered(address(vaultA)));
    }

    function test_registerVault_onlyGovernor_andNoDuplicates() public {
        AgentVault v = _vault(_register(makeAddr("opX")), makeAddr("opX"));
        vm.prank(alice);
        vm.expectRevert(bytes("not governor"));
        oracle.registerVault(address(v));

        vm.expectRevert(bytes("registered"));
        oracle.registerVault(address(vaultA));
    }

    function test_registerVault_rejectsWrongIdentity() public {
        // A vault bound to a DIFFERENT AgentIdentity cannot be registered.
        AgentIdentity other = new AgentIdentity();
        address opY = makeAddr("opY");
        vm.prank(opY);
        uint256 idY = other.register();
        AgentVault wrong = new AgentVault(address(token), idY, address(other), address(registry));
        vm.expectRevert(bytes("wrong identity"));
        oracle.registerVault(address(wrong));
    }

    function test_removeVault_dropsFromCohort_andAllowsReRegister() public {
        assertEq(oracle.vaultCount(), 3);
        oracle.removeVault(idB);
        assertEq(oracle.vaultCount(), 2);
        assertEq(oracle.vaultOf(idB), address(0));
        assertFalse(oracle.isRegistered(address(vaultB)));
        vm.expectRevert(bytes("unknown agent"));
        oracle.scoreOf(idB);
        // remaining agents still score fine (cohort not bricked)
        assertGt(oracle.scoreOf(idA), 0);
        // the freed agentId can be re-registered
        oracle.registerVault(address(vaultB));
        assertEq(oracle.vaultCount(), 3);

        vm.prank(alice);
        vm.expectRevert(bytes("not governor"));
        oracle.removeVault(idA);
        vm.expectRevert(bytes("unknown agent"));
        oracle.removeVault(999);
    }

    function test_setBond_setGuard_transferGovernor_onlyGovernor() public {
        vm.startPrank(alice);
        vm.expectRevert(bytes("not governor"));
        oracle.setBond(address(0));
        vm.expectRevert(bytes("not governor"));
        oracle.setGuard(address(0));
        vm.expectRevert(bytes("not governor"));
        oracle.transferGovernor(alice);
        vm.stopPrank();

        oracle.transferGovernor(alice);
        assertEq(oracle.governor(), alice);
    }

    // --- Trust score: known values (same model as Allocator/_trustScore) ---

    function test_scoreOf_fullMarks_forTopBondedFreshAgent() public {
        _giveRep(vaultA, opAPk, 8e18);
        _bondAgent(idA, opA, 50e18);
        assertEq(oracle.scoreOf(idA), WAD);
        assertEq(oracle.scoreOfVault(address(vaultA)), WAD);
    }

    function test_scoreOf_neverActiveAgent_isDrawdownComponentOnly() public view {
        // No receipt, no rep, no bond; empty vault nav == hwm -> dd = 1. Score = 0.2 * WAD.
        assertEq(oracle.scoreOf(idC), 2e17);
    }

    function test_componentsOf_breakdown() public {
        _giveRep(vaultA, opAPk, 8e18);
        _bondAgent(idA, opA, 50e18);
        (uint256 repC, uint256 freshC, uint256 ddC, uint256 bondC) = oracle.componentsOf(idA);
        assertEq(repC, WAD); // cohort max reputation
        assertEq(freshC, WAD); // just published
        assertEq(ddC, WAD); // nav == hwm
        assertEq(bondC, WAD); // bond at 50e18 target
    }

    function test_scoreOf_unknownAgent_reverts() public {
        vm.expectRevert(bytes("unknown agent"));
        oracle.scoreOf(999);
    }

    // --- Cross-parity: the standalone oracle reproduces the Allocator's on-chain number exactly ---

    function test_parity_withAllocatorTrustScore() public {
        _giveRep(vaultA, opAPk, 8e18);
        _giveRep(vaultB, opBPk, 3e18);
        _bondAgent(idA, opA, 50e18);
        _bondAgent(idB, opB, 25e18);

        Allocator allocator = new Allocator(address(token), address(identity), address(bond));
        allocator.addVault(address(vaultA));
        allocator.addVault(address(vaultB));
        allocator.addVault(address(vaultC));

        assertEq(oracle.scoreOf(idA), allocator.trustScoreOf(address(vaultA)));
        assertEq(oracle.scoreOf(idB), allocator.trustScoreOf(address(vaultB)));
        assertEq(oracle.scoreOf(idC), allocator.trustScoreOf(address(vaultC)));
    }

    // --- Ratings ---

    function test_ratingOf_thresholds() public {
        _giveRep(vaultA, opAPk, 8e18);
        _bondAgent(idA, opA, 50e18);
        assertEq(oracle.ratingOf(idA), "AAA"); // full marks
        assertEq(oracle.ratingOf(idC), "BB"); // 0.2

        // Let the freshness component fully decay: full marks -> 0.8 -> "AA".
        vm.warp(block.timestamp + 25 hours);
        assertEq(oracle.scoreOf(idA), WAD - 2e17);
        assertEq(oracle.ratingOf(idA), "AA");
    }

    // --- allScores ---

    function test_allScores_returnsEveryAgent() public {
        _giveRep(vaultA, opAPk, 8e18);
        _bondAgent(idA, opA, 50e18);
        (uint256[] memory ids, uint256[] memory wad) = oracle.allScores();
        assertEq(ids.length, 3);
        assertEq(ids[0], idA);
        assertEq(wad[0], WAD);
        assertEq(wad[2], 2e17); // C never active
    }

    // --- report(): trust + live ReefGuard verdict in one call ---

    function test_report_clearedWhenBondedAndAllowlisted() public {
        _giveRep(vaultA, opAPk, 8e18);
        _bondAgent(idA, opA, 50e18);
        (uint256 score, string memory rating, bool cleared, string memory reason) =
            oracle.report(idA, address(token), 1000);
        assertEq(score, WAD);
        assertEq(rating, "AAA");
        assertTrue(cleared);
        assertEq(reason, "ok");
    }

    function test_report_blockedByGuard_overSize() public {
        _giveRep(vaultA, opAPk, 8e18);
        _bondAgent(idA, opA, 50e18);
        (,, bool cleared, string memory reason) = oracle.report(idA, address(token), 6000); // > 5000 maxSizeBps
        assertFalse(cleared);
        assertEq(reason, "action size over limit");
    }

    function test_report_guardNotSet() public {
        oracle.setGuard(address(0));
        _giveRep(vaultA, opAPk, 8e18);
        _bondAgent(idA, opA, 50e18);
        (,, bool cleared, string memory reason) = oracle.report(idA, address(token), 1000);
        assertFalse(cleared);
        assertEq(reason, "guard not set");
    }

    // --- TrustOracleConsumer: trust-weighted, trust-gated capital ---

    function test_consumer_gatesAndSizesByScore() public {
        _giveRep(vaultA, opAPk, 8e18);
        _bondAgent(idA, opA, 50e18); // score = WAD

        TrustOracleConsumer consumer = new TrustOracleConsumer(address(oracle), 7e17); // min 0.70
        // A at full marks: limit = baseLimit * 1.0
        assertEq(consumer.creditLimit(idA, 1000e18), 1000e18);
        assertEq(consumer.drawCredit(idA, 1000e18, 1000e18), 1000e18);

        // Over the trust-weighted limit reverts.
        vm.expectRevert(bytes("over trust-weighted limit"));
        consumer.drawCredit(idA, 1001e18, 1000e18);

        // C (score 0.2 < 0.70 bar): disqualified -> 0 limit, draw reverts.
        assertEq(consumer.creditLimit(idC, 1000e18), 0);
        vm.expectRevert(bytes("trust below threshold"));
        consumer.drawCredit(idC, 1, 1000e18);
    }

    // --- Helpers (mirror Allocator.t.sol) ---

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
