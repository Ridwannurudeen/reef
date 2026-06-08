// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IIdentityView {
    function getSummary(uint256 agentId) external view returns (int256 cumulative, uint256 count);
    function nextAgentId() external view returns (uint256);
}

interface IBondView {
    function bondOf(uint256 agentId) external view returns (uint256);
    function activeDisputes(uint256 agentId) external view returns (uint256);
}

/// @title ReefGuard
/// @notice An on-chain policy gate any Mantle protocol can query *before* letting an
/// autonomous agent touch capital. `canExecute(agentId, asset, sizeBps)` checks the agent's
/// registration, ERC-8004 reputation, posted bond, open disputes, an asset allowlist, and the
/// action size against governor-set limits — returning `(allowed, reason)`. It is a pure view
/// (free to call), so it can become the shared policy layer for autonomous finance on Mantle:
/// "is this agent allowed to do this, and if not, why?"
contract ReefGuard {
    IIdentityView public immutable identity;
    IBondView public immutable bond;
    address public governor;

    int256 public minReputation; // min ERC-8004 cumulative reputation (1e18 units)
    uint256 public minBond; // min posted bond (wei)
    uint256 public maxSizeBps; // max single-action size, in bps of the agent's capital

    mapping(address => bool) public assetAllowed;

    event PolicyUpdated(int256 minReputation, uint256 minBond, uint256 maxSizeBps);
    event AssetAllowed(address indexed asset, bool allowed);
    event GovernorTransferred(address indexed governor);

    modifier onlyGovernor() {
        require(msg.sender == governor, "not governor");
        _;
    }

    constructor(
        address identity_,
        address bond_,
        address governor_,
        int256 minReputation_,
        uint256 minBond_,
        uint256 maxSizeBps_
    ) {
        require(identity_ != address(0) && bond_ != address(0) && governor_ != address(0), "zero addr");
        require(maxSizeBps_ <= 10_000, "bps");
        identity = IIdentityView(identity_);
        bond = IBondView(bond_);
        governor = governor_;
        minReputation = minReputation_;
        minBond = minBond_;
        maxSizeBps = maxSizeBps_;
    }

    /// @notice Policy check. Returns (true, "ok") if the agent may execute, else (false, reason).
    /// Pure view — any protocol can call it for free in its own pre-trade checks.
    function canExecute(uint256 agentId, address asset, uint256 sizeBps)
        external
        view
        returns (bool allowed, string memory reason)
    {
        if (agentId == 0 || agentId >= identity.nextAgentId()) return (false, "agent not registered");
        if (sizeBps > maxSizeBps) return (false, "action size over limit");
        if (!assetAllowed[asset]) return (false, "asset not allowlisted");
        if (bond.bondOf(agentId) < minBond) return (false, "insufficient bond");
        if (bond.activeDisputes(agentId) != 0) return (false, "agent under dispute");
        (int256 rep,) = identity.getSummary(agentId);
        if (rep < minReputation) return (false, "reputation below threshold");
        return (true, "ok");
    }

    function setPolicy(int256 minReputation_, uint256 minBond_, uint256 maxSizeBps_) external onlyGovernor {
        require(maxSizeBps_ <= 10_000, "bps");
        minReputation = minReputation_;
        minBond = minBond_;
        maxSizeBps = maxSizeBps_;
        emit PolicyUpdated(minReputation_, minBond_, maxSizeBps_);
    }

    function setAssetAllowed(address asset, bool allowed_) external onlyGovernor {
        assetAllowed[asset] = allowed_;
        emit AssetAllowed(asset, allowed_);
    }

    function transferGovernor(address governor_) external onlyGovernor {
        require(governor_ != address(0), "zero addr");
        governor = governor_;
        emit GovernorTransferred(governor_);
    }
}
