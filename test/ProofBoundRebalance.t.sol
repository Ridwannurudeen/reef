// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {ReefGuard} from "../src/ReefGuard.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategyAdapter} from "./mocks/MockStrategyAdapter.sol";

/// Minimal bond view for ReefGuard (the bond is not what's under test here).
contract MockBond {
    mapping(uint256 => uint256) public bondOf;
    mapping(uint256 => uint256) public activeDisputes;

    function setBond(uint256 id, uint256 b) external {
        bondOf[id] = b;
    }

    function setDisputes(uint256 id, uint256 d) external {
        activeDisputes[id] = d;
    }
}

/// @notice End-to-end proof of the Phase-0 "proof-bound rebalance" loop against the REAL
/// contracts: a decision is gated by ReefGuard, capital actually moves through an
/// AdapterRegistry-approved strategy (NAV-affecting), and the agent's verbatim rationale is
/// committed on-chain as the receipt evidence hash — crediting reputation from REALIZED
/// (donation-proof) NAV growth only. This is the atomic loop the agent runner + UI ride on.
contract ProofBoundRebalanceTest is Test {
    AgentIdentity identity;
    AgentVault vault;
    AdapterRegistry registry;
    ReefGuard guard;
    MockBond bond;
    MockERC20 token;
    MockStrategyAdapter strategy;

    address operator;
    uint256 operatorPk;
    address user = makeAddr("user");
    uint256 agentId;

    bytes32 constant RECEIPT_TYPEHASH =
        keccak256("Receipt(uint256 agentId,uint256 seq,bytes32 evidenceHash,int256 claimedDelta,uint64 period)");

    function _sign(uint256 pk, uint256 seq, bytes32 evidence, int256 claimedDelta, uint64 period)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(RECEIPT_TYPEHASH, agentId, seq, evidence, claimedDelta, period));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function setUp() public {
        (operator, operatorPk) = makeAddrAndKey("operator");
        identity = new AgentIdentity();
        token = new MockERC20();

        vm.prank(operator);
        agentId = identity.register();

        registry = new AdapterRegistry();
        vault = new AgentVault(address(token), agentId, address(identity), address(registry));
        strategy = new MockStrategyAdapter(address(token), address(vault));

        // Vault-only reputation source, governor-vetted adapter approved by the operator.
        vm.prank(operator);
        identity.setReputationSource(agentId, address(vault));
        registry.approveAdapter(address(strategy));
        vm.prank(operator);
        vault.approveStrategy(address(strategy));

        // ReefGuard reads the REAL identity (so credited reputation flows back into the gate) +
        // a mock bond. Policy: min rep 0, min bond 10e18, max single action 50%.
        bond = new MockBond();
        bond.setBond(agentId, 50e18);
        guard = new ReefGuard(address(identity), address(bond), address(this), int256(0), 10e18, 5000);
        guard.setAssetAllowed(address(token), true);

        token.mint(user, 1_000e18);
        vm.prank(user);
        token.approve(address(vault), type(uint256).max);
    }

    /// The full loop: guard-gated decision -> NAV-moving deploy -> realize yield -> publish a
    /// receipt whose evidence == keccak256(rationale), crediting realized-NAV reputation.
    function test_proofBoundRebalance_bindsRationale_realizesNav_creditsReputation() public {
        // User deposits real capital (the interactive entry point).
        vm.prank(user);
        vault.deposit(100e18);
        assertEq(vault.nav(), 1e18);

        // Pre-trade gate: the agent's "increase exposure" action must clear ReefGuard.
        (bool ok, string memory reason) = guard.canExecute(agentId, address(token), 4000);
        assertTrue(ok, "guard should clear a compliant 40% allocation");
        assertEq(reason, "ok");

        // Capital actually moves into the approved strategy (NAV-affecting), yield accrues, and a
        // de-risk realizes it back into the vault — the only thing that lifts reputable NAV.
        vm.prank(operator);
        vault.deployToStrategy(address(strategy), 40e18);
        token.mint(address(strategy), 8e18); // simulate realized strategy yield
        vm.prank(operator);
        vault.recallFromStrategy(address(strategy), 48e18);

        // The decision's verbatim rationale is bound on-chain as the receipt evidence.
        string memory rationale =
            "Take profit: ETH momentum cooled; recall the yield position to realize +8 gain and de-risk to idle.";
        bytes32 evidence = keccak256(bytes(rationale));
        uint256 seq = vault.nextReceiptSeq();
        bytes memory sig = _sign(operatorPk, seq, evidence, int256(0), 600);
        vault.publishReceipt(seq, evidence, int256(0), 600, sig);

        // 1) Rationale is verifiably bound: anyone can recompute the hash and match on-chain.
        assertEq(vault.lastReceiptEvidenceHash(), evidence, "evidence not bound");
        assertEq(keccak256(bytes(rationale)), vault.lastReceiptEvidenceHash(), "rationale hash mismatch");

        // 2) NAV actually grew from realized yield.
        assertGt(vault.nav(), 1e18, "nav did not grow");
        assertEq(vault.reputableNav(), 1.08e18, "realized reputable nav");

        // 3) Reputation credited from realized growth, so the guard now sees a stronger agent.
        (int256 rep,) = identity.getSummary(agentId);
        assertGt(rep, int256(0), "reputation not credited from realized nav");
    }

    /// ReefGuard refuses non-compliant actions with a reason — the on-screen "Reef says no".
    function test_guardRefusal_blocksOversizedAndUnbonded() public {
        (bool ok1, string memory r1) = guard.canExecute(agentId, address(token), 9000);
        assertFalse(ok1);
        assertEq(r1, "action size over limit");

        bond.setBond(agentId, 0);
        (bool ok2, string memory r2) = guard.canExecute(agentId, address(token), 4000);
        assertFalse(ok2);
        assertEq(r2, "insufficient bond");

        bond.setBond(agentId, 50e18);
        bond.setDisputes(agentId, 1);
        (bool ok3, string memory r3) = guard.canExecute(agentId, address(token), 4000);
        assertFalse(ok3);
        assertEq(r3, "agent under dispute");
    }

    /// A receipt bound to a rationale CANNOT mint reputation off an unrealized mark: yield that
    /// only sits as the strategy's spot balance (never recalled) leaves reputable NAV flat (#13).
    function test_unrealizedMark_doesNotCreditReputation_throughLoop() public {
        vm.prank(user);
        vault.deposit(100e18);
        vm.prank(operator);
        vault.deployToStrategy(address(strategy), 40e18);
        token.mint(address(strategy), 50e18); // big unrealized mark, never realized

        assertGt(vault.nav(), 1e18, "spot nav reflects the mark");
        assertEq(vault.reputableNav(), 1e18, "reputable nav ignores the unrealized mark");

        string memory rationale = "Hold: position marked up but not realized.";
        bytes32 evidence = keccak256(bytes(rationale));
        uint256 seq = vault.nextReceiptSeq();
        bytes memory sig = _sign(operatorPk, seq, evidence, int256(0), 600);
        vault.publishReceipt(seq, evidence, int256(0), 600, sig);

        assertEq(vault.lastReceiptEvidenceHash(), evidence, "evidence still bound");
        (int256 rep,) = identity.getSummary(agentId);
        assertEq(rep, int256(0), "unrealized mark must not credit reputation");
    }
}
