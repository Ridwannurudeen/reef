// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentIndex} from "../src/AgentIndex.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {ReputationBond} from "../src/ReputationBond.sol";
import {ReefGuard} from "../src/ReefGuard.sol";
import {TrustOracle} from "../src/TrustOracle.sol";
import {TrustOracleConsumer} from "../src/TrustOracleConsumer.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockStrategyAdapter} from "../test/mocks/MockStrategyAdapter.sol";

/// @notice One-shot fresh deploy of the FULL hardened Reef leaderboard core on Mantle Sepolia,
/// so the live system runs the donation-proof / realized-PnL contracts (reputableNav, #13/#15 fixed)
/// instead of the older nav()-based instance. Deploys identity + index + bond + guard, seeds 5 agents
/// with REALIZED (donation-proof) reputation exactly as Seed.s.sol does, rebalances, then deploys the
/// hardened TrustOracle (reads reputableNav) wired to the new core and registers the 5 vaults.
///
/// Required env: PRIVATE_KEY, ASSET (mintable demo token, e.g. existing MockUSDY).
/// Run: forge script script/DeployHardenedSepolia.s.sol:DeployHardenedSepolia --rpc-url <url> --broadcast --legacy
contract DeployHardenedSepolia is Script {
    bytes32 constant RECEIPT_TYPEHASH =
        keccak256("Receipt(uint256 agentId,uint256 seq,bytes32 evidenceHash,int256 claimedDelta,uint64 period)");

    AgentIdentity identity;
    AgentIndex index;
    ReputationBond bond;
    ReefGuard guard;
    AdapterRegistry registry;
    TrustOracle oracle;
    TrustOracleConsumer consumer;
    address[5] vaults;

    function _sign(uint256 pk, AgentVault vault, uint256 agentId, bytes32 evidence, int256 delta)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash =
            keccak256(abi.encode(RECEIPT_TYPEHASH, agentId, uint256(0), evidence, delta, uint64(86_400)));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// Register an agent, deploy + authorize its vault, manufacture a differentiated REALIZED per-share
    /// NAV gain (deposit 1e18, deploy into a mock strategy, mint yield to the adapter, recall it so the
    /// gain enters cost basis), then publish an operator-signed receipt. Reputation is reputableNav-derived,
    /// so it credits realized, donation-proof performance only (#13/#15). Returns the vault address.
    function _seedAgent(MockERC20 asset, uint256 pk, uint256 i, int256 delta) internal returns (address) {
        uint256 agentId = identity.register();
        AgentVault vault = new AgentVault(address(asset), agentId, address(identity), address(registry));
        identity.setReputationSource(agentId, address(vault));
        index.addVault(address(vault));

        _realizeYield(asset, vault, pk, delta);

        bytes32 evidence = keccak256(abi.encode("seed", i));
        bytes memory sig = _sign(pk, vault, agentId, evidence, delta);
        vault.publishReceipt(0, evidence, delta, uint64(86_400), sig);
        console.log("agent", agentId, "vault", address(vault));
        return address(vault);
    }

    /// Deposit 1e18 principal, deploy into a mock strategy, mint `delta` yield onto the adapter, and
    /// recall it so the gain enters cost basis — making the reputable NAV gain realized (donation-proof).
    function _realizeYield(MockERC20 asset, AgentVault vault, uint256 pk, int256 delta) internal {
        asset.mint(vm.addr(pk), 1e18);
        asset.approve(address(vault), 1e18);
        vault.deposit(1e18);

        MockStrategyAdapter adapter = new MockStrategyAdapter(address(asset), address(vault));
        registry.approveAdapter(address(adapter));
        vault.approveStrategy(address(adapter));
        vault.deployToStrategy(address(adapter), 1e18);
        asset.mint(address(adapter), uint256(delta));
        vault.recallFromStrategy(address(adapter), 1e18 + uint256(delta));
    }

    function run() external {
        require(block.chainid == 5003, "not mantle sepolia");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        MockERC20 asset = MockERC20(vm.envAddress("ASSET"));
        address deployer = vm.addr(pk);

        int256[5] memory navDeltas = [int256(1e18), int256(2e18), int256(3e18), int256(5e18), int256(8e18)];
        uint256 deposit = 1_000e18;

        vm.startBroadcast(pk);

        // Core.
        identity = new AgentIdentity();
        index = new AgentIndex(address(asset), address(identity));
        bond = new ReputationBond(address(asset), address(identity), deployer, 1e18, 5e18, 1 days);
        guard = new ReefGuard(address(identity), address(bond), deployer, 0, 0, 10_000);
        registry = new AdapterRegistry();

        // Index capital to allocate.
        asset.mint(deployer, deposit);
        asset.approve(address(index), deposit);

        // Seed 5 agents with realized, donation-proof reputation.
        for (uint256 i = 0; i < navDeltas.length; i++) {
            vaults[i] = _seedAgent(asset, pk, i, navDeltas[i]);
        }

        index.deposit(deposit);
        index.rebalance();

        // Hardened TrustOracle (reads reputableNav) + reference consumer.
        oracle = new TrustOracle(address(identity), address(bond), address(guard));
        for (uint256 i = 0; i < vaults.length; i++) {
            oracle.registerVault(vaults[i]);
        }
        consumer = new TrustOracleConsumer(address(oracle), 55e16);

        vm.stopBroadcast();

        console.log("=== Reef hardened core (Sepolia) ===");
        console.log("AgentIdentity   :", address(identity));
        console.log("AgentIndex      :", address(index));
        console.log("ReputationBond  :", address(bond));
        console.log("ReefGuard       :", address(guard));
        console.log("AdapterRegistry :", address(registry));
        console.log("TrustOracle     :", address(oracle));
        console.log("Consumer        :", address(consumer));
        for (uint256 i = 0; i < vaults.length; i++) {
            console.log("vault", i, vaults[i]);
        }
    }
}
