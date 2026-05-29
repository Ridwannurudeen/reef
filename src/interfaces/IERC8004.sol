// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ERC-8004 (Draft EIP, Aug 2025) — Trustless Agents Standard
/// @notice Minimal interface combining Identity, Reputation, and Validation registries
/// as defined in https://eips.ethereum.org/EIPS/eip-8004. Reef deploys all three
/// on Mantle as a single AgentIdentity contract that satisfies these methods.
interface IIdentityRegistry {
    event AgentRegistered(uint256 indexed agentId, address indexed wallet, string agentURI);
    event AgentWalletUpdated(uint256 indexed agentId, address indexed wallet);

    function register() external returns (uint256 agentId);
    function setAgentWallet(uint256 agentId, address wallet) external;
    function getAgentWallet(uint256 agentId) external view returns (address);
    function setAgentURI(uint256 agentId, string calldata uri) external;
    function getAgentURI(uint256 agentId) external view returns (string memory);
}

interface IReputationRegistry {
    event FeedbackGiven(uint256 indexed agentId, address indexed source, int128 value, uint8 decimals);

    function giveFeedback(uint256 agentId, int128 value, uint8 valueDecimals) external;
    function revokeFeedback(uint256 agentId, uint256 feedbackId) external;
    function getSummary(uint256 agentId) external view returns (int256 cumulative, uint256 count);
    function readFeedback(uint256 agentId, uint256 offset, uint256 limit)
        external
        view
        returns (int128[] memory values, address[] memory sources);
}

interface IValidationRegistry {
    function validationRequest(uint256 agentId, bytes calldata payload) external returns (bytes32 requestId);
    function validationResponse(bytes32 requestId, bytes32 responseHash) external;
    function getValidationStatus(bytes32 requestId) external view returns (bytes32 responseHash);
}
