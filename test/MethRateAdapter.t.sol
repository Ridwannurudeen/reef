// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {MethRateAdapter} from "../src/adapters/MethRateAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Settable mETH->ETH rate, mirroring the Mantle LSP staking contract's mETHToETH(amount).
contract MockMethRate {
    uint256 public rate; // WAD: ETH per mETH

    constructor(uint256 rate_) {
        rate = rate_;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function mETHToETH(uint256 mETHAmount) external view returns (uint256) {
        return (mETHAmount * rate) / 1e18;
    }
}

contract MethRateAdapterTest is Test {
    AgentIdentity identity;
    AdapterRegistry registry;
    AgentVault vault;
    MethRateAdapter adapter;
    MockMethRate rate;
    MockERC20 meth; // stands in for mETH

    address operator = makeAddr("operator");
    address depositor = makeAddr("depositor");
    uint256 agentId;
    uint256 constant WAD = 1e18;

    function setUp() public {
        identity = new AgentIdentity();
        vm.prank(operator);
        agentId = identity.register();
        meth = new MockERC20();
        registry = new AdapterRegistry();
        vault = new AgentVault(address(meth), agentId, address(identity), address(registry));
        rate = new MockMethRate(WAD); // start at 1.0
        adapter = new MethRateAdapter(address(meth), address(vault), address(rate));
        registry.approveAdapter(address(adapter));
        vm.prank(operator);
        vault.approveStrategy(address(adapter));

        meth.mint(depositor, 100e18);
        vm.prank(depositor);
        meth.approve(address(vault), type(uint256).max);
    }

    function _depositAndDeploy() internal {
        vm.prank(depositor);
        vault.deposit(100e18);
        vm.prank(operator);
        vault.deployToStrategy(address(adapter), 80e18);
    }

    function test_constructor_rejectsZeroAddr() public {
        vm.expectRevert(bytes("zero addr"));
        new MethRateAdapter(address(0), address(vault), address(rate));
        vm.expectRevert(bytes("zero addr"));
        new MethRateAdapter(address(meth), address(vault), address(0));
    }

    function test_totalUnderlying_marksMethToEth() public {
        _depositAndDeploy();
        // rate 1.0: ETH mark == mETH held
        assertEq(adapter.totalUnderlying(), 80e18);
        assertEq(vault.nav(), WAD);
        assertEq(adapter.cumulativePrincipal(), 80e18); // principal stays in mETH token units
    }

    function test_navGrowsWithRate_zeroBalanceChange() public {
        _depositAndDeploy();
        uint256 balBefore = meth.balanceOf(address(adapter));

        // Real staking yield: the rate climbs ~9% while the mETH balance is unchanged.
        rate.setRate(109e16); // 1.09 ETH per mETH

        assertEq(meth.balanceOf(address(adapter)), balBefore, "mETH balance must not change");
        assertEq(adapter.totalUnderlying(), (80e18 * 109e16) / WAD); // 87.2 ETH mark
        // totalAssets = 20 idle mETH + 87.2 ETH mark = 107.2 -> nav 1.072
        assertEq(vault.nav(), (1072e17 * WAD) / 100e18);
        assertGt(vault.nav(), WAD); // NAV reflects REAL accrued yield
    }

    function test_recall_returnsMeth_cappedAtBalance() public {
        _depositAndDeploy();
        rate.setRate(110e16); // mark up; mETH held is still 80

        // Withdraw half the shares. assets is ETH-marked (> mETH available for that slice),
        // so the recall is capped at the realized mETH and the depositor is paid that — never
        // more mETH than exists. Solvency holds; the unrealized mark stays unrealized.
        vm.prank(depositor);
        uint256 got = vault.withdraw(50e18);
        assertGt(got, 0);
        assertLe(meth.balanceOf(address(vault)) + meth.balanceOf(address(adapter)), 80e18 + 20e18);
        // depositor received real mETH back
        assertEq(meth.balanceOf(depositor), got);
    }

    function test_deploy_recall_principalAccounting() public {
        _depositAndDeploy();
        assertEq(adapter.cumulativePrincipal(), 80e18);
        vm.prank(operator);
        vault.recallFromStrategy(address(adapter), 30e18);
        assertEq(adapter.cumulativePrincipal(), 50e18);
        assertEq(meth.balanceOf(address(adapter)), 50e18);
    }
}
