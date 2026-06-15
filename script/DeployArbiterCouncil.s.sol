// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ArbiterCouncil} from "../src/ArbiterCouncil.sol";

/// @notice Deploy the standalone ArbiterCouncil — a minimal 2-of-3 M-of-N council that replaces
/// the `ReputationBond` single-EOA arbiter so no single party can resolve or slash a dispute.
/// This script ONLY deploys the council; it does NOT broadcast any transferArbiter / acceptArbiter
/// wiring (the lead performs that manually, step by step, once the council is live).
/// Required env: PRIVATE_KEY.
/// Usage:
///   forge script script/DeployArbiterCouncil.s.sol --rpc-url <sepolia> --broadcast --legacy --slow
contract DeployArbiterCouncil is Script {
    // Council members (2-of-3). Independent keys so a quorum — not any one actor — governs arbitration.
    address constant MEMBER1 = 0x0cDed2Fda02DAAA7108b7BcBC18C9c15A94dCf43; // deployer
    address constant MEMBER2 = 0xeCF9541C6Ff5e8774A6d8f64B57A4BE473De49eF; // arena
    address constant MEMBER3 = 0x94Da2d2052D8d037c6DcED14B892f8Fb865885fc; // meth
    uint256 constant THRESHOLD = 2;
    // The bond this council is meant to govern (wired manually by the lead).
    address constant REPUTATION_BOND = 0xccfF181441a636a63f8b5f9b6697585b54165DAe;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address[] memory members = new address[](3);
        members[0] = MEMBER1;
        members[1] = MEMBER2;
        members[2] = MEMBER3;

        vm.startBroadcast(pk);
        ArbiterCouncil council = new ArbiterCouncil(members, THRESHOLD);
        vm.stopBroadcast();

        console.log("=== Reef ArbiterCouncil deployed ===");
        console.log("Chain ID       :", block.chainid);
        console.log("Deployer       :", deployer);
        console.log("ArbiterCouncil :", address(council));
        console.log("Member 1       :", MEMBER1);
        console.log("Member 2       :", MEMBER2);
        console.log("Member 3       :", MEMBER3);
        console.log("Threshold      :", THRESHOLD);
        console.log("");

        // JSON-ready summary (drop into deployments/mantle-sepolia.json under "arbiterCouncil").
        string memory summary = string.concat(
            '{"arbiterCouncil":{"address":"',
            vm.toString(address(council)),
            '","members":["',
            vm.toString(MEMBER1),
            '","',
            vm.toString(MEMBER2),
            '","',
            vm.toString(MEMBER3),
            '"],"threshold":2,"governs":"reputationBond ',
            vm.toString(REPUTATION_BOND),
            '"}}'
        );
        console.log(summary);
    }
}
