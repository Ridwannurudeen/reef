// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Pausable
/// @notice Minimal circuit breaker. A `guardian` can pause the contract, which halts
/// functions marked `whenNotPaused` (the risk-taking entry points). Withdrawals are
/// intentionally left un-gated by the inheriting contracts so a pause can never trap
/// user funds. The guardian is rotatable (e.g. to a multisig) via `setGuardian`.
abstract contract Pausable {
    address public guardian;
    bool public paused;

    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event GuardianChanged(address indexed guardian);

    modifier onlyGuardian() {
        require(msg.sender == guardian, "not guardian");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    /// @dev Set once by the inheriting contract's constructor.
    function _initGuardian(address g) internal {
        guardian = g;
    }

    function pause() external onlyGuardian {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyGuardian {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function setGuardian(address g) external onlyGuardian {
        require(g != address(0), "zero guardian");
        guardian = g;
        emit GuardianChanged(g);
    }
}
