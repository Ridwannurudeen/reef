// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {IAgentVault} from "../src/interfaces/IAgentVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategyAdapter} from "./mocks/MockStrategyAdapter.sol";

contract AgentVaultTest is Test {
    AgentIdentity identity;
    AgentVault vault;
    AdapterRegistry registry;
    MockERC20 token;
    MockStrategyAdapter strategy;

    address operator;
    uint256 operatorPk;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint256 agentId;

    bytes32 constant RECEIPT_TYPEHASH =
        keccak256(
            "Receipt(uint256 agentId,uint256 seq,bytes32 evidenceHash,bytes32 contextHash,uint64 decisionTimestamp,uint64 validUntil,uint64 period,uint256 decisionBlock,int256 claimedDelta)"
        );
    bytes32 constant TEST_URI_HASH = keccak256("ipfs://reef-test");

    function _receipt(uint256 seq, bytes32 evidence, int256 claimedDelta, uint64 period)
        internal
        view
        returns (IAgentVault.Receipt memory r)
    {
        r = IAgentVault.Receipt({
            agentId: agentId,
            seq: seq,
            evidenceHash: evidence,
            actionHash: keccak256(abi.encode("action", seq)),
            policyHash: keccak256(abi.encode("policy", seq)),
            executionHash: keccak256(abi.encode("execution", seq)),
            postStateHash: keccak256(abi.encode("post-state", seq)),
            outcomeHash: keccak256(abi.encode("outcome", seq)),
            evidenceUriHash: TEST_URI_HASH,
            decisionTimestamp: uint64(block.timestamp),
            validUntil: uint64(block.timestamp + period),
            period: period,
            decisionBlock: block.number,
            claimedDelta: claimedDelta
        });
    }

    /// EIP-712-sign a receipt for `vault` with key `pk`.
    function _sign(uint256 pk, IAgentVault.Receipt memory receipt) internal view returns (bytes memory) {
        bytes32 contextHash = keccak256(
            abi.encode(
                receipt.actionHash,
                receipt.policyHash,
                receipt.executionHash,
                receipt.postStateHash,
                receipt.outcomeHash,
                receipt.evidenceUriHash
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                RECEIPT_TYPEHASH,
                receipt.agentId,
                receipt.seq,
                receipt.evidenceHash,
                contextHash,
                receipt.decisionTimestamp,
                receipt.validUntil,
                receipt.period,
                receipt.decisionBlock,
                receipt.claimedDelta
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _publish(uint256 seq, bytes32 evidence, int256 claimedDelta, uint64 period) internal {
        IAgentVault.Receipt memory receipt = _receipt(seq, evidence, claimedDelta, period);
        vault.publishReceipt(receipt, _sign(operatorPk, receipt));
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

        // Authorize the vault to write its agent's reputation (vault-only model).
        vm.prank(operator);
        identity.setReputationSource(agentId, address(vault));

        // Protocol governor allowlists the adapter, then the operator approves it.
        registry.approveAdapter(address(strategy));
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

    function test_inflationAttack_isUnprofitable() public {
        // Attacker opens the vault with 1 wei, then donates a large sum directly to
        // spike the share price. The virtual offset makes this a loss, not a theft.
        vm.prank(alice);
        vault.deposit(1);
        token.mint(address(vault), 50e18); // donation inflates totalAssets

        // Victim still receives non-trivial shares (not rounded to zero).
        vm.prank(bob);
        uint256 bobShares = vault.deposit(100e18);
        assertGt(bobShares, 0, "victim griefed to zero shares");

        // Attacker redeems everything and comes out behind what they put in.
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 aliceOut = vault.withdraw(aliceShares);
        assertLt(aliceOut, 50e18 + 1, "attacker profited from inflation");
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

    function test_approveStrategy_revertsWhenNotAllowlisted() public {
        MockStrategyAdapter rogue = new MockStrategyAdapter(address(token), address(vault));
        vm.prank(operator);
        vm.expectRevert(bytes("adapter not allowlisted"));
        vault.approveStrategy(address(rogue));
    }

    function test_approveStrategy_succeedsAfterAllowlist() public {
        MockStrategyAdapter extra = new MockStrategyAdapter(address(token), address(vault));
        registry.approveAdapter(address(extra));
        vm.prank(operator);
        vault.approveStrategy(address(extra));
        assertTrue(vault.approvedStrategies(address(extra)));
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

    /// Withdraw must pay what the strategy ACTUALLY realizes, not the spot mark. If a recall
    /// under-delivers (DEX slippage, a slashed/drained adapter), the vault pays the realized
    /// amount rather than transferring the marked amount it never received (which would revert
    /// the final withdrawer or overpay earlier ones).
    function test_withdraw_paysRealizedNotMarked_whenRecallUnderdelivers() public {
        vm.prank(alice);
        vault.deposit(100e18);
        vm.prank(operator);
        vault.deployToStrategy(address(strategy), 100e18); // fully deployed, zero idle buffer

        strategy.setRecallHaircutBps(50); // adapter realizes 0.5% less than asked

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        uint256 got = vault.withdraw(100e18); // would overdraw -> revert under the old logic

        assertEq(token.balanceOf(alice) - before, got, "paid != returned");
        assertEq(got, 100e18 * 9950 / 10_000); // realized amount, not the 100e18 mark
        assertEq(vault.totalShares(), 0, "shares not fully burned");
        assertEq(token.balanceOf(address(vault)), 0, "vault overdrew its balance");
    }

    // --- Circuit breaker ---

    function test_pause_blocksDeposit_allowsWithdraw() public {
        vm.prank(alice);
        vault.deposit(100e18);

        // Operator is the guardian of its own vault.
        vm.prank(operator);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert(bytes("paused"));
        vault.deposit(10e18);

        // Withdrawals stay open while paused — a pause never traps funds.
        vm.prank(alice);
        uint256 got = vault.withdraw(40e18);
        assertEq(got, 40e18);
    }

    function test_pause_onlyGuardian() public {
        vm.prank(alice);
        vm.expectRevert(bytes("not guardian"));
        vault.pause();
    }

    function test_pause_blocksDeployToStrategy() public {
        vm.prank(alice);
        vault.deposit(100e18);
        vm.prank(operator);
        vault.pause();
        vm.prank(operator);
        vm.expectRevert(bytes("paused"));
        vault.deployToStrategy(address(strategy), 50e18);
    }

    // --- Receipts ---

    function test_publishReceipt_creditsRealNavDelta_notClaim() public {
        // Establish a real +0.5 per-share gain: deposit, deploy, mark up, then REALIZE via recall.
        vm.prank(alice);
        vault.deposit(1e18); // nav = 1e18
        vm.prank(operator);
        vault.deployToStrategy(address(strategy), 1e18);
        token.mint(address(strategy), 5e17); // mark 1.5
        vm.prank(operator);
        vault.recallFromStrategy(address(strategy), 15e17); // realize -> reputableNav 1.5

        bytes32 evidence = keccak256("ev1");
        // The claimed delta in the signed receipt is a lie (1e24); it is ignored on-chain.
        // Submitted by `bob` (a relayer), proving the tx sender need not be the operator.
        IAgentVault.Receipt memory receipt = _receipt(0, evidence, int256(1e24), uint64(3600));
        bytes memory sig = _sign(operatorPk, receipt);
        vm.prank(bob);
        vault.publishReceipt(receipt, sig);

        assertEq(vault.nextReceiptSeq(), 1);
        assertEq(vault.lastReceiptEvidenceHash(), evidence);
        assertEq(vault.lastReceiptAt(), receipt.decisionTimestamp);
        assertEq(vault.lastReceiptValidUntil(), receipt.validUntil);
        assertEq(vault.lastReceiptEvidenceUriHash(), TEST_URI_HASH);
        (int256 cum, uint256 count) = identity.getSummary(agentId);
        assertEq(cum, 5e17); // credited the REAL realized delta, not the claimed 1e24
        assertEq(count, 1);
    }

    function test_reputation_creditsRealizedRecallNotMark() public {
        // SECURITY #13 regression: an UNREALIZED strategy mark credits zero reputation — only a
        // recall that realizes profit above the high-water mark does. (reputableNav values the
        // strategy at cost, so a flash-loaned/inflated spot mark cannot mint reputation.)
        vm.prank(alice);
        vault.deposit(1e18); // 1.0
        vm.prank(operator);
        vault.deployToStrategy(address(strategy), 1e18);

        token.mint(address(strategy), 1e18); // strategy MARKS up to 2.0 — but not recalled
        assertEq(vault.reputableNav(), 1e18); // valued at cost; mark ignored
        _publish(0, keccak256("m0"), int256(0), uint64(60));
        (int256 c0,) = identity.getSummary(agentId);
        assertEq(c0, 0); // unrealized mark mints nothing

        vm.prank(operator);
        vault.recallFromStrategy(address(strategy), 2e18); // REALIZE: +1.0 lands in managedIdle
        assertEq(vault.reputableNav(), 2e18);
        _publish(1, keccak256("m1"), int256(0), uint64(60));
        (int256 c1,) = identity.getSummary(agentId);
        assertEq(c1, 1e18); // credited the REALIZED +1.0 (new HWM = 2.0)

        // Redeploy + a fresh unrealized mark to 2.5: still no credit (cost basis == HWM).
        vm.prank(operator);
        vault.deployToStrategy(address(strategy), 2e18);
        token.mint(address(strategy), 5e17); // mark 2.5
        _publish(2, keccak256("m2"), int256(0), uint64(60));
        (int256 c2,) = identity.getSummary(agentId);
        assertEq(c2, 1e18); // unrealized — no new high credited

        vm.prank(operator);
        vault.recallFromStrategy(address(strategy), 25e17); // realize the new high
        _publish(3, keccak256("m3"), int256(0), uint64(60));
        (int256 c3,) = identity.getSummary(agentId);
        assertEq(c3, 1e18 + 5e17); // only the 0.5 above the prior high-water mark
    }

    function test_publishReceipt_donationDoesNotCreditReputation() public {
        // SECURITY #15 regression: a bare token donation lifts the public nav() but NOT
        // reputableNav(), so a receipt credits zero reputation. Reputation is donation-proof.
        vm.prank(alice);
        vault.deposit(1e18); // reputableNav 1.0
        token.mint(address(vault), 5e17); // donation: nav() -> 1.5, reputableNav stays 1.0

        assertEq(vault.nav(), 15e17); // share-pricing nav reflects the donation
        assertEq(vault.reputableNav(), 1e18); // reputation basis does NOT

        _publish(0, keccak256("d0"), int256(0), uint64(60));
        (int256 cum,) = identity.getSummary(agentId);
        assertEq(cum, 0); // donation minted no reputation
    }

    function test_depositAfterDonationDoesNotLiftReputableNav() public {
        vm.prank(alice);
        vault.deposit(100e18);
        token.mint(address(vault), 100e18); // raw donation inflates share price only

        vm.prank(bob);
        vault.deposit(100e18);

        assertEq(vault.reputableNav(), 1e18);
        _publish(0, keccak256("donation-deposit"), int256(0), uint64(60));
        (int256 cum,) = identity.getSummary(agentId);
        assertEq(cum, 0);
    }

    function test_reputableNavRecognizesPartialRealizedLoss() public {
        vm.prank(alice);
        vault.deposit(100e18);
        vm.prank(operator);
        vault.deployToStrategy(address(strategy), 100e18);

        vm.prank(address(strategy));
        token.transfer(address(0xdead), 50e18); // strategy is now marked at 50 against 100 cost

        vm.prank(operator);
        vault.recallFromStrategy(address(strategy), 25e18); // exits half the impaired position

        assertEq(vault.deployedCostBasis(), 50e18);
        assertEq(vault.realizedPnl(), -25e18);
        assertEq(vault.reputationAssets(), 75e18);
        assertEq(vault.reputableNav(), 75e16);

        _publish(0, keccak256("partial-loss"), int256(0), uint64(60));
        (int256 cum,) = identity.getSummary(agentId);
        assertEq(cum, 0, "loss must not mint reputation");
    }

    function test_withdrawAgainstUnrealizedLossDoesNotRatchetReputableNav() public {
        vm.prank(alice);
        vault.deposit(100e18);
        vm.prank(operator);
        vault.deployToStrategy(address(strategy), 80e18);

        vm.prank(address(strategy));
        token.transfer(address(0xdead), 40e18); // strategy marked below cost, but no recall yet

        vm.prank(alice);
        vault.withdraw(10e18); // paid from idle; old cost-basis numerator ratcheted upward here

        assertEq(vault.reputableNav(), 1e18);
        _publish(0, keccak256("loss-withdraw"), int256(0), uint64(60));
        (int256 cum,) = identity.getSummary(agentId);
        assertEq(cum, 0);
    }

    function test_publishReceipt_badSeq_reverts() public {
        IAgentVault.Receipt memory receipt = _receipt(1, keccak256("ev"), int256(1), uint64(60));
        bytes memory sig = _sign(operatorPk, receipt);
        vm.expectRevert(bytes("bad seq"));
        vault.publishReceipt(receipt, sig);
    }

    function test_publishReceipt_rejectsNonOperatorSignature() public {
        (, uint256 strangerPk) = makeAddrAndKey("stranger");
        IAgentVault.Receipt memory receipt = _receipt(0, keccak256("ev"), int256(1), uint64(60));
        bytes memory sig = _sign(strangerPk, receipt);
        vm.expectRevert(bytes("bad signature"));
        vault.publishReceipt(receipt, sig);
    }

    function test_publishReceipt_rejectsExpiredPresignedReceipt() public {
        IAgentVault.Receipt memory receipt = _receipt(0, keccak256("stale"), int256(0), uint64(60));
        bytes memory sig = _sign(operatorPk, receipt);

        vm.warp(block.timestamp + 61);
        vm.expectRevert(bytes("receipt expired"));
        vault.publishReceipt(receipt, sig);
    }

    function test_publishReceipt_rejectsZeroEvidenceUri() public {
        IAgentVault.Receipt memory receipt = _receipt(0, keccak256("no-uri"), int256(0), uint64(60));
        receipt.evidenceUriHash = bytes32(0);
        bytes memory sig = _sign(operatorPk, receipt);

        vm.expectRevert(bytes("zero evidence uri"));
        vault.publishReceipt(receipt, sig);
    }

    function test_publishReceipt_rejectsOverlongValidity() public {
        IAgentVault.Receipt memory receipt = _receipt(0, keccak256("too-long"), int256(0), uint64(60));
        receipt.validUntil = uint64(block.timestamp + vault.MAX_RECEIPT_VALIDITY() + 1);
        bytes memory sig = _sign(operatorPk, receipt);

        vm.expectRevert(bytes("validity too long"));
        vault.publishReceipt(receipt, sig);
    }

    function test_publishReceipt_rejectsTamperedContext() public {
        IAgentVault.Receipt memory receipt = _receipt(0, keccak256("ctx"), int256(0), uint64(60));
        bytes memory sig = _sign(operatorPk, receipt);
        receipt.policyHash = keccak256("changed-policy");

        vm.expectRevert(bytes("bad signature"));
        vault.publishReceipt(receipt, sig);
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
