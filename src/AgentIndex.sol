// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IAgentIndex} from "./interfaces/IAgentIndex.sol";
import {AgentIdentity} from "./AgentIdentity.sol";
import {AgentVault} from "./AgentVault.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "./utils/SafeTransferLib.sol";

/// @notice Minimal view into ReputationBond for the index's skin-in-the-game gate.
interface IReputationBond {
    function bondOf(uint256 agentId) external view returns (uint256);
}

/// @title AgentIndex
/// @notice Tokenized basket that allocates the index's USDY across registered
/// AgentVaults in proportion to each agent's positive cumulative reputation.
/// Anyone can call `rebalance()`; the allocation formula is transparent and
/// in-source (no admin re-weighting).
contract AgentIndex is IAgentIndex, ReentrancyGuard {
    using SafeTransferLib for IERC20;

    IERC20 public immutable asset;
    AgentIdentity public immutable identity;
    address public governor;

    // Skin-in-the-game gate: when reputationBond is set, only agents bonded for at
    // least minBond receive allocation (unbonded/slashed agents drop out).
    address public reputationBond;
    uint256 public minBond;

    // --- Index share accounting (the share is a transferable ERC-20) ---
    mapping(address => uint256) public balanceOf;
    uint256 public totalShares;

    string public constant name = "Reef AI Yield Index";
    string public constant symbol = "rINDEX";
    uint8 public constant decimals = 18;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // --- Vault registry ---
    AgentVault[] public vaults;
    mapping(address => bool) public isRegistered;
    /// @dev shares of each underlying AgentVault held by this index
    mapping(address => uint256) public vaultShares;

    event VaultAdded(address indexed vault);
    event BondGateSet(address reputationBond, uint256 minBond);

    modifier onlyGovernor() {
        require(msg.sender == governor, "not governor");
        _;
    }

    constructor(address asset_, address identity_) {
        require(asset_ != address(0) && identity_ != address(0), "zero addr");
        asset = IERC20(asset_);
        identity = AgentIdentity(identity_);
        governor = msg.sender;
    }

    // --- Registry ---

    function addVault(address vault) external onlyGovernor {
        require(!isRegistered[vault], "registered");
        require(address(AgentVault(vault).asset()) == address(asset), "wrong asset");
        isRegistered[vault] = true;
        vaults.push(AgentVault(vault));
        emit VaultAdded(vault);
    }

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    function setGovernor(address g) external onlyGovernor {
        require(g != address(0), "zero gov");
        governor = g;
    }

    /// @notice Gate allocation on bonded skin-in-the-game. Pass rb=address(0) to disable.
    function setReputationBond(address rb, uint256 min) external onlyGovernor {
        reputationBond = rb;
        minBond = min;
        emit BondGateSet(rb, min);
    }

    // --- ERC-20 share token ---

    function totalSupply() external view returns (uint256) {
        return totalShares;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "to zero");
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    // --- Index deposit / withdraw ---

    function deposit(uint256 assets) external override nonReentrant returns (uint256 shares) {
        require(assets > 0, "zero assets");
        // Virtual shares/assets offset (+1) neutralizes the first-depositor donation
        // inflation attack while preserving 1:1 minting on the first real deposit.
        shares = (assets * (totalShares + 1)) / (totalAssets() + 1);
        require(shares > 0, "zero shares");
        asset.safeTransferFrom(msg.sender, address(this), assets);
        balanceOf[msg.sender] += shares;
        totalShares += shares;
        emit Transfer(address(0), msg.sender, shares); // mint
        emit IndexDeposit(msg.sender, assets, shares);
    }

    function withdraw(uint256 shares) external override nonReentrant returns (uint256 assets) {
        require(shares > 0, "zero shares");
        require(balanceOf[msg.sender] >= shares, "insufficient shares");
        assets = (shares * (totalAssets() + 1)) / (totalShares + 1);
        require(assets > 0, "zero assets");

        uint256 idle = asset.balanceOf(address(this));
        if (idle < assets) _pullFromVaults(assets - idle);

        balanceOf[msg.sender] -= shares;
        totalShares -= shares;
        emit Transfer(msg.sender, address(0), shares); // burn
        asset.safeTransfer(msg.sender, assets);
        emit IndexWithdraw(msg.sender, assets, shares);
    }

    // --- Rebalance ---

    /// @notice Permissionless. Reweights allocation across all registered vaults
    /// in proportion to clamped-positive reputation. Equal weight if all reputations
    /// are non-positive.
    function rebalance() external override nonReentrant {
        uint256 n = vaults.length;
        require(n > 0, "no vaults");

        uint256 total = totalAssets();
        (uint256[] memory targets, uint256[] memory exposures) = _computeTargetsAndExposures(total);

        // Pass 1: pull from over-allocated
        for (uint256 i = 0; i < n; i++) {
            if (exposures[i] > targets[i]) {
                _recallFromVault(vaults[i], exposures[i] - targets[i]);
            }
        }

        // Pass 2: push to under-allocated
        for (uint256 i = 0; i < n; i++) {
            uint256 deployed =
                vaultShares[address(vaults[i])] > 0 ? (vaultShares[address(vaults[i])] * vaults[i].nav()) / 1e18 : 0;
            if (deployed < targets[i]) {
                uint256 toDeploy = targets[i] - deployed;
                uint256 idle = asset.balanceOf(address(this));
                if (toDeploy > idle) toDeploy = idle;
                if (toDeploy > 0) _depositToVault(vaults[i], toDeploy);
            }
        }

        emit Rebalanced(n, total);
    }

    // --- Views ---

    function totalAssets() public view returns (uint256) {
        uint256 total = asset.balanceOf(address(this));
        for (uint256 i = 0; i < vaults.length; i++) {
            uint256 vs = vaultShares[address(vaults[i])];
            if (vs > 0) total += (vs * vaults[i].nav()) / 1e18;
        }
        return total;
    }

    function getAllocation() external view override returns (Allocation[] memory out) {
        uint256 n = vaults.length;
        uint256 total = totalAssets();
        out = new Allocation[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 vs = vaultShares[address(vaults[i])];
            uint256 deployed = vs > 0 ? (vs * vaults[i].nav()) / 1e18 : 0;
            out[i] = Allocation({
                agentId: vaults[i].agentId(),
                vault: address(vaults[i]),
                weightBps: total == 0 ? 0 : (deployed * 10_000) / total,
                deployed: deployed
            });
        }
    }

    // --- Internals ---

    function _computeTargetsAndExposures(uint256 total)
        internal
        view
        returns (uint256[] memory targets, uint256[] memory exposures)
    {
        uint256 n = vaults.length;
        targets = new uint256[](n);
        exposures = new uint256[](n);
        uint256[] memory rep = new uint256[](n);
        bool[] memory bonded = new bool[](n);
        uint256 totalRep;
        uint256 bondedCount;
        for (uint256 i = 0; i < n; i++) {
            uint256 aid = vaults[i].agentId();
            bonded[i] = reputationBond == address(0) || IReputationBond(reputationBond).bondOf(aid) >= minBond;
            if (bonded[i]) bondedCount++;
            (int256 cum,) = identity.getSummary(aid);
            if (cum > 0 && bonded[i]) {
                rep[i] = uint256(cum);
                totalRep += rep[i];
            }
            uint256 vs = vaultShares[address(vaults[i])];
            exposures[i] = vs > 0 ? (vs * vaults[i].nav()) / 1e18 : 0;
        }
        if (totalRep == 0) {
            // Equal weight among bonded vaults (or all, if the gate is off / none bonded).
            uint256 denom = bondedCount > 0 ? bondedCount : n;
            uint256 equal = total / denom;
            for (uint256 i = 0; i < n; i++) {
                if (bondedCount == 0 || bonded[i]) targets[i] = equal;
            }
        } else {
            for (uint256 i = 0; i < n; i++) {
                targets[i] = (total * rep[i]) / totalRep;
            }
        }
    }

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
