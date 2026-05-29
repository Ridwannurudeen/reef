// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAgentIndex
/// @notice Tokenized basket that allocates USDC across the top-performing
/// AgentVaults by reputation score. Anyone can call rebalance(); allocation
/// is a transparent in-source function of ReputationOracle scores.
interface IAgentIndex {
    struct Allocation {
        uint256 agentId;
        address vault;
        uint256 weightBps;
        uint256 deployed;
    }

    event IndexDeposit(address indexed depositor, uint256 assets, uint256 shares);
    event IndexWithdraw(address indexed depositor, uint256 assets, uint256 shares);
    event Rebalanced(uint256 totalAgents, uint256 totalDeployed);

    function deposit(uint256 assets) external returns (uint256 shares);
    function withdraw(uint256 shares) external returns (uint256 assets);

    /// @notice Permissionless. Pulls top-N agents by reputation and reweights.
    function rebalance() external;

    function getAllocation() external view returns (Allocation[] memory);
    function totalAssets() external view returns (uint256);
}
