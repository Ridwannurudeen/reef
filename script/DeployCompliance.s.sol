// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";

/// @notice Deploy the standalone ComplianceRegistry — the on-chain KYC / accreditation /
/// jurisdiction primitive any Mantle protocol can read before letting an address into a gated
/// flow. Blocks a couple of ISO-3166 numeric sanctioned jurisdictions, then seeds the agent
/// operator with a passing KYC + accredited attestation (US, no expiry) so the gated demo flow
/// works out of the box. The deployer is the owner and (via the constructor) the first issuer.
/// Required env: PRIVATE_KEY. Optional env: AGENT_OPERATOR (defaults to the deployer).
/// Usage:
///   forge script script/DeployCompliance.s.sol --rpc-url <sepolia> --broadcast --legacy --slow
contract DeployCompliance is Script {
    // ISO-3166 numeric country codes for sanctioned jurisdictions to block at deploy.
    uint16 constant DPRK = 408;
    uint16 constant IRAN = 364;
    uint16 constant US = 840;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address operator = vm.envOr("AGENT_OPERATOR", deployer);
        bytes32 evidenceHash = keccak256("reef-seed-attestation");

        vm.startBroadcast(pk);
        ComplianceRegistry compliance = new ComplianceRegistry();
        compliance.setBlockedCountry(DPRK, true);
        compliance.setBlockedCountry(IRAN, true);
        compliance.attest(operator, true, true, US, 0, evidenceHash);
        vm.stopBroadcast();

        console.log("=== Reef ComplianceRegistry deployed ===");
        console.log("Chain ID           :", block.chainid);
        console.log("ComplianceRegistry :", address(compliance));
        console.log("Owner / Issuer     :", deployer);
        console.log("Seed attested      :", operator);
        console.log("Blocked country    :", uint256(DPRK));
        console.log("Blocked country    :", uint256(IRAN));
        console.log("");

        // JSON-ready summary (drop into deployments/mantle-sepolia.json under "complianceRegistry").
        string memory summary = string.concat(
            '{"complianceRegistry":{"address":"',
            vm.toString(address(compliance)),
            '","owner":"',
            vm.toString(deployer),
            '","blockedCountries":[408,364],"seedAttested":"',
            vm.toString(operator),
            '","seedCountry":840,"evidenceHash":"',
            vm.toString(evidenceHash),
            '"}}'
        );
        console.log(summary);
    }
}
