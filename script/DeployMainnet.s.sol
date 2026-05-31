// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentIndex} from "../src/AgentIndex.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {UsdyAdapter} from "../src/adapters/UsdyAdapter.sol";

/// @notice Mainnet-ready deploy: the full Reef system wired to REAL Ondo USDY on
/// Mantle mainnet (chain 5000). Deploys identity + index + one agent vault + the
/// live UsdyAdapter and approves it, so the system is one funded-key away from a
/// real-yield instance. It does NOT deposit (that needs real USDY) and writes no
/// TVL — fund the vault and rebalance only after a third-party audit.
///
/// Required env: PRIVATE_KEY (a funded Mantle mainnet key — real MNT for gas).
/// Run: forge script script/DeployMainnet.s.sol:DeployMainnet --rpc-url mantle --broadcast
///
/// WARNING: these contracts are UNAUDITED (see SECURITY.md, open items #2/#3/#6/#7).
/// Do not custody meaningful TVL on mainnet until audited.
contract DeployMainnet is Script {
    // Ondo USDY on Mantle mainnet (non-rebasing ERC-20, 18 decimals).
    address constant USDY = 0x5bE26527e817998A7206475496fDE1E68957c5A6;

    function run() external {
        require(block.chainid == 5000, "not mantle mainnet");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        AgentIdentity identity = new AgentIdentity();
        AgentIndex index = new AgentIndex(USDY, address(identity));

        uint256 agentId = identity.register();
        AgentVault vault = new AgentVault(USDY, agentId, address(identity));
        identity.setReputationSource(agentId, address(vault)); // vault-only reputation
        index.addVault(address(vault));

        UsdyAdapter adapter = new UsdyAdapter(USDY, address(vault));
        vault.approveStrategy(address(adapter)); // real Ondo USDY strategy
        vm.stopBroadcast();

        console.log("=== Reef MAINNET (chain 5000) deployed ===");
        console.log("Asset (USDY)  :", USDY);
        console.log("AgentIdentity :", address(identity));
        console.log("AgentIndex    :", address(index));
        console.log("AgentVault    :", address(vault));
        console.log("UsdyAdapter   :", address(adapter));
        console.log("Agent ID      :", agentId);
        console.log("");
        console.log(
            "Next (real USDY): holders deposit USDY -> operator deployToStrategy(adapter, amt) -> index.deposit + rebalance."
        );
        console.log("UNAUDITED - do not custody meaningful TVL until audited (SECURITY.md).");
    }
}
