// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ExampleScenario} from "../../src/sim/ExampleScenario.sol";
import {SimClock} from "../../src/sim/SimClock.sol";
import {SimGasMeter} from "../../src/sim/SimGasMeter.sol";
import {Intent, Fill, KIND_SWAP, KIND_ADD_LIQUIDITY} from "../../src/sim/ISimAgent.sol";
import {HonestTrader} from "../../src/sim/agents/HonestTrader.sol";
import {MinimalRouter} from "../../src/MinimalRouter.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice `Fill.gasUsed` is what the action would cost as its OWN transaction, and it does not depend on the test that
/// runs it. Written because a binding that metered `gasleft()` around the call in the test frame charged each agent the
/// test contract's own memory growth: a scenario never frees memory, so the same action cost more late in a run than
/// early (measured downstream, 2026-09-22: +17 % on identical decisions). `src/sim/SimGasMeter.sol` says what the number
/// is and what it still leaves out.
contract GasMeterScenario is ExampleScenario {
    HonestTrader trader;

    function setUp() public {
        cadence = SimClock.ethereumL1();
        label = "gas-meter";
        _setUpScenario(100e18);
        trader = new HonestTrader("honest", 1e17, 1_000_000, 0, 100, 0); // never decides on its own here
        _addAgent(trader, 100e18);
    }

    function _swapIntent() internal view returns (Intent memory it) {
        it.agent = address(trader);
        it.kind = KIND_SWAP;
        it.zeroForOne = true;
        it.amountIn = 1e17;
    }

    function _liquidityIntent() internal view returns (Intent memory it) {
        it.agent = provider;
        it.kind = KIND_ADD_LIQUIDITY;
        it.tickLower = -600;
        it.tickUpper = 600;
        it.liquidityDelta = 1e18;
    }

    /// @dev the test frame's memory grown by `n` bytes and touched at its end: what a long run does to it
    function _growMemory(uint256 n) internal pure {
        bytes memory junk = new bytes(n);
        junk[n - 1] = 0x01;
    }

    function _twiceFromOneState(Intent memory it) internal returns (Fill memory f1, Fill memory f2) {
        uint256 snap = vm.snapshotState();
        f1 = _execute(it);
        vm.revertToState(snap);
        _growMemory(4_000_000);
        f2 = _execute(it);
    }

    /// @notice the same swap from the same state, before and after the TEST's memory grows by 4 MB: the same gas
    function test_a_a_swap_is_metered_the_same_however_much_memory_the_test_holds() public {
        (Fill memory f1, Fill memory f2) = _twiceFromOneState(_swapIntent());
        assertTrue(f1.executed && f2.executed, "the swap did not execute: nothing measured");
        assertEq(f2.gasUsed, f1.gasUsed, "the swap's gas moved with the TEST's memory: the meter reads the harness");
    }

    /// @notice the same for a liquidity change
    function test_b_a_liquidity_change_is_metered_the_same_however_much_memory_the_test_holds() public {
        (Fill memory f1, Fill memory f2) = _twiceFromOneState(_liquidityIntent());
        assertTrue(f1.executed && f2.executed, "the liquidity change did not execute: nothing measured");
        assertEq(f2.gasUsed, f1.gasUsed, "the liquidity change's gas moved with the TEST's memory");
    }

    /// @notice the number IS a transaction's: rebuilt here from forge's record of the router call and its calldata
    function test_c_a_swap_is_metered_as_its_own_transaction() public {
        Intent memory it = _swapIntent();
        Fill memory f = _execute(it);
        // nothing after the router call in `_execute` calls out (a cheatcode does not count): the last frame is the swap's
        (bool ok, bytes memory r) = address(vm).staticcall(abi.encodeWithSignature("lastFrameGas()"));
        assertTrue(ok && r.length >= 128, "lastFrameGas unreadable");
        (, uint64 used,, int64 refunded) = abi.decode(r, (uint64, uint64, uint64, int64));
        assertTrue(f.executed, "the swap did not execute: nothing measured");
        bytes memory data = abi.encodeCall(
            MinimalRouter.swap,
            (key, SwapParams({zeroForOne: true, amountSpecified: -int256(it.amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}), bytes(""))
        );
        uint256 dataGas;
        for (uint256 i = 0; i < data.length; i++) dataGas += data[i] == 0 ? 4 : 16;
        uint256 sum = 21_000 + dataGas + used;
        uint256 refund = refunded > 0 ? uint256(uint64(refunded)) : 0;
        if (refund > sum / 5) refund = sum / 5;
        assertEq(f.gasUsed, sum - refund, "the metered gas is not intrinsic + calldata + execution - capped refund");
        assertGt(used, 0, "no execution recorded");
    }

    /// @notice the arithmetic, on numbers chosen so that each term shows: the intrinsic cost, the calldata, the refund
    /// under its cap, the cap itself, and a negative refund (possible inside a nested frame) charged as none
    function test_d_the_transaction_arithmetic() public pure {
        SimGasMeter.Tx memory t = SimGasMeter.Tx({spent: 100_000, refunded: 1_000, data: 500});
        assertEq(SimGasMeter.total(t), 21_000 + 500 + 100_000 - 1_000, "a refund under the cap is subtracted whole");
        t.refunded = 90_000;
        assertEq(SimGasMeter.total(t), 121_500 - 121_500 / 5, "a refund above the cap is capped at a fifth");
        t.refunded = -5_000;
        assertEq(SimGasMeter.total(t), 121_500, "a negative refund is charged as no refund");
        assertEq(SimGasMeter.calldataGas(hex"00ff0000ab"), 4 + 16 + 4 + 4 + 16, "16 a non-zero byte, 4 a zero one");
    }
}
