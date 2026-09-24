// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ISimAgent, ISimSearcher, SimView, Intent, Fill, KIND_SWAP, REFUSED_AT_QUOTE} from "./ISimAgent.sol";
import {SimClock} from "./SimClock.sol";
import {SimLedger} from "./SimLedger.sol";

/// @title SimEngine - the simulation sandbox's engine, with no opinion about the hook
/// @notice A clock with the target chain's cadence, a queue of intents that are QUOTED when decided and EXECUTED
/// `latency` steps later under an ordering model, agents as contracts, and a ledger per agent. It knows nothing
/// about pools, routers or hooks: a project binds it to its own system by overriding five verbs -
///
///   _quote(intent)        what would this intent return NOW (a quoter, a lens, a swap in a snapshot)
///   _execute(intent)      do it, and say what happened
///   _sqrtPriceNow(venue)  the price the agents may observe, per venue
///   _balances(agent)      the two balances the ledger values
///   _referencePriceX96()  the price the ledger values currency0 at (the main market's, when there is one)
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
///
/// A SWAP QUOTED 0 IS NOT SENT. The quote is taken when the intent is decided; if it says 0 - nothing fillable at that
/// size, in that direction, now - the engine does what a bot that reads its quote does: it does not send. No `_execute`
/// and no gas. The intent is KEPT IN THE QUEUE FOR THE RECORD, MARKED DONE, NEVER IN THE EXECUTION ORDER, NEVER SHOWN TO
/// A SEARCHER: `queueLength()` counts it and `intentAt(i)` returns it (its quote included), `executedOrderOf(i)` is 0
/// for it forever, and neither the FCFS scan nor a searcher's `wrap` ever sees it. The agent's `settle` is called at once
/// with `executed == false` and `revertSelector == REFUSED_AT_QUOTE`, and the ledger counts it in `refusedAtQuote`, apart
/// from `refused` (sent, and came back empty). Other kinds carry no quote and are untouched. Written after a binding's
/// agents sent 841 swaps quoted 0 on a fork: every one came back empty at ~250 000 gas and read as a market refusing.
/// (`test/sim/RefusedAtQuote.t.sol` proves the POLICY - what the engine does with a quote of 0 - on a stub market. Whether
/// a given binding's quote of 0 is right is that binding's question, not this test's.)
///
/// A SWAP THAT WAS SENT AND TOOK NOTHING DID NOT EXECUTE. A book whose side empties between the quote and the fill (another
/// order took it, a maker cancelled) fills nothing, legitimately. The binding reports that as `executed == false` with
/// `revertSelector == FILLED_NOTHING`: settled like any refusal, its gas on the books, counted in `refused`. A fill
/// reported as EXECUTED with no input taken is refused loudly (`FillWithoutInput`, whose `rule` says the above), because
/// it is also what a binding that forgot `Fill.amountInUsed` looks like (`test/sim/FilledNothing.t.sol`).
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
    /// @notice the order in which intents were EXECUTED (1 = first), 0 = not yet (or never: a swap refused at its quote,
    /// which stays in `queue` for the record but never gets a number here). The one record that lets a test
    /// assert that a bundle ran front-run, victim, back-run in that order - and not merely that three swaps happened.
    uint256[] internal executedOrder;
    uint256 internal executedCount;
    uint256 internal seq;
    uint256 public step;

    /// @notice a swap fill reported as EXECUTED with no input taken (`Fill.amountInUsed == 0`). Either the binding forgot to
    /// report the input (every partial fill would then look whole), or the swap really took nothing - a book side that
    /// emptied between the quote and the fill - and then it did not execute: the binding reports `executed = false` with
    /// `revertSelector = FILLED_NOTHING`, and the ledger counts it as refused. `rule` says so in the revert itself.
    error FillWithoutInput(uint256 intentIndex, string rule);

    string internal constant FILLED_NOTHING_RULE =
        "a swap that took no input did not execute: report executed=false, revertSelector=FILLED_NOTHING (counted as refused); an executed swap reports amountInUsed";

    string internal label = "scenario";

    // ------------------------------------------------------------------ the five verbs a project binds
    function _quote(Intent memory it) internal virtual returns (uint256 out);
    function _execute(Intent memory it) internal virtual returns (Fill memory f);
    function _sqrtPriceNow(uint8 venue) internal view virtual returns (uint160);
    function _balances(address agent) internal view virtual returns (uint256 bal0, uint256 bal1);
    /// @notice the price the ledger values currency0 at, quote per custody in Q96. The main market's if there is one.
    function _referencePriceX96() internal view virtual returns (uint256);

    // ------------------------------------------------------------------ setup
    /// @notice the file the ledger writes its lines to: `GAUNTLET_SIM`, or "" for none. Probed once by `_initEngine`
    /// (`SimLedger.LedgerNotWritable`). Virtual only so that a test can name an unwritable path without setting a
    /// process-wide variable that every test running in parallel would see; a binding has no reason to override it.
    function _ledgerPath() internal view virtual returns (string memory) {
        return vm.envOr("GAUNTLET_SIM", string(""));
    }

    function _initEngine() internal {
        if (cadence.l2BlockMillis == 0) cadence = SimClock.ethereumL1();
        ledger = new SimLedger();
        // the ledger file is checked NOW, not at the first write after the last step: a project whose foundry.toml does not
        // let tests write there used to run a whole scenario and then fail with forge's generic error
        string memory path = _ledgerPath();
        if (bytes(path).length != 0) ledger.probeWritable(path);
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

    /// @return sent false when the intent was a swap quoted 0: settled here as REFUSED_AT_QUOTE, never to be executed
    function _submit(Intent memory it, address agent, uint256 decidedAt, uint256 executeAt) internal returns (bool sent) {
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
        if (_unsent(it)) {
            _refuseAtQuote(queue.length - 1);
            return false;
        }
        return true;
    }

    /// @notice a swap its own quote said returns nothing: a bot that reads its quote does not send it
    function _unsent(Intent memory it) internal pure returns (bool) {
        return it.kind == KIND_SWAP && it.quotedOut == 0;
    }

    /// @dev settled at decision time: kept in the queue for the record, marked done (the FCFS scan and the searchers
    /// never see it), never in the execution order, no gas, counted apart from the refusals of the market
    function _refuseAtQuote(uint256 i) internal {
        done[i] = true;
        Fill memory f;
        f.revertSelector = REFUSED_AT_QUOTE;
        ledger.noteRefusedAtQuote(queue[i]);
        ISimAgent(queue[i].agent).settle(queue[i], f);
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
        uint256 n = idx.length;
        for (uint256 j = 0; j < n; j++) out[j] = idx[j];
        for (uint256 j = 0; j < its.length; j++) {
            if (!_submit(its[j], agent, s, s)) continue; // a searcher's leg quoted 0: never sent, already settled
            done[queue.length - 1] = true; // executed here, not by the FCFS scan
            out[n++] = queue.length - 1;
        }
        assembly {
            mstore(out, n) // only the legs that were sent
        }
    }

    function _settleOne(uint256 i) internal returns (Fill memory f) {
        executedOrder[i] = ++executedCount;
        f = _execute(queue[i]);
        // a binding that forgot to report the input taken would make every partial fill look whole: refuse loudly
        if (f.executed && queue[i].kind == 0 && queue[i].amountIn > 0 && f.amountInUsed == 0) {
            revert FillWithoutInput(i, FILLED_NOTHING_RULE);
        }
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
