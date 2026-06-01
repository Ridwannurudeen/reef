// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {Seasons} from "../src/Seasons.sol";

contract SeasonsTest is Test {
    AgentIdentity identity;
    Seasons seasons;

    address human = makeAddr("human");
    address ai = makeAddr("ai");
    uint256 humanId;
    uint256 aiId;

    function setUp() public {
        identity = new AgentIdentity();
        seasons = new Seasons(address(identity));

        vm.prank(human);
        humanId = identity.register();
        vm.prank(ai);
        aiId = identity.register();

        // Use the test contract as each agent's reputation source so it can grow rep.
        vm.prank(human);
        identity.setReputationSource(humanId, address(this));
        vm.prank(ai);
        identity.setReputationSource(aiId, address(this));
    }

    function _grow(uint256 agentId, int128 amount) internal {
        identity.giveFeedback(agentId, amount, 18);
    }

    function test_season_scoresRepEarnedDuringWindow_andPicksWinners() public {
        // Pre-existing reputation before the season should NOT count.
        _grow(humanId, 5e18);
        _grow(aiId, 1e18);

        uint256 id = seasons.startSeason(1 days);

        vm.prank(human);
        seasons.enroll(id, humanId, Seasons.Side.Human);
        vm.prank(ai);
        seasons.enroll(id, aiId, Seasons.Side.AI);

        // Reputation earned during the season.
        _grow(humanId, 2e18);
        _grow(aiId, 7e18);

        // Live scores reflect only in-season gains.
        assertEq(seasons.scoreOf(id, humanId), 2e18);
        assertEq(seasons.scoreOf(id, aiId), 7e18);

        vm.warp(block.timestamp + 1 days + 1);
        seasons.finalize(id);

        // Post-finalize scores are frozen even if reputation keeps moving.
        _grow(aiId, 100e18);
        assertEq(seasons.scoreOf(id, aiId), 7e18);

        (uint256 hWin, int256 hScore) = seasons.winner(id, Seasons.Side.Human);
        (uint256 aWin, int256 aScore) = seasons.winner(id, Seasons.Side.AI);
        assertEq(hWin, humanId);
        assertEq(hScore, 2e18);
        assertEq(aWin, aiId);
        assertEq(aScore, 7e18);
    }

    function test_enroll_onlyOperator() public {
        uint256 id = seasons.startSeason(1 days);
        vm.prank(ai); // not the human agent's operator
        vm.expectRevert(bytes("not operator"));
        seasons.enroll(id, humanId, Seasons.Side.Human);
    }

    function test_enroll_revertsAfterEnd() public {
        uint256 id = seasons.startSeason(1 days);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(human);
        vm.expectRevert(bytes("season ended"));
        seasons.enroll(id, humanId, Seasons.Side.Human);
    }

    function test_finalize_revertsBeforeEnd() public {
        uint256 id = seasons.startSeason(1 days);
        vm.expectRevert(bytes("not ended"));
        seasons.finalize(id);
    }

    function test_startSeason_onlyGovernor() public {
        vm.prank(human);
        vm.expectRevert(bytes("not governor"));
        seasons.startSeason(1 days);
    }
}
