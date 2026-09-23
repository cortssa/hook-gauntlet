// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ExampleScenario} from "../../src/sim/ExampleScenario.sol";
import {SimEngine} from "../../src/sim/SimEngine.sol";
import {SimClock} from "../../src/sim/SimClock.sol";
import {SimLedger} from "../../src/sim/SimLedger.sol";
import {Intent, Fill} from "../../src/sim/ISimAgent.sol";
import {HonestTrader} from "../../src/sim/agents/HonestTrader.sol";

/// @notice Two things a binding owes the engine, each refused LOUDLY when it is missing: a price of gas (0 included,
/// but said), and an answer to a quote-sized intent (convert it, or refuse it). Both were loud only in words until a
/// verifier removed the refusal and 17 tests stayed green, and the missing price was noticed only at the dump line,
/// after the whole run (2026-09-22).

/// @dev the smallest binding there is: no market at all. Enough to see what `run` demands before it starts.
contract NoMarketEngine is SimEngine {
    function setUp() public {
        _initEngine(); // and deliberately NOT `ledger.setGasPrice`
    }

    function _quote(Intent memory) internal pure override returns (uint256) {
        return 0;
    }

    function _execute(Intent memory) internal pure override returns (Fill memory f) {
        return f;
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

    function test_a_run_with_unpriced_gas_refuses_to_start() public {
        vm.expectRevert(SimLedger.GasUnpriced.selector);
        this.run(1);
    }

    function test_a_price_of_zero_said_out_loud_is_enough() public {
        ledger.setGasPrice(0);
        this.run(1);
        assertEq(step, 1);
    }
}

/// @dev the example binding has no conversion: a quote-sized sell must stop the run, not execute in the wrong unit
contract ExampleRefusesQuoteSized is ExampleScenario {
    function setUp() public {
        cadence = SimClock.ethereumL1();
        label = "quote-sized-refusal";
        _setUpScenario(100e18);
    }

    function test_a_quote_sized_sell_stops_a_binding_that_cannot_convert_it() public {
        HonestTrader t = new HonestTrader("quote-sized", 1e17, 1, 0, 100, 0); // its first intent is a sell
        t.setSizeInQuote(true);
        _addAgent(t, 100e18);
        vm.expectRevert(QuoteSizedIntentUnsupported.selector);
        this.run(1);
    }

    /// @dev an external door to the binding, so that a refusal can be expected
    function executeExt(Intent memory it) external returns (Fill memory) {
        return _execute(it);
    }

    function _intent(address agent, bool quoteSized, bool zeroForOne) internal pure returns (Intent memory it) {
        it.agent = agent;
        it.zeroForOne = zeroForOne;
        it.amountIn = 1e17;
        it.amountInQuote = quoteSized;
    }

    /// @notice the four rows of the normative table next to `Intent.amountInQuote` (`ISimAgent.sol`), on the example
    /// binding, which has no conversion: three rows use `amountIn` as is (the pool takes exactly it), and only
    /// quote-sized with a currency0 input is refused. A binding that refused every quote-sized intent would be safe and
    /// wrong (row 3 IS in the input currency); one that refused none would sell the wrong amount in silence (row 4).
    function test_the_four_rows_of_the_unit_table() public {
        HonestTrader t = new HonestTrader("rows", 1e17, 1_000_000, 0, 100, 0); // never decides on its own here
        _addAgent(t, 100e18);
        address a = address(t);
        Fill memory f = this.executeExt(_intent(a, false, true));
        assertTrue(f.executed, "row 1 (input-sized sell) did not execute");
        assertEq(f.amountInUsed, 1e17, "row 1: amountIn was not used as is");
        f = this.executeExt(_intent(a, false, false));
        assertTrue(f.executed, "row 2 (input-sized buy) did not execute");
        assertEq(f.amountInUsed, 1e17, "row 2: amountIn was not used as is");
        f = this.executeExt(_intent(a, true, false));
        assertTrue(f.executed, "row 3 (quote-sized buy: the input IS the quote) was refused or not executed");
        assertEq(f.amountInUsed, 1e17, "row 3: amountIn was not used as is");
        vm.expectRevert(QuoteSizedIntentUnsupported.selector);
        this.executeExt(_intent(a, true, true));
    }

    function test_the_same_trader_in_its_input_unit_runs() public {
        HonestTrader t = new HonestTrader("input-sized", 1e17, 1, 0, 100, 0);
        _addAgent(t, 100e18);
        this.run(2);
        assertEq(booksOf(address(t)).executed, 2, "the control trader did not trade: the refusal above proves nothing");
    }
}
