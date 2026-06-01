// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";

/// @title Mi4Adapter
/// @notice Strategy adapter that holds Mantle Index Four (MI4) — the Securitize-
/// tokenized institutional basket (BTC/ETH/SOL/stables) on Mantle — on behalf of an
/// AgentVault, extending Reef's substrate to a regulated multi-asset RWA index. Like
/// the other adapters it is a vault-only holder routed through SafeTransferLib, and
/// `cumulativePrincipal` records deployed principal for off-chain realized-yield math.
contract Mi4Adapter is IStrategyAdapter {
    using SafeTransferLib for IERC20;

    IERC20 public immutable mi4;
    address public immutable override vault;

    uint256 public cumulativePrincipal;

    event PrincipalUpdated(uint256 cumulativePrincipal);

    modifier onlyVault() {
        require(msg.sender == vault, "not vault");
        _;
    }

    constructor(address mi4_, address vault_) {
        require(mi4_ != address(0) && vault_ != address(0), "zero addr");
        mi4 = IERC20(mi4_);
        vault = vault_;
    }

    function asset() external view override returns (address) {
        return address(mi4);
    }

    function deploy(uint256 amount) external override onlyVault returns (uint256 deployed) {
        cumulativePrincipal += amount;
        emit Deployed(vault, amount);
        emit PrincipalUpdated(cumulativePrincipal);
        return amount;
    }

    function recall(uint256 amount) external override onlyVault returns (uint256 recalled) {
        uint256 bal = mi4.balanceOf(address(this));
        recalled = amount > bal ? bal : amount;
        if (recalled > cumulativePrincipal) {
            cumulativePrincipal = 0;
        } else {
            cumulativePrincipal -= recalled;
        }
        mi4.safeTransfer(vault, recalled);
        emit Recalled(vault, recalled, 0);
        emit PrincipalUpdated(cumulativePrincipal);
        return recalled;
    }

    function totalUnderlying() external view override returns (uint256) {
        return mi4.balanceOf(address(this));
    }
}
