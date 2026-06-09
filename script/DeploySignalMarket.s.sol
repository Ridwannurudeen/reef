// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {SignalMarket} from "../src/SignalMarket.sol";

/// @notice Standalone agent-to-agent (A2A) signal marketplace demo on Mantle Sepolia
/// (chain 5003). Stands up its own AgentIdentity + SignalMarket, registers a few provider
/// agents, lists priced signals under categories, and executes real on-chain purchases so
/// the contract's on-chain economy metrics (salesOf / revenueOf / totalSales /
/// totalRevenueWei) are populated and queryable via getActiveListings(). Isolated from the
/// live leaderboard instance. Reputation is intentionally NOT credited by purchases
/// (vault-only model), so this cannot farm ERC-8004 reputation.
///
/// Required env: PRIVATE_KEY (the broadcaster; also acts as every agent's wallet, so it
/// both lists and buys — net cost is gas plus the tiny self-routed payments).
/// Run (broadcast): forge script script/DeploySignalMarket.s.sol:DeploySignalMarket \
///   --rpc-url <sepolia> --broadcast --legacy
contract DeploySignalMarket is Script {
    function run() external {
        require(block.chainid == 5003, "not mantle sepolia");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        vm.startBroadcast(pk);

        AgentIdentity identity = new AgentIdentity();
        SignalMarket market = new SignalMarket(address(identity));

        // Three provider agents (all walleted to `me`, so this script can list and buy).
        uint256 alloraAgent = identity.register(); // 1
        uint256 smartAgent = identity.register(); // 2
        uint256 momentumAgent = identity.register(); // 3

        // Listings across distinct categories.
        uint256 l1 = market.createListing(alloraAgent, 0.002 ether, "price-prediction");
        uint256 l2 = market.createListing(smartAgent, 0.003 ether, "smart-money");
        uint256 l3 = market.createListing(momentumAgent, 0.0015 ether, "momentum");

        // Real purchases (provider != consumer). Payment routes provider->me; refunds excess.
        // Populates the on-chain economy metrics with differentiated per-provider volume.
        market.purchaseSignal{value: 0.002 ether}(l1, smartAgent, keccak256("allora forecast #1"));
        market.purchaseSignal{value: 0.002 ether}(l1, momentumAgent, keccak256("allora forecast #2"));
        market.purchaseSignal{value: 0.003 ether}(l2, alloraAgent, keccak256("smart-money netflow #1"));

        vm.stopBroadcast();

        console.log("=== Reef A2A Signal Marketplace (Sepolia 5003) ===");
        console.log("identity     :", address(identity));
        console.log("signalMarket :", address(market));
        console.log("provider agents: alloraAgent=1 smartAgent=2 momentumAgent=3 (wallet:", me, ")");
        console.log("listings     : l1(price-prediction)=", l1);
        console.log("               l2(smart-money)=", l2);
        console.log("               l3(momentum)=", l3);
        console.log("totalSales   :", market.totalSales());
        console.log("totalRevenue :", market.totalRevenueWei());
    }
}
