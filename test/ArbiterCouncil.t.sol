// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ArbiterCouncil} from "../src/ArbiterCouncil.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {ReputationBond} from "../src/ReputationBond.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Records the last call it received, so a test can assert the council executed
/// with the exact target and calldata.
contract MockTarget {
    uint256 public calls;
    bytes public lastData;
    uint256 public lastValue;

    function record(uint256 value) external {
        calls += 1;
        lastValue = value;
        lastData = msg.data;
    }
}

/// @notice Always reverts, to exercise the "call failed" path.
contract RevertingTarget {
    function boom() external pure {
        revert("nope");
    }
}

contract ArbiterCouncilTest is Test {
    ArbiterCouncil council;
    MockTarget target;

    address m1 = makeAddr("m1");
    address m2 = makeAddr("m2");
    address m3 = makeAddr("m3");
    address stranger = makeAddr("stranger");

    function setUp() public {
        address[] memory members = new address[](3);
        members[0] = m1;
        members[1] = m2;
        members[2] = m3;
        council = new ArbiterCouncil(members, 2); // 2-of-3
        target = new MockTarget();
    }

    function _data() internal pure returns (bytes memory) {
        return abi.encodeCall(MockTarget.record, (42));
    }

    function test_belowThreshold_doesNotExecute() public {
        bytes memory data = _data();
        vm.prank(m1);
        bool executedNow = council.confirm(address(target), data);
        assertFalse(executedNow);
        assertEq(council.confirmations(council.opHash(address(target), data)), 1);
        assertFalse(council.executed(council.opHash(address(target), data)));
        assertEq(target.calls(), 0);
    }

    function test_threshold_executesCall() public {
        bytes memory data = _data();
        vm.prank(m1);
        council.confirm(address(target), data);

        vm.prank(m2);
        bool executedNow = council.confirm(address(target), data);

        assertTrue(executedNow);
        assertTrue(council.executed(council.opHash(address(target), data)));
        assertEq(target.calls(), 1);
        assertEq(target.lastValue(), 42);
        assertEq(target.lastData(), data);
    }

    function test_nonMember_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("not member"));
        council.confirm(address(target), _data());
    }

    function test_doubleConfirm_sameMember_reverts() public {
        bytes memory data = _data();
        vm.prank(m1);
        council.confirm(address(target), data);
        vm.prank(m1);
        vm.expectRevert(bytes("already confirmed"));
        council.confirm(address(target), data);
    }

    function test_confirmAfterExecuted_reverts() public {
        bytes memory data = _data();
        vm.prank(m1);
        council.confirm(address(target), data);
        vm.prank(m2);
        council.confirm(address(target), data); // executes here

        vm.prank(m3);
        vm.expectRevert(bytes("executed"));
        council.confirm(address(target), data);
    }

    function test_failingCall_reverts() public {
        RevertingTarget bad = new RevertingTarget();
        bytes memory data = abi.encodeCall(RevertingTarget.boom, ());
        vm.prank(m1);
        council.confirm(address(bad), data);
        vm.prank(m2);
        vm.expectRevert(bytes("call failed"));
        council.confirm(address(bad), data);
    }

    function test_constructor_rejectsThresholdAboveMembers() public {
        address[] memory members = new address[](2);
        members[0] = m1;
        members[1] = m2;
        vm.expectRevert(bytes("bad config"));
        new ArbiterCouncil(members, 3);
    }

    function test_constructor_rejectsZeroThreshold() public {
        address[] memory members = new address[](1);
        members[0] = m1;
        vm.expectRevert(bytes("bad config"));
        new ArbiterCouncil(members, 0);
    }

    function test_constructor_rejectsEmptyMembers() public {
        address[] memory members = new address[](0);
        vm.expectRevert(bytes("bad config"));
        new ArbiterCouncil(members, 1);
    }

    function test_constructor_rejectsDuplicateMember() public {
        address[] memory members = new address[](2);
        members[0] = m1;
        members[1] = m1;
        vm.expectRevert(bytes("bad member"));
        new ArbiterCouncil(members, 1);
    }

    function test_constructor_rejectsZeroMember() public {
        address[] memory members = new address[](2);
        members[0] = m1;
        members[1] = address(0);
        vm.expectRevert(bytes("bad member"));
        new ArbiterCouncil(members, 1);
    }

    function test_endToEnd_councilArbitratesRealBond() public {
        // Deploy a real bond whose arbiter is the council itself.
        AgentIdentity identity = new AgentIdentity();
        MockERC20 token = new MockERC20();
        uint256 stake = 10e18;
        uint256 slash = 50e18;
        ReputationBond bond =
            new ReputationBond(address(token), address(identity), address(council), stake, slash, 1 days);

        address operator = makeAddr("operator");
        address challenger = makeAddr("challenger");

        vm.prank(operator);
        uint256 agentId = identity.register();

        token.mint(operator, 1_000e18);
        token.mint(challenger, 1_000e18);
        vm.prank(operator);
        token.approve(address(bond), type(uint256).max);
        vm.prank(challenger);
        token.approve(address(bond), type(uint256).max);

        vm.prank(operator);
        bond.postBond(agentId, 100e18);

        vm.prank(challenger);
        uint256 id = bond.openDispute(agentId, keccak256("evidence"));
        uint256 cbBefore = token.balanceOf(challenger);

        // The council resolves M-of-N: two distinct members confirm resolveDispute(id, true).
        bytes memory data = abi.encodeCall(ReputationBond.resolveDispute, (id, true));
        vm.prank(m1);
        assertFalse(council.confirm(address(bond), data)); // below threshold, no slash yet
        assertEq(bond.activeDisputes(agentId), 1);

        vm.prank(m2);
        assertTrue(council.confirm(address(bond), data)); // quorum reached -> bond slashes

        assertEq(bond.bondOf(agentId), 100e18 - slash); // slashed
        assertEq(bond.activeDisputes(agentId), 0); // dispute resolved
        assertEq(token.balanceOf(challenger), cbBefore + stake + slash); // challenger paid
    }
}
