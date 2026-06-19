// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {AgentIdentity} from "./AgentIdentity.sol";
import {AgentVault} from "./AgentVault.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";
import {Pausable} from "./utils/Pausable.sol";
import {SafeTransferLib} from "./utils/SafeTransferLib.sol";

/// @notice Minimal view into ReputationBond for the bond component of the trust score.
interface IBond {
    function bondOf(uint256 agentId) external view returns (uint256);
}

/// @title Allocator
/// @notice An institutional capital allocator for AI yield agents. LPs deposit one asset;
/// capital is allocated across registered AgentVaults *weighted by each agent's on-chain
/// Trust Score* — and only to agents that *qualify* under the active **mandate** (a named
/// risk profile). Each mandate sets a minimum trust score (the qualification bar) and a
/// per-agent concentration cap (automated risk management). The Trust Score is computed
/// in-source from data already emitted on-chain (ERC-8004 reputation, receipt freshness,
/// drawdown vs high-water, posted bond) — the same four components as the off-chain
/// T-tier, so the allocation is verifiable rather than asserted.
contract Allocator is ReentrancyGuard, Pausable {
    using SafeTransferLib for IERC20;

    // --- Trust score model (WAD-scaled, 1e18 = 1.0). Mirrors agents/scripts/trust_score.py. ---
    uint256 internal constant WAD = 1e18;
    uint256 internal constant FRESH_WINDOW = 86_400; // receipt older than 24h scores 0 on freshness
    uint256 internal constant BOND_TARGET = 50e18; // full marks at the cohort's standard 50e18 bond
    uint256 internal constant DD_PENALTY = 5; // 20% drawdown -> 0 on the drawdown component
    uint256 internal constant W_REP = 4000; // component weights in bps (sum = 10_000)
    uint256 internal constant W_FRESH = 2000;
    uint256 internal constant W_DD = 2000;
    uint256 internal constant W_BOND = 2000;
    uint256 internal constant DEFAULT_REPUTATION_TARGET = 10e18;

    IERC20 public immutable asset;
    AgentIdentity public immutable identity;
    address public bond; // ReputationBond; if unset, the bond component scores 0
    address public governor;
    /// @notice Reputation basis: 0 = cohort-relative; the default non-zero value is an absolute
    /// full-marks target (`min(rep / reputationTarget, 1)`), so a weak field can't all read as top trust.
    uint256 public reputationTarget = DEFAULT_REPUTATION_TARGET;

    struct Mandate {
        string name;
        uint256 minTrustScore; // qualification bar, WAD (0..1e18)
        uint256 maxWeightBps; // per-agent concentration cap, bps of total capital
    }

    Mandate[] public mandates;
    uint256 public activeMandate;

    // --- Permissioned LP allowlist (compliance-sensitive RWA flows) ---
    // Default off: deposits are open. When the governor turns `permissioned` on, only
    // allowlisted addresses may deposit (e.g. KYC'd / onboarded institutions). Withdrawals are
    // never gated — a depositor can always exit. This is real on-chain access control, not a
    // claimed off-chain check.
    bool public permissioned;
    mapping(address => bool) public depositorAllowed;

    // --- LP share accounting (non-transferable allocator position) ---
    mapping(address => uint256) public balanceOf;
    uint256 public totalShares;

    // --- Vault registry ---
    AgentVault[] public vaults;
    mapping(address => bool) public isRegistered;
    mapping(address => uint256) public vaultShares; // AgentVault shares held by this allocator
    /// @dev Removed-vault shares held outside active accounting. They can be recovered if the
    /// vault becomes callable again, but do not brick totalAssets()/withdrawals while quarantined.
    mapping(address => uint256) public quarantinedVaultShares;

    event VaultAdded(address indexed vault);
    event VaultRemoved(address indexed vault);
    event VaultRecovered(address indexed vault, uint256 shares, uint256 assets);
    event MandateAdded(uint256 indexed id, string name, uint256 minTrustScore, uint256 maxWeightBps);
    event ActiveMandateSet(uint256 indexed id);
    event BondSet(address bond);
    event Deposit(address indexed lp, uint256 assets, uint256 shares);
    event Withdraw(address indexed lp, uint256 assets, uint256 shares);
    event Rebalanced(uint256 indexed mandateId, uint256 totalAssets, uint256 qualifying);
    event PermissionedSet(bool enabled);
    event DepositorAllowed(address indexed depositor, bool allowed);

    modifier onlyGovernor() {
        require(msg.sender == governor, "not governor");
        _;
    }

    constructor(address asset_, address identity_, address bond_) {
        require(asset_ != address(0) && identity_ != address(0), "zero addr");
        asset = IERC20(asset_);
        identity = AgentIdentity(identity_);
        bond = bond_;
        governor = msg.sender;
        _initGuardian(msg.sender);
        // Mandate 0 is the always-present "Open" baseline: no bar, no cap.
        mandates.push(Mandate({name: "Open", minTrustScore: 0, maxWeightBps: 10_000}));
        emit MandateAdded(0, "Open", 0, 10_000);
    }

    // --- Governance ---

    function addVault(address vault) external onlyGovernor {
        require(!isRegistered[vault], "registered");
        require(address(AgentVault(vault).asset()) == address(asset), "wrong asset");
        require(address(AgentVault(vault).identity()) == address(identity), "wrong identity");
        isRegistered[vault] = true;
        vaults.push(AgentVault(vault));
        emit VaultAdded(vault);
    }

    /// @notice Evict a vault from the allocator without calling it, so a single reverting
    /// vault (whose `nav()` bricks `totalAssets()` and locks every withdrawal) can be removed
    /// and the allocator restored. Held shares are quarantined for later recovery.
    function removeVault(address vault) external onlyGovernor {
        require(isRegistered[vault], "not registered");
        isRegistered[vault] = false;
        uint256 held = vaultShares[vault];
        if (held > 0) {
            quarantinedVaultShares[vault] += held;
            vaultShares[vault] = 0;
        }
        uint256 n = vaults.length;
        for (uint256 i = 0; i < n; i++) {
            if (address(vaults[i]) == vault) {
                vaults[i] = vaults[n - 1];
                vaults.pop();
                break;
            }
        }
        emit VaultRemoved(vault);
    }

    /// @notice Recover shares from a removed vault if it becomes callable again. Recovered assets
    /// return to idle allocator liquidity; the vault stays removed unless governance re-adds it.
    function recoverRemovedVault(address vault, uint256 shares) external onlyGovernor nonReentrant {
        uint256 q = quarantinedVaultShares[vault];
        require(shares > 0 && shares <= q, "shares");
        quarantinedVaultShares[vault] = q - shares;
        uint256 assets = AgentVault(vault).withdraw(shares);
        emit VaultRecovered(vault, shares, assets);
    }

    function addMandate(string calldata name_, uint256 minTrustScore_, uint256 maxWeightBps_)
        external
        onlyGovernor
        returns (uint256 id)
    {
        require(minTrustScore_ <= WAD, "trust");
        require(maxWeightBps_ > 0 && maxWeightBps_ <= 10_000, "bps");
        id = mandates.length;
        mandates.push(Mandate({name: name_, minTrustScore: minTrustScore_, maxWeightBps: maxWeightBps_}));
        emit MandateAdded(id, name_, minTrustScore_, maxWeightBps_);
    }

    function setActiveMandate(uint256 id) external onlyGovernor {
        require(id < mandates.length, "no mandate");
        activeMandate = id;
        emit ActiveMandateSet(id);
    }

    function setBond(address bond_) external onlyGovernor {
        bond = bond_;
        emit BondSet(bond_);
    }

    /// @notice Set the reputation basis: 0 = cohort-relative; non-zero = absolute full-marks target.
    function setReputationTarget(uint256 target) external onlyGovernor {
        reputationTarget = target;
    }

    function setGovernor(address g) external onlyGovernor {
        require(g != address(0), "zero gov");
        governor = g;
    }

    /// @notice Turn the depositor allowlist on/off. When on, only allowlisted addresses may
    /// deposit; withdrawals stay open. Default off (permissionless).
    function setPermissioned(bool enabled) external onlyGovernor {
        permissioned = enabled;
        emit PermissionedSet(enabled);
    }

    /// @notice Allow/deny an address to deposit while `permissioned` is on (e.g. KYC onboarding).
    function setDepositorAllowed(address depositor, bool allowed) external onlyGovernor {
        depositorAllowed[depositor] = allowed;
        emit DepositorAllowed(depositor, allowed);
    }

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    function mandateCount() external view returns (uint256) {
        return mandates.length;
    }

    // --- LP deposit / withdraw ---

    function deposit(uint256 assets) external nonReentrant whenNotPaused returns (uint256 shares) {
        require(!permissioned || depositorAllowed[msg.sender], "depositor not allowed");
        require(assets > 0, "zero assets");
        // Virtual offset (+1) neutralizes the first-depositor donation inflation attack
        // while preserving 1:1 minting on the first real deposit.
        shares = (assets * (totalShares + 1)) / (totalAssets() + 1);
        require(shares > 0, "zero shares");
        asset.safeTransferFrom(msg.sender, address(this), assets);
        balanceOf[msg.sender] += shares;
        totalShares += shares;
        emit Deposit(msg.sender, assets, shares);
    }

    function withdraw(uint256 shares) external nonReentrant returns (uint256 assets) {
        require(shares > 0, "zero shares");
        require(balanceOf[msg.sender] >= shares, "insufficient shares");
        assets = (shares * (totalAssets() + 1)) / (totalShares + 1);
        require(assets > 0, "zero assets");

        // Effects before interactions (CEI): burn shares before pulling from vaults.
        balanceOf[msg.sender] -= shares;
        totalShares -= shares;

        uint256 idle = asset.balanceOf(address(this));
        if (idle < assets) {
            _pullFromVaults(assets - idle);
            // Pay what the vaults actually realized, never the spot mark — a recall can return
            // less than its nav() mark, so transferring the marked amount would overdraw.
            uint256 available = asset.balanceOf(address(this));
            if (available < assets) assets = available;
        }
        asset.safeTransfer(msg.sender, assets);
        emit Withdraw(msg.sender, assets, shares);
    }

    // --- Rebalance ---

    /// @notice Permissionless. Reallocates capital across qualifying vaults, trust-weighted
    /// and capped at the active mandate's per-agent concentration limit. Non-qualifying agents
    /// are pulled to zero; capital that the cap leaves unplaceable stays idle (redemption buffer).
    function rebalance() external nonReentrant whenNotPaused {
        uint256 n = vaults.length;
        require(n > 0, "no vaults");
        uint256 total = totalAssets();
        (uint256[] memory targets, uint256[] memory exposures, uint256 qualifying) = _computeTargets(total);

        // Pass 1: pull from over-allocated (incl. now-disqualified agents -> target 0).
        for (uint256 i = 0; i < n; i++) {
            if (exposures[i] > targets[i]) {
                _recallFromVault(vaults[i], exposures[i] - targets[i]);
            }
        }
        // Pass 2: push to under-allocated.
        for (uint256 i = 0; i < n; i++) {
            uint256 deployed = _exposure(vaults[i]);
            if (deployed < targets[i]) {
                uint256 toDeploy = targets[i] - deployed;
                uint256 idle = asset.balanceOf(address(this));
                if (toDeploy > idle) toDeploy = idle;
                if (toDeploy > 0) _depositToVault(vaults[i], toDeploy);
            }
        }
        emit Rebalanced(activeMandate, total, qualifying);
    }

    // --- Trust score (on-chain, verifiable) ---

    /// @notice The agent's on-chain Trust Score in WAD (1e18 = 100/100), absolute by default and
    /// cohort-relative only when reputationTarget is zero. Combines reputation (40%), receipt freshness (20%), drawdown vs
    /// high-water (20%) and posted bond (20%).
    function trustScoreOf(address vault) external view returns (uint256) {
        require(isRegistered[vault], "unknown vault");
        return _trustScore(AgentVault(vault), _repBasis());
    }

    /// @notice Full allocation preview for the active mandate: per-vault trust score, whether it
    /// qualifies, and the target capital it would receive at the current total.
    function previewTargets()
        external
        view
        returns (
            address[] memory vaultAddrs,
            uint256[] memory scores,
            bool[] memory qualified,
            uint256[] memory targets
        )
    {
        uint256 n = vaults.length;
        uint256 maxRep = _repBasis();
        Mandate storage m = mandates[activeMandate];
        vaultAddrs = new address[](n);
        scores = new uint256[](n);
        qualified = new bool[](n);
        (targets,,) = _computeTargets(totalAssets());
        for (uint256 i = 0; i < n; i++) {
            vaultAddrs[i] = address(vaults[i]);
            scores[i] = _trustScore(vaults[i], maxRep);
            qualified[i] = scores[i] >= m.minTrustScore;
        }
    }

    // --- Views ---

    function totalAssets() public view returns (uint256) {
        uint256 total = asset.balanceOf(address(this));
        for (uint256 i = 0; i < vaults.length; i++) {
            total += _exposure(vaults[i]);
        }
        return total;
    }

    function _exposure(AgentVault v) internal view returns (uint256) {
        uint256 vs = vaultShares[address(v)];
        return vs > 0 ? (vs * v.nav()) / 1e18 : 0;
    }

    function _maxRep() internal view returns (uint256 m) {
        for (uint256 i = 0; i < vaults.length; i++) {
            (int256 cum,) = identity.getSummary(vaults[i].agentId());
            if (cum > 0 && uint256(cum) > m) m = uint256(cum);
        }
        if (m == 0) m = 1; // avoid div-by-zero; matches the off-chain `max_rep or 1`
    }

    function _repBasis() internal view returns (uint256) {
        return reputationTarget == 0 ? _maxRep() : reputationTarget;
    }

    function _trustScore(AgentVault v, uint256 maxRep) internal view returns (uint256) {
        uint256 aid = v.agentId();

        (int256 cum,) = identity.getSummary(aid);
        uint256 rep = cum > 0 ? uint256(cum) : 0;
        uint256 repC = reputationTarget == 0
            ? (rep * WAD) / maxRep // cohort-relative when explicitly selected
            : (rep >= reputationTarget ? WAD : (rep * WAD) / reputationTarget); // absolute

        uint256 last = v.lastReceiptAt();
        uint256 freshC;
        if (last != 0) {
            uint256 age = block.timestamp > last ? block.timestamp - last : 0;
            freshC = age >= FRESH_WINDOW ? 0 : ((FRESH_WINDOW - age) * WAD) / FRESH_WINDOW;
        }

        uint256 nav = v.reputableNav(); // donation-proof basis for drawdown (matches highWaterNav)
        uint256 hwm = v.highWaterNav();
        uint256 ddC;
        if (hwm == 0) {
            ddC = WAD;
        } else {
            uint256 ddRaw = hwm > nav ? ((hwm - nav) * WAD) / hwm : 0;
            uint256 scaled = ddRaw * DD_PENALTY;
            if (scaled > WAD) scaled = WAD;
            ddC = WAD - scaled;
        }

        uint256 b = bond == address(0) ? 0 : IBond(bond).bondOf(aid);
        uint256 bondC = b >= BOND_TARGET ? WAD : (b * WAD) / BOND_TARGET;

        return (repC * W_REP + freshC * W_FRESH + ddC * W_DD + bondC * W_BOND) / 10_000;
    }

    // --- Allocation math ---

    /// @dev Trust-weighted, qualification-gated, concentration-capped target per vault.
    /// Capping uses a bounded 2-pass water-fill: pass 1 proportional-then-clamp, pass 2
    /// redistributes the freed amount across uncapped qualifiers; any residual stays idle.
    function _computeTargets(uint256 total)
        internal
        view
        returns (uint256[] memory targets, uint256[] memory exposures, uint256 qualifying)
    {
        uint256 n = vaults.length;
        targets = new uint256[](n);
        exposures = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            exposures[i] = _exposure(vaults[i]);
        }
        (uint256[] memory w, uint256 totalW, uint256 q) = _qualifyWeights();
        qualifying = q;
        if (qualifying == 0) return (targets, exposures, qualifying);
        uint256 cap = (total * mandates[activeMandate].maxWeightBps) / 10_000;
        _waterfill(targets, w, totalW, cap, total);
    }

    /// @dev Per-vault weight basis under the active mandate: each qualifier's trust score (or
    /// equal weight if every qualifier scored exactly 0), 0 for non-qualifiers.
    function _qualifyWeights() internal view returns (uint256[] memory w, uint256 totalW, uint256 qualifying) {
        uint256 n = vaults.length;
        uint256 maxRep = _repBasis();
        uint256 minTrust = mandates[activeMandate].minTrustScore;
        w = new uint256[](n);
        uint256[] memory score = new uint256[](n);
        uint256 sumScore;
        for (uint256 i = 0; i < n; i++) {
            score[i] = _trustScore(vaults[i], maxRep);
            if (score[i] >= minTrust) {
                qualifying++;
                sumScore += score[i];
            }
        }
        if (qualifying == 0) return (w, 0, 0);
        bool allZero = sumScore == 0;
        for (uint256 i = 0; i < n; i++) {
            if (score[i] >= minTrust) {
                w[i] = allZero ? 1 : score[i];
                totalW += w[i];
            }
        }
    }

    /// @dev Bounded 2-pass water-fill: proportional-then-clamp, then redistribute the freed
    /// amount across uncapped qualifiers (clamped again). Any residual stays idle. Writes targets.
    function _waterfill(uint256[] memory targets, uint256[] memory w, uint256 totalW, uint256 cap, uint256 total)
        internal
        pure
    {
        uint256 n = w.length;
        uint256 freed;
        uint256 uncappedW;
        for (uint256 i = 0; i < n; i++) {
            if (w[i] == 0) continue;
            uint256 t = totalW == 0 ? 0 : (total * w[i]) / totalW;
            if (t > cap) {
                freed += t - cap;
                t = cap;
            } else {
                uncappedW += w[i];
            }
            targets[i] = t;
        }
        if (freed > 0 && uncappedW > 0) {
            for (uint256 i = 0; i < n; i++) {
                if (w[i] == 0 || targets[i] >= cap) continue;
                uint256 add = (freed * w[i]) / uncappedW;
                uint256 nt = targets[i] + add;
                if (nt > cap) nt = cap;
                targets[i] = nt;
            }
        }
    }

    // --- Vault interaction internals (mirrors AgentIndex's realized-vs-marked recall) ---

    function _recallFromVault(AgentVault v, uint256 amount) internal {
        uint256 myShares = vaultShares[address(v)];
        if (myShares == 0) return;
        uint256 vTotalShares = v.totalShares();
        uint256 vTotalAssets = v.totalAssets();
        if (vTotalAssets == 0 || vTotalShares == 0) return;
        uint256 sharesToWithdraw = (amount * vTotalShares) / vTotalAssets;
        if (sharesToWithdraw > myShares) sharesToWithdraw = myShares;
        if (sharesToWithdraw == 0) return;
        v.withdraw(sharesToWithdraw);
        vaultShares[address(v)] -= sharesToWithdraw;
    }

    function _depositToVault(AgentVault v, uint256 amount) internal {
        asset.safeApprove(address(v), amount);
        uint256 sharesReceived = v.deposit(amount);
        vaultShares[address(v)] += sharesReceived;
    }

    function _pullFromVaults(uint256 needed) internal {
        for (uint256 i = 0; i < vaults.length && needed > 0; i++) {
            uint256 myShares = vaultShares[address(vaults[i])];
            if (myShares == 0) continue;
            uint256 exposure = (myShares * vaults[i].nav()) / 1e18;
            uint256 toRecall = needed > exposure ? exposure : needed;
            uint256 before = asset.balanceOf(address(this));
            _recallFromVault(vaults[i], toRecall);
            uint256 received = asset.balanceOf(address(this)) - before;
            needed = needed > received ? needed - received : 0;
        }
    }
}
