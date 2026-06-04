// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IStrategyAdapter} from "../../src/interfaces/IStrategyAdapter.sol";

/// @notice Test adapter that holds the asset 1:1. `accrue(amount)` lets a test
/// simulate yield by minting extra balance.
contract MockStrategyAdapter is IStrategyAdapter {
    IERC20 public immutable token;
    address public immutable override vault;
    uint256 public recallHaircutBps; // default 0; >0 simulates an adapter realizing less than asked

    constructor(address token_, address vault_) {
        token = IERC20(token_);
        vault = vault_;
    }

    function setRecallHaircutBps(uint256 bps) external {
        recallHaircutBps = bps;
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
        recalled = (amount * (10_000 - recallHaircutBps)) / 10_000;
        require(token.transfer(vault, recalled), "transfer");
        emit Recalled(vault, recalled, 0);
    }

    function totalUnderlying() external view override returns (uint256) {
        return token.balanceOf(address(this));
    }
}
