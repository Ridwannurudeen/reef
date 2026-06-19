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

contract MockTrustOracle {
    mapping(uint256 => uint256) public scores;
    bool public shouldRevert;

    function setScore(uint256 id, uint256 score) external {
        scores[id] = score;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function scoreOf(uint256 agentId) external view returns (uint256) {
        if (shouldRevert) revert("oracle down");
        return scores[agentId];
    }
}

contract ReefGuardTest is Test {
    ReefGuard guard;
    MockIdentity ident;
    MockBond bnd;
    MockTrustOracle oracle;
    address asset = address(0xA55E7);

    function setUp() public {
        ident = new MockIdentity();
        bnd = new MockBond();
        oracle = new MockTrustOracle();
        guard = new ReefGuard(address(ident), address(bnd), address(this), int256(1e18), 50e18, 8000);
        guard.setAssetAllowed(asset, true);
        // agent 1 in good standing
        ident.setRep(1, int256(2e18));
        bnd.setBond(1, 50e18);
        oracle.setScore(1, 9e17);
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

    function test_compositeTrustScoreBelowThreshold() public {
        guard.setTrustPolicy(address(oracle), 95e16);
        (bool ok, string memory r) = _check(1, asset, 5000);
        assertFalse(ok);
        assertEq(r, "trust score below threshold");

        oracle.setScore(1, 95e16);
        (bool ok2, string memory r2) = _check(1, asset, 5000);
        assertTrue(ok2);
        assertEq(r2, "ok");
    }

    function test_compositeTrustScoreUnavailable() public {
        guard.setTrustPolicy(address(oracle), 1);
        oracle.setShouldRevert(true);
        (bool ok, string memory r) = _check(1, asset, 5000);
        assertFalse(ok);
        assertEq(r, "trust score unavailable");
    }

    function test_canExecuteAction_derivesErc20TransferSize() public view {
        bytes memory data = abi.encodeWithSelector(bytes4(0xa9059cbb), address(0xCAFE), 20e18);
        ReefGuard.Action memory action =
            ReefGuard.Action({target: asset, value: 0, data: data, asset: asset, portfolioValue: 100e18});

        (bool ok, string memory r, uint256 amount, uint256 sizeBps) = guard.canExecuteAction(1, action);

        assertTrue(ok);
        assertEq(r, "ok");
        assertEq(amount, 20e18);
        assertEq(sizeBps, 2000);
    }

    function test_canExecuteAction_blocksOversizedDerivedAmount() public view {
        bytes memory data = abi.encodeWithSelector(bytes4(0xa9059cbb), address(0xCAFE), 90e18);
        ReefGuard.Action memory action =
            ReefGuard.Action({target: asset, value: 0, data: data, asset: asset, portfolioValue: 100e18});

        (bool ok, string memory r, uint256 amount, uint256 sizeBps) = guard.canExecuteAction(1, action);

        assertFalse(ok);
        assertEq(r, "action size over limit");
        assertEq(amount, 90e18);
        assertEq(sizeBps, 9000);
    }

    function test_canExecuteAction_failsClosedOnUnsupportedAction() public view {
        ReefGuard.Action memory action = ReefGuard.Action({
            target: asset,
            value: 0,
            data: abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(1)),
            asset: asset,
            portfolioValue: 100e18
        });

        (bool ok, string memory r, uint256 amount, uint256 sizeBps) = guard.canExecuteAction(1, action);

        assertFalse(ok);
        assertEq(r, "unsupported action");
        assertEq(amount, 0);
        assertEq(sizeBps, 0);
    }

    function test_onlyGovernor() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes("not governor"));
        guard.setPolicy(0, 0, 1000);
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes("not governor"));
        guard.setTrustPolicy(address(oracle), 1);
    }

    function test_governorCanRetune() public {
        guard.setPolicy(int256(5e18), 100e18, 2000);
        // now agent 1 (rep 2e18, bond 50e18) fails the raised reputation bar
        (bool ok, string memory r) = _check(1, asset, 1000);
        assertFalse(ok);
        assertEq(r, "insufficient bond"); // bond check precedes reputation; 50e18 < 100e18
    }

    function test_governorCanSetTrustPolicy() public {
        guard.setTrustPolicy(address(oracle), 8e17);
        assertEq(guard.trustOracle(), address(oracle));
        assertEq(guard.minTrustScore(), 8e17);

        vm.expectRevert(bytes("trust"));
        guard.setTrustPolicy(address(oracle), 1e18 + 1);
    }
}
