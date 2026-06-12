// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentIndex} from "../src/AgentIndex.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {MethRate} from "../src/MethRate.sol";
import {MethRateAdapter} from "../src/adapters/MethRateAdapter.sol";

/// @notice Mainnet deploy: a real-RWA Reef instance on Mantle mainnet (chain 5000) custodying
/// **mETH** — Mantle LSP's liquid-staked ETH (0xcDA8…0bb0). mETH is non-rebasing, so its validator
/// yield lives in the mETH->ETH rate (maintained on L1 Ethereum). This deploys a `MethRate` store
/// the keeper feeds from the live L1 rate (agents/scripts/meth_rate_push.py) and a `MethRateAdapter`
/// that marks the vault's held mETH to ETH at that rate — so the vault's on-chain NAV reflects REAL
/// accrued staking yield as the rate climbs. Deploys identity + index + one agent vault + the rate
/// store + adapter, and — if DEPOSIT_AMOUNT is set — deposits and deploys 80% in the same tx.
///
/// Required env: PRIVATE_KEY (funded Mantle mainnet key — real MNT for gas; holds the mETH).
/// Optional env: DEPOSIT_AMOUNT (mETH wei to deposit + deploy; the key must hold it);
///               INITIAL_RATE (mETH->ETH WAD, default 1.09e18 — the keeper sets the exact L1 rate after).
/// Run: forge script script/DeployMainnetMeth.s.sol:DeployMainnetMeth --rpc-url mantle --broadcast --legacy
///
/// WARNING: UNAUDITED (SECURITY.md, open items). Keep deposits at demo scale.
contract DeployMainnetMeth is Script {
    // mETH (Mantle LSP liquid-staked ETH) on Mantle mainnet, 18 decimals.
    address constant METH = 0xcDA86A272531e8640cD7F1a92c01839911B90bb0;

    function run() external {
        require(block.chainid == 5000, "not mantle mainnet");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        uint256 depositAmount = vm.envOr("DEPOSIT_AMOUNT", uint256(0));
        uint256 initialRate = vm.envOr("INITIAL_RATE", uint256(109e16)); // 1.09 ETH/mETH (keeper refines)

        vm.startBroadcast(pk);
        AgentIdentity identity = new AgentIdentity();
        AgentIndex index = new AgentIndex(METH, address(identity));
        AdapterRegistry registry = new AdapterRegistry();

        uint256 agentId = identity.register();
        AgentVault vault = new AgentVault(METH, agentId, address(identity), address(registry));
        identity.setReputationSource(agentId, address(vault)); // vault-only reputation
        index.addVault(address(vault));

        // L2 rate store (keeper = deployer; feed the live L1 mETH->ETH rate via meth_rate_push.py).
        MethRate rate = new MethRate(me, initialRate);
        MethRateAdapter adapter = new MethRateAdapter(METH, address(vault), address(rate));
        registry.approveAdapter(address(adapter)); // protocol vets the real mETH adapter
        vault.approveStrategy(address(adapter));

        if (depositAmount > 0) {
            IERC20(METH).approve(address(vault), depositAmount);
            vault.deposit(depositAmount);
            vault.deployToStrategy(address(adapter), (depositAmount * 80) / 100); // 20% idle buffer
        }
        vm.stopBroadcast();

        console.log("=== Reef MAINNET (chain 5000) deployed - real mETH ===");
        console.log("Asset (mETH)    :", METH);
        console.log("AgentIdentity   :", address(identity));
        console.log("AgentIndex      :", address(index));
        console.log("AgentVault      :", address(vault));
        console.log("MethRate        :", address(rate));
        console.log("MethRateAdapter :", address(adapter));
        console.log("Agent ID        :", agentId);
        console.log("Initial rate    :", initialRate);
        console.log("Deposited (mETH):", depositAmount);
        console.log("Next: run agents/scripts/meth_rate_push.py to sync the live L1 rate, then verify.");
        console.log("UNAUDITED - keep deposits at demo scale until audited (SECURITY.md).");
    }
}
