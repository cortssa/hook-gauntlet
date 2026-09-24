// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SimEngine} from "../../src/sim/SimEngine.sol";
import {SimLedger} from "../../src/sim/SimLedger.sol";
import {SimClock} from "../../src/sim/SimClock.sol";
import {ExampleScenario} from "../../src/sim/ExampleScenario.sol";
import {
    ISimAgent,
    SimView,
    Intent,
    Fill,
    KIND_SWAP,
    KIND_REMOVE_LIQUIDITY,
    KIND_ADD_LIQUIDITY,
    FILLED_NOTHING
} from "../../src/sim/ISimAgent.sol";
import {HonestTrader} from "../../src/sim/agents/HonestTrader.sol";

/// @dev one swap of `size`, decided at the first step it is asked, with no slippage rule; remembers what came back.
/// Its own copy, not RefusedAtQuote.t.sol's: importing a test file makes forge run that file's suite a second time.
contract OneSwapAgent is ISimAgent {
    uint256 internal immutable _latency;
    uint256 public immutable size;
    bool internal decided;
    bool public lastExecuted;
    bytes4 public lastSelector;

    constructor(uint256 latency_, uint256 size_) {
        _latency = latency_;
        size = size_;
    }

    function name() external pure returns (string memory) {
        return "one-swap";
    }

    function latency() external view returns (uint256) {
        return _latency;
    }

    function observe(SimView calldata) external {}

    function decide() external returns (bool wants, Intent memory it) {
        if (decided) return (false, it);
        decided = true;
        it.kind = KIND_SWAP;
        it.amountIn = size;
        it.maxSlippageBps = 10_000;
        return (true, it);
    }

    function settle(Intent calldata, Fill calldata f) external {
        lastExecuted = f.executed;
        lastSelector = f.revertSelector;
    }
}

/// @notice A book (or a pool) whose side EMPTIES between the quote and the fill. The quote was not 0, so the swap was
/// sent; by the time it executes somebody else has taken everything, and it takes nothing. That is a legitimate market
/// outcome, not a binding bug, and the contract for it is: the binding reports `executed == false` with the
/// `FILLED_NOTHING` marker, the ledger counts it in `refused` (it was sent and came back empty, gas paid), and the run
/// goes on. Before 2026-09-23 the only thing a binding could do was report `executed == true` with no input taken, and
/// the engine aborted the whole run with `FillWithoutInput` (both arms of the second blind run hit it on a book venue).
///
/// The engine still refuses `executed == true` with nothing taken - a binding that forgot `amountInUsed` would make
/// every partial fill look whole - and its revert now says what to report instead (`FILLED_NOTHING_RULE`).
///
/// The market here: one side of `DEPTH`, taken first come first served, quoted as whatever is left NOW.
contract EngineFilledNothing is SimEngine {
    uint256 constant DEPTH = 100;
    uint256 constant SENT_GAS = 30_000;
    uint256 public depth = DEPTH;
    bool public careless; // a binding that reports a fill that took nothing as executed

    function setUp() public {
        label = "filled-nothing";
        _initEngine();
        ledger.setGasPrice(0);
    }

    function _quote(Intent memory it) internal view override returns (uint256) {
        return it.amountIn < depth ? it.amountIn : depth;
    }

    function _execute(Intent memory it) internal override returns (Fill memory f) {
        uint256 take = it.amountIn < depth ? it.amountIn : depth;
        f.gasUsed = SENT_GAS; // sent: the gas is paid whatever came back
        if (take == 0 && !careless) {
            f.executed = false;
            f.revertSelector = FILLED_NOTHING;
            return f;
        }
        depth -= take;
        f.executed = true;
        f.amountOut = take;
        f.amountInUsed = take;
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

    function _two() internal returns (OneSwapAgent first, OneSwapAgent second) {
        // both decide at step 1 and both are quoted the whole side; both execute at step 2, first one first
        first = new OneSwapAgent(1, DEPTH);
        _registerAgent(first);
        second = new OneSwapAgent(1, DEPTH);
        _registerAgent(second);
    }

    function test_a_side_emptied_between_quote_and_fill_is_refused_not_a_revert() public {
        (OneSwapAgent first, OneSwapAgent second) = _two();
        run(2);
        assertEq(intentAt(0).quotedOut, DEPTH, "first: quoted the whole side");
        assertEq(intentAt(1).quotedOut, DEPTH, "second: quoted the whole side too (the quote was not 0: it was SENT)");
        SimLedger.Books memory a = booksOf(address(first));
        SimLedger.Books memory b = booksOf(address(second));
        assertEq(a.executed, 1, "the first took the side");
        assertEq(a.amountInTotal, DEPTH);
        assertEq(b.executed, 0, "the second took nothing: not executed");
        assertEq(b.refused, 1, "and it is counted as refused (sent, came back empty)");
        assertEq(b.refusedAtQuote, 0, "never as refused-at-quote: its quote was not 0");
        assertEq(b.amountInTotal, 0);
        assertEq(b.gasTotal, SENT_GAS, "it was sent: its gas is on the books");
        assertFalse(second.lastExecuted());
        assertEq(second.lastSelector(), FILLED_NOTHING, "the agent is told why");
        assertEq(executedOrderOf(1), 2, "it was in the execution order: sent, not refused at the quote");
    }

    function test_a_binding_that_reports_nothing_taken_as_executed_is_told_what_to_report() public {
        careless = true;
        _two();
        // the revert data compared BYTE FOR BYTE: with `vm.expectRevert(bytes)` this case was GREEN on the old engine, whose
        // one-field `FillWithoutInput(1)` forge 1.8.1 accepted against the expected two-field data (measured 2026-09-23)
        try this.run(2) {
            assertTrue(false, "a fill that took nothing, reported as executed, did not revert");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(SimEngine.FillWithoutInput.selector, uint256(1), FILLED_NOTHING_RULE));
        }
    }
}

/// @notice The same on the example binding: a v4 pool whose only liquidity is withdrawn between a trader's quote and its
/// execution. The swap then walks an empty pool, takes no input and gives no output; `ExampleScenario` reports it
/// `executed == false`, `FILLED_NOTHING`, and rolls the empty swap's price move back (it did not trade).
contract ExampleFilledNothing is ExampleScenario {
    HonestTrader trader;
    int256 constant RANGE_LIQUIDITY = 1e21;

    function setUp() public {
        cadence = SimClock.ethereumL1();
        label = "filled-nothing-v4";
        // as in PartialFill.t.sol: no full-range liquidity (one wei in, one wei out), all of it in one narrow range
        _setUpScenario(1);
        _addFullRangeLiquidity(key, provider, -1);
        _fundAndApprove(provider, 1e24);
        _range(RANGE_LIQUIDITY);
        trader = new HonestTrader("late", 1e17, 1, 1, 10_000, 0);
        _addAgent(trader, 1000e18);
    }

    function _range(int256 delta) internal returns (Fill memory f) {
        Intent memory it;
        it.agent = provider;
        it.kind = delta > 0 ? KIND_ADD_LIQUIDITY : KIND_REMOVE_LIQUIDITY;
        it.tickLower = -60;
        it.tickUpper = 60;
        it.liquidityDelta = delta;
        f = _modifyLiquidity(it);
    }

    function test_a_pool_emptied_between_quote_and_fill_is_refused_not_a_revert() public {
        Intent memory it;
        it.kind = KIND_SWAP;
        it.zeroForOne = true;
        it.amountIn = 1e17;
        it.maxSlippageBps = 10_000; // no slippage rule: minOut is 0, so only the new rule can refuse it
        assertTrue(_submit(it, address(trader), 1, 2), "the swap was quoted 0 and never sent: the test is inert");
        assertGt(intentAt(0).quotedOut, 0);
        assertTrue(_range(-RANGE_LIQUIDITY).executed, "the range was not withdrawn");
        uint160 before = _sqrtPriceNow(0);
        _executeDue(2, _view());
        SimLedger.Books memory b = booksOf(address(trader));
        assertEq(b.executed, 0, "an empty pool's swap took nothing: not executed");
        assertEq(b.refused, 1, "counted as refused");
        assertEq(b.amountInTotal, 0);
        assertGt(b.gasTotal, 0, "it was sent: its gas is on the books");
        uint160 after_ = _sqrtPriceNow(0);
        assertEq(after_, before, "the empty swap's price move was not rolled back");
    }
}
