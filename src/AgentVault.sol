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
    /// @dev All-time-high per-share NAV. Reputation credits only growth ABOVE this
    /// high-water mark, so a drawdown-then-recovery is never double-counted — the score
    /// is risk-adjusted (rewards sustained new highs) and capital-normalized (per-share).
    uint256 public highWaterNav;

    // --- EIP-712 receipt signing ---
    // Receipts are typed-data signed by the agent's operator and may be submitted by
    // anyone (a keeper/relayer), so agents need not hold gas. The per-vault domain
    // (verifyingContract = this vault) prevents cross-vault replay; agentId + strict
    // seq prevent in-vault replay.
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _RECEIPT_TYPEHASH =
        keccak256("Receipt(uint256 agentId,uint256 seq,bytes32 evidenceHash,int256 claimedDelta,uint64 period)");
    uint256 private immutable _cachedChainId;
    bytes32 private immutable _cachedDomainSeparator;

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
        highWaterNav = 1e18; // reputation accrues only on new per-share NAV highs
        _cachedChainId = block.chainid;
        _cachedDomainSeparator = _buildDomainSeparator();
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

    /// @notice Publish a strict-sequence receipt for the latest period. The receipt is
    /// EIP-712 typed-data signed by the agent's operator; ANYONE may submit it (a keeper
    /// or relayer), so agents need not hold gas. Reputation credited is the vault's REAL
    /// per-share NAV change since the last receipt, computed on-chain — the operator's
    /// `claimedDelta` is signed (an attestation matched by the evidence hash) but ignored
    /// for reputation, closing the operator-overstatement vector.
    function publishReceipt(
        uint256 seq,
        bytes32 evidenceHash,
        int256 claimedDelta,
        uint64 period,
        bytes calldata signature
    ) external override {
        require(seq == nextReceiptSeq, "bad seq");
        require(evidenceHash != bytes32(0), "zero evidence");
        require(period > 0, "zero period");
        _verifyReceiptSig(seq, evidenceHash, claimedDelta, period, signature);

        nextReceiptSeq = seq + 1;
        lastReceiptEvidenceHash = evidenceHash;
        lastReceiptAt = uint64(block.timestamp);

        // Risk-adjusted: credit only per-share NAV growth above the all-time high-water
        // mark. Recovering from a drawdown earns nothing until a new high is set, so
        // volatility/round-tripping cannot farm reputation.
        uint256 currentNav = nav();
        int256 credit = 0;
        if (currentNav > highWaterNav) {
            credit = int256(currentNav - highWaterNav);
            highWaterNav = currentNav;
        }
        identity.giveFeedback(agentId, _clipToInt128(credit), 18);

        emit ReceiptPublished(seq, evidenceHash, credit);
    }

    /// @dev Recover the receipt signer and require it is the agent's operator.
    function _verifyReceiptSig(
        uint256 seq,
        bytes32 evidenceHash,
        int256 claimedDelta,
        uint64 period,
        bytes calldata signature
    ) private view {
        bytes32 structHash = keccak256(abi.encode(_RECEIPT_TYPEHASH, agentId, seq, evidenceHash, claimedDelta, period));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
        address signer = _recover(digest, signature);
        require(signer != address(0) && signer == identity.getAgentWallet(agentId), "bad signature");
    }

    /// @notice EIP-712 domain separator for this vault (recomputed if the chain forked).
    function domainSeparator() public view returns (bytes32) {
        return block.chainid == _cachedChainId ? _cachedDomainSeparator : _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(_DOMAIN_TYPEHASH, keccak256("Reef AgentVault"), keccak256("1"), block.chainid, address(this))
        );
    }

    /// @dev Minimal ECDSA recovery (no external dependency). A malleable (high-s) variant
    /// recovers the SAME signer, and replay is already blocked by the strict `seq` + the
    /// per-vault domain, so an explicit low-s check is unnecessary here.
    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (v < 27) v += 27;
        if (v != 27 && v != 28) return address(0);
        return ecrecover(digest, v, r, s);
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
