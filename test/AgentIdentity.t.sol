// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {MockReputationSource} from "./mocks/MockReputationSource.sol";

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
        MockReputationSource src = new MockReputationSource(address(identity), id);
        vm.prank(alice);
        identity.setReputationSource(id, address(src));

        src.giveFeedback(5e17, 18); // +0.5

        (int256 cum, uint256 count) = identity.getSummary(id);
        assertEq(cum, 5e17);
        assertEq(count, 1);
    }

    function test_giveFeedback_normalizesDecimals() public {
        vm.prank(alice);
        uint256 id = identity.register();
        MockReputationSource src = new MockReputationSource(address(identity), id);
        vm.prank(alice);
        identity.setReputationSource(id, address(src));

        src.giveFeedback(50, 2); // +0.50 in 2-decimal fixed point

        (int256 cum,) = identity.getSummary(id);
        assertEq(cum, 5e17); // normalized to 18 decimals
    }

    function test_revokeFeedback_decreasesSummary_onlyBySource() public {
        vm.prank(alice);
        uint256 id = identity.register();
        MockReputationSource src = new MockReputationSource(address(identity), id);
        vm.prank(alice);
        identity.setReputationSource(id, address(src));

        src.giveFeedback(1e18, 18);

        // operator cannot revoke the source's feedback
        vm.prank(operator);
        vm.expectRevert(bytes("not source"));
        identity.revokeFeedback(id, 0);

        // the source can
        src.revokeFeedback(0);
        (int256 cum, uint256 count) = identity.getSummary(id);
        assertEq(cum, 0);
        assertEq(count, 0);
    }

    function test_revokeFeedback_cannotDoubleRevoke() public {
        vm.prank(alice);
        uint256 id = identity.register();
        MockReputationSource src = new MockReputationSource(address(identity), id);
        vm.prank(alice);
        identity.setReputationSource(id, address(src));
        src.giveFeedback(1e18, 18);
        src.revokeFeedback(0);
        vm.expectRevert(bytes("already revoked"));
        src.revokeFeedback(0);
    }

    function test_giveFeedback_revertsForUnknownAgent() public {
        vm.prank(bob);
        vm.expectRevert(bytes("no agent"));
        identity.giveFeedback(999, 1, 18);
    }

    function test_giveFeedback_unauthorizedSource_reverts() public {
        vm.prank(alice);
        uint256 id = identity.register();
        // no reputation source designated → arbitrary caller is rejected
        vm.prank(bob);
        vm.expectRevert(bytes("unauthorized source"));
        identity.giveFeedback(id, 1e18, 18);
    }

    function test_setReputationSource_cannotBindEOA_norRebind_andMintRep() public {
        vm.prank(alice);
        uint256 id = identity.register();

        // An EOA cannot be the source (blocks pointing it at the agent's own wallet to
        // mint arbitrary reputation, bypassing the vault's realized-PnL machinery).
        vm.prank(alice);
        vm.expectRevert(bytes("source must be a contract"));
        identity.setReputationSource(id, bob);

        // A contract not bound to this identity + agentId is rejected.
        MockReputationSource wrong = new MockReputationSource(address(identity), id + 1);
        vm.prank(alice);
        vm.expectRevert(bytes("source agent mismatch"));
        identity.setReputationSource(id, address(wrong));

        AgentIdentity other = new AgentIdentity();
        MockReputationSource wrongIdentity = new MockReputationSource(address(other), id);
        vm.prank(alice);
        vm.expectRevert(bytes("source identity mismatch"));
        identity.setReputationSource(id, address(wrongIdentity));

        // The legitimate one-time binding to the agent's own (vault-like) source works.
        MockReputationSource src = new MockReputationSource(address(identity), id);
        vm.prank(alice);
        identity.setReputationSource(id, address(src));
        assertEq(identity.reputationSource(id), address(src));
        src.giveFeedback(1e18, 18);
        (int256 cum,) = identity.getSummary(id);
        assertEq(cum, 1e18);

        // One-shot: it cannot be repointed (e.g. to an EOA) after being set.
        MockReputationSource src2 = new MockReputationSource(address(identity), id);
        vm.prank(alice);
        vm.expectRevert(bytes("source already set"));
        identity.setReputationSource(id, address(src2));
        vm.prank(alice);
        vm.expectRevert(bytes("source already set"));
        identity.setReputationSource(id, bob);

        // And the agent's wallet still cannot mint reputation directly.
        vm.prank(alice);
        vm.expectRevert(bytes("unauthorized source"));
        identity.giveFeedback(id, 1e18, 18);
    }

    function test_readFeedback_paginates() public {
        vm.prank(alice);
        uint256 id = identity.register();
        MockReputationSource src = new MockReputationSource(address(identity), id);
        vm.prank(alice);
        identity.setReputationSource(id, address(src));

        for (uint256 i = 0; i < 5; i++) {
            src.giveFeedback(int128(int256(i + 1) * 1e17), 18);
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
