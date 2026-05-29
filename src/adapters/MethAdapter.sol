// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";

/// @title MethAdapter
/// @notice Strategy adapter that holds Mantle LSP's mETH (bridged ERC-20) on
/// behalf of an AgentVault. Staking is on L1 Ethereum; on Mantle the bridged
/// token appreciates as the underlying validator yield accrues. Mainnet mETH
/// token on Mantle: 0xcDA86A272531e8640cD7F1a92c01839911B90bb0.
contract MethAdapter is IStrategyAdapter {
    IERC20 public immutable meth;
    address public immutable override vault;

    uint256 public cumulativePrincipal;

    event PrincipalUpdated(uint256 cumulativePrincipal);

    modifier onlyVault() {
        require(msg.sender == vault, "not vault");
        _;
    }

    constructor(address meth_, address vault_) {
        require(meth_ != address(0) && vault_ != address(0), "zero addr");
        meth = IERC20(meth_);
        vault = vault_;
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
        require(meth.transfer(vault, recalled), "transfer");
        emit Recalled(vault, recalled, 0);
        emit PrincipalUpdated(cumulativePrincipal);
        return recalled;
    }

    function totalUnderlying() external view override returns (uint256) {
        return meth.balanceOf(address(this));
    }
}
