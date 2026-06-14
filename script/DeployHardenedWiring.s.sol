// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentIndex} from "../src/AgentIndex.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {ReputationBond} from "../src/ReputationBond.sol";
import {Allocator} from "../src/Allocator.sol";
import {Seasons} from "../src/Seasons.sol";
import {MockProtocol} from "../src/MockProtocol.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Wire the hardened Sepolia core (from DeployHardenedSepolia) into the full demo surface:
/// bond the 5 agents (so the bond component matches the original), turn on the index bond-gate, then
/// deploy the trust-weighted Allocator + permissioned Allocator + Seasons (Human-vs-AI, all enrolled)
/// + a MockProtocol that executes one ReefGuard-gated action. Everything wired to the hardened
/// identity/bond/guard + the 5 hardened (reputableNav) vaults, governed by the deployer.
/// Run: forge script script/DeployHardenedWiring.s.sol:DeployHardenedWiring --rpc-url <url> --broadcast --legacy --slow
contract DeployHardenedWiring is Script {
    address constant IDENTITY = 0xe6D6320a3647a4b21Abe1654C30E848318D161DD;
    address constant INDEX = 0xf847D0d2c3E4DBED7cd02eB729e48d0aAEfB8C54;
    address constant BOND = 0xccfF181441a636a63f8b5f9b6697585b54165DAe;
    address constant GUARD = 0x108411e3AA1fA2D3643b86A0B52Fd5bE12FDfe3f;
    address constant ASSET = 0xbc17D7F8f265d069781ed765914ED092989d92e7;

    uint256 constant BOND_EACH = 50e18;
    uint256 constant SLASH = 10e18;

    Allocator open;
    Allocator perm;
    Seasons seasons;
    MockProtocol proto;

    function _vaults() internal pure returns (address[5] memory) {
        return [
            0xfEB9E7903CA909cC04aF18e2CcE08211c7ef8a67,
            0xbeb8CaDAFD213f5Cd24b5Bc36FC82C3802509A23,
            0x5Cd85315163BBfFDB4F196F51741917aB82E83E5,
            0x54c62c634D12286FB2895aE443F1d6d06009BdC4,
            0xd107D0b110F60582672d28b00236acD39EB46eca
        ];
    }

    function _bondAgents(address me) internal {
        MockERC20 asset = MockERC20(ASSET);
        ReputationBond bond = ReputationBond(BOND);
        AgentIndex index = AgentIndex(INDEX);
        asset.mint(me, BOND_EACH * 5);
        asset.approve(BOND, BOND_EACH * 5);
        address[5] memory vs = _vaults();
        for (uint256 i = 0; i < 5; i++) {
            bond.postBond(AgentVault(vs[i]).agentId(), BOND_EACH);
        }
        index.setReputationBond(BOND, SLASH);
    }

    function _deployAllocator(address me, bool permissioned, uint256 seed) internal returns (Allocator a) {
        MockERC20 asset = MockERC20(ASSET);
        a = new Allocator(ASSET, IDENTITY, BOND);
        address[5] memory vs = _vaults();
        for (uint256 i = 0; i < 5; i++) {
            a.addVault(vs[i]);
        }
        a.addMandate("Balanced", 60e16, 5000);
        uint256 conservative = a.addMandate("Conservative", 70e16, 3500);
        a.addMandate("Aggressive", 40e16, 10_000);
        a.setActiveMandate(conservative);
        if (permissioned) {
            a.setPermissioned(true);
            a.setDepositorAllowed(me, true);
        }
        asset.mint(me, seed);
        asset.approve(address(a), seed);
        a.deposit(seed);
        a.rebalance();
    }

    function _deploySeasons() internal {
        seasons = new Seasons(IDENTITY);
        uint256 id = seasons.startSeason(7 days);
        address[5] memory vs = _vaults();
        for (uint256 i = 0; i < 5; i++) {
            uint256 aid = AgentVault(vs[i]).agentId();
            seasons.enroll(id, aid, aid % 2 == 0 ? Seasons.Side.AI : Seasons.Side.Human);
        }
    }

    function run() external {
        require(block.chainid == 5003, "not mantle sepolia");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);

        vm.startBroadcast(pk);
        _bondAgents(me);
        open = _deployAllocator(me, false, 100e18);
        perm = _deployAllocator(me, true, 50e18);
        _deploySeasons();
        proto = new MockProtocol(GUARD);
        uint256 amount = proto.executeAgentAction(1, ASSET, 1000, 1e18);
        vm.stopBroadcast();

        console.log("=== Reef hardened wiring ===");
        console.log("Allocator (open)        :", address(open));
        console.log("Allocator (permissioned):", address(perm));
        console.log("Seasons                 :", address(seasons));
        console.log("MockProtocol            :", address(proto));
        console.log("gated action amount     :", amount);
    }
}
