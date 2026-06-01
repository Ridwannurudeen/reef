// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";

/// @title FbtcAdapter
/// @notice Strategy adapter that holds Ignition FBTC (non-rebasing wrapped BTC) on
/// behalf of an AgentVault, broadening Reef's RWA/yield substrate beyond USDY/mETH.
/// Like the other adapters, funds always move vault → adapter (never to the operator),
/// and `cumulativePrincipal` records deployed principal so realized yield can be
/// computed off-chain as (recall_value − reduction_in_cumulativePrincipal).
contract FbtcAdapter is IStrategyAdapter {
    using SafeTransferLib for IERC20;

    IERC20 public immutable fbtc;
    address public immutable override vault;

    uint256 public cumulativePrincipal;

    event PrincipalUpdated(uint256 cumulativePrincipal);

    modifier onlyVault() {
        require(msg.sender == vault, "not vault");
        _;
    }

    constructor(address fbtc_, address vault_) {
        require(fbtc_ != address(0) && vault_ != address(0), "zero addr");
        fbtc = IERC20(fbtc_);
        vault = vault_;
    }

    function asset() external view override returns (address) {
        return address(fbtc);
    }

    function deploy(uint256 amount) external override onlyVault returns (uint256 deployed) {
        cumulativePrincipal += amount;
        emit Deployed(vault, amount);
        emit PrincipalUpdated(cumulativePrincipal);
        return amount;
    }

    function recall(uint256 amount) external override onlyVault returns (uint256 recalled) {
        uint256 bal = fbtc.balanceOf(address(this));
        recalled = amount > bal ? bal : amount;
        if (recalled > cumulativePrincipal) {
            cumulativePrincipal = 0;
        } else {
            cumulativePrincipal -= recalled;
        }
        fbtc.safeTransfer(vault, recalled);
        emit Recalled(vault, recalled, 0);
        emit PrincipalUpdated(cumulativePrincipal);
        return recalled;
    }

    function totalUnderlying() external view override returns (uint256) {
        return fbtc.balanceOf(address(this));
    }
}
