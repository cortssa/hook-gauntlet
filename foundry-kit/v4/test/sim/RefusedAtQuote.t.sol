// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SimEngine} from "../../src/sim/SimEngine.sol";
import {SimLedger} from "../../src/sim/SimLedger.sol";
import {
    ISimAgent,
    ISimSearcher,
    SimView,
    Intent,
    Fill,
    KIND_SWAP,
    KIND_ADD_LIQUIDITY,
    REFUSED_AT_QUOTE
} from "../../src/sim/ISimAgent.sol";

/// @dev an agent that sends exactly the intents it is told to, and remembers what came back
contract ScriptedAgent is ISimAgent, ISimSearcher {
    uint256 internal immutable _latency;
    uint8 public kind;
    uint256 public size;
    uint256 public decisionsLeft;
    uint256 public wrapSize; // as a searcher: the size of the one front leg it places (0 = abstains)

    uint256 public settles;
    uint256 public settledAtStep;
    bool public lastExecuted;
    bytes4 public lastSelector;
    uint256 public lastGas;
    uint256 public wrapCalls;
    uint256 internal stepSeen;

    constructor(uint256 latency_, uint8 kind_, uint256 size_, uint256 decisions_, uint256 wrapSize_) {
        _latency = latency_;
        kind = kind_;
        size = size_;
        decisionsLeft = decisions_;
        wrapSize = wrapSize_;
    }

    function name() external pure returns (string memory) {
        return "scripted";
    }

    function latency() external view returns (uint256) {
        return _latency;
    }

    function observe(SimView calldata v) external {
        stepSeen = v.step;
    }

    function decide() external returns (bool wants, Intent memory it) {
        if (decisionsLeft == 0) return (false, it);
        decisionsLeft -= 1;
        it.kind = kind;
        it.amountIn = size;
        it.maxSlippageBps = 10_000;
        return (true, it);
    }

    function settle(Intent calldata, Fill calldata f) external {
        settles += 1;
        settledAtStep = stepSeen;
        lastExecuted = f.executed;
        lastSelector = f.revertSelector;
        lastGas = f.gasUsed;
    }

    function wrap(Intent calldata, SimView calldata) external returns (Intent[] memory before_) {
        wrapCalls += 1;
        if (wrapSize == 0) return before_;
        before_ = new Intent[](1);
        before_[0].kind = KIND_SWAP;
        before_[0].amountIn = wrapSize;
        before_[0].maxSlippageBps = 10_000;
    }

    function unwind(Intent calldata, Fill calldata, SimView calldata) external pure returns (Intent[] memory after_) {
        return after_;
    }
}

/// @notice A swap whose own quote at decision time was 0 is NOT SENT. A bot that reads its quote does not pay gas to
/// buy nothing: the engine does not execute it, charges no gas, settles it at once with `executed == false` and the
/// `REFUSED_AT_QUOTE` marker, and the ledger counts it in `refusedAtQuote`, never in `refused`. Every other kind is
/// untouched (it carries no quote: its `quotedOut` is always 0). The refused swap is KEPT IN THE QUEUE FOR THE RECORD,
/// marked done, never in the execution order, never shown to a searcher.
///
/// What this file proves is the engine's POLICY for a quote of 0, on a stub market whose quote is 0 by construction. It
/// does not prove that any real quote of 0 is right: that is the binding's `_quote`, tested where the binding is.
///
/// Written after a binding's agents ignored their own quote on a fork: 841 swaps quoted 0 were sent, all 841 came back
/// empty at ~250 000 gas each, and the ledger showed them as a market that refused (2026-09-22). The engine here is a
/// market with a hole in it: nothing is fillable at size `DRY`, everything else fills 1:1.
contract EngineRefusesAtQuote is SimEngine {
    uint256 constant DRY = 7;
    uint256 public executeCalls;

    function setUp() public {
        label = "at-quote";
        _initEngine();
        ledger.setGasPrice(0);
    }

    function _quote(Intent memory it) internal pure override returns (uint256) {
        return it.amountIn == DRY ? 0 : it.amountIn;
    }

    function _execute(Intent memory it) internal override returns (Fill memory f) {
        executeCalls += 1;
        f.executed = true;
        f.amountOut = it.amountIn;
        f.amountInUsed = it.amountIn;
        f.gasUsed = 50_000;
    }

    function _sqrtPriceNow(uint8) internal pure override returns (uint160) {
        return 0;
    }

    function _balances(address) internal pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function _referencePriceX96() internal pure override returns (uint256) {
        return 0;
    }

    function _agent(uint256 latency_, uint8 kind_, uint256 size_, uint256 decisions_, uint256 wrapSize_)
        internal
        returns (ScriptedAgent a)
    {
        a = new ScriptedAgent(latency_, kind_, size_, decisions_, wrapSize_);
        _registerAgent(a);
    }

    function test_a_swap_quoted_zero_is_never_sent() public {
        ScriptedAgent a = _agent(2, KIND_SWAP, DRY, 1, 0);
        run(1);
        // settled AT DECISION, not `latency` steps later: the agent was told "nothing" when it asked
        assertEq(a.settles(), 1, "the agent was not told at decision time that its swap was not sent");
        assertEq(a.settledAtStep(), 1);
        run(4);
        assertEq(executeCalls, 0, "a swap quoted 0 was sent to the binding");
        assertEq(a.settles(), 1, "settled twice");
        assertFalse(a.lastExecuted());
        assertEq(a.lastSelector(), REFUSED_AT_QUOTE, "the fill does not say why it was not executed");
        assertEq(a.lastGas(), 0, "a swap that was never sent cost gas");
        assertEq(executedOrderOf(0), 0, "a swap that was never sent has an execution order");

        SimLedger.Books memory b = booksOf(address(a));
        assertEq(b.decided, 1);
        assertEq(b.refusedAtQuote, 1, "not counted as refused at quote");
        assertEq(b.refused, 0, "counted as a refusal of the market: it was never sent to one");
        assertEq(b.executed, 0);
        assertEq(b.gasTotal, 0, "gas charged for a swap that was never sent");

        string memory l = ledger.line(label, address(a), 0, 0, 0);
        // ... refused ... gas pnl gasCost pnlNet atQuote
        assertTrue(_endsWith(l, "\t0\t0\t0\t0\t1"), "the dump line does not end with gas, pnl, gasCost, pnlNet, atQuote");
    }

    function test_control_a_swap_quoted_above_zero_is_sent() public {
        ScriptedAgent a = _agent(2, KIND_SWAP, 100, 1, 0);
        run(5);
        assertEq(executeCalls, 1, "a swap with a quote was not sent: the test above proves nothing");
        SimLedger.Books memory b = booksOf(address(a));
        assertEq(b.executed, 1);
        assertEq(b.refusedAtQuote, 0);
        assertEq(b.gasTotal, 50_000);
        assertTrue(a.lastExecuted());
        assertEq(a.settledAtStep(), 3, "executed `latency` steps after the decision");
    }

    function test_a_non_swap_kind_is_untouched() public {
        // a liquidity change carries no quote: its `quotedOut` is always 0, and it must be executed all the same
        ScriptedAgent a = _agent(0, KIND_ADD_LIQUIDITY, 0, 1, 0);
        run(2);
        assertEq(executeCalls, 1, "a non-swap was held back by the swap's quote rule");
        SimLedger.Books memory b = booksOf(address(a));
        assertEq(b.executed, 1);
        assertEq(b.refusedAtQuote, 0, "a non-swap was counted as refused at quote");
    }

    function test_a_searchers_leg_quoted_zero_is_never_sent() public {
        ordering = Ordering.BUNDLE;
        ScriptedAgent victim = _agent(0, KIND_SWAP, 100, 1, 0);
        ScriptedAgent searcher = _agent(0, KIND_SWAP, 0, 0, DRY); // never decides; wraps with a front leg quoted 0
        _registerSearcher(searcher);
        run(1);
        assertEq(searcher.wrapCalls(), 1);
        assertEq(executeCalls, 1, "the searcher's leg quoted 0 was sent (only the victim should have been)");
        assertTrue(victim.lastExecuted());
        SimLedger.Books memory s = booksOf(address(searcher));
        assertEq(s.decided, 1);
        assertEq(s.refusedAtQuote, 1);
        assertEq(s.executed + s.refused, 0);
        assertEq(searcher.settles(), 1, "the searcher's leg was not settled exactly once");
        assertEq(searcher.lastSelector(), REFUSED_AT_QUOTE);
    }

    function test_under_bundle_a_victim_quoted_zero_is_shown_to_nobody() public {
        // it never reached a mempool: there is nothing to see, and nothing to wrap
        ordering = Ordering.BUNDLE;
        ScriptedAgent victim = _agent(0, KIND_SWAP, DRY, 1, 0);
        ScriptedAgent searcher = _agent(0, KIND_SWAP, 0, 0, 100);
        _registerSearcher(searcher);
        run(2);
        assertEq(searcher.wrapCalls(), 0, "a swap that was never sent was shown to a searcher");
        assertEq(executeCalls, 0);
        assertEq(booksOf(address(victim)).refusedAtQuote, 1);
    }

    /// @notice "not sent" is not "forgotten": the refused swap stays in the queue FOR THE RECORD - `queueLength()` counts
    /// it, `intentAt` returns it with its quote of 0 - and it is marked done, so it is NEVER in the execution order
    /// (`executedOrderOf` stays 0 and the swap sent after it is number 1, not 2). A reader who counts the queue must know
    /// the refused ones are in it; a reader who walks the execution order must know they are not.
    function test_a_swap_refused_at_quote_is_kept_for_the_record_and_never_in_the_execution_order() public {
        ScriptedAgent dry = _agent(0, KIND_SWAP, DRY, 1, 0);
        ScriptedAgent wet = _agent(0, KIND_SWAP, 100, 1, 0);
        run(3);
        assertEq(queueLength(), 2, "the refused swap is not in the queue: the record lost it");
        assertEq(intentAt(0).agent, address(dry));
        assertEq(intentAt(0).amountIn, DRY);
        assertEq(intentAt(0).quotedOut, 0, "the record does not carry the quote that refused it");
        assertEq(executedOrderOf(0), 0, "a swap that was never sent has a place in the execution order");
        assertEq(intentAt(1).agent, address(wet));
        assertEq(executedOrderOf(1), 1, "the swap sent after a refused one is not first in the execution order");
        assertEq(executedCount, 1, "the execution order counts a swap that was never sent");
        assertEq(executeCalls, 1);
        assertEq(dry.settles(), 1, "the refused swap was settled again by a later scan");
    }

    function _endsWith(string memory s, string memory suffix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(suffix);
        if (b.length > a.length) return false;
        for (uint256 i = 0; i < b.length; i++) {
            if (a[a.length - b.length + i] != b[i]) return false;
        }
        return true;
    }
}
