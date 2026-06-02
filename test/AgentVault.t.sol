// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
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
        keccak256("Receipt(uint256 agentId,uint256 seq,bytes32 evidenceHash,int256 claimedDelta,uint64 period)");

    /// EIP-712-sign a receipt for `vault` with key `pk`.
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
        // Establish a real +0.5 per-share NAV gain: deposit principal, then simulate yield.
        vm.prank(alice);
        vault.deposit(1e18); // nav = 1e18
        token.mint(address(vault), 5e17); // donate yield -> nav = 1.5e18

        bytes32 evidence = keccak256("ev1");
        // The claimed delta in the signed receipt is a lie (1e24); it is ignored on-chain.
        // Submitted by `bob` (a relayer), proving the tx sender need not be the operator.
        bytes memory sig = _sign(operatorPk, 0, evidence, int256(1e24), uint64(3600));
        vm.prank(bob);
        vault.publishReceipt(0, evidence, int256(1e24), uint64(3600), sig);

        assertEq(vault.nextReceiptSeq(), 1);
        assertEq(vault.lastReceiptEvidenceHash(), evidence);
        (int256 cum, uint256 count) = identity.getSummary(agentId);
        assertEq(cum, 5e17); // credited the REAL nav delta, not the claimed 1e24
        assertEq(count, 1);
    }

    function test_reputation_highWaterMark_ignoresDrawdownRecovery() public {
        vm.prank(alice);
        vault.deposit(1e18); // nav 1.0
        token.mint(address(vault), 1e18); // nav 2.0
        vault.publishReceipt(0, keccak256("h0"), int256(0), uint64(60), _sign(operatorPk, 0, keccak256("h0"), 0, 60));
        (int256 c0,) = identity.getSummary(agentId);
        assertEq(c0, 1e18); // credited the +1.0 gain (new HWM = 2.0)

        // Drawdown: vault loses 1.0 (nav back to 1.0); a receipt credits nothing.
        vm.prank(address(vault));
        token.transfer(address(0xdEaD), 1e18);
        vault.publishReceipt(1, keccak256("h1"), int256(0), uint64(60), _sign(operatorPk, 1, keccak256("h1"), 0, 60));
        (int256 c1,) = identity.getSummary(agentId);
        assertEq(c1, 1e18); // unchanged — in drawdown

        // Recovery back to the prior peak (nav 2.0): still no credit (not a NEW high).
        token.mint(address(vault), 1e18);
        vault.publishReceipt(2, keccak256("h2"), int256(0), uint64(60), _sign(operatorPk, 2, keccak256("h2"), 0, 60));
        (int256 c2,) = identity.getSummary(agentId);
        assertEq(c2, 1e18); // no double-count of recovered ground

        // New high (nav 2.5): credit only the 0.5 above the high-water mark.
        token.mint(address(vault), 5e17);
        vault.publishReceipt(3, keccak256("h3"), int256(0), uint64(60), _sign(operatorPk, 3, keccak256("h3"), 0, 60));
        (int256 c3,) = identity.getSummary(agentId);
        assertEq(c3, 1e18 + 5e17);
    }

    function test_publishReceipt_badSeq_reverts() public {
        bytes memory sig = _sign(operatorPk, 1, keccak256("ev"), int256(1), uint64(60));
        vm.expectRevert(bytes("bad seq"));
        vault.publishReceipt(1, keccak256("ev"), int256(1), uint64(60), sig);
    }

    function test_publishReceipt_rejectsNonOperatorSignature() public {
        (, uint256 strangerPk) = makeAddrAndKey("stranger");
        bytes memory sig = _sign(strangerPk, 0, keccak256("ev"), int256(1), uint64(60));
        vm.expectRevert(bytes("bad signature"));
        vault.publishReceipt(0, keccak256("ev"), int256(1), uint64(60), sig);
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
