// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAgentVault
/// @notice Per-agent vault. The agent (operator) EIP-712-signs receipts attesting to
/// NAV and decisions; any relayer may submit the signed receipt. Depositors hold shares;
/// reputation accrues to the agent's ERC-8004 identity via the receipt pipeline.
interface IAgentVault {
    struct VaultView {
        uint256 agentId;
        address asset;
        uint256 totalAssets;
        uint256 totalShares;
        uint256 idle; // assets sitting in vault, not deployed to a strategy
        uint256 outstanding; // assets deployed across strategies
        uint64 lastReceiptAt;
    }

    event Deposited(address indexed depositor, uint256 assets, uint256 shares);
    event Withdrawn(address indexed depositor, uint256 assets, uint256 shares);
    event StrategyDeployed(address indexed adapter, uint256 amount);
    event StrategyRecalled(address indexed adapter, uint256 amount);
    event ReceiptPublished(uint256 indexed seq, bytes32 evidenceHash, int256 navDelta);

    function deposit(uint256 assets) external returns (uint256 shares);
    function withdraw(uint256 shares) external returns (uint256 assets);

    function deployToStrategy(address adapter, uint256 amount) external;
    function recallFromStrategy(address adapter, uint256 amount) external;

    /// @notice Submit an operator-EIP-712-signed receipt covering the latest period.
    /// Callable by anyone (keeper/relayer); the signature must recover to the agent's
    /// operator. Forwards a NAV-derived reputation update to AgentIdentity.
    function publishReceipt(
        uint256 seq,
        bytes32 evidenceHash,
        int256 claimedDelta,
        uint64 period,
        bytes calldata signature
    ) external;

    function snapshot() external view returns (VaultView memory);
    function nav() external view returns (uint256);
    function agentId() external view returns (uint256);
}
