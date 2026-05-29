// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IStrategyAdapter} from "../../src/interfaces/IStrategyAdapter.sol";

/// @notice Test adapter that holds the asset 1:1. `accrue(amount)` lets a test
/// simulate yield by minting extra balance.
contract MockStrategyAdapter is IStrategyAdapter {
    IERC20 public immutable token;
    address public immutable override vault;

    constructor(address token_, address vault_) {
        token = IERC20(token_);
        vault = vault_;
    }

    function asset() external view override returns (address) {
        return address(token);
    }

    function deploy(uint256 amount) external override returns (uint256 deployed) {
        require(msg.sender == vault, "not vault");
        emit Deployed(vault, amount);
        return amount;
    }

    function recall(uint256 amount) external override returns (uint256 recalled) {
        require(msg.sender == vault, "not vault");
        require(token.transfer(vault, amount), "transfer");
        emit Recalled(vault, amount, 0);
        return amount;
    }

    function totalUnderlying() external view override returns (uint256) {
        return token.balanceOf(address(this));
    }
}
