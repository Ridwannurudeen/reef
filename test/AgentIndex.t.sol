// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {AgentIndex} from "../src/AgentIndex.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {ReputationBond} from "../src/ReputationBond.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategyAdapter} from "./mocks/MockStrategyAdapter.sol";

contract AgentIndexTest is Test {
    AgentIdentity identity;
    AgentIndex index;
    AgentVault vaultA;
    AgentVault vaultB;
    AdapterRegistry registry;
    MockERC20 token;

    address opA;
    uint256 opAPk;
    address opB;
    uint256 opBPk;

    bytes32 constant RECEIPT_TYPEHASH =
        keccak256("Receipt(uint256 agentId,uint256 seq,bytes32 evidenceHash,int256 claimedDelta,uint64 period)");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 idA;
    uint256 idB;

    function setUp() public {
        (opA, opAPk) = makeAddrAndKey("opA");
        (opB, opBPk) = makeAddrAndKey("opB");
        identity = new AgentIdentity();
        token = new MockERC20();
        index = new AgentIndex(address(token), address(identity));
        registry = new AdapterRegistry();

        vm.prank(opA);
        idA = identity.register();
        vm.prank(opB);
        idB = identity.register();

        vaultA = new AgentVault(address(token), idA, address(identity), address(registry));
        vaultB = new AgentVault(address(token), idB, address(identity), address(registry));

        index.addVault(address(vaultA));
        index.addVault(address(vaultB));

        // Authorize each vault to write its agent's reputation (vault-only model).
        vm.prank(opA);
        identity.setReputationSource(idA, address(vaultA));
        vm.prank(opB);
        identity.setReputationSource(idB, address(vaultB));

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
        AgentVault other = new AgentVault(address(token), idA, address(identity), address(registry));
        vm.prank(alice);
        vm.expectRevert(bytes("not governor"));
        index.addVault(address(other));

        index.addVault(address(other));
        vm.expectRevert(bytes("registered"));
        index.addVault(address(other));
    }

    function test_removeVault_evictsAndKeepsTotalAssetsLive() public {
        assertEq(index.vaultCount(), 2);

        vm.prank(alice);
        vm.expectRevert(bytes("not governor"));
        index.removeVault(address(vaultA));

        // Deposit + rebalance so the index actually holds shares in both vaults.
        vm.prank(alice);
        index.deposit(100e18);
        index.rebalance();
        assertGt(index.vaultShares(address(vaultA)), 0);

        index.removeVault(address(vaultA));
        assertEq(index.vaultCount(), 1);
        assertFalse(index.isRegistered(address(vaultA)));
        assertEq(index.vaultShares(address(vaultA)), 0);

        // totalAssets still computes (the removed vault is never called) and getAllocation excludes it.
        index.totalAssets();
        AgentIndex.Allocation[] memory alloc = index.getAllocation();
        assertEq(alloc.length, 1);
        assertEq(alloc[0].vault, address(vaultB));

        vm.expectRevert(bytes("not registered"));
        index.removeVault(address(vaultA));
    }

    function test_addVault_rejectsWrongAsset() public {
        MockERC20 otherToken = new MockERC20();
        vm.prank(opA);
        uint256 idX = identity.register();
        AgentVault otherVault = new AgentVault(address(otherToken), idX, address(identity), address(registry));
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

        _giveRep(vaultA, opAPk, 3e18); // vaultA earns reputation via a real NAV gain; vaultB stays at 0

        index.rebalance();
        AgentIndex.Allocation[] memory alloc = index.getAllocation();
        // vaultA has all the positive rep → 100% allocation
        assertEq(alloc[0].weightBps, 10000);
        assertEq(alloc[1].deployed, 0);
    }

    function test_rebalance_redistributes_whenReputationChanges() public {
        vm.prank(alice);
        index.deposit(100e18);
        // first: A gets all rep
        _giveRep(vaultA, opAPk, 2e18);
        index.rebalance();
        assertEq(index.getAllocation()[0].weightBps, 10000);

        // now B catches up: A=2, B=6 → A≈25%, B≈75% (±rounding from non-unit NAV)
        _giveRep(vaultB, opBPk, 6e18);
        index.rebalance();
        AgentIndex.Allocation[] memory alloc = index.getAllocation();
        assertApproxEqAbs(alloc[0].weightBps, 2500, 5);
        assertApproxEqAbs(alloc[1].weightBps, 7500, 5);
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

    // --- Circuit breaker + withdrawPool ---

    function test_pause_blocksDepositAndRebalance_allowsWithdraw() public {
        vm.prank(alice);
        index.deposit(100e18);

        index.pause(); // test contract is governor = guardian

        vm.prank(alice);
        vm.expectRevert(bytes("paused"));
        index.deposit(10e18);

        vm.expectRevert(bytes("paused"));
        index.rebalance();

        // Redemptions stay open while paused.
        vm.prank(alice);
        uint256 got = index.withdraw(40e18);
        assertEq(got, 40e18);
    }

    function test_pause_onlyGuardian() public {
        vm.prank(alice);
        vm.expectRevert(bytes("not guardian"));
        index.pause();
    }

    function test_reserveBps_keepsLiquidityIdle() public {
        index.setReserveBps(2000); // hold back 20%
        vm.prank(alice);
        index.deposit(100e18);
        index.rebalance();

        // 80 allocated equally (40/40), 20 retained as withdrawPool liquidity.
        assertEq(token.balanceOf(address(index)), 20e18);
        AgentIndex.Allocation[] memory alloc = index.getAllocation();
        assertApproxEqAbs(alloc[0].deployed, 40e18, 1);
        assertApproxEqAbs(alloc[1].deployed, 40e18, 1);
    }

    function test_setReserveBps_rejectsOver100pct() public {
        vm.expectRevert(bytes("bps"));
        index.setReserveBps(10_001);
    }

    // --- Permissionless bonded self-listing ---

    function _newBondedVault(uint256 bondAmt)
        internal
        returns (ReputationBond rb, AgentVault vaultC, address opC, uint256 idC)
    {
        rb = new ReputationBond(address(token), address(identity), address(this), 1e18, 10e18, 1 days);
        index.setReputationBond(address(rb), 10e18);
        opC = makeAddr("opC");
        vm.prank(opC);
        idC = identity.register();
        vaultC = new AgentVault(address(token), idC, address(identity), address(registry));
        if (bondAmt > 0) {
            token.mint(opC, bondAmt);
            vm.prank(opC);
            token.approve(address(rb), type(uint256).max);
            vm.prank(opC);
            rb.postBond(idC, bondAmt);
        }
    }

    function test_selfListVault_permissionless_whenBonded() public {
        (, AgentVault vaultC, address opC,) = _newBondedVault(50e18);
        uint256 before = index.vaultCount();
        vm.prank(opC);
        index.selfListVault(address(vaultC));
        assertEq(index.vaultCount(), before + 1);
        assertTrue(index.isRegistered(address(vaultC)));
    }

    function test_selfListVault_revertsWhenUnderbonded() public {
        (, AgentVault vaultC, address opC,) = _newBondedVault(0); // no bond posted
        vm.prank(opC);
        vm.expectRevert(bytes("underbonded"));
        index.selfListVault(address(vaultC));
    }

    function test_selfListVault_revertsForNonOperator() public {
        (, AgentVault vaultC,,) = _newBondedVault(50e18);
        vm.prank(alice);
        vm.expectRevert(bytes("not operator"));
        index.selfListVault(address(vaultC));
    }

    function test_selfListVault_revertsWhenListingClosed() public {
        // No bond gate configured → self-listing is closed.
        address opC = makeAddr("opC");
        vm.prank(opC);
        uint256 idC = identity.register();
        AgentVault vaultC = new AgentVault(address(token), idC, address(identity), address(registry));
        vm.prank(opC);
        vm.expectRevert(bytes("listing closed"));
        index.selfListVault(address(vaultC));
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

    /// Index withdraw must pay what the vaults ACTUALLY realize, not their spot mark. If a
    /// listed vault's recall under-delivers (its adapter realizes less than nav()), the index
    /// pays the realized total instead of overdrawing — which would revert the last redeemer.
    function test_withdraw_paysRealizedNotMarked_whenVaultUnderdelivers() public {
        // vaultA deploys its index-allocated capital into a strategy that realizes less on recall.
        MockStrategyAdapter adA = new MockStrategyAdapter(address(token), address(vaultA));
        registry.approveAdapter(address(adA));
        vm.prank(opA);
        vaultA.approveStrategy(address(adA));

        vm.prank(alice);
        index.deposit(100e18);
        index.rebalance(); // ~50 to each vault, 0 idle in the index

        uint256 vaultAIdle = token.balanceOf(address(vaultA));
        vm.prank(opA);
        vaultA.deployToStrategy(address(adA), vaultAIdle); // vaultA fully deployed
        adA.setRecallHaircutBps(200); // realizes 2% less than asked on recall

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        uint256 got = index.withdraw(100e18); // would overdraw -> revert under the old logic

        assertEq(token.balanceOf(alice) - before, got, "paid != returned");
        assertEq(index.totalShares(), 0, "shares not fully burned");
        assertLt(got, 100e18); // bears vaultA's realization haircut
        assertEq(token.balanceOf(address(index)), 0, "index overdrew its balance");
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

    function _giveRep(AgentVault v, uint256 opPk, uint256 repAmount) internal {
        // Donation-proof reputation: deposit principal, deploy into a strategy, then simulate
        // `repAmount` of REAL strategy yield (mint to the adapter, not the vault) so reputableNav()
        // rises by exactly repAmount per share. A bare vault donation no longer credits reputation.
        address op = vm.addr(opPk);
        token.mint(address(this), 1e18);
        token.approve(address(v), 1e18);
        v.deposit(1e18);
        MockStrategyAdapter adapter = new MockStrategyAdapter(address(token), address(v));
        registry.approveAdapter(address(adapter));
        vm.prank(op);
        v.approveStrategy(address(adapter));
        vm.prank(op);
        v.deployToStrategy(address(adapter), 1e18);
        token.mint(address(adapter), repAmount); // strategy yield (unrealized mark)
        vm.prank(op);
        v.recallFromStrategy(address(adapter), 1e18 + repAmount); // realize it (cost-basis model)
        uint256 seq = v.nextReceiptSeq();
        bytes32 evidence = keccak256(abi.encode("rep", address(v), seq));
        bytes32 structHash = keccak256(abi.encode(RECEIPT_TYPEHASH, v.agentId(), seq, evidence, int256(0), uint64(60)));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", v.domainSeparator(), structHash));
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(opPk, digest);
        v.publishReceipt(seq, evidence, int256(0), uint64(60), abi.encodePacked(r, s, vv));
    }

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
        _giveRep(vaultA, opAPk, 5e18);
        _giveRep(vaultB, opBPk, 5e18);
        index.rebalance();
        AgentIndex.Allocation[] memory alloc = index.getAllocation();
        assertEq(alloc[0].weightBps, 10000); // A gets all
        assertEq(alloc[1].deployed, 0); // B excluded — no bond
    }
}
