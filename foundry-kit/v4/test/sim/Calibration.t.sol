// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ExampleScenario} from "../../src/sim/ExampleScenario.sol";
import {SimClock} from "../../src/sim/SimClock.sol";
import {SimLedger} from "../../src/sim/SimLedger.sol";
import {HonestTrader} from "../../src/sim/agents/HonestTrader.sol";

/// @notice THE CALIBRATION SCENARIO, mandatory before any result of the sandbox counts. One honest agent, zero
/// latency, no adversary. Under those conditions the quote and the execution are the same computation on the same
/// state, so they must agree to the wei; the ledger's totals must equal what the wallet says; and nothing may be
/// refused. If any of this fails, the sandbox is wrong and no number it produces means anything.
contract CalibrationScenario is ExampleScenario {
    HonestTrader trader;

    function setUp() public {
        cadence = SimClock.ethereumL1();
        label = "calibration";
        _setUpScenario(100e18);
        trader = new HonestTrader("honest", 1e17, 1, 0, 100, 0); // every step, latency 0, 1 % slippage rule
        _addAgent(trader, 100e18);
    }

    function test_calibration_quote_equals_execution_at_zero_latency() public {
        uint256 b0 = token0.balanceOf(address(trader));
        uint256 b1 = token1.balanceOf(address(trader));
        run(40);
        _finish();

        SimLedger.Books memory b = booksOf(address(trader));
        assertEq(b.decided, 40, "one intent per step");
        assertEq(b.executed, 40, "every intent executed");
        assertEq(b.refused, 0, "nothing refused at zero latency");
        assertEq(b.shortfallTotal, 0, "the quote was above the execution: the quoter is not the executor");
        assertEq(b.windfallTotal, 0, "the execution was above the quote: same");
        assertEq(b.quotedOutTotal, b.amountOutTotal);
        assertEq(trader.fills(), 40);

        // the books agree with the wallet: what left the wallet is what was swapped in, what arrived is what came out
        uint256 a0 = token0.balanceOf(address(trader));
        uint256 a1 = token1.balanceOf(address(trader));
        uint256 spent = (b0 > a0 ? b0 - a0 : 0) + (b1 > a1 ? b1 - a1 : 0);
        uint256 gained = (a0 > b0 ? a0 - b0 : 0) + (a1 > b1 ? a1 - b1 : 0);
        // in and out cross both tokens (buys pay quote, sells pay custody), so compare the NET: in - out == spent - gained.
        // `in` is the input the pool TOOK (`Fill.amountInUsed`): the dust it could not fill went back to the wallet and is
        // not a cost. This is the line that was 15 wei off before the ledger learned the difference.
        assertEq(b.amountInTotal - b.amountOutTotal, spent - gained, "the ledger and the wallet disagree");
    }

    /// @notice the same trader with latency 1 on the same hook: the quote is taken in one block and executed in the
    /// next. On THIS hook the fee depends on how many swaps the block has already seen, so even alone in the world
    /// the execution can differ from the quote - the mildest form of a stale quote. Not an assertion of a number
    /// (one draw is one draw): an assertion that the sandbox SEES the gap when there is one, and a printed line.
    function test_latency_one_shows_a_gap_the_calibration_cannot() public {
        label = "latency-one";
        HonestTrader late = new HonestTrader("late", 1e17, 1, 1, 10_000, 0);
        _addAgent(late, 100e18);
        run(41); // one step more than the intents, so that the last one (decided at 40, due at 41) is settled
        _finish();
        SimLedger.Books memory b = booksOf(address(late));
        assertEq(b.executed + b.refused + b.refusedAtQuote, 40, "every intent settled one way or the other");
        assertGt(b.executed, 0);
        assertGt(b.shortfallTotal + b.windfallTotal, 0, "a stale quote on this hook should show a gap somewhere in 40 fills");

        // And a second lesson, measured the first time this ran: the HONEST trader, latency ZERO, now shows a gap
        // too. Its quote is taken on the block's opening state, and the late trader's intent - submitted a step
        // earlier, so ahead in the FCFS queue - executes before it inside the same block. "Zero latency" is not
        // "nobody ahead of me". The calibration holds only for an agent ALONE in the world; that is why it is run alone.
        SimLedger.Books memory h = booksOf(address(trader));
        assertEq(h.executed, 41, "the zero-latency trader settles every intent, including the 41st");
    }
}
