// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {SignalMarket} from "../src/SignalMarket.sol";

contract SignalMarketTest is Test {
    AgentIdentity identity;
    SignalMarket market;

    address provider = makeAddr("provider");
    address consumer = makeAddr("consumer");
    address stranger = makeAddr("stranger");

    uint256 providerAgent;
    uint256 consumerAgent;

    bytes32 evidence = keccak256("signal payload v1");

    function setUp() public {
        identity = new AgentIdentity();
        market = new SignalMarket(address(identity));
        vm.prank(provider);
        providerAgent = identity.register();
        vm.prank(consumer);
        consumerAgent = identity.register();
        vm.deal(consumer, 10 ether);
    }

    function test_createListing_onlyProvider() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("not provider"));
        market.createListing(providerAgent, 0.01 ether, "momentum");

        vm.prank(provider);
        uint256 id = market.createListing(providerAgent, 0.01 ether, "momentum");
        assertEq(id, 1);
    }

    function test_purchaseSignal_paysProvider() public {
        vm.prank(provider);
        uint256 id = market.createListing(providerAgent, 0.01 ether, "momentum");

        uint256 beforeBal = provider.balance;
        vm.prank(consumer);
        market.purchaseSignal{value: 0.01 ether}(id, consumerAgent, evidence);

        assertEq(provider.balance, beforeBal + 0.01 ether);
        // Reputation is intentionally NOT credited by SignalMarket (vault-only model).
        (int256 pCum,) = identity.getSummary(providerAgent);
        assertEq(pCum, 0);
    }

    function test_purchaseSignal_refundsExcess() public {
        vm.prank(provider);
        uint256 id = market.createListing(providerAgent, 0.01 ether, "momentum");

        uint256 before = consumer.balance;
        vm.prank(consumer);
        market.purchaseSignal{value: 0.05 ether}(id, consumerAgent, evidence);
        assertEq(consumer.balance, before - 0.01 ether);
    }

    function test_purchaseSignal_underpaid_reverts() public {
        vm.prank(provider);
        uint256 id = market.createListing(providerAgent, 0.01 ether, "momentum");
        vm.prank(consumer);
        vm.expectRevert(bytes("underpaid"));
        market.purchaseSignal{value: 0.005 ether}(id, consumerAgent, evidence);
    }

    function test_purchaseSignal_onlyConsumerOperator() public {
        vm.prank(provider);
        uint256 id = market.createListing(providerAgent, 0.01 ether, "momentum");
        // stranger tries to spoof consumerAgent
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(bytes("not consumer"));
        market.purchaseSignal{value: 0.01 ether}(id, consumerAgent, evidence);
    }

    function test_purchaseSignal_zeroEvidence_reverts() public {
        vm.prank(provider);
        uint256 id = market.createListing(providerAgent, 0.01 ether, "momentum");
        vm.prank(consumer);
        vm.expectRevert(bytes("zero evidence"));
        market.purchaseSignal{value: 0.01 ether}(id, consumerAgent, bytes32(0));
    }

    function test_deactivate_blocksPurchase_onlyProvider() public {
        vm.prank(provider);
        uint256 id = market.createListing(providerAgent, 0.01 ether, "momentum");

        vm.prank(stranger);
        vm.expectRevert(bytes("not provider"));
        market.deactivate(id);

        vm.prank(provider);
        market.deactivate(id);

        vm.prank(consumer);
        vm.expectRevert(bytes("not active"));
        market.purchaseSignal{value: 0.01 ether}(id, consumerAgent, evidence);
    }

    function test_createListing_zeroPrice_reverts() public {
        vm.prank(provider);
        vm.expectRevert(bytes("zero price"));
        market.createListing(providerAgent, 0, "momentum");
    }

    function test_createListing_noCategory_reverts() public {
        vm.prank(provider);
        vm.expectRevert(bytes("no category"));
        market.createListing(providerAgent, 0.01 ether, "");
    }

    function test_purchaseSignal_tracksEconomyMetrics() public {
        vm.prank(provider);
        uint256 id = market.createListing(providerAgent, 0.01 ether, "momentum");

        vm.prank(consumer);
        market.purchaseSignal{value: 0.01 ether}(id, consumerAgent, evidence);

        assertEq(market.salesOf(providerAgent), 1);
        assertEq(market.revenueOf(providerAgent), 0.01 ether);
        assertEq(market.totalSales(), 1);
        assertEq(market.totalRevenueWei(), 0.01 ether);
    }

    function test_getActiveListings_returnsActiveWithStats() public {
        vm.startPrank(provider);
        uint256 id1 = market.createListing(providerAgent, 0.01 ether, "momentum");
        uint256 id2 = market.createListing(providerAgent, 0.02 ether, "smart-money");
        vm.stopPrank();

        vm.prank(consumer);
        market.purchaseSignal{value: 0.01 ether}(id1, consumerAgent, evidence);

        // Deactivating id1 drops it from the active view; provider stats persist.
        vm.prank(provider);
        market.deactivate(id1);

        SignalMarket.ListingView[] memory active = market.getActiveListings();
        assertEq(active.length, 1);
        assertEq(active[0].id, id2);
        assertEq(active[0].providerAgentId, providerAgent);
        assertEq(active[0].priceWei, 0.02 ether);
        assertEq(active[0].category, "smart-money");
        assertEq(active[0].sales, 1);
        assertEq(active[0].revenueWei, 0.01 ether);
    }

    function test_purchaseSignal_selfDeal_reverts() public {
        vm.prank(provider);
        uint256 id = market.createListing(providerAgent, 0.01 ether, "momentum");
        vm.deal(provider, 1 ether);
        // provider tries to buy their own listing to farm reputation at ~zero cost
        vm.prank(provider);
        vm.expectRevert(bytes("self deal"));
        market.purchaseSignal{value: 0.01 ether}(id, providerAgent, evidence);
    }
}
