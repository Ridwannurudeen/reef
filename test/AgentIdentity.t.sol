// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";

contract AgentIdentityTest is Test {
    AgentIdentity identity;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address operator = makeAddr("operator");

    function setUp() public {
        identity = new AgentIdentity();
    }

    // --- Identity ---

    function test_register_assignsId_andSetsWallet() public {
        vm.prank(alice);
        uint256 id = identity.register();
        assertEq(id, 1);
        assertEq(identity.getAgentWallet(id), alice);
    }

    function test_register_incrementsId() public {
        vm.prank(alice);
        uint256 a = identity.register();
        vm.prank(bob);
        uint256 b = identity.register();
        assertEq(a, 1);
        assertEq(b, 2);
    }

    function test_setAgentWallet_onlyCurrentWallet() public {
        vm.prank(alice);
        uint256 id = identity.register();

        vm.prank(bob);
        vm.expectRevert(bytes("not agent wallet"));
        identity.setAgentWallet(id, bob);

        vm.prank(alice);
        identity.setAgentWallet(id, operator);
        assertEq(identity.getAgentWallet(id), operator);
    }

    function test_setAgentURI_andRead() public {
        vm.prank(alice);
        uint256 id = identity.register();
        vm.prank(alice);
        identity.setAgentURI(id, "ipfs://bafy...");
        assertEq(identity.getAgentURI(id), "ipfs://bafy...");
    }

    // --- Reputation ---

    function test_giveFeedback_updatesSummary() public {
        vm.prank(alice);
        uint256 id = identity.register();

        vm.prank(bob);
        identity.giveFeedback(id, 5e17, 18); // +0.5

        (int256 cum, uint256 count) = identity.getSummary(id);
        assertEq(cum, 5e17);
        assertEq(count, 1);
    }

    function test_giveFeedback_normalizesDecimals() public {
        vm.prank(alice);
        uint256 id = identity.register();

        vm.prank(bob);
        identity.giveFeedback(id, 50, 2); // +0.50 in 2-decimal fixed point

        (int256 cum,) = identity.getSummary(id);
        assertEq(cum, 5e17); // normalized to 18 decimals
    }

    function test_revokeFeedback_decreasesSummary_onlyBySource() public {
        vm.prank(alice);
        uint256 id = identity.register();

        vm.prank(bob);
        identity.giveFeedback(id, 1e18, 18);

        // operator cannot revoke bob's feedback
        vm.prank(operator);
        vm.expectRevert(bytes("not source"));
        identity.revokeFeedback(id, 0);

        // bob can
        vm.prank(bob);
        identity.revokeFeedback(id, 0);
        (int256 cum, uint256 count) = identity.getSummary(id);
        assertEq(cum, 0);
        assertEq(count, 0);
    }

    function test_revokeFeedback_cannotDoubleRevoke() public {
        vm.prank(alice);
        uint256 id = identity.register();
        vm.prank(bob);
        identity.giveFeedback(id, 1e18, 18);
        vm.prank(bob);
        identity.revokeFeedback(id, 0);
        vm.prank(bob);
        vm.expectRevert(bytes("already revoked"));
        identity.revokeFeedback(id, 0);
    }

    function test_giveFeedback_revertsForUnknownAgent() public {
        vm.prank(bob);
        vm.expectRevert(bytes("no agent"));
        identity.giveFeedback(999, 1, 18);
    }

    function test_readFeedback_paginates() public {
        vm.prank(alice);
        uint256 id = identity.register();

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(bob);
            identity.giveFeedback(id, int128(int256(i + 1) * 1e17), 18);
        }

        (int128[] memory vals,) = identity.readFeedback(id, 1, 3);
        assertEq(vals.length, 3);
        assertEq(vals[0], 2e17);
        assertEq(vals[1], 3e17);
        assertEq(vals[2], 4e17);
    }

    // --- Validation ---

    function test_validationRequest_thenResponse() public {
        vm.prank(alice);
        uint256 id = identity.register();

        vm.prank(bob);
        bytes32 reqId = identity.validationRequest(id, "payload");
        assertEq(identity.getValidationStatus(reqId), bytes32(0));

        bytes32 respHash = keccak256("answer");
        vm.prank(alice);
        identity.validationResponse(reqId, respHash);
        assertEq(identity.getValidationStatus(reqId), respHash);
    }

    function test_validationResponse_onlyAgent() public {
        vm.prank(alice);
        uint256 id = identity.register();
        vm.prank(bob);
        bytes32 reqId = identity.validationRequest(id, "payload");

        vm.prank(operator);
        vm.expectRevert(bytes("not agent"));
        identity.validationResponse(reqId, keccak256("x"));
    }

    function test_validationResponse_cannotDoubleAnswer() public {
        vm.prank(alice);
        uint256 id = identity.register();
        vm.prank(bob);
        bytes32 reqId = identity.validationRequest(id, "payload");
        vm.prank(alice);
        identity.validationResponse(reqId, keccak256("a"));
        vm.prank(alice);
        vm.expectRevert(bytes("already responded"));
        identity.validationResponse(reqId, keccak256("b"));
    }
}
