// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Allocator} from "../src/Allocator.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Deploy the trust-weighted Allocator wired to the live Sepolia core instance
/// (AgentIdentity + ReputationBond + the 5 seeded AgentVaults sharing the index asset).
/// Seeds three risk-profile mandates on top of the always-present "Open" baseline, makes
/// "Conservative" active (min Trust Score 70/100, 35% concentration cap), then funds a small
/// LP position and rebalances so the on-chain allocation is live.
/// Run: PRIVATE_KEY=<key> forge script script/DeployAllocator.s.sol:DeployAllocator --rpc-url <url> --broadcast --legacy
contract DeployAllocator is Script {
    address constant IDENTITY = 0x4eCE1853623CA801536d319cB9ddE454f5dA6dC7;
    address constant BOND = 0xeF2F3602d5fe04487a971e5d749DAC7343b8F895;
    address constant ASSET = 0xbc17D7F8f265d069781ed765914ED092989d92e7;

    function run() external {
        require(block.chainid == 5003, "not mantle sepolia");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);

        address[5] memory vaults = [
            0x7E4399B91bF6801d7D74E359d162065c88EA9d1B,
            0x06e196408356D2BDa4d21301B3bbB78c931AE9E3,
            0xBA8075d91983D15628DE99CDC510cD6C70F434EE,
            0x7E1827697843f377761F19f6F3386D8750d75BBD,
            0xa40AF1a30E4094b2807fDfbF6195C06245ab0822
        ];

        vm.startBroadcast(pk);
        Allocator allocator = new Allocator(ASSET, IDENTITY, BOND);
        for (uint256 i = 0; i < vaults.length; i++) {
            allocator.addVault(vaults[i]);
        }
        // Mandate menu (Trust Score is WAD: 1e18 == 100/100):
        uint256 balanced = allocator.addMandate("Balanced", 60e16, 5000); // >=60, 50% cap
        uint256 conservative = allocator.addMandate("Conservative", 70e16, 3500); // >=70 (AA), 35% cap
        allocator.addMandate("Aggressive", 40e16, 10_000); // >=40 (BBB), uncapped
        allocator.setActiveMandate(conservative);

        // Fund a small LP position and allocate it trust-weighted across qualifying agents.
        uint256 seed = 100e18;
        IMintable(ASSET).mint(me, seed);
        IMintable(ASSET).approve(address(allocator), seed);
        allocator.deposit(seed);
        allocator.rebalance();
        vm.stopBroadcast();

        console.log("Allocator   :", address(allocator));
        console.log("governor    :", me);
        console.log("activeMandate:", conservative);
        console.log("balanced id :", balanced);
    }
}
