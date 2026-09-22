// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {ExampleScenario} from "../../src/sim/ExampleScenario.sol";
import {SimEngine} from "../../src/sim/SimEngine.sol";
import {SimClock} from "../../src/sim/SimClock.sol";
import {SimLedger} from "../../src/sim/SimLedger.sol";
import {VENUE_UNDER_TEST, VENUE_MAIN} from "../../src/sim/ISimAgent.sol";
import {HonestTrader} from "../../src/sim/agents/HonestTrader.sol";
import {RandomTrader} from "../../src/sim/agents/RandomTrader.sol";
import {PassiveLP} from "../../src/sim/agents/PassiveLP.sol";
import {JitLP} from "../../src/sim/agents/JitLP.sol";

/// @notice The liquidity side: a passive LP that is there all along, a JIT LP that appears around each swap, a
/// seeded world. The same population is run under BOTH orderings inside one test, from one snapshot, so that the
/// two ledgers are directly comparable: the only thing that differs is whether the JIT LP was ever asked.
contract LiquidityScenario is ExampleScenario {
    RandomTrader worldA;
    RandomTrader worldB;
    HonestTrader victim;
    PassiveLP passive;
    JitLP jit;
    uint256 seedUsed;

    function setUp() public {
        cadence = SimClock.ethereumL1();
        _setUpScenario(50e18);
        _addMainMarket(3000, 100e18);
        seedUsed = vm.envOr("SIM_SEED", uint256(1));
        worldA = new RandomTrader("world-a", VENUE_MAIN, seedUsed, 1e17, 8e17, 60, 5000, 0);
        worldB = new RandomTrader("world-b", VENUE_MAIN, seedUsed + 1, 1e17, 5e17, 40, 5000, 1);
        victim = new HonestTrader("victim", 3e17, 2, 1, 300, VENUE_UNDER_TEST);
        (int24 lower, int24 upper) = _fullRange(60);
        passive = new PassiveLP("passive-lp", VENUE_UNDER_TEST, lower, upper, 30e18, 59);
        jit = new JitLP("jit-lp", 200e18, 1e16, 60);
        _addAgent(worldA, 200e18);
        _addAgent(worldB, 200e18);
        _addAgent(victim, 100e18);
        _addAgent(passive, 200e18);
        _addSearcher(jit, 400e18);
    }

    function test_jit_takes_the_fee_the_passive_lp_would_have_earned_only_under_bundle() public {
        uint256 snap = vm.snapshotState();

        ordering = SimEngine.Ordering.FCFS;
        label = "liquidity-fcfs";
        run(60);
        _finish();
        SimLedger.Books memory jF = booksOf(address(jit));
        SimLedger.Books memory pF = booksOf(address(passive));
        (uint256 p0F, uint256 p1F) = _balances(address(passive));
        int256 passivePnlFcfs = ledger.pnl(address(passive), p0F, p1F, _referencePriceX96());
        assertEq(jF.decided, 0, "under FCFS the JIT LP is never asked");
        assertEq(pF.executed, 2, "the passive LP added and removed");
        assertTrue(passive.removed(), "the passive LP is back in its wallet, so its P&L is a real number");

        vm.revertToState(snap);

        ordering = SimEngine.Ordering.BUNDLE;
        label = "liquidity-bundle";
        run(60);
        _finish();
        SimLedger.Books memory jB = booksOf(address(jit));
        SimLedger.Books memory pB = booksOf(address(passive));
        (uint256 p0B, uint256 p1B) = _balances(address(passive));
        int256 passivePnlBundle = ledger.pnl(address(passive), p0B, p1B, _referencePriceX96());
        (uint256 j0, uint256 j1) = _balances(address(jit));
        int256 jitPnl = ledger.pnl(address(jit), j0, j1, _referencePriceX96());

        assertGt(jit.wraps(), 0, "the JIT LP saw swaps");
        assertEq(jB.decided, jit.wraps() * 2, "one add and one remove per wrap");
        assertEq(jB.executed + jB.refused, jB.decided, "every JIT intent settled once");
        assertEq(pB.executed, 2);
        console2.log("passive LP pnl, FCFS   :", passivePnlFcfs);
        console2.log("passive LP pnl, BUNDLE :", passivePnlBundle);
        console2.log("JIT LP pnl, BUNDLE     :", jitPnl);
        // THE claim of JIT liquidity: what it earns comes out of the passive LP's fees. Asserted as an ordering, not
        // a number: the passive LP is worse off with the JIT LP in the world than without, on the same tape.
        assertLt(passivePnlBundle, passivePnlFcfs, "the JIT LP did not take anything from the passive LP");
    }

    /// @notice the world is seeded: the same seed reproduces the same run, a different seed gives a different one.
    /// Both halves matter - a result nobody can replay is a rumour, and a result that never varies is one draw.
    function test_the_world_is_reproducible_and_varies_with_the_seed() public {
        uint256 snap = vm.snapshotState();
        run(20);
        uint256 fillsA1 = worldA.fills();
        SimLedger.Books memory a1 = booksOf(address(worldA));
        vm.revertToState(snap);
        run(20);
        assertEq(worldA.fills(), fillsA1, "same seed, same tape");
        SimLedger.Books memory a2 = booksOf(address(worldA));
        assertEq(a2.amountInTotal, a1.amountInTotal, "same seed, same sizes");

        // and the seed is the ONLY thing that separates two otherwise identical traders: same seed, same decisions;
        // different seed, different ones. A world that ignored its seed would pass the replay check above and fail here.
        vm.revertToState(snap);
        RandomTrader twin = new RandomTrader("world-twin", VENUE_MAIN, seedUsed, 1e17, 8e17, 60, 5000, 0);
        RandomTrader other = new RandomTrader("world-other", VENUE_MAIN, seedUsed + 1000, 1e17, 8e17, 60, 5000, 0);
        _addAgent(twin, 200e18);
        _addAgent(other, 200e18);
        run(20);
        SimLedger.Books memory t = booksOf(address(twin));
        SimLedger.Books memory o = booksOf(address(other));
        assertEq(t.decided, a1.decided, "same seed, same decisions");
        assertEq(t.amountInTotal, a1.amountInTotal, "same seed, same sizes");
        assertTrue(o.amountInTotal != t.amountInTotal || o.decided != t.decided, "a different seed changed nothing");
    }
}
