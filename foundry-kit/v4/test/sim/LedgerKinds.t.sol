// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SimLedger} from "../../src/sim/SimLedger.sol";
import {Intent, Fill, KIND_SWAP, KIND_ADD_LIQUIDITY} from "../../src/sim/ISimAgent.sol";

/// @notice The ledger's amount columns belong to SWAPS. Every other kind is whatever the binding needs it to be:
/// a liquidity change, a book join, a whole ladder moved in one transaction. A binding is entitled to report
/// something in `Fill.amountOut` for those that is not an amount, and the ledger must not add it up.
///
/// Written after a private binding reported a COUNT of ladder rungs there and the ledger turned it into 912 units of
/// `amountOutTotal` and, because a non-swap carries no quote, 912 units of `windfallTotal` as well (2026-09-22).
/// The kit's own example never exposed this: its liquidity path reports `amountOut = 0`, so the bug was invisible
/// here and visible only downstream. That is the reason this test talks to the ledger directly.
contract LedgerKinds is Test {
    SimLedger ledger;
    address constant AGENT = address(0xA9E7);

    function setUp() public {
        ledger = new SimLedger();
        ledger.register(AGENT, "agent", 0, 0);
    }

    function _books() internal view returns (SimLedger.Books memory) {
        return ledger.get(AGENT);
    }

    function test_a_non_swap_fill_never_touches_the_amount_columns() public {
        Intent memory it;
        it.agent = AGENT;
        it.kind = KIND_ADD_LIQUIDITY;
        it.amountIn = 0;
        it.quotedOut = 0;
        Fill memory f;
        f.executed = true;
        f.amountOut = 912; // a count of rungs, not an amount: exactly the shape that corrupted a real tape
        f.amountInUsed = 7;
        f.gasUsed = 1234;
        ledger.noteFill(it, f);

        SimLedger.Books memory b = _books();
        assertEq(b.executed, 1, "a non-swap fill must still be counted as executed");
        assertEq(b.gasTotal, 1234, "gas is charged for every kind");
        assertEq(b.amountOutTotal, 0, "a non-swap's amountOut was added to the ledger's amounts");
        assertEq(b.amountInTotal, 0, "a non-swap's input was added to the ledger's amounts");
        assertEq(b.quotedOutTotal, 0, "a non-swap contributed to the quoted total");
        assertEq(b.windfallTotal, 0, "a non-swap was booked as windfall against a quote it never had");
        assertEq(b.shortfallTotal, 0);
    }

    function test_a_swap_fill_still_fills_the_amount_columns() public {
        Intent memory it;
        it.agent = AGENT;
        it.kind = KIND_SWAP;
        it.quotedOut = 100;
        Fill memory f;
        f.executed = true;
        f.amountOut = 98;
        f.amountInUsed = 50;
        ledger.noteFill(it, f);

        SimLedger.Books memory b = _books();
        assertEq(b.amountInTotal, 50, "the swap's input was not counted");
        assertEq(b.amountOutTotal, 98, "the swap's output was not counted");
        assertEq(b.quotedOutTotal, 100);
        assertEq(b.shortfallTotal, 2, "the swap's shortfall against its quote was not counted");
        assertEq(b.windfallTotal, 0);
    }

    function test_a_refused_fill_of_any_kind_is_only_a_refusal() public {
        Intent memory it;
        it.agent = AGENT;
        it.kind = KIND_SWAP;
        it.quotedOut = 100;
        Fill memory f;
        f.executed = false;
        f.amountOut = 5;
        f.amountInUsed = 5;
        f.gasUsed = 9;
        ledger.noteFill(it, f);

        SimLedger.Books memory b = _books();
        assertEq(b.refused, 1);
        assertEq(b.executed, 0);
        assertEq(b.gasTotal, 9, "a refusal still costs gas");
        assertEq(b.amountOutTotal, 0, "a refused fill moved the amount columns");
        assertEq(b.amountInTotal, 0);
    }
}
