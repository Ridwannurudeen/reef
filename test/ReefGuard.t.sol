// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ReefGuard} from "../src/ReefGuard.sol";

contract MockIdentity {
    uint256 public nextAgentId = 3; // agents 1,2 registered

    mapping(uint256 => int256) public repOf;

    function setRep(uint256 id, int256 r) external {
        repOf[id] = r;
    }

    function setNext(uint256 n) external {
        nextAgentId = n;
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

contract ReefGuardTest is Test {
    ReefGuard guard;
    MockIdentity ident;
    MockBond bnd;
    address asset = address(0xA55E7);

    function setUp() public {
        ident = new MockIdentity();
        bnd = new MockBond();
        guard = new ReefGuard(address(ident), address(bnd), address(this), int256(1e18), 50e18, 8000);
        guard.setAssetAllowed(asset, true);
        // agent 1 in good standing
        ident.setRep(1, int256(2e18));
        bnd.setBond(1, 50e18);
    }

    function _check(uint256 id, address a, uint256 bps) internal view returns (bool, string memory) {
        return guard.canExecute(id, a, bps);
    }

    function test_happyPath() public view {
        (bool ok, string memory r) = _check(1, asset, 5000);
        assertTrue(ok);
        assertEq(r, "ok");
    }

    function test_notRegistered() public view {
        (bool ok, string memory r) = _check(9, asset, 5000);
        assertFalse(ok);
        assertEq(r, "agent not registered");
    }

    function test_sizeOverLimit() public view {
        (bool ok, string memory r) = _check(1, asset, 9000);
        assertFalse(ok);
        assertEq(r, "action size over limit");
    }

    function test_assetNotAllowed() public view {
        (bool ok, string memory r) = _check(1, address(0xBEEF), 5000);
        assertFalse(ok);
        assertEq(r, "asset not allowlisted");
    }

    function test_insufficientBond() public {
        bnd.setBond(1, 10e18);
        (bool ok, string memory r) = _check(1, asset, 5000);
        assertFalse(ok);
        assertEq(r, "insufficient bond");
    }

    function test_underDispute() public {
        bnd.setDisputes(1, 1);
        (bool ok, string memory r) = _check(1, asset, 5000);
        assertFalse(ok);
        assertEq(r, "agent under dispute");
    }

    function test_reputationBelowThreshold() public {
        ident.setRep(1, int256(0));
        (bool ok, string memory r) = _check(1, asset, 5000);
        assertFalse(ok);
        assertEq(r, "reputation below threshold");
    }

    function test_onlyGovernor() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes("not governor"));
        guard.setPolicy(0, 0, 1000);
    }

    function test_governorCanRetune() public {
        guard.setPolicy(int256(5e18), 100e18, 2000);
        // now agent 1 (rep 2e18, bond 50e18) fails the raised reputation bar
        (bool ok, string memory r) = _check(1, asset, 1000);
        assertFalse(ok);
        assertEq(r, "insufficient bond"); // bond check precedes reputation; 50e18 < 100e18
    }
}
