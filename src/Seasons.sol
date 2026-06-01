// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AgentIdentity} from "./AgentIdentity.sol";

/// @title Seasons
/// @notice Time-boxed Human-vs-AI seasons over ERC-8004 agents. The governor opens a
/// season; each agent's operator enrolls it on a side (Human or AI), which snapshots
/// the agent's cumulative reputation at entry. After the season ends anyone can
/// finalize it — that snapshots end reputation, freezing each entrant's score
/// (reputation earned during the season). Puts the previously client-side
/// Human-vs-AI leaderboard on-chain. Reputation is read from the AgentIdentity registry.
contract Seasons {
    AgentIdentity public immutable identity;
    address public governor;

    enum Side {
        Human,
        AI
    }

    struct Season {
        uint64 start;
        uint64 end;
        bool finalized;
    }

    Season[] public seasons;
    mapping(uint256 => uint256[]) internal _entrants; // season => agentIds
    mapping(uint256 => mapping(uint256 => bool)) public enrolled; // season => agentId => enrolled
    mapping(uint256 => mapping(uint256 => Side)) public sideOf;
    mapping(uint256 => mapping(uint256 => int256)) public startRep;
    mapping(uint256 => mapping(uint256 => int256)) public endRep;

    event SeasonStarted(uint256 indexed id, uint64 start, uint64 end);
    event Enrolled(uint256 indexed id, uint256 indexed agentId, Side side, int256 startRep);
    event SeasonFinalized(uint256 indexed id, uint256 entrants);

    modifier onlyGovernor() {
        require(msg.sender == governor, "not governor");
        _;
    }

    constructor(address identity_) {
        require(identity_ != address(0), "zero addr");
        identity = AgentIdentity(identity_);
        governor = msg.sender;
    }

    function setGovernor(address g) external onlyGovernor {
        require(g != address(0), "zero gov");
        governor = g;
    }

    function startSeason(uint64 duration) external onlyGovernor returns (uint256 id) {
        require(duration > 0, "zero duration");
        uint64 start = uint64(block.timestamp);
        id = seasons.length;
        seasons.push(Season({start: start, end: start + duration, finalized: false}));
        emit SeasonStarted(id, start, start + duration);
    }

    /// @notice Enroll an agent (caller must be its operator) on a side before the season ends.
    function enroll(uint256 id, uint256 agentId, Side side) external {
        Season storage s = seasons[id];
        require(!s.finalized, "finalized");
        require(block.timestamp < s.end, "season ended");
        require(identity.getAgentWallet(agentId) == msg.sender, "not operator");
        require(!enrolled[id][agentId], "enrolled");
        (int256 cum,) = identity.getSummary(agentId);
        enrolled[id][agentId] = true;
        sideOf[id][agentId] = side;
        startRep[id][agentId] = cum;
        _entrants[id].push(agentId);
        emit Enrolled(id, agentId, side, cum);
    }

    /// @notice After the season ends, freeze every entrant's end reputation.
    function finalize(uint256 id) external {
        Season storage s = seasons[id];
        require(!s.finalized, "finalized");
        require(block.timestamp >= s.end, "not ended");
        s.finalized = true;
        uint256[] storage e = _entrants[id];
        for (uint256 i = 0; i < e.length; i++) {
            (int256 cum,) = identity.getSummary(e[i]);
            endRep[id][e[i]] = cum;
        }
        emit SeasonFinalized(id, e.length);
    }

    /// @notice Reputation earned during the season. Reads live reputation before
    /// finalize, the frozen snapshot after.
    function scoreOf(uint256 id, uint256 agentId) public view returns (int256) {
        require(enrolled[id][agentId], "not enrolled");
        int256 end;
        if (seasons[id].finalized) {
            end = endRep[id][agentId];
        } else {
            (end,) = identity.getSummary(agentId);
        }
        return end - startRep[id][agentId];
    }

    /// @notice Highest-scoring entrant on `side`. Returns (0, 0) if the side has no entrants.
    function winner(uint256 id, Side side) external view returns (uint256 winAgent, int256 winScore) {
        uint256[] storage e = _entrants[id];
        bool found;
        for (uint256 i = 0; i < e.length; i++) {
            uint256 aid = e[i];
            if (sideOf[id][aid] != side) continue;
            int256 sc = scoreOf(id, aid);
            if (!found || sc > winScore) {
                found = true;
                winAgent = aid;
                winScore = sc;
            }
        }
    }

    function entrants(uint256 id) external view returns (uint256[] memory) {
        return _entrants[id];
    }

    function seasonCount() external view returns (uint256) {
        return seasons.length;
    }
}
