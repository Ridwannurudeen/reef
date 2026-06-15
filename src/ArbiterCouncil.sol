// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ArbiterCouncil
/// @notice Decentralized arbiter for `ReputationBond`. It replaces the bond's single-EOA
/// arbiter with a minimal M-of-N council so no single party can resolve or slash a dispute.
/// Members confirm a `(target, data)` operation; once `threshold` DISTINCT members have
/// confirmed the same op, the council executes the low-level call to `target` exactly once.
/// Wired as the bond's arbiter, this lets the council call `resolveDispute`, `acceptArbiter`,
/// or `transferArbiter` under M-of-N control. In production the members are independent
/// parties (separate keys/orgs), so a quorum — not any one actor — governs arbitration.
contract ArbiterCouncil {
    address[] public members;
    mapping(address => bool) public isMember;
    uint256 public immutable threshold;
    mapping(bytes32 => mapping(address => bool)) public confirmedBy; // opHash => member => bool
    mapping(bytes32 => uint256) public confirmations; // opHash => count
    mapping(bytes32 => bool) public executed; // opHash => executed

    event Confirmed(bytes32 indexed opHash, address indexed member, uint256 confirmations);
    event Executed(bytes32 indexed opHash, address indexed target);

    constructor(address[] memory members_, uint256 threshold_) {
        require(members_.length > 0 && threshold_ > 0 && threshold_ <= members_.length, "bad config");
        for (uint256 i = 0; i < members_.length; i++) {
            address m = members_[i];
            require(m != address(0) && !isMember[m], "bad member");
            isMember[m] = true;
            members.push(m);
        }
        threshold = threshold_;
    }

    modifier onlyMember() {
        require(isMember[msg.sender], "not member");
        _;
    }

    /// @notice Deterministic id of a `(target, data)` operation. Members confirm this id.
    function opHash(address target, bytes calldata data) public pure returns (bytes32) {
        return keccak256(abi.encode(target, data));
    }

    /// @notice Confirm `(target, data)` as a council member. On reaching `threshold` DISTINCT
    /// confirmations the op executes ONCE: the `executed` flag is set BEFORE the external call
    /// (checks-effects-interactions), so the call cannot re-enter to double-execute. Each
    /// member may confirm a given op at most once, and a given op executes at most once.
    function confirm(address target, bytes calldata data) external onlyMember returns (bool executedNow) {
        bytes32 h = keccak256(abi.encode(target, data));
        require(!executed[h], "executed");
        require(!confirmedBy[h][msg.sender], "already confirmed");
        confirmedBy[h][msg.sender] = true;
        uint256 c = ++confirmations[h];
        emit Confirmed(h, msg.sender, c);
        if (c >= threshold) {
            executed[h] = true;
            (bool ok,) = target.call(data);
            require(ok, "call failed");
            emit Executed(h, target);
            return true;
        }
        return false;
    }

    function memberCount() external view returns (uint256) {
        return members.length;
    }
}
