// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ExampleScenario} from "../../src/sim/ExampleScenario.sol";
import {SimEngine} from "../../src/sim/SimEngine.sol";
import {SimClock} from "../../src/sim/SimClock.sol";
import {SimLedger} from "../../src/sim/SimLedger.sol";
import {VENUE_UNDER_TEST, VENUE_MAIN} from "../../src/sim/ISimAgent.sol";
import {HonestTrader} from "../../src/sim/agents/HonestTrader.sol";
import {RandomTrader} from "../../src/sim/agents/RandomTrader.sol";
import {Arbitrageur} from "../../src/sim/agents/Arbitrageur.sol";
import {Sandwicher} from "../../src/sim/agents/Sandwicher.sol";

/// @notice The same population, run under the two ordering models. What changes between the two runs is ONLY the
/// ordering: the difference in the sandwicher's line is what the ordering model is worth to it.
///
/// The population: a main market (hookless pool) pushed by two world traders, a passive stream of honest swaps on
/// the venue under test, an arbitrageur that reacts to the gap between the two, and a sandwicher.
///
/// The world is SEEDED (`SIM_SEED`, default 1): the two world traders draw their sizes and directions from it, so
/// "run it over several seeds" (`doctrine/SIMULATE.md`) means several different runs here. It used to be two fixed
/// traders, and a fresh reader ran it on seeds 1-3 and got three identical ledgers that `sim-report.sh` then called
/// "3 runs". The victim, the arbitrageur and the sandwicher stay deterministic: they react to what the world did.
abstract contract PopulationScenario is ExampleScenario {
    RandomTrader world1;
    RandomTrader world2;
    HonestTrader victim;
    Arbitrageur arb;
    Sandwicher sandwich;

    function _population() internal {
        cadence = SimClock.ethereumL1();
        _setUpScenario(100e18);
        _addMainMarket(3000, 100e18);
        uint256 seed = vm.envOr("SIM_SEED", uint256(1));
        world1 = new RandomTrader("world-a", VENUE_MAIN, seed, 3e17, 7e17, 50, 5000, 0);
        world2 = new RandomTrader("world-b", VENUE_MAIN, seed + 1, 1e17, 5e17, 33, 5000, 1);
        victim = new HonestTrader("victim", 2e17, 2, 1, 200, VENUE_UNDER_TEST); // 2 % slippage rule
        arb = new Arbitrageur("arb", 1e17, 40, 1, false); // reacts to a 0.4 % gap in price, one step behind, never closes
        sandwich = new Sandwicher("sandwich", 20_000, 1e16); // front-runs with 2x the victim's size
        _addAgent(world1, 200e18);
        _addAgent(world2, 200e18);
        _addAgent(victim, 100e18);
        _addAgent(arb, 100e18);
        _addSearcher(sandwich, 100e18);
    }
}

contract OrderingFCFS is PopulationScenario {
    function setUp() public {
        _population();
        ordering = SimEngine.Ordering.FCFS;
        label = "population-fcfs";
    }

    function test_under_fcfs_the_sandwicher_is_never_asked() public {
        run(60);
        _finish();
        SimLedger.Books memory s = booksOf(address(sandwich));
        assertEq(s.decided, 0, "under FCFS nobody sees a pending intent: the sandwicher has nothing to do");
        assertEq(sandwich.wraps(), 0);
        SimLedger.Books memory v = booksOf(address(victim));
        assertGt(v.executed, 0, "the victim traded");
        SimLedger.Books memory a = booksOf(address(arb));
        assertGt(a.decided, 0, "the world moved the main market enough for the arbitrageur to act");
    }
}

contract OrderingBUNDLE is PopulationScenario {
    /// @dev walk the queue in EXECUTION order and check the shape: whenever a searcher intent executes, the next
    /// executed intent is a non-searcher (the victim) and the one after is the searcher again (the back-run)
    function _assertFrontVictimBack() internal view {
        uint256 n = queueLength();
        uint256 total = 0;
        for (uint256 i = 0; i < n; i++) if (executedOrderOf(i) > 0) total++;
        address[] memory byOrder = new address[](total + 1);
        for (uint256 i = 0; i < n; i++) {
            uint256 o = executedOrderOf(i);
            if (o > 0) byOrder[o] = intentAt(i).agent;
        }
        uint256 sandwiches;
        for (uint256 o = 1; o + 2 <= total; o++) {
            if (byOrder[o] != address(sandwich)) continue;
            assertTrue(byOrder[o + 1] != address(sandwich), "two searcher intents in a row: the victim is missing");
            assertEq(byOrder[o + 2], address(sandwich), "the back-run did not follow the victim");
            sandwiches += 1;
            o += 2;
        }
        assertEq(sandwiches, sandwich.wraps(), "every wrap is front, victim, back - in that order");
    }

    function setUp() public {
        _population();
        ordering = SimEngine.Ordering.BUNDLE;
        label = "population-bundle";
    }

    function test_under_bundle_the_sandwicher_wraps_the_victim() public {
        run(60);
        _finish();
        SimLedger.Books memory s = booksOf(address(sandwich));
        assertGt(sandwich.wraps(), 0, "the sandwicher saw victims");
        assertEq(s.decided, sandwich.wraps() * 2, "one front-run and one back-run per wrap");
        assertGt(s.executed, 0);
        assertEq(s.executed + s.refused + s.refusedAtQuote, s.decided, "every searcher intent settled exactly once");

        // THE ORDER, asserted from the engine's own record: for every wrap, front-run, victim, back-run. Without
        // this a mutant that runs the back-run first would still show "two intents per wrap".
        _assertFrontVictimBack();
        // whether it PROFITS on this hook is the measurement, not an assertion: the hook's fee is set by the previous
        // block's volume, so a sandwich (three swaps in one block) pays what the block before set and makes the next
        // block dearer for everyone, itself included. Read the ledger line over several seeds (README, step 2).
        SimLedger.Books memory v = booksOf(address(victim));
        assertGt(v.executed + v.refused, 0);
    }
}
