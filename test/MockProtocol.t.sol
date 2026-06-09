// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ReefGuard} from "../src/ReefGuard.sol";
import {MockProtocol} from "../src/MockProtocol.sol";

contract MockIdentity {
    uint256 public nextAgentId = 3; // agents 1,2 registered

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

/// @notice Proves the external-integration shape: a protocol calls ReefGuard before letting an
/// agent act, and the policy reason propagates as the revert reason.
contract MockProtocolTest is Test {
    ReefGuard guard;
    MockIdentity ident;
    MockBond bnd;
    MockProtocol proto;
    address asset = address(0xA55E7);

    event ActionExecuted(uint256 indexed agentId, address indexed asset, uint256 sizeBps, uint256 amount);

    function setUp() public {
        ident = new MockIdentity();
        bnd = new MockBond();
        guard = new ReefGuard(address(ident), address(bnd), address(this), int256(1e18), 50e18, 8000);
        guard.setAssetAllowed(asset, true);
        ident.setRep(1, int256(2e18)); // agent 1 in good standing
        bnd.setBond(1, 50e18);
        proto = new MockProtocol(address(guard));
    }

    function test_clearedAgent_executes() public {
        vm.expectEmit(true, true, false, true);
        emit ActionExecuted(1, asset, 5000, 100e18);
        uint256 out = proto.executeAgentAction(1, asset, 5000, 100e18);
        assertEq(out, 100e18);
    }

    function test_unregisteredAgent_reverts() public {
        vm.expectRevert(bytes("agent not registered"));
        proto.executeAgentAction(9, asset, 5000, 100e18);
    }

    function test_oversize_reverts() public {
        vm.expectRevert(bytes("action size over limit"));
        proto.executeAgentAction(1, asset, 9000, 100e18);
    }

    function test_disallowedAsset_reverts() public {
        vm.expectRevert(bytes("asset not allowlisted"));
        proto.executeAgentAction(1, address(0xBEEF), 5000, 100e18);
    }

    function test_insufficientBond_reverts() public {
        bnd.setBond(1, 10e18);
        vm.expectRevert(bytes("insufficient bond"));
        proto.executeAgentAction(1, asset, 5000, 100e18);
    }

    function test_underDispute_reverts() public {
        bnd.setDisputes(1, 1);
        vm.expectRevert(bytes("agent under dispute"));
        proto.executeAgentAction(1, asset, 5000, 100e18);
    }

    function test_check_isReadOnlyPreview() public view {
        (bool ok, string memory reason) = proto.check(1, asset, 5000);
        assertTrue(ok);
        assertEq(reason, "ok");
        (bool bad, string memory r2) = proto.check(1, asset, 9000);
        assertFalse(bad);
        assertEq(r2, "action size over limit");
    }
}
