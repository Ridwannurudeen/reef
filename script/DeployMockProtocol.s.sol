// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockProtocol} from "../src/MockProtocol.sol";

/// @notice Deploys MockProtocol wired to the LIVE ReefGuard on Mantle Sepolia and executes one
/// real gated agent action — proving an external protocol can call ReefGuard before letting an
/// agent touch capital. Agent 1 / MockAsset / 1000 bps clears the live policy (verified on-chain),
/// so executeAgentAction succeeds and emits ActionExecuted. A rejected case (oversize /
/// unregistered) is shown read-only via MockProtocol.check() — it would revert with the policy
/// reason if executed.
///
/// Required env: PRIVATE_KEY. Run (broadcast): forge script script/DeployMockProtocol.s.sol \
///   --rpc-url <sepolia> --broadcast --legacy
contract DeployMockProtocol is Script {
    address constant REEFGUARD = 0xe84E84D7e2E588aa8F88d1D1ADF2bdc70365a02b;
    address constant ASSET = 0xbc17D7F8f265d069781ed765914ED092989d92e7; // MockAsset (allowlisted)
    uint256 constant AGENT_ID = 1;

    function run() external {
        require(block.chainid == 5003, "not mantle sepolia");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        MockProtocol proto = new MockProtocol(REEFGUARD);
        // Real gated action: agent 1 is registered, bonded, and within size — clears ReefGuard.
        uint256 amount = proto.executeAgentAction(AGENT_ID, ASSET, 1000, 1e18);

        vm.stopBroadcast();

        console.log("=== Reef MockProtocol (Sepolia 5003) ===");
        console.log("mockProtocol :", address(proto));
        console.log("reefGuard    :", REEFGUARD);
        console.log("gated action executed for agent 1, amount:", amount);
    }
}
