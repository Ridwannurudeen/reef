// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";

/// @title UsdyAdapter
/// @notice Strategy adapter that holds Ondo USDY (non-rebasing ERC-20) on behalf of
/// an AgentVault. Yield accrues via USDY's off-chain price oracle (Ondo publishes
/// the USD value daily). Mainnet USDY token: 0x5bE26527e817998A7206475496fDE1E68957c5A6.
///
/// The adapter is permissioned (vault-only) and records the cumulative principal
/// the vault has deployed, so that realized yield can be recomputed at recall time
/// off-chain as (recall_value - principal_at_recall).
contract UsdyAdapter is IStrategyAdapter {
    IERC20 public immutable usdy;
    address public immutable override vault;

    /// @dev Sum of all `amount`s passed through deploy(); decremented on recall.
    /// Lets off-chain observers compute realized yield as
    ///   yield = recalled_value - reduction_in_cumulativePrincipal.
    uint256 public cumulativePrincipal;

    event PrincipalUpdated(uint256 cumulativePrincipal);

    modifier onlyVault() {
        require(msg.sender == vault, "not vault");
        _;
    }

    constructor(address usdy_, address vault_) {
        require(usdy_ != address(0) && vault_ != address(0), "zero addr");
        usdy = IERC20(usdy_);
        vault = vault_;
    }

    function asset() external view override returns (address) {
        return address(usdy);
    }

    /// @notice Acknowledge a deposit. The vault has already transferred `amount`
    /// of USDY to this contract before calling.
    function deploy(uint256 amount) external override onlyVault returns (uint256 deployed) {
        cumulativePrincipal += amount;
        emit Deployed(vault, amount);
        emit PrincipalUpdated(cumulativePrincipal);
        return amount;
    }

    /// @notice Return `amount` USDY to the vault. Caller may request more than the
    /// nominal principal — the adapter will return up to its current balance, since
    /// non-rebasing USDY does not show yield in `balanceOf`.
    function recall(uint256 amount) external override onlyVault returns (uint256 recalled) {
        uint256 bal = usdy.balanceOf(address(this));
        recalled = amount > bal ? bal : amount;
        if (recalled > cumulativePrincipal) {
            cumulativePrincipal = 0;
        } else {
            cumulativePrincipal -= recalled;
        }
        require(usdy.transfer(vault, recalled), "transfer");
        emit Recalled(vault, recalled, 0);
        emit PrincipalUpdated(cumulativePrincipal);
        return recalled;
    }

    function totalUnderlying() external view override returns (uint256) {
        return usdy.balanceOf(address(this));
    }
}
