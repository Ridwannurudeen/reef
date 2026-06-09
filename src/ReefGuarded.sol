// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IReefGuard {
    function canExecute(uint256 agentId, address asset, uint256 sizeBps)
        external
        view
        returns (bool allowed, string memory reason);
}

/// @title ReefGuarded
/// @notice Inheritable helper that lets any Mantle protocol gate functions behind ReefGuard's
/// on-chain policy in one line. Inherit it, pass the ReefGuard address to the constructor, and
/// add the `onlyCleared(agentId, asset, sizeBps)` modifier to any agent-driven entrypoint — the
/// call reverts with ReefGuard's *exact* policy reason ("insufficient bond", "agent under
/// dispute", …) if the agent may not touch that asset at that size. This is the Solidity half of
/// the ReefGuard SDK: integrating Reef's trust/risk gate becomes a base contract + a modifier.
abstract contract ReefGuarded {
    IReefGuard public immutable reefGuard;

    constructor(address reefGuard_) {
        require(reefGuard_ != address(0), "zero guard");
        reefGuard = IReefGuard(reefGuard_);
    }

    /// @notice Revert with ReefGuard's policy reason unless `agentId` may act on `asset` at `sizeBps`.
    function _requireCleared(uint256 agentId, address asset, uint256 sizeBps) internal view {
        (bool allowed, string memory reason) = reefGuard.canExecute(agentId, asset, sizeBps);
        require(allowed, reason);
    }

    /// @notice Gate a function: reverts with ReefGuard's reason if the agent isn't cleared.
    modifier onlyCleared(uint256 agentId, address asset, uint256 sizeBps) {
        _requireCleared(agentId, asset, sizeBps);
        _;
    }

    /// @notice Read-only policy preview — for off-chain checks or UI, no state change.
    function reefCheck(uint256 agentId, address asset, uint256 sizeBps)
        external
        view
        returns (bool allowed, string memory reason)
    {
        return reefGuard.canExecute(agentId, asset, sizeBps);
    }
}
