// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentVault} from "../../src/AgentVault.sol";
import {AgentIdentity} from "../../src/AgentIdentity.sol";
import {AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Drives a fixed depositor set through fuzzed deposit/withdraw cycles plus raw
/// asset donations — the donation is the first-depositor inflation-attack vector the
/// virtual-offset share math defends against. No strategy is wired, so the vault holds all
/// assets idle and `totalAssets()` is just its token balance.
contract VaultHandler is Test {
    AgentVault public vault;
    MockERC20 public asset;
    address[4] public actors;

    constructor(AgentVault vault_, MockERC20 asset_, address[4] memory actors_) {
        vault = vault_;
        asset = asset_;
        actors = actors_;
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address a = actors[actorSeed % 4];
        amount = bound(amount, 1, 1_000_000e18);
        asset.mint(a, amount);
        vm.startPrank(a);
        asset.approve(address(vault), amount);
        // A deposit smaller than the current per-share price rounds to zero shares and reverts; skip.
        if ((amount * (vault.totalShares() + 1)) / (vault.totalAssets() + 1) == 0) {
            vm.stopPrank();
            return;
        }
        vault.deposit(amount);
        vm.stopPrank();
    }

    function withdraw(uint256 actorSeed, uint256 shareSeed) external {
        address a = actors[actorSeed % 4];
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        uint256 shares = bound(shareSeed, 1, bal);
        vm.prank(a);
        vault.withdraw(shares);
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000e18);
        asset.mint(address(vault), amount);
    }
}

/// @notice Invariants for the vault's share accounting:
/// 1. Shares are conserved — the sum of holder balances equals totalShares.
/// 2. The vault is always solvent — it holds enough idle asset to pay every holder's full
///    redemption at once (so the virtual-offset rounding never lets claims exceed assets,
///    even after donation-based inflation attempts).
contract AgentVaultInvariantTest is Test {
    AgentVault vault;
    MockERC20 asset;
    AgentIdentity identity;
    AdapterRegistry registry;
    VaultHandler handler;
    address[4] actors;

    function setUp() public {
        asset = new MockERC20();
        identity = new AgentIdentity();
        registry = new AdapterRegistry();
        vm.prank(makeAddr("operator"));
        uint256 agentId = identity.register();
        vault = new AgentVault(address(asset), agentId, address(identity), address(registry));

        actors = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol"), makeAddr("dave")];
        handler = new VaultHandler(vault, asset, actors);
        targetContract(address(handler));
    }

    function invariant_sharesConserved() public view {
        uint256 sum;
        for (uint256 i = 0; i < 4; i++) {
            sum += vault.balanceOf(actors[i]);
        }
        assertEq(sum, vault.totalShares(), "share supply mismatch");
    }

    function invariant_solvent() public view {
        uint256 ts = vault.totalShares();
        uint256 ta = vault.totalAssets();
        uint256 owed;
        for (uint256 i = 0; i < 4; i++) {
            owed += (vault.balanceOf(actors[i]) * (ta + 1)) / (ts + 1);
        }
        assertLe(owed, asset.balanceOf(address(vault)), "vault cannot cover all redemptions");
    }
}
