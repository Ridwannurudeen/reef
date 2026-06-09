// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ReefGuard} from "../src/ReefGuard.sol";
import {ReefGuarded} from "../src/ReefGuarded.sol";

contract MockIdentity {
    uint256 public nextAgentId = 3;

    mapping(uint256 => int256) public repOf;

    function setRep(uint256 id, int256 r) external {
        repOf[id] = r;
    }

    function getSummary(uint256 agentId) external view returns (int256, uint256) {
        return (repOf[agentId], 0);
    }
}

contract MockBond {
    mapping(uint256 => uint256) public bondOf;
    mapping(uint256 => uint256) public activeDisputes;

    function setBond(uint256 id, uint256 b) external {
        bondOf[id] = b;
    }

    function setDisputes(uint256 id, uint256 d) external {
        activeDisputes[id] = d;
    }
}

/// @dev A minimal protocol that integrates the gate purely via the `onlyCleared` modifier —
/// exercises the inheritable helper exactly as a real protocol would.
contract GuardedExample is ReefGuarded {
    uint256 public lastAmount;

    constructor(address guard_) ReefGuarded(guard_) {}

    function act(uint256 agentId, address asset, uint256 sizeBps, uint256 amount)
        external
        onlyCleared(agentId, asset, sizeBps)
        returns (uint256)
    {
        lastAmount = amount;
        return amount;
    }
}

contract ReefGuardedTest is Test {
    ReefGuard guard;
    MockIdentity ident;
    MockBond bnd;
    GuardedExample ex;
    address asset = address(0xA55E7);

    function setUp() public {
        ident = new MockIdentity();
        bnd = new MockBond();
        guard = new ReefGuard(address(ident), address(bnd), address(this), int256(1e18), 50e18, 8000);
        guard.setAssetAllowed(asset, true);
        ident.setRep(1, int256(2e18));
        bnd.setBond(1, 50e18);
        ex = new GuardedExample(address(guard));
    }

    function test_modifier_allowsClearedAgent() public {
        uint256 out = ex.act(1, asset, 5000, 123);
        assertEq(out, 123);
        assertEq(ex.lastAmount(), 123);
    }

    function test_modifier_revertsWithPolicyReason() public {
        vm.expectRevert(bytes("action size over limit"));
        ex.act(1, asset, 9000, 123);

        bnd.setBond(1, 1e18);
        vm.expectRevert(bytes("insufficient bond"));
        ex.act(1, asset, 5000, 123);

        // state untouched after reverts
        assertEq(ex.lastAmount(), 0);
    }

    function test_reefCheck_preview() public view {
        (bool ok, string memory r) = ex.reefCheck(1, asset, 5000);
        assertTrue(ok);
        assertEq(r, "ok");
        (bool bad, string memory r2) = ex.reefCheck(9, asset, 5000);
        assertFalse(bad);
        assertEq(r2, "agent not registered");
    }

    function test_reefGuardAddress_wired() public view {
        assertEq(address(ex.reefGuard()), address(guard));
    }

    function test_constructor_rejectsZeroGuard() public {
        vm.expectRevert(bytes("zero guard"));
        new GuardedExample(address(0));
    }
}
