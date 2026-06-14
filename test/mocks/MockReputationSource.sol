// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AgentIdentity} from "../../src/AgentIdentity.sol";

/// @notice Test reputation writer bound to one agent. Satisfies AgentIdentity's
/// reputationSource binding (it reports the same identity + agentId an AgentVault would),
/// so tests can exercise feedback flows without a full vault.
contract MockReputationSource {
    AgentIdentity public immutable identityContract;
    uint256 public immutable agentId;

    constructor(address identity_, uint256 agentId_) {
        identityContract = AgentIdentity(identity_);
        agentId = agentId_;
    }

    function identity() external view returns (address) {
        return address(identityContract);
    }

    function giveFeedback(int128 value, uint8 valueDecimals) external {
        identityContract.giveFeedback(agentId, value, valueDecimals);
    }

    function revokeFeedback(uint256 feedbackId) external {
        identityContract.revokeFeedback(agentId, feedbackId);
    }
}
