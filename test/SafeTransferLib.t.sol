// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {NoReturnERC20} from "./mocks/NoReturnERC20.sol";

/// @notice Proves Reef works with USDT-style tokens that return no bool from
/// transfer/transferFrom — the SafeTransferLib (#7) path. A raw typed IERC20 call
/// would revert on the empty return-data decode.
contract SafeTransferLibTest is Test {
    AgentIdentity identity;
    AgentVault vault;
    NoReturnERC20 token;
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");
    uint256 agentId;

    function setUp() public {
        identity = new AgentIdentity();
        token = new NoReturnERC20();
        AdapterRegistry registry = new AdapterRegistry();

        vm.prank(operator);
        agentId = identity.register();
        vault = new AgentVault(address(token), agentId, address(identity), address(registry));

        token.mint(alice, 1_000e18);
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
    }

    function test_depositAndWithdraw_withNonBoolToken() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(100e18);
        assertEq(shares, 100e18);
        assertEq(token.balanceOf(address(vault)), 100e18);

        vm.prank(alice);
        uint256 got = vault.withdraw(100e18);
        assertEq(got, 100e18);
        assertEq(token.balanceOf(alice), 1_000e18);
    }
}
