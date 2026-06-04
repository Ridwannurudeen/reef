// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {FusionXAdapter} from "../src/adapters/FusionXAdapter.sol";

/// @notice Fork tests for FusionXAdapter against the LIVE FusionX V2 router and the real
/// USDC/WMNT pool on Mantle mainnet — exercising the deploy -> mark-to-market -> recall loop
/// over real reserves, fees (0.3%) and price impact, not the deterministic mock AMM.
/// Run with `forge test --match-path "test/FusionXAdapter.fork.t.sol" --fork-url $MANTLE_RPC`
/// or unconditionally — the test spins its own fork via vm.createSelectFork.
contract FusionXAdapterForkTest is Test {
    // Verified live on Mantle mainnet (chain 5000) 2026-06-04.
    address constant ROUTER = 0xDd0840118bF9CCCc6d67b2944ddDfbdb995955FD; // FusionX V2 router
    address constant FACTORY = 0xE5020961fA51ffd3662CDf307dEf18F9a87Cce7c;
    address constant USDC = 0x09Bc4E0D864854c6aFB6eB9A9cdF58aC190D0dF9; // 6 decimals (vault asset)
    address constant WMNT = 0x78c1b0C915c4FAA5FffA6CAbf0219DA63d7f4cb8; // 18 decimals (long)
    string constant MANTLE_RPC = "https://rpc.mantle.xyz";

    AgentIdentity identity;
    AgentVault vault;
    FusionXAdapter adapter;
    IERC20 usdc;

    address operator = makeAddr("operator");
    address depositor = makeAddr("depositor");
    uint256 agentId;

    function setUp() public {
        // Skip cleanly if the RPC is unreachable; CI sets MANTLE_RPC env.
        try vm.createSelectFork(MANTLE_RPC) returns (uint256) {}
        catch {
            vm.skip(true);
        }
        assertEq(block.chainid, 5000, "not mantle mainnet");

        usdc = IERC20(USDC);
        identity = new AgentIdentity();
        vm.prank(operator);
        agentId = identity.register();
        AdapterRegistry registry = new AdapterRegistry();
        vault = new AgentVault(USDC, agentId, address(identity), address(registry));
        adapter = new FusionXAdapter(USDC, WMNT, ROUTER, address(vault), 300);
        registry.approveAdapter(address(adapter));
        vm.prank(operator);
        vault.approveStrategy(address(adapter));
    }

    function test_fork_routerWiredToLivePool() public view {
        (bool ok, bytes memory data) = ROUTER.staticcall(abi.encodeWithSignature("factory()"));
        require(ok, "factory");
        assertEq(abi.decode(data, (address)), FACTORY, "unexpected factory");
        // The USDC/WMNT pool is live and quotes a non-zero price.
        address[] memory path = new address[](2);
        path[0] = WMNT;
        path[1] = USDC;
        (bool ok2, bytes memory q) =
            ROUTER.staticcall(abi.encodeWithSignature("getAmountsOut(uint256,address[])", 1e18, path));
        require(ok2, "quote");
        uint256[] memory amounts = abi.decode(q, (uint256[]));
        assertGt(amounts[1], 0, "dead pool");
    }

    function test_fork_endToEnd_realDexPosition() public {
        // Fund the depositor with real USDC via foundry's storage hack.
        deal(USDC, depositor, 1_000e6);
        assertEq(usdc.balanceOf(depositor), 1_000e6, "deal failed");

        vm.prank(depositor);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(depositor);
        uint256 shares = vault.deposit(1_000e6);
        assertEq(shares, 1_000e6); // 1:1 at nav 1.0
        assertEq(vault.nav(), 1e18);

        // Deploy 80% into the live WMNT position; keep a 20% idle buffer.
        vm.prank(operator);
        vault.deployToStrategy(address(adapter), 800e6);
        assertEq(usdc.balanceOf(address(vault)), 200e6, "idle buffer");
        assertEq(usdc.balanceOf(address(adapter)), 0, "all asset swapped");
        assertGt(IERC20(WMNT).balanceOf(address(adapter)), 0, "no WMNT acquired");
        // Marked back to USDC, the position is worth ~800 minus round-trip fee/impact (<3%).
        assertApproxEqRel(adapter.totalUnderlying(), 800e6, 0.03e18, "position mark");
        assertApproxEqRel(vault.totalAssets(), 1_000e6, 0.03e18, "total assets");

        // Withdraw half the shares -> needs more than the idle buffer -> partial recall (sells
        // just enough WMNT to honor the exact payout, well within the position).
        uint256 nav = vault.nav();
        uint256 expectAssets = (500e6 * (vault.totalAssets() + 1)) / (vault.totalShares() + 1);
        uint256 before = usdc.balanceOf(depositor);
        vm.prank(depositor);
        uint256 got = vault.withdraw(500e6);

        assertEq(got, expectAssets, "payout != nav-priced assets");
        assertEq(usdc.balanceOf(depositor) - before, got, "depositor underpaid");
        assertApproxEqRel(got, 497e6, 0.03e18, "payout magnitude"); // ~500 * nav(~0.99)
        assertLt(nav, 1e18); // nav dipped from the round-trip fee, as expected
        assertEq(vault.balanceOf(depositor), 500e6, "shares burned");
        // A live position still backs the remaining shares.
        assertGt(adapter.totalUnderlying(), 0, "position drained");

        // Full drain on the live pool: withdraw the remaining shares -> recall sells the whole
        // position. Asserts the vault exits cleanly (no overdraw) when the position is realized
        // in full against real reserves/fees.
        uint256 before2 = usdc.balanceOf(depositor);
        vm.prank(depositor);
        uint256 got2 = vault.withdraw(500e6);
        assertEq(usdc.balanceOf(depositor) - before2, got2, "drain payout mismatch");
        assertEq(vault.totalShares(), 0, "shares not fully burned");
        assertEq(usdc.balanceOf(address(vault)), 0, "vault overdrew");
    }
}
