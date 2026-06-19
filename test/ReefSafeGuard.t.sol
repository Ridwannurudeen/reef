// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ReefGuard} from "../src/ReefGuard.sol";
import {ITransactionGuard, ReefSafeGuard} from "../src/ReefSafeGuard.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract SafeGuardIdentity {
    uint256 public nextAgentId = 2;
    mapping(uint256 => int256) public repOf;

    function setRep(uint256 id, int256 rep) external {
        repOf[id] = rep;
    }

    function getSummary(uint256 agentId) external view returns (int256, uint256) {
        return (repOf[agentId], 1);
    }
}

contract SafeGuardBond {
    mapping(uint256 => uint256) public bondOf;
    mapping(uint256 => uint256) public activeDisputes;

    function setBond(uint256 id, uint256 bond) external {
        bondOf[id] = bond;
    }
}

contract ReefSafeGuardTest is Test {
    ReefGuard guard;
    ReefSafeGuard safeGuard;
    SafeGuardIdentity identity;
    SafeGuardBond bond;
    MockERC20 token;

    address safe = makeAddr("safe");
    address recipient = makeAddr("recipient");

    function setUp() public {
        identity = new SafeGuardIdentity();
        bond = new SafeGuardBond();
        token = new MockERC20();
        guard = new ReefGuard(address(identity), address(bond), address(this), int256(1e18), 50e18, 8000);
        guard.setAssetAllowed(address(token), true);
        guard.setAssetAllowed(address(0), true);
        safeGuard = new ReefSafeGuard(address(guard), address(this));
        safeGuard.setSafeAgent(safe, 1);
        identity.setRep(1, int256(2e18));
        bond.setBond(1, 50e18);
        token.mint(safe, 100e18);
        vm.deal(safe, 100e18);
    }

    function _check(address to, uint256 value, bytes memory data) internal {
        vm.prank(safe);
        safeGuard.checkTransaction(
            to,
            value,
            data,
            ITransactionGuard.Operation.Call,
            0,
            0,
            0,
            address(0),
            payable(address(0)),
            "",
            safe
        );
    }

    function test_checkTransaction_allowsCompliantErc20Transfer() public {
        bytes memory data = abi.encodeWithSelector(bytes4(0xa9059cbb), recipient, 20e18);
        _check(address(token), 0, data);
    }

    function test_checkTransaction_blocksOversizedErc20Transfer() public {
        bytes memory data = abi.encodeWithSelector(bytes4(0xa9059cbb), recipient, 90e18);
        vm.expectRevert(bytes("action size over limit"));
        _check(address(token), 0, data);
    }

    function test_checkTransaction_allowsCompliantNativeTransfer() public {
        _check(recipient, 20e18, "");
    }

    function test_checkTransaction_blocksDelegateCall() public {
        vm.prank(safe);
        vm.expectRevert(bytes("delegatecall blocked"));
        safeGuard.checkTransaction(
            address(token),
            0,
            abi.encodeWithSelector(bytes4(0xa9059cbb), recipient, 20e18),
            ITransactionGuard.Operation.DelegateCall,
            0,
            0,
            0,
            address(0),
            payable(address(0)),
            "",
            safe
        );
    }

    function test_checkTransaction_requiresConfiguredSafe() public {
        address otherSafe = makeAddr("otherSafe");
        vm.prank(otherSafe);
        vm.expectRevert(bytes("safe not registered"));
        safeGuard.checkTransaction(
            address(token),
            0,
            abi.encodeWithSelector(bytes4(0xa9059cbb), recipient, 20e18),
            ITransactionGuard.Operation.Call,
            0,
            0,
            0,
            address(0),
            payable(address(0)),
            "",
            otherSafe
        );
    }
}
