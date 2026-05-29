// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IStrategyAdapter
/// @notice Adapter interface that lets an AgentVault deploy capital into a yield
/// position (e.g. Ondo USDY, bridged mETH). Funds always move vault → adapter,
/// never to the operator wallet, so the operator never custodies the funds.
interface IStrategyAdapter {
    event Deployed(address indexed vault, uint256 amount);
    event Recalled(address indexed vault, uint256 amount, int256 pnl);

    function asset() external view returns (address);
    function vault() external view returns (address);

    /// @notice Called by the linked vault to allocate `amount` of asset into the strategy.
    function deploy(uint256 amount) external returns (uint256 deployed);

    /// @notice Called by the linked vault to recall `amount` worth of underlying.
    /// @return recalled actual underlying returned (may include realized yield)
    function recall(uint256 amount) external returns (uint256 recalled);

    /// @notice Current strategy balance in underlying-asset terms (mark-to-market).
    function totalUnderlying() external view returns (uint256);
}
