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
    address constant IDENTITY = 0x4eCE1853623CA801536d319cB9ddE454f5dA6dC7;
    address constant BOND = 0xeF2F3602d5fe04487a971e5d749DAC7343b8F895;
    address constant GUARD = 0xe84E84D7e2E588aa8F88d1D1ADF2bdc70365a02b;

    function run() external {
        require(block.chainid == 5003, "not mantle sepolia");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        address[5] memory vaults = [
            0x7E4399B91bF6801d7D74E359d162065c88EA9d1B,
            0x06e196408356D2BDa4d21301B3bbB78c931AE9E3,
            0xBA8075d91983D15628DE99CDC510cD6C70F434EE,
            0x7E1827697843f377761F19f6F3386D8750d75BBD,
            0xa40AF1a30E4094b2807fDfbF6195C06245ab0822
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
