// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";

/// @notice Minimal Uniswap-V2-style router surface (FusionX V2, Merchant Moe, etc.).
interface IV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory);
}

/// @title FusionXAdapter
/// @notice Real DEX strategy adapter: deploys the vault's `asset` into a market
/// position (`longToken`) via a Uniswap-V2-style router (FusionX V2 on Mantle), so the
/// vault's NAV is the live mark-to-market value of that position — real on-chain exposure,
/// not simulated yield. `deploy` swaps asset→long; `recall` sells just enough long→asset to
/// hand the vault the exact amount it asked for (slippage shrinks the marked position, never
/// breaks vault accounting); `totalUnderlying` marks the held long back to asset via the
/// router quote. Funds only ever move vault↔adapter↔DEX, never to the operator.
/// @dev Intended for deep pools (Mantle mainnet). Testnet pools are thin (high slippage), so
/// the immutable Sepolia demo uses MockYieldAdapter; this ships fork/unit-tested for mainnet.
contract FusionXAdapter is IStrategyAdapter {
    using SafeTransferLib for IERC20;

    IERC20 public immutable assetToken;
    IERC20 public immutable longToken;
    IV2Router public immutable router;
    address public immutable override vault;
    uint256 public immutable maxSlippageBps;

    modifier onlyVault() {
        require(msg.sender == vault, "not vault");
        _;
    }

    constructor(address asset_, address long_, address router_, address vault_, uint256 maxSlippageBps_) {
        require(
            asset_ != address(0) && long_ != address(0) && router_ != address(0) && vault_ != address(0), "zero addr"
        );
        require(maxSlippageBps_ <= 5000, "slippage too high");
        assetToken = IERC20(asset_);
        longToken = IERC20(long_);
        router = IV2Router(router_);
        vault = vault_;
        maxSlippageBps = maxSlippageBps_;
    }

    function asset() external view override returns (address) {
        return address(assetToken);
    }

    /// @notice The vault has already transferred `amount` asset here; swap it into the long.
    function deploy(uint256 amount) external override onlyVault returns (uint256 deployed) {
        address[] memory path = _path(address(assetToken), address(longToken));
        uint256 expected = router.getAmountsOut(amount, path)[1];
        uint256 minOut = (expected * (10_000 - maxSlippageBps)) / 10_000;
        assetToken.safeApprove(address(router), amount);
        router.swapExactTokensForTokens(amount, minOut, path, address(this), block.timestamp);
        emit Deployed(vault, amount);
        return amount;
    }

    /// @notice Sell enough long to return exactly `amount` asset to the vault (capped at the
    /// position's value). Excess from rounding stays as idle asset, marked by totalUnderlying.
    function recall(uint256 amount) external override onlyVault returns (uint256 recalled) {
        uint256 idle = assetToken.balanceOf(address(this));
        if (idle < amount) {
            uint256 shortfall = amount - idle;
            address[] memory path = _path(address(longToken), address(assetToken));
            uint256 longBal = longToken.balanceOf(address(this));
            uint256 needLong = router.getAmountsIn(shortfall, path)[0];
            uint256 sell = needLong > longBal ? longBal : needLong;
            if (sell > 0) {
                longToken.safeApprove(address(router), sell);
                router.swapExactTokensForTokens(sell, 0, path, address(this), block.timestamp);
            }
        }
        uint256 bal = assetToken.balanceOf(address(this));
        recalled = bal < amount ? bal : amount;
        assetToken.safeTransfer(vault, recalled);
        emit Recalled(vault, recalled, 0);
        return recalled;
    }

    /// @notice Mark-to-market in asset terms: idle asset + the held long quoted back to asset.
    function totalUnderlying() external view override returns (uint256) {
        uint256 idle = assetToken.balanceOf(address(this));
        uint256 longBal = longToken.balanceOf(address(this));
        if (longBal == 0) return idle;
        return idle + router.getAmountsOut(longBal, _path(address(longToken), address(assetToken)))[1];
    }

    function _path(address a, address b) private pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }
}
