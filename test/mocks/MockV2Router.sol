// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice Deterministic Uniswap-V2-style router for tests: a settable price between a
/// fixed (tokenA, tokenB) pair, zero fee, so adapter deploy/mark/recall math is exact and
/// market moves can be simulated with setPrice. Must be funded with both tokens to pay swaps.
contract MockV2Router {
    address public immutable tokenA;
    address public immutable tokenB;
    uint256 public pxBperA; // WAD: units of B per 1 A

    constructor(address a, address b, uint256 pxBperA_) {
        tokenA = a;
        tokenB = b;
        pxBperA = pxBperA_;
    }

    function setPrice(uint256 pxBperA_) external {
        pxBperA = pxBperA_;
    }

    function _out(uint256 amtIn, address inTok, address outTok) internal view returns (uint256) {
        if (inTok == tokenA && outTok == tokenB) return (amtIn * pxBperA) / 1e18;
        if (inTok == tokenB && outTok == tokenA) return (amtIn * 1e18) / pxBperA;
        revert("bad path");
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory a) {
        a = new uint256[](2);
        a[0] = amountIn;
        a[1] = _out(amountIn, path[0], path[1]);
    }

    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory a) {
        a = new uint256[](2);
        // invert _out: amountIn needed to get amountOut of path[1]
        if (path[0] == tokenA && path[1] == tokenB) a[0] = (amountOut * 1e18) / pxBperA;
        else if (path[0] == tokenB && path[1] == tokenA) a[0] = (amountOut * pxBperA) / 1e18;
        else revert("bad path");
        a[1] = amountOut;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /*deadline*/
    ) external returns (uint256[] memory a) {
        uint256 out = _out(amountIn, path[0], path[1]);
        require(out >= amountOutMin, "slippage");
        require(IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn), "in");
        require(IERC20(path[1]).transfer(to, out), "out");
        a = new uint256[](2);
        a[0] = amountIn;
        a[1] = out;
    }
}
