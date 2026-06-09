// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IReefGuard {
    function canExecute(uint256 agentId, address asset, uint256 sizeBps)
        external
        view
        returns (bool allowed, string memory reason);
}

/// @title MockProtocol
/// @notice A stand-in for any external Mantle protocol (a vault, router, lending market…) that
/// lets autonomous agents move capital — but only after asking ReefGuard *"can this agent touch
/// this asset, at this size, right now?"*. It calls `ReefGuard.canExecute` as a pre-trade gate
/// and reverts with the policy reason if the agent isn't cleared. This is the integration shape
/// a real protocol uses: ReefGuard is the shared trust/risk gate; the protocol keeps its own
/// execution logic. Reef thus becomes infrastructure other Mantle protocols call, not a dashboard.
contract MockProtocol {
    IReefGuard public immutable guard;

    /// @notice Emitted when an agent action clears the ReefGuard policy and executes.
    event ActionExecuted(uint256 indexed agentId, address indexed asset, uint256 sizeBps, uint256 amount);

    constructor(address guard_) {
        require(guard_ != address(0), "zero guard");
        guard = IReefGuard(guard_);
    }

    /// @notice Execute an agent-driven action, gated by ReefGuard. Reverts with the exact policy
    /// reason (e.g. "insufficient bond", "agent under dispute") if the agent is not cleared.
    /// A real protocol would move `amount` of `asset` here; this reference just records the event.
    function executeAgentAction(uint256 agentId, address asset, uint256 sizeBps, uint256 amount)
        external
        returns (uint256)
    {
        (bool allowed, string memory reason) = guard.canExecute(agentId, asset, sizeBps);
        require(allowed, reason);
        emit ActionExecuted(agentId, asset, sizeBps, amount);
        return amount;
    }

    /// @notice Read-only preview of whether the action would clear, without executing.
    function check(uint256 agentId, address asset, uint256 sizeBps)
        external
        view
        returns (bool allowed, string memory reason)
    {
        return guard.canExecute(agentId, asset, sizeBps);
    }
}
