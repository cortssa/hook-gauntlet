// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ISimAgent, ISimSearcher, SimView, Intent, Fill} from "./ISimAgent.sol";
import {SimClock} from "./SimClock.sol";
import {SimLedger} from "./SimLedger.sol";

/// @title SimEngine - the simulation sandbox's engine, with no opinion about the hook
/// @notice A clock with the target chain's cadence, a queue of intents that are QUOTED when decided and EXECUTED
/// `latency` steps later under an ordering model, agents as contracts, and a ledger per agent. It knows nothing
/// about pools, routers or hooks: a project binds it to its own system by overriding four verbs -
///
///   _quote(intent)        what would this intent return NOW (a quoter, a lens, a swap in a snapshot)
///   _execute(intent)      do it, and say what happened
///   _sqrtPriceNow(venue)  the price the agents may observe, per venue
///   _balances(agent)      the two balances the ledger values
///
/// `ExampleScenario.sol` binds it to the kit's example hook; a project with its own router and its own quoter binds
/// it to those. The loop, the clock, the queue and the books are the same either way.
///
/// What this measures and what it does not (`doctrine/EVIDENCE.md`: the label is SUPPORTED, never proved): for THIS
/// population under THIS ordering model, who ends richer, who poorer, and how far execution drifts from the quote.
/// A fuzz campaign searches for one sequence that breaks a rule; this measures a distribution over many structured
/// sequences. It does not find the attack nobody wrote an agent for: the dossier lists the agents that ran, so that
/// the absence of one is visible.
///
/// ORDERING is a parameter, because it is the assumption that decides which attacks exist at all:
///   FCFS    first-come-first-served by the step an intent reaches the sequencer, ties by submission order. A
///           single-sequencer chain with no public mempool: nobody sees a pending intent, nobody buys position.
///           What remains is reacting faster than others to public information.
///   BUNDLE  every intent about to execute is shown to the searcher agents, who may place their own before and
///           after it. A chain with a public mempool or builder bundles. Sandwiches and JIT liquidity live here.
/// Every number the ledger prints is a number UNDER ONE OF THESE, and the report says which. Run the same population
/// under both: the difference is what the ordering model is worth to an attacker, and it is often the whole result.
abstract contract SimEngine is Test {
    enum Ordering {
        FCFS,
        BUNDLE
    }

    SimClock.Cadence internal cadence;
    Ordering public ordering = Ordering.FCFS;
    SimLedger public ledger;

    ISimAgent[] internal agents;
    ISimSearcher[] internal searchers;
    Intent[] internal queue;
    bool[] internal done;
    /// @notice the order in which intents were EXECUTED (1 = first), 0 = not yet. The one record that lets a test
    /// assert that a bundle ran front-run, victim, back-run in that order - and not merely that three swaps happened.
    uint256[] internal executedOrder;
    uint256 internal executedCount;
    uint256 internal seq;
    uint256 public step;

    /// @notice a swap fill reported as executed without the input it took (`Fill.amountInUsed`)
    error FillWithoutInput(uint256 intentIndex);
    string internal label = "scenario";

    // ------------------------------------------------------------------ the four verbs a project binds
    function _quote(Intent memory it) internal virtual returns (uint256 out);
    function _execute(Intent memory it) internal virtual returns (Fill memory f);
    function _sqrtPriceNow(uint8 venue) internal view virtual returns (uint160);
    function _balances(address agent) internal view virtual returns (uint256 bal0, uint256 bal1);
    /// @notice the price the ledger values currency0 at, quote per custody in Q96. The main market's if there is one.
    function _referencePriceX96() internal view virtual returns (uint256);

    // ------------------------------------------------------------------ setup
    function _initEngine() internal {
        if (cadence.l2BlockMillis == 0) cadence = SimClock.ethereumL1();
        ledger = new SimLedger();
        _applyClock(0);
    }

    /// @notice put an agent on the books. The project funds and approves it BEFORE calling this: the balances read
    /// here are the ones its P&L is measured from.
    function _registerAgent(ISimAgent a) internal {
        agents.push(a);
        (uint256 b0, uint256 b1) = _balances(address(a));
        ledger.register(address(a), a.name(), b0, b1);
    }

    /// @notice an agent that is ALSO a searcher: asked to bundle under BUNDLE ordering, ignored under FCFS
    function _registerSearcher(ISimSearcher s) internal {
        searchers.push(s);
    }

    // ------------------------------------------------------------------ the loop
    /// @notice advance the world by `steps` steps, CONTINUING from where the last call stopped: a scenario may add agents
    /// between two calls (the makers before the traders), and a test may snapshot, run, revert and run again
    function run(uint256 steps) public {
        // the binding must have priced gas (`ledger.setGasPrice`, 0 included) before the first step, not be told so by
        // the dump line after the last one
        if (!ledger.gasPriced()) revert SimLedger.GasUnpriced();
        uint256 from = step;
        for (uint256 s = from + 1; s <= from + steps; s++) {
            step = s;
            _applyClock(s);
            SimView memory v = _view();
            for (uint256 i = 0; i < agents.length; i++) {
                agents[i].observe(v);
                (bool wants, Intent memory it) = agents[i].decide();
                if (!wants) continue;
                _submit(it, address(agents[i]), s, s + agents[i].latency());
            }
            _executeDue(s, v);
        }
    }

    function _submit(Intent memory it, address agent, uint256 decidedAt, uint256 executeAt) internal {
        it.agent = agent;
        it.decidedAtStep = decidedAt;
        it.executeAtStep = executeAt;
        it.seq = ++seq;
        if (it.kind == 0) {
            it.quotedOut = _quote(it);
            it.minOut = it.quotedOut * (10_000 - _clampBps(it.maxSlippageBps)) / 10_000;
        }
        ledger.noteDecided(it);
        queue.push(it);
        done.push(false);
        executedOrder.push(0);
    }

    /// @notice every intent whose step has come, in submission order; under BUNDLE each one is first shown to the
    /// searchers, whose intents are executed around it
    function _executeDue(uint256 s, SimView memory v) internal virtual {
        for (uint256 i = 0; i < queue.length; i++) {
            if (done[i] || queue[i].executeAtStep > s) continue;
            done[i] = true;
            if (ordering == Ordering.BUNDLE && searchers.length > 0) {
                _executeBundled(i, s, v);
            } else {
                _settleOne(i);
            }
        }
    }

    function _executeBundled(uint256 victimIdx, uint256 s, SimView memory v) internal {
        // the searchers see the victim's intent, quote included - what a mempool watcher sees - and wrap it
        uint256[] memory beforeIdx;
        for (uint256 k = 0; k < searchers.length; k++) {
            beforeIdx = _append(beforeIdx, searchers[k].wrap(queue[victimIdx], v), address(searchers[k]), s);
        }
        for (uint256 j = 0; j < beforeIdx.length; j++) _settleOne(beforeIdx[j]);
        Fill memory victimFill = _settleOne(victimIdx);
        uint256[] memory afterIdx;
        for (uint256 k = 0; k < searchers.length; k++) {
            afterIdx = _append(afterIdx, searchers[k].unwind(queue[victimIdx], victimFill, v), address(searchers[k]), s);
        }
        for (uint256 j = 0; j < afterIdx.length; j++) _settleOne(afterIdx[j]);
    }

    function _append(uint256[] memory idx, Intent[] memory its, address agent, uint256 s)
        internal
        returns (uint256[] memory out)
    {
        out = new uint256[](idx.length + its.length);
        for (uint256 j = 0; j < idx.length; j++) out[j] = idx[j];
        for (uint256 j = 0; j < its.length; j++) {
            _submit(its[j], agent, s, s);
            done[queue.length - 1] = true; // executed here, not by the FCFS scan
            out[idx.length + j] = queue.length - 1;
        }
    }

    function _settleOne(uint256 i) internal returns (Fill memory f) {
        executedOrder[i] = ++executedCount;
        f = _execute(queue[i]);
        // a binding that forgot to report the input taken would make every partial fill look whole: refuse loudly
        if (f.executed && queue[i].kind == 0 && queue[i].amountIn > 0 && f.amountInUsed == 0) revert FillWithoutInput(i);
        ledger.noteFill(queue[i], f);
        ISimAgent(queue[i].agent).settle(queue[i], f);
    }

    // ------------------------------------------------------------------ clock and view
    function _applyClock(uint256 s) internal {
        vm.roll(SimClock.blockNumberAt(cadence, s));
        vm.warp(SimClock.timestampAt(cadence, s));
    }

    function _view() internal view returns (SimView memory v) {
        v = SimView({
            step: step,
            l2Block: step,
            l1BlockEstimate: block.number,
            timestamp: block.timestamp,
            sqrtPriceX96: _sqrtPriceNow(0),
            mainSqrtPriceX96: _sqrtPriceNow(1)
        });
    }

    function _clampBps(uint256 bps) internal pure returns (uint256) {
        return bps > 10_000 ? 10_000 : bps;
    }

    // ------------------------------------------------------------------ the books
    /// @notice write every agent's line (to `GAUNTLET_SIM` if set) and print them
    function _finish() internal {
        uint256 px = _referencePriceX96();
        for (uint256 i = 0; i < agents.length; i++) {
            address a = address(agents[i]);
            (uint256 b0, uint256 b1) = _balances(a);
            ledger.write(label, a, b0, b1, px);
            console2.log(ledger.line(label, a, b0, b1, px));
        }
    }

    function booksOf(address a) public view returns (SimLedger.Books memory b) {
        return ledger.get(a);
    }

    function agentCount() public view returns (uint256) {
        return agents.length;
    }

    function queueLength() public view returns (uint256) {
        return queue.length;
    }

    function intentAt(uint256 i) public view returns (Intent memory) {
        return queue[i];
    }

    function executedOrderOf(uint256 i) public view returns (uint256) {
        return executedOrder[i];
    }
}
