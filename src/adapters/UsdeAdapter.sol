// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";

/// @title UsdeAdapter
/// @notice Strategy adapter that holds Ethena USDe (synthetic dollar) on behalf of an
/// AgentVault, broadening Reef's stable yield substrate beyond USDY. Yield accrues to
/// the staked form (sUSDe); this adapter holds the configured ERC-20 and reports its
/// balance as the marked underlying. Funds always move vault → adapter, and
/// `cumulativePrincipal` records deployed principal for off-chain realized-yield math.
contract UsdeAdapter is IStrategyAdapter {
    using SafeTransferLib for IERC20;

    IERC20 public immutable usde;
    address public immutable override vault;

    uint256 public cumulativePrincipal;

    event PrincipalUpdated(uint256 cumulativePrincipal);

    modifier onlyVault() {
        require(msg.sender == vault, "not vault");
        _;
    }

    constructor(address usde_, address vault_) {
        require(usde_ != address(0) && vault_ != address(0), "zero addr");
        usde = IERC20(usde_);
        vault = vault_;
    }

    function asset() external view override returns (address) {
        return address(usde);
    }

    function deploy(uint256 amount) external override onlyVault returns (uint256 deployed) {
        cumulativePrincipal += amount;
        emit Deployed(vault, amount);
        emit PrincipalUpdated(cumulativePrincipal);
        return amount;
    }

    function recall(uint256 amount) external override onlyVault returns (uint256 recalled) {
        uint256 bal = usde.balanceOf(address(this));
        recalled = amount > bal ? bal : amount;
        if (recalled > cumulativePrincipal) {
            cumulativePrincipal = 0;
        } else {
            cumulativePrincipal -= recalled;
        }
        usde.safeTransfer(vault, recalled);
        emit Recalled(vault, recalled, 0);
        emit PrincipalUpdated(cumulativePrincipal);
        return recalled;
    }

    function totalUnderlying() external view override returns (uint256) {
        return usde.balanceOf(address(this));
    }
}
