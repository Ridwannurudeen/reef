// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MethRate
/// @notice An on-chain mETH->ETH rate store for Mantle L2. mETH is non-rebasing and its exchange
/// rate is maintained on L1 Ethereum (the Mantle LSP staking contract's `mETHToETH`); the bridged
/// L2 token has no rate function. This contract lets a keeper push the verified L1 rate onto L2 so
/// `MethRateAdapter` can mark held mETH to ETH and surface REAL staking yield in vault NAV. It
/// implements the same `mETHToETH(uint256)` view the adapter expects, so the adapter is agnostic to
/// whether the rate comes from L1 directly or this L2 mirror. `rateAge()` lets consumers reject a
/// stale push. Owner-settable keeper; bounded rate (sanity guard against a fat-fingered push).
contract MethRate {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_RATE = 2e18; // mETH/ETH won't plausibly exceed 2.0 for years
    uint256 internal constant MAX_STEP_BPS = 500; // a single push may move the rate <=5% of the current value

    address public keeper;
    uint256 public rate; // WAD: ETH per 1 mETH
    uint64 public updatedAt;

    event RatePushed(uint256 rate, uint64 at);
    event KeeperTransferred(address indexed keeper);

    modifier onlyKeeper() {
        require(msg.sender == keeper, "not keeper");
        _;
    }

    constructor(address keeper_, uint256 initialRate_) {
        require(keeper_ != address(0), "zero keeper");
        require(initialRate_ >= WAD && initialRate_ < MAX_RATE, "rate range");
        keeper = keeper_;
        rate = initialRate_;
        updatedAt = uint64(block.timestamp);
    }

    /// @notice Push the latest mETH->ETH rate (read from L1 by the keeper). Bounded for sanity
    /// (mETH stays in [1.0, 2.0) vs ETH) AND rate-limited: a single push may move the stored rate by
    /// at most MAX_STEP_BPS of its current value. Real mETH moves a few bps per ~8h update, so the
    /// cap never blocks an honest push but caps the blast radius of a compromised keeper key or a
    /// poisoned L1 RPC (it cannot jump the rate in one transaction).
    function setRate(uint256 rate_) external onlyKeeper {
        require(rate_ >= WAD && rate_ < MAX_RATE, "rate range");
        uint256 cur = rate;
        uint256 diff = rate_ > cur ? rate_ - cur : cur - rate_;
        require(diff * 10_000 <= cur * MAX_STEP_BPS, "rate step");
        rate = rate_;
        updatedAt = uint64(block.timestamp);
        emit RatePushed(rate_, updatedAt);
    }

    function transferKeeper(address keeper_) external onlyKeeper {
        require(keeper_ != address(0), "zero keeper");
        keeper = keeper_;
        emit KeeperTransferred(keeper_);
    }

    /// @notice ETH value of `mETHAmount` mETH at the current rate. Matches the L1 staking signature.
    function mETHToETH(uint256 mETHAmount) external view returns (uint256) {
        return (mETHAmount * rate) / WAD;
    }

    /// @notice Seconds since the last rate push (for consumers that want a freshness gate).
    function rateAge() external view returns (uint256) {
        return block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
    }
}
