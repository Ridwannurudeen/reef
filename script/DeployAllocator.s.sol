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
    address constant IDENTITY = 0xe6D6320a3647a4b21Abe1654C30E848318D161DD;
    address constant BOND = 0xccfF181441a636a63f8b5f9b6697585b54165DAe;
    address constant ASSET = 0xbc17D7F8f265d069781ed765914ED092989d92e7;

    function run() external {
        require(block.chainid == 5003, "not mantle sepolia");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);

        address[5] memory vaults = [
            0xfEB9E7903CA909cC04aF18e2CcE08211c7ef8a67,
            0xbeb8CaDAFD213f5Cd24b5Bc36FC82C3802509A23,
            0x5Cd85315163BBfFDB4F196F51741917aB82E83E5,
            0x54c62c634D12286FB2895aE443F1d6d06009BdC4,
            0xd107D0b110F60582672d28b00236acD39EB46eca
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
