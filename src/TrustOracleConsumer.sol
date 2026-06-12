// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITrustOracle {
    function scoreOf(uint256 agentId) external view returns (uint256);
}

/// @title TrustOracleConsumer
/// @notice A stand-in for any external Mantle protocol that extends *capital* to autonomous agents
/// — a lending market, a credit line, an allocator — and wants to size and gate that capital by an
/// agent's on-chain trustworthiness. It reads `TrustOracle.scoreOf(agentId)` (0..1e18) and (a) gates:
/// only agents at or above `minScore` may draw; (b) sizes: the credit limit scales linearly with the
/// Trust Score. This is the "trust-weighted capital" integration shape — Reef supplies the verifiable
/// trust number, the protocol keeps its own lending logic. One external read, no Reef stack required.
contract TrustOracleConsumer {
    uint256 internal constant WAD = 1e18;

    ITrustOracle public immutable oracle;
    uint256 public immutable minScore; // qualification bar, WAD (0..1e18)

    /// @notice Emitted when an agent clears the trust bar and draws credit.
    event CreditExtended(uint256 indexed agentId, uint256 score, uint256 amount);

    constructor(address oracle_, uint256 minScore_) {
        require(oracle_ != address(0), "zero oracle");
        require(minScore_ <= WAD, "minScore");
        oracle = ITrustOracle(oracle_);
        minScore = minScore_;
    }

    /// @notice Trust-weighted credit limit: `baseLimit` scaled by the agent's Trust Score. An agent
    /// below `minScore` gets 0 (disqualified); otherwise limit = baseLimit * score / 1e18.
    function creditLimit(uint256 agentId, uint256 baseLimit) public view returns (uint256) {
        uint256 score = oracle.scoreOf(agentId);
        if (score < minScore) return 0;
        return (baseLimit * score) / WAD;
    }

    /// @notice Draw credit, gated and sized by the agent's Trust Score. Reverts "trust below
    /// threshold" if disqualified, or "over trust-weighted limit" if the draw exceeds the limit.
    /// A real protocol would transfer `amount` here; this reference records the event.
    function drawCredit(uint256 agentId, uint256 amount, uint256 baseLimit) external returns (uint256) {
        uint256 score = oracle.scoreOf(agentId);
        require(score >= minScore, "trust below threshold");
        require(amount <= (baseLimit * score) / WAD, "over trust-weighted limit");
        emit CreditExtended(agentId, score, amount);
        return amount;
    }
}
