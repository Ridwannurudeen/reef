// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IIdentityView {
    function getSummary(uint256 agentId) external view returns (int256 cumulative, uint256 count);
}

interface IBondView {
    function bondOf(uint256 agentId) external view returns (uint256);
}

interface IVaultView {
    function agentId() external view returns (uint256);
    function nav() external view returns (uint256);
    function highWaterNav() external view returns (uint256);
    function lastReceiptAt() external view returns (uint64);
    function identity() external view returns (address);
}

interface IGuardView {
    function canExecute(uint256 agentId, address asset, uint256 sizeBps)
        external
        view
        returns (bool allowed, string memory reason);
}

/// @title TrustOracle
/// @notice The single public read surface for "how much should capital trust this agent?" on
/// Mantle. `scoreOf(agentId)` returns a 0..1e18 Trust Score computed in-source from data already
/// on-chain — ERC-8004 reputation (40%), receipt freshness (20%), drawdown vs high-water (20%) and
/// posted bond (20%) — the same four components as Reef's off-chain rating and its Allocator, so
/// the number is verifiable rather than asserted. `report(...)` folds in ReefGuard's live policy
/// verdict so an integrating protocol gets score, letter rating and "is this allowed right now"
/// from one call. Pure views (free to call): any Mantle protocol can read trust without running
/// Reef's stack.
contract TrustOracle {
    // --- Trust score model (WAD-scaled, 1e18 = 1.0). Mirrors src/Allocator.sol + trust_score.py. ---
    uint256 internal constant WAD = 1e18;
    uint256 internal constant FRESH_WINDOW = 86_400; // receipt older than 24h scores 0 on freshness
    uint256 internal constant BOND_TARGET = 50e18; // full marks at the cohort's standard 50e18 bond
    uint256 internal constant DD_PENALTY = 5; // 20% drawdown -> 0 on the drawdown component
    uint256 internal constant W_REP = 4000; // component weights in bps (sum = 10_000)
    uint256 internal constant W_FRESH = 2000;
    uint256 internal constant W_DD = 2000;
    uint256 internal constant W_BOND = 2000;

    // Letter-rating cutoffs in WAD (match agents/scripts/trust_score.py: AAA>=85, AA>=70, A>=55, BBB>=40).
    uint256 internal constant R_AAA = 85e16;
    uint256 internal constant R_AA = 70e16;
    uint256 internal constant R_A = 55e16;
    uint256 internal constant R_BBB = 40e16;

    IIdentityView public immutable identity;
    address public bond; // ReputationBond; if unset, the bond component scores 0
    address public guard; // ReefGuard; if unset, report() returns guardCleared=false / "guard not set"
    address public governor;

    // --- Agent registry (cohort): the reputation component is normalized against the cohort max. ---
    address[] public vaults;
    mapping(uint256 => address) public vaultOf; // agentId => its AgentVault
    mapping(address => bool) public isRegistered;

    event VaultRegistered(uint256 indexed agentId, address indexed vault);
    event VaultRemoved(uint256 indexed agentId, address indexed vault);
    event BondSet(address bond);
    event GuardSet(address guard);
    event GovernorTransferred(address indexed governor);

    modifier onlyGovernor() {
        require(msg.sender == governor, "not governor");
        _;
    }

    constructor(address identity_, address bond_, address guard_) {
        require(identity_ != address(0), "zero addr");
        identity = IIdentityView(identity_);
        bond = bond_;
        guard = guard_;
        governor = msg.sender;
    }

    // --- Governance ---

    /// @notice Register an agent's vault into the scored cohort. The vault must be bound to THIS
    /// oracle's AgentIdentity (so a vault can't bind an arbitrary agent's reputation to its own NAV),
    /// and its agentId must be free.
    function registerVault(address vault) external onlyGovernor {
        require(vault != address(0), "zero addr");
        require(!isRegistered[vault], "registered");
        require(IVaultView(vault).identity() == address(identity), "wrong identity");
        uint256 aid = IVaultView(vault).agentId();
        require(vaultOf[aid] == address(0), "agent registered");
        isRegistered[vault] = true;
        vaultOf[aid] = vault;
        vaults.push(vault);
        emit VaultRegistered(aid, vault);
    }

    /// @notice Drop a vault from the cohort by agentId (does NOT call the vault, so a broken/reverting
    /// vault can still be removed — preventing it from bricking the cohort-wide `_maxRep`/`allScores`).
    function removeVault(uint256 agentId) external onlyGovernor {
        address vault = vaultOf[agentId];
        require(vault != address(0), "unknown agent");
        isRegistered[vault] = false;
        vaultOf[agentId] = address(0);
        uint256 n = vaults.length;
        for (uint256 i = 0; i < n; i++) {
            if (vaults[i] == vault) {
                vaults[i] = vaults[n - 1];
                vaults.pop();
                break;
            }
        }
        emit VaultRemoved(agentId, vault);
    }

    function setBond(address bond_) external onlyGovernor {
        bond = bond_;
        emit BondSet(bond_);
    }

    function setGuard(address guard_) external onlyGovernor {
        guard = guard_;
        emit GuardSet(guard_);
    }

    function transferGovernor(address governor_) external onlyGovernor {
        require(governor_ != address(0), "zero addr");
        governor = governor_;
        emit GovernorTransferred(governor_);
    }

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    // --- Trust score (on-chain, verifiable) ---

    /// @notice The agent's Trust Score in WAD (1e18 = 100/100). Reverts if the agent is unknown.
    function scoreOf(uint256 agentId) public view returns (uint256) {
        address v = vaultOf[agentId];
        require(v != address(0), "unknown agent");
        return _trustScore(v, _maxRep());
    }

    /// @notice Trust Score by vault address (same value as scoreOf(vault.agentId())).
    function scoreOfVault(address vault) external view returns (uint256) {
        require(isRegistered[vault], "unknown vault");
        return _trustScore(vault, _maxRep());
    }

    /// @notice The four trust components in WAD (reputation, freshness, drawdown, bond) before weighting.
    function componentsOf(uint256 agentId)
        external
        view
        returns (uint256 repC, uint256 freshC, uint256 ddC, uint256 bondC)
    {
        address v = vaultOf[agentId];
        require(v != address(0), "unknown agent");
        return _components(v, _maxRep());
    }

    /// @notice Letter rating (AAA/AA/A/BBB/BB) for the agent's current score.
    function ratingOf(uint256 agentId) public view returns (string memory) {
        return _rating(scoreOf(agentId));
    }

    /// @notice One-call trust verdict for an integrating protocol: the Trust Score, its letter
    /// rating, and whether ReefGuard would currently clear `agentId` to move `sizeBps` of `asset`.
    function report(uint256 agentId, address asset, uint256 sizeBps)
        external
        view
        returns (uint256 score, string memory rating, bool guardCleared, string memory guardReason)
    {
        score = scoreOf(agentId);
        rating = _rating(score);
        if (guard == address(0)) {
            return (score, rating, false, "guard not set");
        }
        (guardCleared, guardReason) = IGuardView(guard).canExecute(agentId, asset, sizeBps);
    }

    /// @notice Every registered agent's id and Trust Score in one call (for dashboards / snapshots).
    function allScores() external view returns (uint256[] memory agentIds, uint256[] memory wad) {
        uint256 n = vaults.length;
        agentIds = new uint256[](n);
        wad = new uint256[](n);
        uint256 maxRep = _maxRep();
        for (uint256 i = 0; i < n; i++) {
            address v = vaults[i];
            agentIds[i] = IVaultView(v).agentId();
            wad[i] = _trustScore(v, maxRep);
        }
    }

    // --- Internals (1:1 with Allocator._trustScore) ---

    function _maxRep() internal view returns (uint256 m) {
        for (uint256 i = 0; i < vaults.length; i++) {
            (int256 cum,) = identity.getSummary(IVaultView(vaults[i]).agentId());
            if (cum > 0 && uint256(cum) > m) m = uint256(cum);
        }
        if (m == 0) m = 1; // avoid div-by-zero; matches the off-chain `max_rep or 1`
    }

    function _components(address vault, uint256 maxRep)
        internal
        view
        returns (uint256 repC, uint256 freshC, uint256 ddC, uint256 bondC)
    {
        IVaultView v = IVaultView(vault);
        uint256 aid = v.agentId();

        (int256 cum,) = identity.getSummary(aid);
        uint256 rep = cum > 0 ? uint256(cum) : 0;
        repC = (rep * WAD) / maxRep;

        uint256 last = v.lastReceiptAt();
        if (last != 0) {
            uint256 age = block.timestamp > last ? block.timestamp - last : 0;
            freshC = age >= FRESH_WINDOW ? 0 : ((FRESH_WINDOW - age) * WAD) / FRESH_WINDOW;
        }

        uint256 nav = v.nav();
        uint256 hwm = v.highWaterNav();
        if (hwm == 0) {
            ddC = WAD;
        } else {
            uint256 ddRaw = hwm > nav ? ((hwm - nav) * WAD) / hwm : 0;
            uint256 scaled = ddRaw * DD_PENALTY;
            if (scaled > WAD) scaled = WAD;
            ddC = WAD - scaled;
        }

        uint256 b = bond == address(0) ? 0 : IBondView(bond).bondOf(aid);
        bondC = b >= BOND_TARGET ? WAD : (b * WAD) / BOND_TARGET;
    }

    function _trustScore(address vault, uint256 maxRep) internal view returns (uint256) {
        (uint256 repC, uint256 freshC, uint256 ddC, uint256 bondC) = _components(vault, maxRep);
        return (repC * W_REP + freshC * W_FRESH + ddC * W_DD + bondC * W_BOND) / 10_000;
    }

    function _rating(uint256 score) internal pure returns (string memory) {
        if (score >= R_AAA) return "AAA";
        if (score >= R_AA) return "AA";
        if (score >= R_A) return "A";
        if (score >= R_BBB) return "BBB";
        return "BB";
    }
}
