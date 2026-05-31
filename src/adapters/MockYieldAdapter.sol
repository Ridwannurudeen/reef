// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";

/// @notice The testnet MockERC20 exposes a public `mint`; used to realize accrued
/// yield on recall so the gain is backed by real tokens.
interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @title MockYieldAdapter
/// @notice TESTNET-ONLY strategy adapter that accrues linear yield on deployed
/// principal at a fixed APR. It makes `AgentVault.totalAssets()` (and the
/// `AgentIndex` NAV) reflect a real, time-varying, adapter-reported balance —
/// replacing paper-mode simulated NAV deltas with a marked position that grows
/// on-chain. On recall, accrued yield beyond the held balance is minted (the
/// asset is a freely-mintable testnet MockERC20) so the realized gain is backed
/// by real tokens. DO NOT deploy on mainnet — it mints the underlying freely.
contract MockYieldAdapter is IStrategyAdapter {
    IERC20 public immutable token;
    address public immutable override vault;
    uint256 public immutable aprBps; // annualized yield, basis points

    /// @notice Marked principal; folds in accrued yield at each deploy/recall.
    uint256 public principal;
    uint64 public lastAccrualAt;

    uint256 private constant YEAR = 365 days;

    modifier onlyVault() {
        require(msg.sender == vault, "not vault");
        _;
    }

    constructor(address token_, address vault_, uint256 aprBps_) {
        require(token_ != address(0) && vault_ != address(0), "zero addr");
        token = IERC20(token_);
        vault = vault_;
        aprBps = aprBps_;
    }

    function asset() external view override returns (address) {
        return address(token);
    }

    /// @notice Marked value = principal + linear yield accrued since lastAccrualAt.
    function totalUnderlying() public view override returns (uint256) {
        if (principal == 0) return 0;
        uint256 elapsed = block.timestamp - lastAccrualAt;
        uint256 yield = (principal * aprBps * elapsed) / (10_000 * YEAR);
        return principal + yield;
    }

    function deploy(uint256 amount) external override onlyVault returns (uint256 deployed) {
        // Fold any accrued yield into principal, then add the freshly transferred amount.
        principal = totalUnderlying() + amount;
        lastAccrualAt = uint64(block.timestamp);
        emit Deployed(vault, amount);
        return amount;
    }

    function recall(uint256 amount) external override onlyVault returns (uint256 recalled) {
        uint256 marked = totalUnderlying();
        recalled = amount > marked ? marked : amount;

        // Realize the position: ensure the adapter holds `recalled` tokens,
        // minting the accrued-yield shortfall so the transfer is fully backed.
        uint256 bal = token.balanceOf(address(this));
        uint256 minted = 0;
        if (bal < recalled) {
            minted = recalled - bal;
            IMintable(address(token)).mint(address(this), minted);
        }

        principal = marked - recalled; // remaining marked value
        lastAccrualAt = uint64(block.timestamp);

        require(token.transfer(vault, recalled), "transfer");
        emit Recalled(vault, recalled, int256(minted));
        return recalled;
    }
}
