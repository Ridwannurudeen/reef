// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IIdentityRegistry, IReputationRegistry, IValidationRegistry} from "./interfaces/IERC8004.sol";

/// @notice Minimal view used to bind a reputation source to the agent it writes for.
/// A valid source (e.g. an AgentVault) exposes its `agentId` and the `identity` it is
/// bound to, so `setReputationSource` can verify the source belongs to THIS identity
/// and THIS agent — blocking an agent pointing its source at an arbitrary writer.
interface IReputationSourceView {
    function agentId() external view returns (uint256);
    function identity() external view returns (address);
}

/// @title AgentIdentity
/// @notice ERC-8004 agent identity for Reef, on Mantle (Mantle deployed the official
/// ERC-8004 registry to its mainnet in Feb 2026; this is Reef's own instance built on
/// that standard). Combines the three registries (Identity, Reputation, Validation)
/// defined in EIP-8004 into one contract for deploy simplicity; the interface methods
/// match the spec.
contract AgentIdentity is IIdentityRegistry, IReputationRegistry, IValidationRegistry {
    // --- Identity ---

    struct Agent {
        address wallet;
        string uri;
    }

    struct CanonicalIdentity {
        bytes32 namespace;
        uint256 chainId;
        address identityRegistry;
        uint256 agentId;
        bool bound;
    }

    uint256 public nextAgentId = 1;
    mapping(uint256 => Agent) private agents;
    mapping(uint256 => CanonicalIdentity) private canonicalIdentities;

    event CanonicalIdentityBound(
        uint256 indexed localAgentId,
        bytes32 indexed namespace,
        uint256 chainId,
        address indexed identityRegistry,
        uint256 canonicalAgentId
    );

    // --- Reputation ---

    struct Feedback {
        address source;
        int128 value;
        uint8 decimals;
        uint64 timestamp;
        bool revoked;
    }

    mapping(uint256 => Feedback[]) private feedback;
    /// @dev cumulative sum of non-revoked feedback values (normalised to 18 decimals).
    mapping(uint256 => int256) private cumValue;
    mapping(uint256 => uint256) private liveCount;

    /// @dev Authorized reputation writer per agent, set by the agent's own wallet.
    /// `giveFeedback` is gated to this address so reputation cannot be minted by
    /// arbitrary callers. Unset (address(0)) means no source can write yet.
    mapping(uint256 => address) public reputationSource;

    event ReputationSourceSet(uint256 indexed agentId, address source);

    // --- Validation ---

    struct Validation {
        uint256 agentId;
        address requester;
        bytes32 payloadHash;
        bytes32 responseHash; // bytes32(0) = pending
    }

    mapping(bytes32 => Validation) private validations;
    uint256 private validationNonce;

    // --- Modifiers ---

    modifier onlyAgentWallet(uint256 agentId) {
        require(agents[agentId].wallet == msg.sender, "not agent wallet");
        _;
    }

    modifier exists(uint256 agentId) {
        require(agents[agentId].wallet != address(0), "no agent");
        _;
    }

    // --- Identity functions ---

    function register() external override returns (uint256 agentId) {
        agentId = nextAgentId++;
        agents[agentId] = Agent({wallet: msg.sender, uri: ""});
        emit AgentRegistered(agentId, msg.sender, "");
    }

    function setAgentWallet(uint256 agentId, address wallet) external override onlyAgentWallet(agentId) {
        require(wallet != address(0), "zero wallet");
        agents[agentId].wallet = wallet;
        emit AgentWalletUpdated(agentId, wallet);
    }

    function getAgentWallet(uint256 agentId) external view override returns (address) {
        return agents[agentId].wallet;
    }

    function setAgentURI(uint256 agentId, string calldata uri) external override onlyAgentWallet(agentId) {
        agents[agentId].uri = uri;
    }

    function getAgentURI(uint256 agentId) external view override returns (string memory) {
        return agents[agentId].uri;
    }

    /// @notice Bind the Reef-local id to the canonical ERC-8004 identity tuple once.
    function bindCanonicalIdentity(
        uint256 localAgentId,
        bytes32 namespace,
        uint256 chainId,
        address identityRegistry,
        uint256 canonicalAgentId
    ) external onlyAgentWallet(localAgentId) {
        require(namespace != bytes32(0), "zero namespace");
        require(chainId != 0, "zero chain");
        require(identityRegistry != address(0), "zero registry");
        require(canonicalAgentId != 0, "zero canonical agent");
        require(!canonicalIdentities[localAgentId].bound, "canonical already bound");
        canonicalIdentities[localAgentId] = CanonicalIdentity({
            namespace: namespace,
            chainId: chainId,
            identityRegistry: identityRegistry,
            agentId: canonicalAgentId,
            bound: true
        });
        emit CanonicalIdentityBound(localAgentId, namespace, chainId, identityRegistry, canonicalAgentId);
    }

    function canonicalIdentityOf(uint256 localAgentId)
        external
        view
        exists(localAgentId)
        returns (bytes32 namespace, uint256 chainId, address identityRegistry, uint256 canonicalAgentId, bool bound)
    {
        CanonicalIdentity storage c = canonicalIdentities[localAgentId];
        return (c.namespace, c.chainId, c.identityRegistry, c.agentId, c.bound);
    }

    function canonicalIdentityHash(uint256 localAgentId) external view exists(localAgentId) returns (bytes32) {
        CanonicalIdentity storage c = canonicalIdentities[localAgentId];
        if (!c.bound) return bytes32(0);
        return keccak256(abi.encode(c.namespace, c.chainId, c.identityRegistry, c.agentId));
    }

    /// @notice The agent's wallet designates which address may write its reputation
    /// (its AgentVault). Required before any feedback can be recorded. One-shot and
    /// bound: the source must be a contract reporting this same identity + agentId, so
    /// an agent cannot point it at its own EOA and mint arbitrary reputation, bypassing
    /// the vault's realized-PnL machinery (SECURITY #1).
    function setReputationSource(uint256 agentId, address source) external onlyAgentWallet(agentId) {
        require(reputationSource[agentId] == address(0), "source already set");
        require(source.code.length > 0, "source must be a contract");
        require(IReputationSourceView(source).agentId() == agentId, "source agent mismatch");
        require(IReputationSourceView(source).identity() == address(this), "source identity mismatch");
        reputationSource[agentId] = source;
        emit ReputationSourceSet(agentId, source);
    }

    // --- Reputation functions ---

    function giveFeedback(uint256 agentId, int128 value, uint8 valueDecimals) external override exists(agentId) {
        require(msg.sender == reputationSource[agentId], "unauthorized source");
        feedback[agentId].push(
            Feedback({
                source: msg.sender,
                value: value,
                decimals: valueDecimals,
                timestamp: uint64(block.timestamp),
                revoked: false
            })
        );
        cumValue[agentId] += _normalize(value, valueDecimals);
        liveCount[agentId] += 1;
        emit FeedbackGiven(agentId, msg.sender, value, valueDecimals);
    }

    function revokeFeedback(uint256 agentId, uint256 feedbackId) external override exists(agentId) {
        Feedback storage f = feedback[agentId][feedbackId];
        require(f.source == msg.sender, "not source");
        require(!f.revoked, "already revoked");
        f.revoked = true;
        cumValue[agentId] -= _normalize(f.value, f.decimals);
        liveCount[agentId] -= 1;
    }

    function getSummary(uint256 agentId) external view override returns (int256 cumulative, uint256 count) {
        return (cumValue[agentId], liveCount[agentId]);
    }

    function readFeedback(uint256 agentId, uint256 offset, uint256 limit)
        external
        view
        override
        returns (int128[] memory values, address[] memory sources)
    {
        Feedback[] storage all = feedback[agentId];
        uint256 end = offset + limit;
        if (end > all.length) end = all.length;
        uint256 n = end > offset ? end - offset : 0;
        values = new int128[](n);
        sources = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            Feedback storage f = all[offset + i];
            values[i] = f.revoked ? int128(0) : f.value;
            sources[i] = f.source;
        }
    }

    // --- Validation functions ---

    function validationRequest(uint256 agentId, bytes calldata payload)
        external
        override
        exists(agentId)
        returns (bytes32 requestId)
    {
        requestId = keccak256(abi.encode(agentId, msg.sender, payload, validationNonce++));
        validations[requestId] =
            Validation({agentId: agentId, requester: msg.sender, payloadHash: keccak256(payload), responseHash: 0});
    }

    function validationResponse(bytes32 requestId, bytes32 responseHash) external override {
        Validation storage v = validations[requestId];
        require(v.requester != address(0), "no request");
        require(agents[v.agentId].wallet == msg.sender, "not agent");
        require(v.responseHash == bytes32(0), "already responded");
        require(responseHash != bytes32(0), "zero hash");
        v.responseHash = responseHash;
    }

    function getValidationStatus(bytes32 requestId) external view override returns (bytes32 responseHash) {
        return validations[requestId].responseHash;
    }

    // --- Internals ---

    /// @dev Normalize a fixed-point feedback value to 18 decimals for cumulative aggregation.
    function _normalize(int128 value, uint8 decimals) internal pure returns (int256) {
        if (decimals == 18) return int256(value);
        if (decimals < 18) return int256(value) * int256(10 ** (18 - decimals));
        return int256(value) / int256(10 ** (decimals - 18));
    }
}
