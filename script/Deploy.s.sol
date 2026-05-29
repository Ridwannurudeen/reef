// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentIndex} from "../src/AgentIndex.sol";

/// @notice Deploy the singleton Reef infrastructure on Mantle (Sepolia or Mainnet).
/// Required env: PRIVATE_KEY, ASSET (USDY/USDC token address on the target chain).
/// Usage:
///   forge script script/Deploy.s.sol --rpc-url mantle_sepolia --broadcast
///   forge script script/Deploy.s.sol --rpc-url mantle --broadcast
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address asset = vm.envAddress("ASSET");

        vm.startBroadcast(pk);
        AgentIdentity identity = new AgentIdentity();
        AgentIndex index = new AgentIndex(asset, address(identity));
        vm.stopBroadcast();

        console.log("=== Reef deployed ===");
        console.log("Chain ID      :", block.chainid);
        console.log("Asset (USDY)  :", asset);
        console.log("AgentIdentity :", address(identity));
        console.log("AgentIndex    :", address(index));
        console.log("Governor      :", vm.addr(pk));
        console.log("");
        console.log("Next:");
        console.log("  - Agents call AgentIdentity.register() to mint their ERC-8004 NFT.");
        console.log("  - Operators deploy AgentVault(asset, agentId, identity).");
        console.log("  - Governor calls AgentIndex.addVault(vault) to include in the basket.");
    }
}
