// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title AdapterRegistry
/// @notice Protocol-governed allowlist of vetted StrategyAdapter instances. An
/// AgentVault may only approve an adapter the protocol governor has reviewed and
/// listed here, so a malicious operator cannot point a vault at an adapter that
/// lies about `totalUnderlying()` to inflate NAV (and thus reputation and index
/// weight). This is the second key on top of the operator's own `approveStrategy`.
/// @dev Allowlisting is by adapter ADDRESS, not codehash: Solidity embeds immutable
/// variables into runtime bytecode, so two instances of the same adapter type have
/// distinct EXTCODEHASHes — a codehash allowlist would reject legitimate instances.
/// The governor reviews and lists each deployed instance. The testnet-only
/// `MockYieldAdapter` (which mints the underlying freely) must never be approved on
/// a registry that gates real TVL.
contract AdapterRegistry {
    address public governor;
    mapping(address => bool) public isApproved;

    event AdapterApproved(address indexed adapter);
    event AdapterRevoked(address indexed adapter);
    event GovernorChanged(address indexed newGovernor);

    modifier onlyGovernor() {
        require(msg.sender == governor, "not governor");
        _;
    }

    constructor() {
        governor = msg.sender;
    }

    function approveAdapter(address adapter) external onlyGovernor {
        require(adapter != address(0) && adapter.code.length > 0, "bad adapter");
        isApproved[adapter] = true;
        emit AdapterApproved(adapter);
    }

    function revokeAdapter(address adapter) external onlyGovernor {
        isApproved[adapter] = false;
        emit AdapterRevoked(adapter);
    }

    function setGovernor(address g) external onlyGovernor {
        require(g != address(0), "zero gov");
        governor = g;
        emit GovernorChanged(g);
    }
}
