// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {FusionXAdapter} from "../src/adapters/FusionXAdapter.sol";

/// @notice Mainnet deploy: a self-contained 4-agent on-chain AI-trading benchmark on Mantle
/// mainnet (chain 5000). Each agent gets its own AgentVault (asset = USDC) plus a real
/// FusionXAdapter that swaps that USDC into a WMNT long via FusionX V2, so every vault's NAV is
/// a live mark-to-market of an actual on-chain position — the four agents compete on real PnL.
/// Stands up one shared AgentIdentity + AdapterRegistry, registers 4 agents, deploys 4 vault +
/// adapter pairs, vets each adapter in the registry, wires it as its vault's strategy, and binds
/// each vault as its agent's reputation source. Slippage is set TIGHT (150 bps = 1.5%) — the
/// 30% testnet tolerance has no place against a deep mainnet pool.
///
/// Does NOT deposit or seed any funds — the lead seeds the demo capital manually afterwards.
/// USDC is 6-decimals; this script never hardcodes token amounts (the vault/adapter math is
/// unit-agnostic).
///
/// Required env: PRIVATE_KEY (funded Mantle mainnet key — real MNT for gas; becomes the operator
/// of all 4 agents and the registry governor).
/// Run: forge script script/DeployMainnetFusionX.s.sol:DeployMainnetFusionX --rpc-url mantle --broadcast --legacy
///
/// WARNING: UNAUDITED (SECURITY.md, open items). Keep seeded capital at demo scale.
contract DeployMainnetFusionX is Script {
    // Verified live Mantle mainnet addresses (deployments/mantle-mainnet.json).
    address constant USDC = 0x09Bc4E0D864854c6aFB6eB9A9cdF58aC190D0dF9; // 6 decimals
    address constant WMNT = 0x78c1b0C915c4FAA5FffA6CAbf0219DA63d7f4cb8;
    address constant ROUTER = 0xDd0840118bF9CCCc6d67b2944ddDfbdb995955FD; // FusionX V2

    uint256 constant AGENTS = 4;
    uint256 constant SLIPPAGE_BPS = 150; // 1.5% — tight, deep mainnet pool (NOT the 30% testnet default)

    struct Pair {
        uint256 agentId;
        AgentVault vault;
        FusionXAdapter adapter;
    }

    /// @notice Persona names, indexed by registration order. MUST mirror BENCHMARK_PERSONAS in
    /// agents/shared/personas.py — the keeper resolves each vault's strategy by this exact string.
    function _personaNames() internal pure returns (string[4] memory) {
        return ["GLM Synthesis", "Momentum", "Contrarian", "HODL"];
    }

    /// @notice The full wiring sequence, shared by run() (real broadcast) and the test (mocks).
    /// Registers `count` agents and, for each, deploys an AgentVault + FusionXAdapter, vets the
    /// adapter in the registry, wires it as the vault's strategy, and binds the vault as the
    /// agent's reputation source. Caller is operator/governor of everything it creates.
    function deployBenchmark(address asset, address long, address router, uint256 count, uint256 slippageBps)
        public
        returns (AgentIdentity identity, AdapterRegistry registry, Pair[] memory pairs)
    {
        identity = new AgentIdentity();
        registry = new AdapterRegistry();
        pairs = new Pair[](count);

        for (uint256 i = 0; i < count; i++) {
            uint256 agentId = identity.register();
            AgentVault vault = new AgentVault(asset, agentId, address(identity), address(registry));
            identity.setReputationSource(agentId, address(vault)); // vault-only reputation

            FusionXAdapter adapter = new FusionXAdapter(asset, long, router, address(vault), slippageBps);
            registry.approveAdapter(address(adapter)); // protocol vets the real DEX adapter instance
            vault.approveStrategy(address(adapter)); // operator wires it as the vault's strategy

            pairs[i] = Pair(agentId, vault, adapter);
        }
    }

    function run() external {
        require(block.chainid == 5000, "not mantle mainnet");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        (AgentIdentity identity, AdapterRegistry registry, Pair[] memory pairs) =
            deployBenchmark(USDC, WMNT, ROUTER, AGENTS, SLIPPAGE_BPS);
        vm.stopBroadcast();

        string[4] memory personas = _personaNames();

        console.log("=== Reef MAINNET (chain 5000) - 4-agent FusionX USDC->WMNT benchmark ===");
        console.log("Asset (USDC)    :", USDC);
        console.log("Long  (WMNT)    :", WMNT);
        console.log("Router (FusionX):", ROUTER);
        console.log("maxSlippageBps  :", SLIPPAGE_BPS);
        console.log("AgentIdentity   :", address(identity));
        console.log("AdapterRegistry :", address(registry));
        for (uint256 i = 0; i < AGENTS; i++) {
            console.log("--- agent", pairs[i].agentId, personas[i]);
            console.log("  AgentVault    :", address(pairs[i].vault));
            console.log("  FusionXAdapter:", address(pairs[i].adapter));
        }
        console.log("");

        // JSON-ready block — paste into deployments/mantle-mainnet.json under "benchmark"
        // (the exact shape agents/scripts/mainnet_keeper.py consumes).
        string memory vaultsJson = "[";
        for (uint256 i = 0; i < AGENTS; i++) {
            vaultsJson = string.concat(
                vaultsJson,
                i == 0 ? "" : ",",
                '{"agentId":',
                vm.toString(pairs[i].agentId),
                ',"persona":"',
                personas[i],
                '","vault":"',
                vm.toString(address(pairs[i].vault)),
                '","adapter":"',
                vm.toString(address(pairs[i].adapter)),
                '"}'
            );
        }
        vaultsJson = string.concat(vaultsJson, "]");

        string memory summary = string.concat(
            '{"benchmark":{"chainId":5000,"asset":"USDC","assetAddress":"',
            vm.toString(USDC),
            '","long":"WMNT","longAddress":"',
            vm.toString(WMNT),
            '","router":"',
            vm.toString(ROUTER),
            '","maxSlippageBps":',
            vm.toString(SLIPPAGE_BPS),
            ',"identity":"',
            vm.toString(address(identity)),
            '","registry":"',
            vm.toString(address(registry)),
            '","vaults":',
            vaultsJson,
            "}}"
        );
        console.log(summary);
    }
}
