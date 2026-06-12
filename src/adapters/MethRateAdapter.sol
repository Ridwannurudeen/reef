// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";

/// @notice The Mantle LSP rate source: how much ETH a given amount of mETH is currently worth.
/// On L1 Ethereum this is the staking contract (mETHToETH), which the bridged L2 token lacks.
interface IMethRate {
    function mETHToETH(uint256 mETHAmount) external view returns (uint256);
}

/// @title MethRateAdapter
/// @notice Strategy adapter that custodies Mantle LSP's mETH and marks it to ETH at the live
/// exchange rate. mETH is **non-rebasing** — its `balanceOf` never grows; the validator yield
/// accrues in the mETH→ETH rate. A plain balance-only adapter (see MethAdapter) therefore shows a
/// FLAT NAV. This adapter instead reports `totalUnderlying()` as the ETH mark-to-market of the held
/// mETH (`rate.mETHToETH(balance)`), so the vault's NAV reflects REAL accrued staking yield as the
/// rate climbs — verifiable against the on-chain Mantle LSP rate (mainnet-fork tested). The mark is
/// realizable by unstaking to ETH on L1; on L2 withdrawals return the held mETH (the vault pays the
/// realized amount, never the unrealized mark), so accounting stays solvent.
contract MethRateAdapter is IStrategyAdapter {
    using SafeTransferLib for IERC20;

    IERC20 public immutable meth;
    IMethRate public immutable rate;
    address public immutable override vault;

    uint256 public cumulativePrincipal; // mETH tokens deployed (token units, for realized accounting)

    event PrincipalUpdated(uint256 cumulativePrincipal);

    modifier onlyVault() {
        require(msg.sender == vault, "not vault");
        _;
    }

    constructor(address meth_, address vault_, address rate_) {
        require(meth_ != address(0) && vault_ != address(0) && rate_ != address(0), "zero addr");
        meth = IERC20(meth_);
        vault = vault_;
        rate = IMethRate(rate_);
    }

    function asset() external view override returns (address) {
        return address(meth);
    }

    function deploy(uint256 amount) external override onlyVault returns (uint256 deployed) {
        cumulativePrincipal += amount;
        emit Deployed(vault, amount);
        emit PrincipalUpdated(cumulativePrincipal);
        return amount;
    }

    function recall(uint256 amount) external override onlyVault returns (uint256 recalled) {
        uint256 bal = meth.balanceOf(address(this));
        recalled = amount > bal ? bal : amount;
        if (recalled > cumulativePrincipal) {
            cumulativePrincipal = 0;
        } else {
            cumulativePrincipal -= recalled;
        }
        meth.safeTransfer(vault, recalled);
        emit Recalled(vault, recalled, 0);
        emit PrincipalUpdated(cumulativePrincipal);
        return recalled;
    }

    /// @notice ETH mark-to-market of the held mETH at the live Mantle LSP rate. Grows with real
    /// staking yield even though the mETH balance is constant.
    function totalUnderlying() external view override returns (uint256) {
        return rate.mETHToETH(meth.balanceOf(address(this)));
    }
}
