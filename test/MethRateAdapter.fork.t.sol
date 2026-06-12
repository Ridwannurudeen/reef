// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {MethRateAdapter, IMethRate} from "../src/adapters/MethRateAdapter.sol";

/// @notice Fork test against the LIVE Mantle LSP mETH on L1 Ethereum. mETH is non-rebasing — its
/// value accrues in the mETH->ETH exchange rate, which lives on L1 (the bridged L2 token has no
/// rate function). This proves the rate-aware adapter captures REAL staking yield: a held mETH
/// balance marks to MORE ETH than its nominal because the live on-chain rate is > 1.
/// Run: forge test --match-path "test/MethRateAdapter.fork.t.sol" (self-forks via createSelectFork;
/// override the endpoint with ETHEREUM_RPC=<archive rpc> if the default public node is rate-limited).
contract MethRateAdapterForkTest is Test {
    // L1 Ethereum (chain 1)
    address constant L1_METH = 0xd5F7838F5C461fefF7FE49ea5ebaF7728bB0ADfa;
    address constant L1_METH_RATE = 0xe3cBd06D7dadB3F4e6557bAb7EdD924CD1489E8f; // Mantle LSP staking

    AgentIdentity identity;
    AgentVault vault;
    MethRateAdapter adapter;
    IERC20 meth;

    address operator = makeAddr("operator");
    address depositor = makeAddr("depositor");
    uint256 agentId;

    function setUp() public {
        // Opt-in: set ETHEREUM_RPC to a reliable archive endpoint to run this against live state.
        // Skips cleanly by default (and in CI) — public ETH RPCs rate-limit forge's fork state
        // reads, and an RPC-induced gas burn isn't try/catch-recoverable, so we gate explicitly
        // rather than risk a flaky failure. The live rate is also asserted here when enabled.
        string memory rpc = vm.envOr("ETHEREUM_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        try vm.createSelectFork(rpc) returns (uint256) {}
        catch {
            vm.skip(true);
            return;
        }
        assertEq(block.chainid, 1, "not ethereum mainnet");

        meth = IERC20(L1_METH);
        identity = new AgentIdentity();
        vm.prank(operator);
        agentId = identity.register();
        AdapterRegistry registry = new AdapterRegistry();
        vault = new AgentVault(L1_METH, agentId, address(identity), address(registry));
        adapter = new MethRateAdapter(L1_METH, address(vault), L1_METH_RATE);
        registry.approveAdapter(address(adapter));
        vm.prank(operator);
        vault.approveStrategy(address(adapter));
    }

    function test_fork_realRateShowsAccruedYield() public view {
        // The live Mantle LSP rate: 1 mETH is worth > 1 ETH (validator yield accrued).
        uint256 rate = IMethRate(L1_METH_RATE).mETHToETH(1e18);
        assertGt(rate, 1e18, "mETH should be worth more than 1 ETH (accrued yield)");
        assertLt(rate, 2e18, "rate sanity");
    }

    function test_fork_adapterMarksRealMethToEth() public {
        // Give the live adapter a real mETH balance, then assert it marks that balance to MORE ETH
        // than its nominal at the LIVE on-chain rate — i.e. it captures real staking yield that a
        // balance-only adapter would miss. (The full vault deposit/withdraw flow is covered by the
        // mock-rate unit tests; here we validate the mark against the real rate with light reads.)
        deal(L1_METH, address(adapter), 8e18);
        uint256 bal = meth.balanceOf(address(adapter));
        assertEq(bal, 8e18, "deal mETH to adapter");

        uint256 marked = adapter.totalUnderlying();
        assertEq(marked, IMethRate(L1_METH_RATE).mETHToETH(bal));
        assertGt(marked, bal, "ETH mark exceeds nominal mETH -> real yield captured");
    }
}
