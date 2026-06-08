// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentIndex} from "../src/AgentIndex.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {FusionXAdapter} from "../src/adapters/FusionXAdapter.sol";
import {DemoToken, IFusionXFactory, IFusionXPair} from "./DeployDexNav.s.sol";

/// @notice Strategy-arena deploy on Mantle Sepolia (chain 5003): 5 AgentVaults, one per
/// persona, all holding raUSD and deploying into a SHARED raUSD/raETH FusionX pool whose
/// price tracks real ETH (kept pegged by the arena keeper). Each vault starts with a
/// different exposure stance, so the leaderboard's reputation (NAV-derived, via the keeper's
/// receipts) reflects which strategy times ETH exposure best — real on-chain, not a score.
contract DeployArena is Script {
    address constant ROUTER = 0x272465431A6b86E3B9E5b9bD33f5D103a3F59eDb;
    address constant FACTORY = 0x8734110e5e1dcF439c7F549db740E546fea82d66;

    uint256 constant DEPOSIT = 10_000e18; // raUSD per vault
    uint256 constant ETH_RESERVE = 1_000e18; // raETH side of the pool

    struct Ctx {
        DemoToken usd;
        DemoToken eth;
        AgentIdentity identity;
        AgentIndex index;
        AdapterRegistry registry;
        address me;
    }

    function run() external {
        require(block.chainid == 5003, "not mantle sepolia");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        uint256 ethPrice = vm.envOr("ARENA_ETH_PRICE", uint256(1666)); // raUSD per raETH
        address me = vm.addr(pk);

        vm.startBroadcast(pk);
        Ctx memory c;
        c.me = me;
        c.usd = new DemoToken("Reef Arena USD", "raUSD");
        c.eth = new DemoToken("Reef Arena ETH", "raETH");

        // Deep shared pool seeded at the real ETH price (raETH priced at ~$ETH in raUSD).
        uint256 usdReserve = ethPrice * ETH_RESERVE;
        c.usd.mint(me, usdReserve);
        c.eth.mint(me, ETH_RESERVE);
        address pair = IFusionXFactory(FACTORY).createPair(address(c.usd), address(c.eth));
        c.usd.transfer(pair, usdReserve);
        c.eth.transfer(pair, ETH_RESERVE);
        IFusionXPair(pair).mint(me);

        c.identity = new AgentIdentity();
        c.index = new AgentIndex(address(c.usd), address(c.identity));
        c.registry = new AdapterRegistry();

        // Initial exposure stance per persona (bps of the deposit). Allora/Smart/GLM/Contrarian/Conservative.
        uint256 n = vm.envOr("ARENA_N", uint256(2)); // # competing vaults (lean head-to-head = 2)
        address[5] memory vaults;
        address[5] memory adapters;
        for (uint256 i = 0; i < n; i++) {
            (vaults[i], adapters[i]) = _spawn(c);
        }
        vm.stopBroadcast();

        console.log("=== Reef Strategy Arena (Sepolia 5003) ===");
        console.log("raUSD    :", address(c.usd));
        console.log("raETH    :", address(c.eth));
        console.log("pair     :", pair);
        console.log("identity :", address(c.identity));
        console.log("index    :", address(c.index));
        console.log("registry :", address(c.registry));
        console.log("ethPrice :", ethPrice);
        for (uint256 i = 0; i < n; i++) {
            console.log("vault", i + 1, vaults[i]);
            console.log("adapter", i + 1, adapters[i]);
        }
    }

    function _spawn(Ctx memory c) internal returns (address vault, address adapter) {
        uint256 agentId = c.identity.register();
        AgentVault v = new AgentVault(address(c.usd), agentId, address(c.identity), address(c.registry));
        c.identity.setReputationSource(agentId, address(v));
        c.index.addVault(address(v));

        FusionXAdapter a = new FusionXAdapter(address(c.usd), address(c.eth), ROUTER, address(v), 500);
        c.registry.approveAdapter(address(a));
        v.approveStrategy(address(a));

        // Deposit only — funds stay idle; the arena keeper sets each vault's initial
        // exposure on its first round (keeps the deploy swap-free and cheap/reliable).
        c.usd.mint(c.me, DEPOSIT);
        c.usd.approve(address(v), DEPOSIT);
        v.deposit(DEPOSIT);
        return (address(v), address(a));
    }
}
