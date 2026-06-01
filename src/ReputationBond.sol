// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {AgentIdentity} from "./AgentIdentity.sol";
import {SafeTransferLib} from "./utils/SafeTransferLib.sol";

/// @title ReputationBond
/// @notice Skin-in-the-game + dispute layer for Reef agents. An agent's operator
/// posts a bond; a challenger opens a dispute (staking a deposit) against the agent
/// within a window; the arbiter resolves it. Upheld disputes slash the agent's bond
/// to the challenger (stake returned + reward); rejected disputes forfeit the
/// challenger's stake into the agent's bond; if the arbiter never resolves within
/// the window, the challenger reclaims their stake. Operator identity is verified
/// against the ERC-8004 AgentIdentity registry.
/// Testnet/hackathon code — it custodies funds and is unaudited.
contract ReputationBond {
    using SafeTransferLib for IERC20;

    enum Status {
        None,
        Open,
        Upheld,
        Rejected,
        Expired
    }

    struct Dispute {
        uint256 agentId;
        address challenger;
        uint256 stake;
        uint64 deadline;
        Status status;
        bytes32 evidence;
    }

    IERC20 public immutable asset;
    AgentIdentity public immutable identity;
    address public immutable arbiter;
    uint256 public immutable challengeStake;
    uint256 public immutable slashAmount;
    uint64 public immutable disputeWindow;

    mapping(uint256 => uint256) public bondOf; // agentId -> posted bond
    mapping(uint256 => uint256) public activeDisputes; // agentId -> open dispute count
    Dispute[] public disputes;

    event BondPosted(uint256 indexed agentId, uint256 amount, uint256 total);
    event BondWithdrawn(uint256 indexed agentId, uint256 amount, uint256 total);
    event DisputeOpened(uint256 indexed id, uint256 indexed agentId, address challenger, uint256 stake);
    event DisputeResolved(uint256 indexed id, uint256 indexed agentId, bool upheld, uint256 slashed);
    event StakeReclaimed(uint256 indexed id, address challenger, uint256 amount);

    modifier onlyOperator(uint256 agentId) {
        require(identity.getAgentWallet(agentId) == msg.sender, "not operator");
        _;
    }

    constructor(
        address asset_,
        address identity_,
        address arbiter_,
        uint256 challengeStake_,
        uint256 slashAmount_,
        uint64 disputeWindow_
    ) {
        require(asset_ != address(0) && identity_ != address(0) && arbiter_ != address(0), "zero addr");
        require(challengeStake_ > 0 && slashAmount_ > 0 && disputeWindow_ > 0, "zero param");
        asset = IERC20(asset_);
        identity = AgentIdentity(identity_);
        arbiter = arbiter_;
        challengeStake = challengeStake_;
        slashAmount = slashAmount_;
        disputeWindow = disputeWindow_;
    }

    function postBond(uint256 agentId, uint256 amount) external onlyOperator(agentId) {
        require(amount > 0, "zero amount");
        asset.safeTransferFrom(msg.sender, address(this), amount);
        bondOf[agentId] += amount;
        emit BondPosted(agentId, amount, bondOf[agentId]);
    }

    function withdrawBond(uint256 agentId, uint256 amount) external onlyOperator(agentId) {
        require(activeDisputes[agentId] == 0, "active dispute");
        require(amount > 0 && amount <= bondOf[agentId], "amount");
        bondOf[agentId] -= amount;
        asset.safeTransfer(msg.sender, amount);
        emit BondWithdrawn(agentId, amount, bondOf[agentId]);
    }

    /// @notice Open a dispute against `agentId`, staking `challengeStake`. The agent
    /// must be bonded for at least `slashAmount`.
    function openDispute(uint256 agentId, bytes32 evidence) external returns (uint256 id) {
        require(bondOf[agentId] >= slashAmount, "underbonded");
        require(evidence != bytes32(0), "zero evidence");
        // An agent's own operator cannot dispute itself (self-slash farming / griefing).
        require(identity.getAgentWallet(agentId) != msg.sender, "self challenge");
        // One active dispute per agent: with concurrent disputes a depleting bond could
        // not pay every upheld slash in full, making payouts order-dependent. Serializing
        // keeps slash accounting deterministic against the posted bond.
        require(activeDisputes[agentId] == 0, "dispute active");
        asset.safeTransferFrom(msg.sender, address(this), challengeStake);
        id = disputes.length;
        disputes.push(
            Dispute({
                agentId: agentId,
                challenger: msg.sender,
                stake: challengeStake,
                deadline: uint64(block.timestamp) + disputeWindow,
                status: Status.Open,
                evidence: evidence
            })
        );
        activeDisputes[agentId] += 1;
        emit DisputeOpened(id, agentId, msg.sender, challengeStake);
    }

    function resolveDispute(uint256 id, bool uphold) external {
        require(msg.sender == arbiter, "not arbiter");
        Dispute storage d = disputes[id];
        require(d.status == Status.Open, "not open");
        activeDisputes[d.agentId] -= 1;
        if (uphold) {
            uint256 slash = slashAmount > bondOf[d.agentId] ? bondOf[d.agentId] : slashAmount;
            bondOf[d.agentId] -= slash;
            d.status = Status.Upheld;
            asset.safeTransfer(d.challenger, d.stake + slash); // stake back + reward
            emit DisputeResolved(id, d.agentId, true, slash);
        } else {
            bondOf[d.agentId] += d.stake; // forfeited stake compensates the agent
            d.status = Status.Rejected;
            emit DisputeResolved(id, d.agentId, false, 0);
        }
    }

    /// @notice If the arbiter never resolves within the window, the challenger reclaims their stake.
    function claimExpiredStake(uint256 id) external {
        Dispute storage d = disputes[id];
        require(d.status == Status.Open, "not open");
        require(block.timestamp > d.deadline, "window open");
        require(msg.sender == d.challenger, "not challenger");
        activeDisputes[d.agentId] -= 1;
        d.status = Status.Expired;
        asset.safeTransfer(d.challenger, d.stake);
        emit StakeReclaimed(id, d.challenger, d.stake);
    }

    function disputeCount() external view returns (uint256) {
        return disputes.length;
    }
}
