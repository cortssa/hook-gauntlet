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
/// seeded world. The same population is run under BOTH orderings, from one snapshot, so that the two ledgers are
/// directly comparable: the only thing that differs is whether the JIT LP was ever asked.
///
/// What is asserted, and what is only measured. An earlier version of this file asserted the result of ONE seed as
/// "the shape" of JIT liquidity (the passive LP is worse off with the JIT LP in the world) and a fresh reader turned
/// it red with `SIM_SEED=2`: on seeds 2 and 3 the JIT LP lost money and the passive LP was not worse off. So:
///   * `test_the_jit_lp_on_SIM_SEED_is_asked_only_under_bundle` reads `SIM_SEED` (default 1) and asserts only what
///     holds on EVERY seed - the ordering decides who is asked, every intent settles once - and prints the P&Ls;
///   * `test_over_seeds_1_to_5_...` runs the five seeds named in its name, whatever `SIM_SEED` says, and asserts the
///     COUNTS measured on them (stated in the test and in the README), so that a change to the engine, an agent or the
///     hook that moves the distribution goes red and has to be re-measured, not re-worded.
///
/// Measured on seeds 1-5 (2026-09-23): the passive LP is worse off with the JIT LP in the world on ONE seed of five
/// (seed 1, the one the old assertion was written from), and better off on the other four; the JIT LP profits on the
/// same one seed and loses on the other four. What held on all five is the pairing: the JIT LP's P&L and the change in
/// the passive LP's P&L have OPPOSITE signs - what one gains the other gives, whichever way it goes. On this
/// population what the JIT LP takes is a share of the pool's fortunes - the passive LP's fees on seed 1, its losses to
/// price moves on the other four - and "JIT liquidity takes the passive LP's fees" is one seed of five.
contract LiquidityScenario is ExampleScenario {
    RandomTrader worldA;
    RandomTrader worldB;
    HonestTrader victim;
    PassiveLP passive;
    JitLP jit;
    uint256 seedUsed;

    /// @notice measured on seeds 1-5 (forge 1.8.1, 2026-09-23, the one-block-late example hook): see the README table
    uint256 internal constant SEEDS = 5;
    uint256 internal constant PASSIVE_WORSE_MEASURED = 1;
    uint256 internal constant JIT_PROFITABLE_MEASURED = 1;
    uint256 internal constant OPPOSITE_SIGNS_MEASURED = 5;

    struct Outcome {
        int256 passiveFcfs;
        int256 passiveBundle;
        int256 jitBundle;
        uint256 wraps;
    }

    function setUp() public {
        cadence = SimClock.ethereumL1();
        _setUpScenario(50e18);
        _addMainMarket(3000, 100e18);
        seedUsed = vm.envOr("SIM_SEED", uint256(1));
    }

    function _population(uint256 seed) internal {
        worldA = new RandomTrader("world-a", VENUE_MAIN, seed, 1e17, 8e17, 60, 5000, 0);
        worldB = new RandomTrader("world-b", VENUE_MAIN, seed + 1, 1e17, 5e17, 40, 5000, 1);
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

    /// @dev one seed, both orderings, from one snapshot; the state is put back as it was before the population, so the
    /// next seed starts from the same market. Asserts only what holds on every seed.
    function _bothOrderings(uint256 seed) internal returns (Outcome memory o) {
        uint256 base = vm.snapshotState();
        _population(seed);
        uint256 snap = vm.snapshotState();

        ordering = SimEngine.Ordering.FCFS;
        label = "liquidity-fcfs";
        run(60);
        _finish();
        SimLedger.Books memory jF = booksOf(address(jit));
        SimLedger.Books memory pF = booksOf(address(passive));
        (uint256 p0F, uint256 p1F) = _balances(address(passive));
        o.passiveFcfs = ledger.pnl(address(passive), p0F, p1F, _referencePriceX96());
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
        o.passiveBundle = ledger.pnl(address(passive), p0B, p1B, _referencePriceX96());
        (uint256 j0, uint256 j1) = _balances(address(jit));
        o.jitBundle = ledger.pnl(address(jit), j0, j1, _referencePriceX96());
        o.wraps = jit.wraps();

        assertGt(jit.wraps(), 0, "the JIT LP saw swaps");
        assertEq(jB.decided, jit.wraps() * 2, "one add and one remove per wrap");
        assertEq(jB.executed + jB.refused, jB.decided, "every JIT intent settled once");
        assertEq(pB.executed, 2);
        console2.log("seed", seed);
        console2.log("  passive LP pnl, FCFS   :", o.passiveFcfs);
        console2.log("  passive LP pnl, BUNDLE :", o.passiveBundle);
        console2.log("  JIT LP pnl, BUNDLE     :", o.jitBundle);
        console2.log("  JIT wraps              :", o.wraps);

        vm.revertToState(base);
    }

    /// @notice `SIM_SEED=<n> forge test --match-test SIM_SEED` - one seed, read honestly: the assertions are the ones
    /// that hold on every seed; the P&Ls are printed, and a direction on one seed is one draw.
    function test_the_jit_lp_on_SIM_SEED_is_asked_only_under_bundle() public {
        _bothOrderings(seedUsed);
    }

    /// @notice the claim of JIT liquidity, over the five seeds this file names: counted, not asserted per seed.
    /// `forge test --match-path test/sim/Liquidity.t.sol --match-test over_seeds -vv` prints the five P&L triples.
    function test_over_seeds_1_to_5_the_counts_of_passive_worse_off_and_jit_profitable_are_as_measured() public {
        uint256 passiveWorse;
        uint256 jitProfitable;
        uint256 opposite;
        for (uint256 s = 1; s <= SEEDS; s++) {
            // five seeds x two orderings do not fit in one test's gas limit (measured: out of gas in the fourth seed).
            // Resetting the TEST frame's meter changes no number here: every gas figure in the ledger is metered per
            // action by SimGasMeter from forge's record of that call, never from this frame's gasleft().
            vm.resetGasMetering();
            Outcome memory o = _bothOrderings(s);
            int256 passiveDelta = o.passiveBundle - o.passiveFcfs;
            if (passiveDelta < 0) passiveWorse += 1;
            if (o.jitBundle > 0) jitProfitable += 1;
            if ((o.jitBundle > 0 && passiveDelta < 0) || (o.jitBundle < 0 && passiveDelta > 0)) opposite += 1;
        }
        console2.log("seeds 1-5: passive LP worse off under BUNDLE in", passiveWorse);
        console2.log("seeds 1-5: JIT LP profitable in                 ", jitProfitable);
        console2.log("seeds 1-5: JIT P&L and passive change opposite  ", opposite);
        assertEq(passiveWorse, PASSIVE_WORSE_MEASURED, "the passive-LP count moved: re-measure, then re-state it");
        assertEq(jitProfitable, JIT_PROFITABLE_MEASURED, "the JIT-profit count moved: re-measure, then re-state it");
        assertEq(opposite, OPPOSITE_SIGNS_MEASURED, "the JIT LP and the passive LP no longer trade places on every seed");
    }

    /// @notice the world is seeded: the same seed reproduces the same run, a different seed gives a different one.
    /// Both halves matter - a result nobody can replay is a rumour, and a result that never varies is one draw.
    function test_the_world_is_reproducible_and_varies_with_the_seed() public {
        _population(seedUsed);
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
