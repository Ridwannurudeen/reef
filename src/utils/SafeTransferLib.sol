// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @title SafeTransferLib
/// @notice Minimal SafeERC20-style wrappers. Some ERC-20s (e.g. USDT) do not return a
/// bool from transfer/transferFrom/approve; the raw typed calls would revert on the
/// return-data ABI decode even when the token op succeeded. These helpers treat
/// "call succeeded and returned either nothing or true" as success and revert otherwise,
/// so Reef works with both standard and non-standard assets.
library SafeTransferLib {
    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        _call(address(token), abi.encodeWithSelector(IERC20.transfer.selector, to, amount), "safe transfer");
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        _call(address(token), abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount), "safe transferFrom");
    }

    function safeApprove(IERC20 token, address spender, uint256 amount) internal {
        _call(address(token), abi.encodeWithSelector(IERC20.approve.selector, spender, amount), "safe approve");
    }

    function _call(address token, bytes memory data, string memory op) private {
        (bool ok, bytes memory ret) = token.call(data);
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), op);
    }
}
