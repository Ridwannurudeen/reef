// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ReefGuard} from "../src/ReefGuard.sol";

/// @notice Deploy ReefGuard wired to the live Sepolia AgentIdentity + ReputationBond, with a
/// demo policy (min reputation 0.5e18, min bond 10e18, max action 50%) and the live index asset
/// allowlisted, so any protocol can query canExecute(agentId, asset, sizeBps) for the seeded agents.
/// Run: PRIVATE_KEY=<key> forge script script/DeployReefGuard.s.sol:DeployReefGuard --rpc-url <url> --broadcast
contract DeployReefGuard is Script {
    address constant IDENTITY = 0xe6D6320a3647a4b21Abe1654C30E848318D161DD;
    address constant BOND = 0xccfF181441a636a63f8b5f9b6697585b54165DAe;
    address constant ASSET = 0xbc17D7F8f265d069781ed765914ED092989d92e7; // live index MockAsset

    function run() external {
        require(block.chainid == 5003, "not mantle sepolia");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        vm.startBroadcast(pk);
        ReefGuard guard = new ReefGuard(IDENTITY, BOND, me, int256(5e17), 10e18, 5000);
        guard.setAssetAllowed(ASSET, true);
        vm.stopBroadcast();
        console.log("ReefGuard:", address(guard));
        console.log("governor :", me);
    }
}
