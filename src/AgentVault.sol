// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IAgentVault} from "./interfaces/IAgentVault.sol";
import {IStrategyAdapter} from "./interfaces/IStrategyAdapter.sol";
import {AgentIdentity} from "./AgentIdentity.sol";
import {AdapterRegistry} from "./AdapterRegistry.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";
import {Pausable} from "./utils/Pausable.sol";
import {SafeTransferLib} from "./utils/SafeTransferLib.sol";

/// @title AgentVault
/// @notice Per-agent vault. Operator deploys capital into approved StrategyAdapters
/// — funds always move vault→adapter, never to the operator wallet. Each cycle the
/// operator publishes a strict-sequence receipt; the cumulative PnL flows into the
/// agent's ERC-8004 reputation via AgentIdentity.giveFeedback.
contract AgentVault is IAgentVault, ReentrancyGuard, Pausable {
    using SafeTransferLib for IERC20;

    IERC20 public immutable asset;
    uint256 public immutable override agentId;
    AgentIdentity public immutable identity;
    /// @dev Protocol allowlist; only adapters it approves may be set as a strategy.
    AdapterRegistry public immutable adapterRegistry;

    // --- Share accounting ---

    mapping(address => uint256) public balanceOf;
    uint256 public totalShares;

    // --- Strategy state ---

    /// @dev Single active strategy at a time keeps v1 simple. Switching strategies
    /// requires a full recall first; the AgentIndex sees this as a transient pause.
    address public currentStrategy;
    mapping(address => bool) public approvedStrategies;

    // --- Receipt state ---

    uint256 public nextReceiptSeq;
    bytes32 public lastReceiptEvidenceHash;
    uint64 public lastReceiptAt;
    /// @dev Per-share NAV at the last receipt; reputation credits the delta since.
    uint256 public lastReputableNav;

    event StrategyApproved(address indexed adapter);

    modifier onlyOperator() {
        require(identity.getAgentWallet(agentId) == msg.sender, "not operator");
        _;
    }

    constructor(address asset_, uint256 agentId_, address identity_, address registry_) {
        require(asset_ != address(0) && identity_ != address(0) && registry_ != address(0), "zero addr");
        require(AgentIdentity(identity_).getAgentWallet(agentId_) != address(0), "no agent");
        asset = IERC20(asset_);
        agentId = agentId_;
        identity = AgentIdentity(identity_);
        adapterRegistry = AdapterRegistry(registry_);
        // The agent's own wallet is the circuit-breaker guardian for its sovereign vault.
        _initGuardian(AgentIdentity(identity_).getAgentWallet(agentId_));
        lastReputableNav = 1e18; // starting NAV; reputation accrues on gains above this
    }

    // --- Deposit / Withdraw ---

    function deposit(uint256 assets) external override nonReentrant whenNotPaused returns (uint256 shares) {
        require(assets > 0, "zero assets");
        // Virtual shares/assets offset (+1) neutralizes the first-depositor donation
        // inflation attack: it removes the empty-vault 1-wei→1-share edge and makes any
        // price-inflating donation a loss to the attacker rather than a theft from the
        // next depositor. First real deposit still mints 1:1 (assets·1/1).
        shares = (assets * (totalShares + 1)) / (totalAssets() + 1);
        require(shares > 0, "zero shares");
        asset.safeTransferFrom(msg.sender, address(this), assets);
        balanceOf[msg.sender] += shares;
        totalShares += shares;
        emit Deposited(msg.sender, assets, shares);
    }

    function withdraw(uint256 shares) external override nonReentrant returns (uint256 assets) {
        require(shares > 0, "zero shares");
        require(balanceOf[msg.sender] >= shares, "insufficient shares");
        assets = (shares * (totalAssets() + 1)) / (totalShares + 1);
        require(assets > 0, "zero assets");

        // Effects before interactions (CEI): burn shares first, then recall + pay out.
        balanceOf[msg.sender] -= shares;
        totalShares -= shares;

        uint256 idle = asset.balanceOf(address(this));
        if (idle < assets) {
            require(currentStrategy != address(0), "insufficient liquidity");
            IStrategyAdapter(currentStrategy).recall(assets - idle);
        }

        asset.safeTransfer(msg.sender, assets);
        emit Withdrawn(msg.sender, assets, shares);
    }

    // --- Strategy ---

    function approveStrategy(address adapter) external onlyOperator {
        require(adapter != address(0), "zero adapter");
        require(adapterRegistry.isApproved(adapter), "adapter not allowlisted");
        require(IStrategyAdapter(adapter).asset() == address(asset), "wrong asset");
        require(IStrategyAdapter(adapter).vault() == address(this), "wrong vault");
        approvedStrategies[adapter] = true;
        emit StrategyApproved(adapter);
    }

    function deployToStrategy(address adapter, uint256 amount)
        external
        override
        onlyOperator
        nonReentrant
        whenNotPaused
    {
        require(approvedStrategies[adapter], "not approved");
        require(currentStrategy == address(0) || currentStrategy == adapter, "recall current first");
        require(amount <= asset.balanceOf(address(this)), "amount > idle");
        currentStrategy = adapter;
        asset.safeTransfer(adapter, amount);
        IStrategyAdapter(adapter).deploy(amount);
        emit StrategyDeployed(adapter, amount);
    }

    function recallFromStrategy(address adapter, uint256 amount) external override onlyOperator nonReentrant {
        require(adapter == currentStrategy, "not current");
        IStrategyAdapter(adapter).recall(amount);
        emit StrategyRecalled(adapter, amount);
        // When the strategy is fully drained, clear the slot so a new one can be set.
        if (IStrategyAdapter(adapter).totalUnderlying() == 0) currentStrategy = address(0);
    }

    // --- Receipts ---

    /// @notice Operator publishes a strict-sequence receipt for the latest period.
    /// Reputation credited is the vault's REAL per-share NAV change since the last
    /// receipt, computed on-chain — not the operator-supplied figure (the payload's
    /// claimed delta is ignored for reputation; it remains only as off-chain claim
    /// matched by the evidence hash). This closes the operator-overstatement vector.
    /// @dev Payload layout (abi.encode): (uint256 seq, bytes32 evidenceHash, int256 claimedDelta, uint64 period)
    function publishReceipt(bytes calldata eip712Receipt) external override onlyOperator {
        (uint256 seq, bytes32 evidenceHash,, uint64 period) =
            abi.decode(eip712Receipt, (uint256, bytes32, int256, uint64));
        require(seq == nextReceiptSeq, "bad seq");
        require(evidenceHash != bytes32(0), "zero evidence");
        require(period > 0, "zero period");

        nextReceiptSeq = seq + 1;
        lastReceiptEvidenceHash = evidenceHash;
        lastReceiptAt = uint64(block.timestamp);

        // Credit the real on-chain per-share NAV delta since the last receipt.
        uint256 currentNav = nav();
        int256 realDelta = int256(currentNav) - int256(lastReputableNav);
        lastReputableNav = currentNav;
        identity.giveFeedback(agentId, _clipToInt128(realDelta), 18);

        emit ReceiptPublished(seq, evidenceHash, realDelta);
    }

    // --- Views ---

    function totalAssets() public view returns (uint256) {
        uint256 outstanding = currentStrategy == address(0) ? 0 : IStrategyAdapter(currentStrategy).totalUnderlying();
        return asset.balanceOf(address(this)) + outstanding;
    }

    function nav() public view override returns (uint256) {
        if (totalShares == 0) return 1e18;
        return (totalAssets() * 1e18) / totalShares;
    }

    function snapshot() external view override returns (VaultView memory) {
        uint256 idle = asset.balanceOf(address(this));
        uint256 outstanding = currentStrategy == address(0) ? 0 : IStrategyAdapter(currentStrategy).totalUnderlying();
        return VaultView({
            agentId: agentId,
            asset: address(asset),
            totalAssets: idle + outstanding,
            totalShares: totalShares,
            idle: idle,
            outstanding: outstanding,
            lastReceiptAt: lastReceiptAt
        });
    }

    // --- Internal ---

    function _clipToInt128(int256 x) internal pure returns (int128) {
        if (x > type(int128).max) return type(int128).max;
        if (x < type(int128).min) return type(int128).min;
        return int128(x);
    }
}
