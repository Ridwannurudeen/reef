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

interface ITrustOracleView {
    function scoreOf(uint256 agentId) external view returns (uint256);
}

/// @title ReefGuard
/// @notice An on-chain policy gate any Mantle protocol can query *before* letting an
/// autonomous agent touch capital. `canExecute(agentId, asset, sizeBps)` checks the agent's
/// registration, ERC-8004 reputation, posted bond, open disputes, an asset allowlist, action
/// size, and optionally the composite TrustOracle score against governor-set limits —
/// returning `(allowed, reason)`. It is a pure view (free to call), so it can become the
/// shared policy layer for autonomous finance on Mantle: "is this agent allowed to do this,
/// and if not, why?"
contract ReefGuard {
    uint256 internal constant WAD = 1e18;
    bytes4 internal constant ERC20_TRANSFER = 0xa9059cbb;
    bytes4 internal constant ERC20_APPROVE = 0x095ea7b3;
    bytes4 internal constant ERC20_TRANSFER_FROM = 0x23b872dd;

    IIdentityView public immutable identity;
    IBondView public immutable bond;
    address public governor;
    address public trustOracle;

    int256 public minReputation; // min ERC-8004 cumulative reputation (1e18 units)
    uint256 public minBond; // min posted bond (wei)
    uint256 public maxSizeBps; // max single-action size, in bps of the agent's capital
    uint256 public minTrustScore; // optional composite TrustOracle bar, WAD (0..1e18)

    mapping(address => bool) public assetAllowed;

    struct Action {
        address target;
        uint256 value;
        bytes data;
        address asset;
        uint256 portfolioValue;
    }

    event PolicyUpdated(int256 minReputation, uint256 minBond, uint256 maxSizeBps);
    event TrustPolicyUpdated(address indexed trustOracle, uint256 minTrustScore);
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
        return _checkPolicy(agentId, asset, sizeBps);
    }

    /// @notice Inspect a standard native/ERC-20 action, derive its amount and size, then apply
    /// the same policy gate. This avoids trusting the agent to supply its own `sizeBps`.
    function canExecuteAction(uint256 agentId, Action calldata action)
        external
        view
        returns (bool allowed, string memory reason, uint256 amount, uint256 sizeBps)
    {
        if (action.portfolioValue == 0) return (false, "zero portfolio", 0, 0);
        (bool parsed, string memory parseReason, uint256 parsedAmount) = _actionAmount(action);
        if (!parsed) return (false, parseReason, 0, 0);
        amount = parsedAmount;
        sizeBps = _toBps(amount, action.portfolioValue);
        (allowed, reason) = _checkPolicy(agentId, action.asset, sizeBps);
    }

    function _checkPolicy(uint256 agentId, address asset, uint256 sizeBps)
        internal
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
        if (trustOracle != address(0) && minTrustScore > 0) {
            try ITrustOracleView(trustOracle).scoreOf(agentId) returns (uint256 score) {
                if (score < minTrustScore) return (false, "trust score below threshold");
            } catch {
                return (false, "trust score unavailable");
            }
        }
        return (true, "ok");
    }

    function _actionAmount(Action calldata action)
        private
        pure
        returns (bool parsed, string memory reason, uint256 amount)
    {
        if (action.data.length == 0) {
            if (action.asset != address(0)) return (false, "native asset mismatch", 0);
            return (true, "ok", action.value);
        }
        if (action.target != action.asset) return (false, "asset target mismatch", 0);
        bytes calldata data = action.data;
        if (data.length < 4) return (false, "unsupported action", 0);

        bytes4 selector;
        assembly {
            selector := calldataload(data.offset)
        }
        if (selector == ERC20_TRANSFER || selector == ERC20_APPROVE) {
            if (data.length != 68) return (false, "malformed action", 0);
            return (true, "ok", _calldataWord(data, 36));
        }
        if (selector == ERC20_TRANSFER_FROM) {
            if (data.length != 100) return (false, "malformed action", 0);
            return (true, "ok", _calldataWord(data, 68));
        }
        return (false, "unsupported action", 0);
    }

    function _calldataWord(bytes calldata data, uint256 offset) private pure returns (uint256 word) {
        assembly {
            word := calldataload(add(data.offset, offset))
        }
    }

    function _toBps(uint256 amount, uint256 portfolioValue) private pure returns (uint256) {
        if (amount > portfolioValue) return 10_001;
        if (amount == portfolioValue) return 10_000;
        if (amount > type(uint256).max / 10_000) return 10_001;
        return (amount * 10_000 + portfolioValue - 1) / portfolioValue;
    }

    function setPolicy(int256 minReputation_, uint256 minBond_, uint256 maxSizeBps_) external onlyGovernor {
        require(maxSizeBps_ <= 10_000, "bps");
        minReputation = minReputation_;
        minBond = minBond_;
        maxSizeBps = maxSizeBps_;
        emit PolicyUpdated(minReputation_, minBond_, maxSizeBps_);
    }

    function setTrustPolicy(address trustOracle_, uint256 minTrustScore_) external onlyGovernor {
        require(minTrustScore_ <= WAD, "trust");
        trustOracle = trustOracle_;
        minTrustScore = minTrustScore_;
        emit TrustPolicyUpdated(trustOracle_, minTrustScore_);
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
