// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ExampleScenario} from "../../src/sim/ExampleScenario.sol";
import {SimClock} from "../../src/sim/SimClock.sol";
import {SimLedger} from "../../src/sim/SimLedger.sol";
import {Intent, KIND_ADD_LIQUIDITY} from "../../src/sim/ISimAgent.sol";
import {HonestTrader} from "../../src/sim/agents/HonestTrader.sol";

/// @notice A fill that takes LESS than the intent offered. All the liquidity there is sits in one narrow range; a
/// swap bigger than the range walks out of it and stops, and v4 leaves the rest of the input in the wallet. The
/// ledger must charge the input TAKEN (`Fill.amountInUsed`), not the input offered - the calibration on a pool with
/// full-range liquidity cannot see the difference, because there every swap takes its whole input (a mutant that
/// charged `Intent.amountIn` SURVIVED it, 2026-09-22). This one can.
contract PartialFillScenario is ExampleScenario {
    HonestTrader trader;

    function setUp() public {
        cadence = SimClock.ethereumL1();
        label = "partial-fill";
        // NO full-range liquidity: even one wei of it absorbs the rest of an order, at a price that runs to the edge, and
        // the order is then whole again. v4 refuses a zero-delta update of an empty position, so: one wei in, one wei out.
        _setUpScenario(1);
        _addFullRangeLiquidity(key, provider, -1);
        // the only real liquidity: a narrow range around the price, holding about 1.5 of each token
        _fundAndApprove(provider, 1e24);
        Intent memory it;
        it.agent = provider;
        it.kind = KIND_ADD_LIQUIDITY;
        it.tickLower = -60;
        it.tickUpper = 60;
        it.liquidityDelta = 1e21;
        _modifyLiquidity(it);
        // a trader that offers 10 per swap, far more than the range holds, with no slippage rule
        trader = new HonestTrader("big", 10e18, 1, 0, 10_000, 0);
        _addAgent(trader, 1000e18);
    }

    function test_a_partial_fill_charges_only_the_input_taken() public {
        uint256 b0 = token0.balanceOf(address(trader));
        uint256 b1 = token1.balanceOf(address(trader));
        run(4);
        _finish();
        SimLedger.Books memory b = booksOf(address(trader));
        assertEq(b.executed, 4, "the swaps executed (partially)");
        assertEq(b.shortfallTotal, 0, "the quote saw a different partial fill than the execution");
        assertEq(b.windfallTotal, 0);
        // the input taken is less than the input offered: the range ran out before the order did
        assertLt(b.amountInTotal, 4 * 10e18, "every swap took its whole input: no partial fill happened, the test is inert");
        assertGt(b.amountInTotal, 0);
        // and the wallet agrees with the ledger only if the ledger counted the input TAKEN
        uint256 a0 = token0.balanceOf(address(trader));
        uint256 a1 = token1.balanceOf(address(trader));
        uint256 spent = (b0 > a0 ? b0 - a0 : 0) + (b1 > a1 ? b1 - a1 : 0);
        uint256 gained = (a0 > b0 ? a0 - b0 : 0) + (a1 > b1 ? a1 - b1 : 0);
        // signed: after the first swap parks the price at the range's edge, the swap back gets more out than it puts in
        assertEq(
            int256(b.amountInTotal) - int256(b.amountOutTotal),
            int256(spent) - int256(gained),
            "the ledger charged input the pool never took"
        );
    }
}
