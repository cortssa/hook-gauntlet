// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SimView, Intent, Fill, VENUE_MAIN, VENUE_UNDER_TEST} from "../../src/sim/ISimAgent.sol";
import {Arbitrageur} from "../../src/sim/agents/Arbitrageur.sol";
import {HonestTrader} from "../../src/sim/agents/HonestTrader.sol";
import {RandomTrader} from "../../src/sim/agents/RandomTrader.sol";
import {Sandwicher} from "../../src/sim/agents/Sandwicher.sol";

/// @notice `Intent.amountInQuote` says in which currency `amountIn` is. Only the agent knows, so the agents are tested
/// here, with no binding in between: the arbitrageur's CLOSING leg sells what its opening leg delivered and must never
/// carry the flag, whatever unit the agent was told to size its opening leg in.
///
/// Written after a binding that converted every sell as if it were quote-sized converted the closing legs a second
/// time: on a pair with a 6-decimal quote and an 18-decimal token, every close asked for ~10^12 times the wallet and
/// was refused (2026-09-22). The bug was in the binding's guess; the fix is that nothing is left to guess.
contract IntentUnit is Test {
    uint160 constant ONE = 79228162514264337593543950336; // sqrt(1) in Q96

    function _view(uint256 step, uint160 venueSqrt, uint160 mainSqrt) internal pure returns (SimView memory v) {
        v.step = step;
        v.sqrtPriceX96 = venueSqrt;
        v.mainSqrtPriceX96 = mainSqrt;
    }

    /// @dev an arbitrageur that has just seen the venue at 1/4 of the main price, and decided to buy there
    function _opened(bool quoteSized) internal returns (Arbitrageur arb, Intent memory open) {
        arb = new Arbitrageur("arb", 50, 100, 0, true);
        if (quoteSized) arb.setSizeInQuote(true);
        arb.observe(_view(1, ONE, 2 * ONE));
        bool wants;
        (wants, open) = arb.decide();
        assertTrue(wants, "the arbitrageur did not act on a 4x gap");
        assertEq(open.venue, VENUE_UNDER_TEST);
        assertFalse(open.zeroForOne, "a cheaper venue is a BUY there");
    }

    function test_the_closing_leg_never_says_it_is_quote_sized() public {
        (Arbitrageur arb, Intent memory open) = _opened(true);
        assertTrue(open.amountInQuote, "the opening leg ignored the unit the scenario set");

        Fill memory f;
        f.executed = true;
        f.amountOut = 12_345; // what the venue delivered: currency0
        f.amountInUsed = 50;
        arb.settle(open, f);
        arb.observe(_view(2, ONE, 2 * ONE));
        (bool wants, Intent memory close) = arb.decide();
        assertTrue(wants, "no closing leg after a fill");
        assertEq(close.venue, VENUE_MAIN);
        assertTrue(close.zeroForOne, "the close of a buy is a sell");
        assertEq(close.amountIn, 12_345, "the close does not sell what the fill delivered");
        assertFalse(close.amountInQuote, "the closing leg is sized by the fill, in currency0: it must not be converted");
    }

    /// @notice the sandwich's front leg is sized as a multiple of the victim's `amountIn`, so it is in the victim's unit
    /// and must say so; its back leg sells what the front leg delivered and, like the arbitrageur's close, never does
    function test_the_sandwich_front_leg_carries_the_victims_unit() public {
        Sandwicher s = new Sandwicher("sandwich", 20_000, 1);
        Intent memory victim;
        victim.venue = VENUE_UNDER_TEST;
        victim.zeroForOne = true;
        victim.amountIn = 1_000;
        victim.amountInQuote = true;
        SimView memory v = _view(1, ONE, ONE);
        Intent[] memory front = s.wrap(victim, v);
        assertEq(front.length, 1, "the sandwicher did not wrap");
        assertEq(front[0].amountIn, 2_000);
        assertTrue(front[0].amountInQuote, "the front leg is a multiple of a quote-sized victim but claims the input unit");

        Fill memory f;
        f.executed = true;
        f.amountOut = 777;
        f.amountInUsed = 1;
        s.settle(front[0], f);
        Intent[] memory back = s.unwind(victim, f, v);
        assertEq(back.length, 1);
        assertEq(back[0].amountIn, 777);
        assertFalse(back[0].amountInQuote, "the back leg sells what the front leg delivered: it must not be converted");

        victim.amountInQuote = false;
        front = s.wrap(victim, v);
        assertFalse(front[0].amountInQuote, "an input-sized victim made a quote-sized front leg");
    }

    function test_the_unit_is_the_input_currency_unless_the_scenario_says_otherwise() public {
        (, Intent memory open) = _opened(false);
        assertFalse(open.amountInQuote, "an agent nobody configured claimed quote sizing");

        HonestTrader h = new HonestTrader("honest", 7, 1, 0, 100, VENUE_UNDER_TEST);
        h.observe(_view(1, ONE, ONE));
        (, Intent memory a) = h.decide();
        assertFalse(a.amountInQuote);
        h.setSizeInQuote(true);
        (, Intent memory b) = h.decide();
        assertTrue(b.amountInQuote, "the honest trader ignored the unit the scenario set");

        RandomTrader r = new RandomTrader("world", VENUE_MAIN, 1, 5, 9, 100, 5000, 0);
        r.observe(_view(1, ONE, ONE));
        (bool w1, Intent memory c) = r.decide();
        assertTrue(w1, "a trader asked to trade every step did not");
        assertFalse(c.amountInQuote);
        r.setSizeInQuote(true);
        (, Intent memory d) = r.decide();
        assertTrue(d.amountInQuote, "the random trader ignored the unit the scenario set");
    }
}
