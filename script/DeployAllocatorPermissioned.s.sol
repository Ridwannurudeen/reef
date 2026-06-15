// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Allocator} from "../src/Allocator.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Deploy a PERMISSIONED Allocator instance for compliance-sensitive RWA flows — wired
/// to the live Sepolia core (AgentIdentity + ReputationBond + the 5 seeded AgentVaults). Same
/// mandate menu as the open instance, but the depositor allowlist is turned ON: only onboarded
/// (e.g. KYC'd) addresses may deposit; withdrawals stay open. Allowlists the deployer, then
/// makes a real allowlisted deposit + rebalance to prove an approved institution can participate.
/// A non-allowlisted deposit reverts "depositor not allowed" (demonstrate via eth_call).
/// Run: PRIVATE_KEY=<key> forge script script/DeployAllocatorPermissioned.s.sol:DeployAllocatorPermissioned --rpc-url <url> --broadcast --legacy
contract DeployAllocatorPermissioned is Script {
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
        allocator.addMandate("Balanced", 60e16, 5000);
        uint256 conservative = allocator.addMandate("Conservative", 70e16, 3500);
        allocator.addMandate("Aggressive", 40e16, 10_000);
        allocator.setActiveMandate(conservative);

        // Compliance gate ON; allowlist the deployer (the onboarded institution).
        allocator.setPermissioned(true);
        allocator.setDepositorAllowed(me, true);

        // An allowlisted deposit succeeds and is allocated trust-weighted under the mandate.
        uint256 seed = 50e18;
        IMintable(ASSET).mint(me, seed);
        IMintable(ASSET).approve(address(allocator), seed);
        allocator.deposit(seed);
        allocator.rebalance();
        vm.stopBroadcast();

        console.log("Permissioned Allocator:", address(allocator));
        console.log("governor              :", me);
        console.log("permissioned          :", allocator.permissioned());
        console.log("deployer allowlisted   :", allocator.depositorAllowed(me));
        console.log("activeMandate (Conservative):", conservative);
    }
}
