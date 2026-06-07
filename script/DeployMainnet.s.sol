// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentIndex} from "../src/AgentIndex.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {UsdyAdapter} from "../src/adapters/UsdyAdapter.sol";

interface IRedemptionOracle {
    function getPrice() external view returns (uint256);
}

/// @notice Mainnet deploy: a real-RWA Reef instance on Mantle mainnet (chain 5000),
/// wired to **mUSD** — "Mantle USD", the REBASING wrapper of Ondo USDY
/// (0x5bE2…c5A6). mUSD's `balanceOf` grows as the underlying T-bill yield accrues,
/// so the vault's on-chain NAV reflects REAL yield — unlike non-rebasing USDY, whose
/// yield lives only in an off-chain price. Ondo's on-chain redemption oracle
/// (0xA96a…882f) publishes USDY's USD price (logged here as proof of accrued yield).
///
/// Deploys identity + index + one agent vault + a vault-only UsdyAdapter holding
/// mUSD, and — if DEPOSIT_AMOUNT is set — makes a real deposit and deploys 80% into
/// the strategy in the same transaction (20% idle redemption buffer).
///
/// Required env: PRIVATE_KEY (funded Mantle mainnet key — real MNT for gas).
/// Optional env: DEPOSIT_AMOUNT (mUSD wei to deposit + deploy; the key must hold it).
/// Run: forge script script/DeployMainnet.s.sol:DeployMainnet --rpc-url mantle --broadcast
///
/// WARNING: UNAUDITED (SECURITY.md, open items). Keep deposits at demo scale.
contract DeployMainnet is Script {
    // Mantle USD (mUSD) — rebasing wrapper of Ondo USDY on Mantle mainnet, 18 decimals.
    address constant MUSD = 0xab575258d37EaA5C8956EfABe71F4eE8F6397cF3;
    // Ondo on-chain redemption price oracle for USDY (USD value, 18 decimals).
    address constant ORACLE = 0xA96abbe61AfEdEB0D14a20440Ae7100D9aB4882f;

    function run() external {
        require(block.chainid == 5000, "not mantle mainnet");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        uint256 depositAmount = vm.envOr("DEPOSIT_AMOUNT", uint256(0));

        vm.startBroadcast(pk);
        AgentIdentity identity = new AgentIdentity();
        AgentIndex index = new AgentIndex(MUSD, address(identity));
        AdapterRegistry registry = new AdapterRegistry();

        uint256 agentId = identity.register();
        AgentVault vault = new AgentVault(MUSD, agentId, address(identity), address(registry));
        identity.setReputationSource(agentId, address(vault)); // vault-only reputation
        index.addVault(address(vault));

        UsdyAdapter adapter = new UsdyAdapter(MUSD, address(vault));
        registry.approveAdapter(address(adapter)); // protocol vets the real mUSD adapter
        vault.approveStrategy(address(adapter));

        if (depositAmount > 0) {
            IERC20(MUSD).approve(address(vault), depositAmount);
            vault.deposit(depositAmount);
            vault.deployToStrategy(address(adapter), (depositAmount * 80) / 100); // 20% idle buffer
        }
        vm.stopBroadcast();

        uint256 price = IRedemptionOracle(ORACLE).getPrice();
        console.log("=== Reef MAINNET (chain 5000) deployed - real mUSD ===");
        console.log("Asset (mUSD)    :", MUSD);
        console.log("AgentIdentity   :", address(identity));
        console.log("AgentIndex      :", address(index));
        console.log("AgentVault      :", address(vault));
        console.log("UsdyAdapter     :", address(adapter));
        console.log("Agent ID        :", agentId);
        console.log("USDY price (1e18):", price);
        console.log("Deposited (mUSD):", depositAmount);
        console.log("UNAUDITED - keep deposits at demo scale until audited (SECURITY.md).");
    }
}
