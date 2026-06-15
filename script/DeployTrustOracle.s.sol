// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TrustOracle} from "../src/TrustOracle.sol";
import {TrustOracleConsumer} from "../src/TrustOracleConsumer.sol";

/// @notice Deploy the standalone TrustOracle wired to the live Sepolia core instance
/// (AgentIdentity + ReputationBond + ReefGuard + the 5 seeded AgentVaults), register the cohort,
/// and deploy a TrustOracleConsumer reference (trust-gated credit, min Trust Score 0.55 = "A").
/// Run: PRIVATE_KEY=<arena key> forge script script/DeployTrustOracle.s.sol:DeployTrustOracle --rpc-url <url> --broadcast --legacy
contract DeployTrustOracle is Script {
    address constant IDENTITY = 0xe6D6320a3647a4b21Abe1654C30E848318D161DD;
    address constant BOND = 0xccfF181441a636a63f8b5f9b6697585b54165DAe;
    address constant GUARD = 0x108411e3AA1fA2D3643b86A0B52Fd5bE12FDfe3f;

    function run() external {
        require(block.chainid == 5003, "not mantle sepolia");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        address[5] memory vaults = [
            0xfEB9E7903CA909cC04aF18e2CcE08211c7ef8a67,
            0xbeb8CaDAFD213f5Cd24b5Bc36FC82C3802509A23,
            0x5Cd85315163BBfFDB4F196F51741917aB82E83E5,
            0x54c62c634D12286FB2895aE443F1d6d06009BdC4,
            0xd107D0b110F60582672d28b00236acD39EB46eca
        ];

        vm.startBroadcast(pk);
        TrustOracle oracle = new TrustOracle(IDENTITY, BOND, GUARD);
        for (uint256 i = 0; i < vaults.length; i++) {
            oracle.registerVault(vaults[i]);
        }
        // Reference consumer: a protocol that gates+sizes capital by Trust Score (min 0.55 = "A").
        TrustOracleConsumer consumer = new TrustOracleConsumer(address(oracle), 55e16);
        vm.stopBroadcast();

        console.log("TrustOracle :", address(oracle));
        console.log("Consumer    :", address(consumer));
        console.log("vaults      :", oracle.vaultCount());
    }
}
