// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {UsdyAdapter} from "../src/adapters/UsdyAdapter.sol";

/// @notice Fork tests against the live Ondo USDY token on Mantle mainnet.
/// Run with `forge test --match-path "test/UsdyAdapter.fork.t.sol" --fork-url $MANTLE_RPC`
/// or unconditionally — the test will spin its own fork via vm.createSelectFork.
contract UsdyAdapterForkTest is Test {
    address constant MANTLE_USDY = 0x5bE26527e817998A7206475496fDE1E68957c5A6;
    string constant MANTLE_RPC = "https://rpc.mantle.xyz";

    AgentIdentity identity;
    AgentVault vault;
    UsdyAdapter adapter;
    IERC20 usdy;

    address operator = makeAddr("operator");
    address depositor = makeAddr("depositor");
    uint256 agentId;

    function setUp() public {
        // Skip cleanly if the RPC is unreachable; CI sets MANTLE_RPC env.
        try vm.createSelectFork(MANTLE_RPC) returns (
            uint256
        ) {
        // forked successfully
        }
        catch {
            vm.skip(true);
        }
        assertEq(block.chainid, 5000, "not mantle mainnet");

        usdy = IERC20(MANTLE_USDY);
        identity = new AgentIdentity();
        vm.prank(operator);
        agentId = identity.register();
        vault = new AgentVault(MANTLE_USDY, agentId, address(identity));
        adapter = new UsdyAdapter(MANTLE_USDY, address(vault));
        vm.prank(operator);
        vault.approveStrategy(address(adapter));
    }

    function test_fork_metadata_matchesOndo() public view {
        // sanity: the token at the pinned address is the Ondo USDY we expect
        (bool ok, bytes memory data) = MANTLE_USDY.staticcall(abi.encodeWithSignature("name()"));
        require(ok, "name");
        string memory name = abi.decode(data, (string));
        assertEq(name, "Ondo U.S. Dollar Yield");
    }

    function test_fork_endToEnd_deposit_deploy_recall_withdraw() public {
        // give the depositor real USDY via foundry's storage hack
        deal(MANTLE_USDY, depositor, 100e18);
        assertEq(usdy.balanceOf(depositor), 100e18);

        vm.prank(depositor);
        usdy.approve(address(vault), type(uint256).max);

        vm.prank(depositor);
        uint256 shares = vault.deposit(100e18);
        assertEq(shares, 100e18);
        assertEq(usdy.balanceOf(address(vault)), 100e18);

        vm.prank(operator);
        vault.deployToStrategy(address(adapter), 80e18);
        assertEq(usdy.balanceOf(address(vault)), 20e18);
        assertEq(adapter.totalUnderlying(), 80e18);
        assertEq(adapter.cumulativePrincipal(), 80e18);

        // partial withdraw triggers auto-recall from adapter
        vm.prank(depositor);
        uint256 got = vault.withdraw(60e18);
        assertEq(got, 60e18);
        assertEq(usdy.balanceOf(depositor), 60e18);
    }
}
