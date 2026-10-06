// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
// Inside the kit: imports are relative. In your project: see scripts/setup-deps.sh's import lines.

import {console2} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {V4Harness} from "../../src/V4Harness.sol";
import {HookMiner} from "../../src/HookMiner.sol";
import {SwapEventReader} from "../../src/SwapEventReader.sol";
import {InRangeLedger} from "../../src/InRangeLedger.sol";
import {JitRecipient} from "../../src/JitRecipient.sol";
import {InRangeDonateHook} from "../../src/examples/InRangeDonateHook.sol";
import {InRangeDonateHookNaive} from "./InRangeDonateHookNaive.sol";
import {InRangeDonateWatcher} from "./InRangeDonateWatcher.sol";

/// @notice Unit tests for `InRangeDonateHook` (D1-D5 and R1-R4 in its header), and the same scenarios against its first
/// draft, `InRangeDonateHookNaive`, with the JIT-recipient actor (`src/JitRecipient.sol`) and the reference model
/// (`src/InRangeLedger.sol`, fed by `InRangeDonateWatcher`). Every payout scenario reads two things: how much each
/// party RECEIVED (off the manager: fees collected plus owed) and how much it was ENTITLED to by the SPEC (the model).
/// The naive hook gets every AMOUNT right in all of them - what is taken is what is donated - and pays the wrong PARTIES.
///
/// The pool: LP fee 0 (so every unit of fee growth is a payout of the hook, or of the one third-party donor), tick
/// spacing 60, price 1. Honest liquidity: alice 1e20 on [-1200, 1200], bob 5e19 on [0, 2400]; nothing outside
/// [-1200, 2400], so a price pushed to tick 3000 has nobody in range.
contract InRangeDonateHookTest is V4Harness {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B0);
    address internal trader = address(0x7AADE);
    address internal treasury = address(0x7EA5);

    InRangeDonateHook internal hook;
    InRangeDonateHookNaive internal naive;

    struct World {
        PoolKey key;
        InRangeDonateWatcher w;
        InRangeLedger ledger;
        JitRecipient jit;
        address payout; // the hook whose sweep the actor calls
    }

    function setUp() public {
        _setUpV4();
        hook = InRangeDonateHook(
            _deployHook(
                type(InRangeDonateHook).creationCode,
                abi.encode(manager, treasury),
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                    | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            )
        );
        naive = InRangeDonateHookNaive(
            _deployHook(
                type(InRangeDonateHookNaive).creationCode,
                abi.encode(manager),
                Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            )
        );
        vm.label(address(hook), "InRangeDonateHook");
        vm.label(address(naive), "InRangeDonateHookNaive");
        _fundAndApprove(alice, 1e30);
        _fundAndApprove(bob, 1e30);
        _fundAndApprove(trader, 1e30);
    }

    // ------------------------------------------------------------------ the world, and its moves
    function _world(address h) internal returns (World memory x) {
        x.key = _initPool(IHooks(h), 0, 60, SQRT_PRICE_1_1);
        x.w = new InRangeDonateWatcher(manager, router, liquidity, x.key, 30, true);
        x.ledger = x.w.ledger();
        x.w.modifyAs(alice, -1200, 1200, 1e20, 0);
        x.w.modifyAs(bob, 0, 2400, 5e19, 0);
        x.jit = x.w.newJit();
        token0.mint(address(x.jit), 1e30);
        token1.mint(address(x.jit), 1e30);
        x.payout = h;
        vm.label(address(x.jit), "JitRecipient");
    }

    function _toTick(int24 t) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(t);
    }

    /// @notice an exact-in swap that stops at `limitTick` at the latest
    function _in(bool zeroForOne, uint256 amount, int24 limitTick) internal pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amount), sqrtPriceLimitX96: _toTick(limitTick)});
    }

    function _tick(PoolKey memory k) internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(k.toId());
    }

    /// @notice honest trading around the price: fees accrue while alice and bob are in range
    function _honestTrading(World memory x) internal {
        for (uint256 i = 0; i < 4; i++) {
            x.w.swapAs(trader, _in(false, 2e18, 900), 0);
            x.w.swapAs(trader, _in(true, 2e18, -900), 0);
        }
    }

    function _sweepCall(World memory x) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("sweep((address,address,uint24,int24,address))", x.key);
    }

    function _plan(World memory x, uint128 liq) internal pure returns (JitRecipient.Plan memory p) {
        p.key = x.key;
        p.liquidity = liq;
        p.spacings = 1;
        p.payoutTarget = x.payout;
        p.payoutCall = _sweepCall(x);
    }

    function _excess(World memory x, address party) internal view returns (uint256) {
        (uint256 x0, uint256 x1) = x.ledger.excess(party);
        return x0 + x1;
    }

    function _received(World memory x, address party) internal view returns (uint256) {
        (uint256 r0, uint256 r1) = x.ledger.received(party);
        return r0 + r1;
    }

    function _entitled(World memory x, address party) internal view returns (uint256) {
        (uint256 e0, uint256 e1) = x.ledger.entitled(party);
        return e0 + e1;
    }

    function _pot(World memory x) internal view returns (uint256 p0, uint256 p1) {
        if (x.payout == address(hook)) return hook.potOf(x.key.toId());
        return naive.potOf(x.key.toId());
    }

    /// @notice the honest LPs got what the SPEC owes them, once the pot is counted, to within rounding
    function _honestPaidInFull(World memory x) internal view {
        (uint256 p0, uint256 p1) = _pot(x);
        address[2] memory lps = [alice, bob];
        for (uint256 i = 0; i < 2; i++) {
            (uint256 y0, uint256 y1) = x.ledger.shortfall(lps[i], p0, p1);
            assertEq(y0 + y1, 0, "an honest LP was paid less than it was in range for");
            assertEq(_excess(x, lps[i]), 0, "an honest LP was paid more than it was in range for");
        }
    }

    function _log(World memory x, string memory what) internal view {
        console2.log(what);
        console2.log("  jit received / entitled:", _received(x, address(x.jit)), _entitled(x, address(x.jit)));
        console2.log("  alice received / entitled:", _received(x, alice), _entitled(x, alice));
        console2.log("  bob received / entitled:", _received(x, bob), _entitled(x, bob));
    }

    // ------------------------------------------------------------------ the address, the fee, the claims (D1)
    function test_the_address_carries_exactly_the_declared_flags() public view {
        assertTrue(HookMiner.carriesExactly(address(hook), hook.requiredFlags()));
        assertTrue(HookMiner.carriesExactly(address(naive), naive.requiredFlags()));
    }

    /// @notice D1: four orientations; each fee is 0.30 % of the pool's unspecified amount, held as a claim, in the pot
    /// of the currency it was taken in; the claims are the pot (nothing unowned: somebody is always in range)
    function test_D1_the_fee_is_exact_held_as_a_claim_and_in_the_pot() public {
        World memory x = _world(address(hook));
        for (uint256 o = 0; o < 4; o++) {
            _d1(x, o % 2 == 0, o < 2);
        }
        assertEq(hook.unowned(currency0) + hook.unowned(currency1), 0);
    }

    function _d1(World memory x, bool zeroForOne, bool exactIn) internal {
        SwapParams memory p = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactIn ? -int256(1e18) : int256(1e18),
            sqrtPriceLimitX96: zeroForOne ? _toTick(-1100) : _toTick(1100)
        });
        bool s0 = exactIn == zeroForOne;
        Currency feeSide = s0 ? currency1 : currency0;
        Currency otherSide = s0 ? currency0 : currency1;
        uint256 takenBefore = hook.feesTaken(feeSide);
        uint256 otherBefore = hook.feesTaken(otherSide);
        SwapBooks memory b = _swapWithBooks(trader, x.key, p);
        uint256 fee = _abs(s0 ? b.pool1 : b.pool0) * 30 / 10_000;
        assertGt(fee, 0);
        assertEq(hook.feesTaken(feeSide) - takenBefore, fee, "fee not 0.30 % of the unspecified amount");
        assertEq(hook.feesTaken(otherSide), otherBefore, "a fee on the specified side");
        // per party, claims counted: swapper + hook + manager = 0; the hook's balance never moves
        assertEq(b.swapper0 + b.hook0 + b.manager0, 0);
        assertEq(b.swapper1 + b.hook1 + b.manager1, 0);
        assertEq(b.hook0, 0);
        assertEq(b.hook1, 0);
        // the swap first paid the previous pot (a donation: claims burned), then took this fee as a claim
        (uint256 p0, uint256 p1) = hook.potOf(x.key.toId());
        assertEq(manager.balanceOf(address(hook), currency0.toId()), p0 + hook.unowned(currency0), "claims != pot");
        assertEq(manager.balanceOf(address(hook), currency1.toId()), p1 + hook.unowned(currency1), "claims != pot");
        assertEq(s0 ? p1 : p0, fee, "the pot is not this swap's fee");
        assertEq(s0 ? p0 : p1, 0, "the previous pot was not paid before this swap");
    }

    /// @notice D1 on the input side, where the fee is taken off a NEGATIVE amount: exact-out swaps of 1 500 different sizes,
    /// both ways, each fee held to `floor(|input| * 30 / 10 000)` to the wei. A fee computed from `~u` instead of `-u`
    /// (one less on a negative amount) differs only when `|input| * 30 mod 10 000 < 30` - about 1 swap in 330 - and the
    /// four-orientation test above and a 64 x 64 campaign both left it alive (forge's native pass, then K18's N1); the test
    /// requires at least one swap to have met that case, so it cannot pass without looking there
    function test_D1_the_fee_on_the_input_of_an_exact_out_swap_is_exact_at_every_rounding_edge() public {
        World memory x = _world(address(hook));
        uint256 edges;
        for (uint256 i = 0; i < 1_500; i++) {
            bool zeroForOne = i % 2 == 0;
            SwapParams memory p = SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(1e15 + i * 7_919_993),
                sqrtPriceLimitX96: zeroForOne ? _toTick(-1100) : _toTick(1100)
            });
            Currency input = zeroForOne ? currency0 : currency1;
            uint256 before = hook.feesTaken(input);
            vm.recordLogs();
            vm.prank(trader);
            router.swap(x.key, p, "");
            (, int128 pool0, int128 pool1) = SwapEventReader.lastSwapDelta(vm.getRecordedLogs(), address(manager));
            uint256 abs = _abs(zeroForOne ? pool0 : pool1);
            if ((abs * 30) % 10_000 < 30) edges += 1;
            assertEq(hook.feesTaken(input) - before, abs * 30 / 10_000, "the fee on the input is not floor(|input| * 0.30 %)");
        }
        console2.log("exact-out swaps whose input sat on a rounding edge:", edges);
        assertGt(edges, 0, "no swap met the rounding edge: the test looked nowhere");
    }

    function _abs(int256 v) internal pure returns (uint256) {
        return v < 0 ? uint256(-v) : uint256(v);
    }

    // ------------------------------------------------------------------ who is paid (D2, D4)
    /// @notice D2: after honest trading and a sweep, alice and bob received exactly what they were in range for, to
    /// within rounding, and the donations are the fees
    function test_D2_the_lps_in_range_when_a_fee_was_taken_are_the_ones_paid() public {
        World memory x = _world(address(hook));
        _honestTrading(x);
        hook.sweep(x.key);
        _honestPaidInFull(x);
        assertGt(_received(x, alice), 0);
        assertGt(_received(x, bob), 0);
        assertEq(hook.donated(currency0), hook.feesTaken(currency0), "a fee was not donated");
        assertEq(hook.donated(currency1), hook.feesTaken(currency1), "a fee was not donated");
        assertEq(x.ledger.disagreements(), 0);
        _log(x, "honest trading, then a sweep");
    }

    /// @notice D4: a fee taken at a price where bob is in range is paid to bob even if the NEXT swap moves the price out
    /// of his range - the pot goes before the price moves
    function test_D4_the_pot_is_paid_before_a_swap_moves_the_price() public {
        World memory x = _world(address(hook));
        x.w.swapAs(trader, _in(false, 1e18, 900), 0); // up: alice and bob in range; the fee is in the pot
        assertGt(_tick(x.key), 0);
        (, uint256 p1) = hook.potOf(x.key.toId());
        assertEq(p1, 0);
        x.w.swapAs(trader, _in(true, 5e18, -600), 0); // down, out of bob's range
        assertLt(_tick(x.key), 0, "setup: the price did not leave bob's range");
        (uint256 e0, uint256 e1) = x.ledger.entitled(bob);
        (uint256 r0, uint256 r1) = x.ledger.received(bob);
        assertGt(e0 + e1, 0);
        assertEq(r0 + r1 + 1 >= e0 + e1 && r0 + r1 <= e0 + e1 + 1, true, "bob was not paid for the first swap");
        _honestPaidInFull(x);
    }

    // ------------------------------------------------------------------ the JIT-recipient actor, on both hooks
    /// @notice a position as large as alice's, placed just before a sweep and removed right after, in ONE transaction.
    /// Naive: it takes its liquidity's share of every fee taken before it arrived. Defended: its arrival pays the pot
    /// first; the sweep finds nothing; it leaves with nothing
    function test_jit_around_a_sweep_takes_a_share_on_the_naive_hook_and_nothing_on_the_defended_one() public {
        World memory n = _world(address(naive));
        _honestTrading(n);
        JitRecipient.Result memory r = n.w.runJit(n.jit, _plan(n, 1e20));
        _log(n, "naive: JIT around a sweep");
        assertGt(r.fees0 + r.fees1, 0, "the JIT took nothing from the naive hook");
        assertEq(_entitled(n, address(n.jit)), 0, "the model owes the JIT something");
        assertGt(_excess(n, address(n.jit)), 0, "the WHO check did not see it");
        assertEq(naive.donated(currency0), naive.feesTaken(currency0), "the amount is right: every fee was donated");
        assertEq(naive.donated(currency1), naive.feesTaken(currency1), "the amount is right: every fee was donated");

        World memory d = _world(address(hook));
        _honestTrading(d);
        r = d.w.runJit(d.jit, _plan(d, 1e20));
        _log(d, "defended: JIT around a sweep");
        assertEq(r.fees0 + r.fees1, 0, "the JIT took something from the defended hook");
        assertEq(_excess(d, address(d.jit)), 0);
        _honestPaidInFull(d);
    }

    /// @notice FR13's variant: push the price where nobody is in range, place DUST (liquidity 1) there, sweep, leave,
    /// push back - one transaction. Naive: the dust is alone in range and takes the whole pot. Defended: the push pays the
    /// pot to alice and bob before the price moves; the push's own fee, taken with nobody in range, goes to the treasury
    function test_dust_after_a_push_takes_the_whole_pot_on_the_naive_hook_and_nothing_on_the_defended_one() public {
        World memory n = _world(address(naive));
        _honestTrading(n);
        (uint256 pot0, uint256 pot1) = naive.potOf(n.key.toId());
        JitRecipient.Plan memory p = _plan(n, 1);
        p.pushToSqrtPrice = _toTick(3000);
        p.pushBack = true;
        JitRecipient.Result memory r = n.w.runJit(n.jit, p);
        _log(n, "naive: dust after a push");
        console2.log("  pot before the run:", pot0, pot1);
        console2.log("  dust took:", r.fees0, r.fees1);
        console2.log("  the run's balance change (push, dust, push back):");
        console2.logInt(r.net0);
        console2.logInt(r.net1);
        assertGe(r.fees0, pot0, "the dust did not take the whole pot in currency0");
        assertGe(r.fees1 + 1, pot1, "the dust did not take the whole pot in currency1");
        assertGt(_excess(n, address(n.jit)), 0);

        World memory d = _world(address(hook));
        _honestTrading(d);
        p = _plan(d, 1);
        p.pushToSqrtPrice = _toTick(3000);
        p.pushBack = true;
        r = d.w.runJit(d.jit, p);
        _log(d, "defended: dust after a push");
        assertEq(r.fees0 + r.fees1, 0, "the dust took something from the defended hook");
        assertEq(_excess(d, address(d.jit)), 0);
        _honestPaidInFull(d);
        (uint256 u0, uint256 u1) = d.ledger.unownedEntitled();
        assertGt(u0 + u1, 0, "the push paid no fee with nobody in range");
        assertEq(hook.unowned(currency0), u0, "D3: the treasury's share is not the fees taken with nobody in range");
        assertEq(hook.unowned(currency1), u1, "D3: the treasury's share is not the fees taken with nobody in range");
    }

    /// @notice FR13's other variant: nobody pushes - the price has LEFT every honest range by honest trading, and fees
    /// are taken there. Naive: they wait in the pot for whoever comes; dust placed later takes them. Defended: they were
    /// owed to nobody, and are the treasury's
    function test_fees_taken_where_nobody_is_go_to_the_next_dust_on_the_naive_hook_and_to_the_treasury_on_the_defended()
        public
    {
        World[2] memory ws = [_world(address(naive)), _world(address(hook))];
        for (uint256 i = 0; i < 2; i++) {
            World memory x = ws[i];
            x.w.swapAs(trader, _in(false, 1e22, 3000), 0); // the price leaves every honest range
            assertEq(manager.getLiquidity(x.key.toId()), 0, "setup: somebody is still in range");
            JitRecipient.Result memory r = x.w.runJit(x.jit, _plan(x, 1));
            _log(x, i == 0 ? "naive: dust where the price already was" : "defended: dust where the price already was");
            if (i == 0) {
                assertGt(r.fees0 + r.fees1, 0, "the dust took nothing on the naive hook");
                assertGt(_excess(x, address(x.jit)), 0);
            } else {
                assertEq(r.fees0 + r.fees1, 0, "the dust took something on the defended hook");
                assertEq(_excess(x, address(x.jit)), 0);
                (uint256 u0, uint256 u1) = x.ledger.unownedEntitled();
                assertEq(hook.unowned(currency0), u0);
                assertEq(hook.unowned(currency1), u1);
            }
        }
    }

    /// @notice wash + JIT, the trader variant (the A/B's finding): a position ten times alice's placed around the price,
    /// then the actor trades 1e18 there and back, sweeps, leaves. Naive: it recovers most of its own fees AND most of the
    /// pot other traders paid - it ends richer. Defended: its arrival paid the old pot to alice and bob; it recovers only
    /// its liquidity's share of its OWN wash fees (owed by D2: it was in range when they were taken, R1/R2), and ends
    /// poorer by the rest
    function test_wash_and_jit_profits_on_the_naive_hook_and_only_loses_on_the_defended_one() public {
        int256[2] memory value;
        for (uint256 i = 0; i < 2; i++) {
            World memory x = _world(i == 0 ? address(naive) : address(hook));
            _honestTrading(x);
            JitRecipient.Plan memory p = _plan(x, 1e21);
            p.washAmount = 1e18;
            p.washBack = true;
            JitRecipient.Result memory r = x.w.runJit(x.jit, p);
            value[i] = r.net0 + r.net1; // price ~1: one unit of each is worth about the same
            _log(x, i == 0 ? "naive: wash + JIT" : "defended: wash + JIT");
            console2.log("  the run's balance change, both currencies at price ~1:");
            console2.logInt(value[i]);
            if (i == 0) {
                assertGt(_excess(x, address(x.jit)), 0, "the WHO check did not see the naive wash");
            } else {
                assertEq(_excess(x, address(x.jit)), 0);
                assertGt(_received(x, address(x.jit)), 0, "R1: its own fees came back in part");
                _honestPaidInFull(x);
            }
        }
        assertGt(value[0], 0, "wash + JIT did not profit on the naive hook");
        assertLt(value[1], 0, "wash + JIT did not lose on the defended hook");
    }

    /// @notice R2, accepted and measured: just-in-time liquidity around somebody ELSE's swap takes its share of that swap's
    /// fee - as it takes its share of the pool's own LP fee (class 14). The model owes it exactly that
    function test_R2_jit_around_somebody_elses_swap_takes_its_share_of_that_swaps_fee() public {
        World memory x = _world(address(hook));
        _honestTrading(x);
        x.w.jitEnter(x.jit, 1e20, 5);
        uint256 owedBefore = x.w.feesOwed(0);
        x.w.swapAs(trader, _in(false, 1e17, 900), 0);
        uint256 thatFee = x.w.feesOwed(0) - owedBefore;
        x.w.jitExit(x.jit);
        _log(x, "defended: JIT around a trader's swap");
        uint256 got = x.jit.lastFees0() + x.jit.lastFees1();
        console2.log("R2: that swap's fee / the JIT's take:", thatFee, got);
        assertGt(got, 0, "R2: the JIT took nothing of the swap it was in range for");
        assertEq(_excess(x, address(x.jit)), 0);
        assertLe(got, thatFee, "more than the one swap's fee");
        _honestPaidInFull(x);
    }

    /// @notice R1, accepted and measured: the fee follows the END of its swap. A trader that places dust beyond every honest
    /// range and swaps INTO it is paid its own fee back, although the swap traded against alice and bob all the way
    function test_R1_a_trader_that_ends_its_swap_in_its_own_dust_range_is_paid_its_own_fee() public {
        World memory x = _world(address(hook));
        _fundAndApprove(address(0xD057), 1e30);
        x.w.modifyAs(address(0xD057), 2400, 2460, 1, 0);
        x.w.swapAs(address(0xD057), _in(false, 1e22, 2430), 0);
        assertEq(_tick(x.key), 2430, "setup: not inside the dust range");
        hook.sweep(x.key);
        uint256 fee = x.w.feesOwed(0) + x.w.feesOwed(1);
        uint256 got = _received(x, address(0xD057));
        console2.log("R1: the swap's fee / what its own dust range was paid:", fee, got);
        assertGe(got + 1, fee, "the dust range was not paid the swap's fee");
        assertEq(_excess(x, address(0xD057)), 0, "the model does not owe it: R1 is not what D2 says");
        assertEq(_received(x, alice) + _received(x, bob), 0, "alice and bob were paid for a swap that ended elsewhere");
    }

    /// @notice R3, a RESIDUAL, pinned as it is (not a promise; found by the verifier V18, numbers its own): dust PARKED
    /// beyond every honest range, BEFORE anything happens, takes 100 % of a STRANGER's swap fee whenever that swap ends
    /// there - a fee that, without the dust, D3 gives to the treasury. Not R1 (the trader's own fee) nor R2 (a share next
    /// to others): the dust is alone in range where the swap stops, so D2 owes it all, and the WHO invariant is green by
    /// construction - it checks conformance to D2, and here D2 itself is what pays. If this test goes red, the hook's
    /// entitlement rule changed: rewrite R3 in its header and in `foundry-kit/v4/README.md`, do not just fix the number.
    /// V18's geometry: tick spacing 10, carol 3e19 on [-600, 600], dave 7e19 on [-200, 1000], six trades between; the
    /// dust (liquidity 1) on [1000, 1010); the stranger's swap ends at tick 1005, then two small ones stay there
    function test_R3_dust_parked_beyond_every_honest_range_takes_a_strangers_whole_fee() public {
        address parker = address(0x9A2CE2);
        address stranger = address(0x57A);
        _fundAndApprove(parker, 1e30);
        _fundAndApprove(stranger, 1e30);
        _fundAndApprove(address(0xCA201), 1e30);
        _fundAndApprove(address(0xDA7E), 1e30);
        uint256[2] memory fees;
        uint256[2] memory got;
        uint256[2] memory toTreasury;
        for (uint256 i = 0; i < 2; i++) {
            uint256 snap = vm.snapshotState();
            PoolKey memory k = _initPool(IHooks(address(hook)), 0, 10, SQRT_PRICE_1_1);
            InRangeDonateWatcher w = new InRangeDonateWatcher(manager, router, liquidity, k, 30, true);
            w.modifyAs(address(0xCA201), -600, 600, 3e19, 0);
            w.modifyAs(address(0xDA7E), -200, 1000, 7e19, 0);
            _v18Trading(w, k);
            if (i == 1) w.modifyAs(parker, 1000, 1010, 1, 0);
            uint256 before = w.feesOwed(0) + w.feesOwed(1);
            _swapUpTo(w, k, stranger, false, 1e22, 1005); // leaves every honest range, stops at 1005
            _swapUpTo(w, k, stranger, true, 1e12, 1001);
            _swapUpTo(w, k, stranger, false, 1e12, 1008);
            fees[i] = w.feesOwed(0) + w.feesOwed(1) - before;
            hook.sweep(k);
            (uint256 r0, uint256 r1) = w.ledger().received(parker);
            got[i] = r0 + r1;
            toTreasury[i] = hook.unowned(currency0) + hook.unowned(currency1);
            (uint256 x0, uint256 x1) = w.ledger().excess(parker);
            assertEq(x0 + x1, 0, "R3: the model does not owe the dust what it took - D2 changed");
            vm.revertToState(snap);
        }
        console2.log("R3, no parked dust: the stranger's fees / to the treasury:", fees[0], toTreasury[0]);
        console2.log("R3, dust [1000, 1010) liquidity 1: the stranger's fees / the dust received:", fees[1], got[1]);
        assertEq(fees[0], fees[1], "setup: the stranger's swaps are not the same with and without the dust");
        assertEq(toTreasury[0], fees[0], "without the dust the fees are the treasury's (D3)");
        assertEq(got[0], 0);
        assertLe(got[1], fees[1]);
        assertGe(got[1] + 3, fees[1], "R3: the parked dust did not take the stranger's whole fee");
        assertEq(toTreasury[1], 0, "R3: with the dust parked there, nothing is the treasury's");
    }

    function _v18Trading(InRangeDonateWatcher w, PoolKey memory k) internal {
        _swapUpTo(w, k, trader, false, 3e17, 500);
        _swapUpTo(w, k, trader, true, 5e17, -500);
        _swapUpTo(w, k, trader, false, 1e18, 900);
        _swapUpTo(w, k, trader, true, 2e18, -550);
        _swapUpTo(w, k, trader, false, 4e17, 300);
        _swapUpTo(w, k, trader, true, 7e17, -150);
    }

    /// @notice an exact-in swap towards `limitTick`, skipped if the price is already there or past it
    function _swapUpTo(InRangeDonateWatcher w, PoolKey memory k, address who, bool zeroForOne, uint256 amount, int24 limitTick)
        internal
    {
        uint160 lim = _toTick(limitTick);
        (uint160 now_,,,) = manager.getSlot0(k.toId());
        if (zeroForOne ? now_ <= lim : now_ >= lim) return;
        w.swapAs(who, _in(zeroForOne, amount, limitTick), 0);
    }

    /// @notice D1/D2 per pool (`HOOK-ATTACKS.md` classes 3 and 4): a second pool of this hook shares both currencies;
    /// fees taken on pool A are paid only to A's LPs - a sweep of B pays B's LP nothing - and A's sweep pays A's
    function test_the_pot_is_per_pool_and_a_sweep_of_another_pool_pays_nothing() public {
        World memory a = _world(address(hook));
        PoolKey memory kb = _initPool(IHooks(address(hook)), 0, 10, SQRT_PRICE_1_1);
        InRangeDonateWatcher wb = new InRangeDonateWatcher(manager, router, liquidity, kb, 30, true);
        wb.modifyAs(alice, -600, 600, 1e20, 0);
        _honestTrading(a);
        hook.sweep(kb);
        (uint256 r0, uint256 r1) = wb.ledger().received(alice);
        assertEq(r0 + r1, 0, "pool B's LP was paid pool A's fees");
        (uint256 b0, uint256 b1) = hook.potOf(kb.toId());
        assertEq(b0 + b1, 0, "pool B has a pot it never earned");
        hook.sweep(a.key);
        _honestPaidInFull(a);
        assertGt(_received(a, alice), 0);
    }

    /// @notice a third party's donation lands on whoever is in range when it lands; the model owes it to them, and the
    /// hook's pot is not confused by it
    function test_a_third_party_donation_is_paid_to_whoever_is_in_range_and_owed_to_them() public {
        World memory x = _world(address(hook));
        token0.mint(address(x.w.donor()), 1e20);
        token1.mint(address(x.w.donor()), 1e20);
        _honestTrading(x);
        x.w.thirdPartyDonate(3e17, 5e17);
        hook.sweep(x.key);
        _honestPaidInFull(x);
    }

    // ------------------------------------------------------------------ D3: the treasury
    function test_D3_only_the_treasury_withdraws_what_nobody_was_owed_and_never_more() public {
        World memory x = _world(address(hook));
        x.w.swapAs(trader, _in(false, 1e22, 3000), 0);
        x.w.swapAs(trader, _in(true, 1e15, 2900), 0);
        uint256 u0 = hook.unowned(currency0);
        assertGt(u0, 0, "setup: nothing unowned");
        vm.prank(trader);
        vm.expectRevert(InRangeDonateHook.NotTheTreasury.selector);
        hook.withdrawUnowned(currency0, trader, u0);
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(InRangeDonateHook.MoreThanUnowned.selector, u0 + 1, u0));
        hook.withdrawUnowned(currency0, treasury, u0 + 1);
        uint256 before = token0.trueBalanceOf(treasury);
        vm.prank(treasury);
        hook.withdrawUnowned(currency0, treasury, u0);
        assertEq(token0.trueBalanceOf(treasury) - before, u0, "the treasury was not paid what it withdrew");
        assertEq(hook.unowned(currency0), 0);
        assertEq(hook.withdrawn(currency0), u0);
        (uint256 p0,) = hook.potOf(x.key.toId());
        assertEq(manager.balanceOf(address(hook), currency0.toId()), p0, "claims left behind after the withdrawal");
    }

    /// @notice D3 over several fees and several withdrawals (the native mutation pass left `unownedTotal`, a second
    /// fee into `unowned`, a partial and a second withdrawal, and a caller below the treasury's address untested): two fees
    /// taken with nobody in range add up, in `unowned` and in `unownedTotal`, to what the model says nobody was owed; the
    /// treasury takes them in two parts; a stranger on either side of its address is refused
    function test_D3_fees_nobody_was_owed_add_up_and_are_withdrawn_in_parts_by_the_treasury_only() public {
        World memory x = _world(address(hook));
        x.w.swapAs(trader, _in(false, 1e22, 3000), 0); // out of every range: a currency0 fee with nobody in range
        x.w.swapAs(trader, _in(true, 1e19, 0), 0); // back into range
        x.w.swapAs(trader, _in(false, 1e22, 3000), 0); // out again: a second one
        (uint256 u0, uint256 u1) = x.ledger.unownedEntitled();
        assertGt(u0, 0);
        assertEq(u1, 0);
        assertEq(hook.unowned(currency0), u0, "D3: unowned is not the sum of the fees nobody was owed");
        assertEq(hook.unownedTotal(currency0), u0, "D3: unownedTotal is not the sum of the fees nobody was owed");
        address[2] memory strangers = [address(0x1), address(uint160(treasury) + 1)];
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(strangers[i]);
            vm.expectRevert(InRangeDonateHook.NotTheTreasury.selector);
            hook.withdrawUnowned(currency0, strangers[i], 1);
        }
        vm.prank(treasury);
        hook.withdrawUnowned(currency0, treasury, u0 / 3);
        assertEq(hook.unowned(currency0), u0 - u0 / 3, "a partial withdrawal did not leave the rest");
        vm.prank(treasury);
        hook.withdrawUnowned(currency0, treasury, u0 - u0 / 3);
        assertEq(hook.unowned(currency0), 0);
        assertEq(hook.withdrawn(currency0), u0, "withdrawn is not the sum of the two withdrawals");
        assertEq(hook.unownedTotal(currency0), u0, "a withdrawal moved unownedTotal");
        assertEq(token0.trueBalanceOf(treasury), u0);
    }

    /// @notice D4's last clause: a pot found with nobody in range - impossible while D4 holds - is moved to `unowned`,
    /// never donated to an empty range (which reverts `NoLiquidityToReceiveFees` and would kill the swap that found it).
    /// Planted with `vm.store` (the pot is slot 0 of the hook's storage: `_pot[id]` at keccak(id, 0), `[0]`, `[1]`)
    function test_D4_a_pot_with_nobody_in_range_goes_to_unowned_and_never_kills_the_action() public {
        World memory x = _world(address(hook));
        x.w.swapAs(trader, _in(true, 1e22, -1300), 0); // below every range: a currency1 fee nobody was owed
        x.w.swapAs(trader, _in(false, 1e22, 3000), 0); // above every range: a currency0 one
        assertEq(manager.getLiquidity(x.key.toId()), 0);
        assertGt(hook.unowned(currency1), 0, "setup: nothing unowned in currency1 (the planted pot must ADD to it)");
        bytes32 base = keccak256(abi.encode(PoolId.unwrap(x.key.toId()), uint256(0)));
        vm.store(address(hook), base, bytes32(uint256(7)));
        vm.store(address(hook), bytes32(uint256(base) + 1), bytes32(uint256(11)));
        (uint256 p0, uint256 p1) = hook.potOf(x.key.toId());
        assertEq(p0, 7, "setup: the slot is not the pot");
        assertEq(p1, 11, "setup: the next slot is not the pot's currency1");
        uint256[4] memory before = [
            hook.unowned(currency0), hook.unowned(currency1), hook.unownedTotal(currency0), hook.unownedTotal(currency1)
        ];
        x.w.swapAs(trader, _in(false, 1e15, 3100), 0); // nobody in range at 3000..3100 either: this swap's own fee is 0
        assertEq(hook.unowned(currency0) - before[0], 7, "the orphaned pot is not unowned");
        assertEq(hook.unowned(currency1) - before[1], 11, "the orphaned pot is not unowned");
        assertEq(hook.unownedTotal(currency0) - before[2], 7, "the orphaned pot is not in unownedTotal");
        assertEq(hook.unownedTotal(currency1) - before[3], 11, "the orphaned pot is not in unownedTotal");
        (p0, p1) = hook.potOf(x.key.toId());
        assertEq(p0 + p1, 0, "the pot was not emptied");
    }

    // ------------------------------------------------------------------ D5
    /// @notice every declared callback and `unlockCallback` refuse any caller but the manager - with callers on BOTH
    /// sides of the manager's address (`MUTANTS.md` family one of the capped example)
    function test_D5_only_the_manager_calls_the_callbacks() public {
        World memory x = _world(address(hook));
        ModifyLiquidityParams memory mp = ModifyLiquidityParams(-60, 60, 1, bytes32(0));
        SwapParams memory sp = _in(true, 1, -60);
        address[3] memory callers =
            [address(0xBAD), address(uint160(address(manager)) - 1), address(uint160(address(manager)) + 1)];
        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(callers[i]);
            vm.expectRevert(InRangeDonateHook.NotTheManager.selector);
            hook.beforeSwap(callers[i], x.key, sp, "");
            vm.expectRevert(InRangeDonateHook.NotTheManager.selector);
            hook.afterSwap(callers[i], x.key, sp, BalanceDelta.wrap(0), "");
            vm.expectRevert(InRangeDonateHook.NotTheManager.selector);
            hook.beforeAddLiquidity(callers[i], x.key, mp, "");
            vm.expectRevert(InRangeDonateHook.NotTheManager.selector);
            hook.beforeRemoveLiquidity(callers[i], x.key, mp, "");
            vm.expectRevert(InRangeDonateHook.NotTheManager.selector);
            hook.unlockCallback(abi.encode(InRangeDonateHook.Action.WITHDRAW, abi.encode(currency0, callers[i], 1)));
            vm.stopPrank();
        }
    }

    function test_every_undeclared_entry_point_reverts() public {
        World memory x = _world(address(hook));
        ModifyLiquidityParams memory mp = ModifyLiquidityParams(-60, 60, 1, bytes32(0));
        vm.startPrank(address(manager));
        vm.expectRevert(InRangeDonateHook.NotImplemented.selector);
        hook.beforeInitialize(address(0), x.key, SQRT_PRICE_1_1);
        vm.expectRevert(InRangeDonateHook.NotImplemented.selector);
        hook.afterInitialize(address(0), x.key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(InRangeDonateHook.NotImplemented.selector);
        hook.afterAddLiquidity(address(0), x.key, mp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
        vm.expectRevert(InRangeDonateHook.NotImplemented.selector);
        hook.afterRemoveLiquidity(address(0), x.key, mp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
        vm.expectRevert(InRangeDonateHook.NotImplemented.selector);
        hook.beforeDonate(address(0), x.key, 1, 1, "");
        vm.expectRevert(InRangeDonateHook.NotImplemented.selector);
        hook.afterDonate(address(0), x.key, 1, 1, "");
        vm.stopPrank();
    }

    /// @notice D5: `hookData` is never read - the same swaps with junk `hookData` leave the same pot
    function test_D5_hook_data_changes_nothing() public {
        World memory x = _world(address(hook));
        uint256 snap = vm.snapshotState();
        vm.prank(trader);
        router.swap(x.key, _in(false, 1e18, 900), "");
        (uint256 a0, uint256 a1) = hook.potOf(x.key.toId());
        vm.revertToState(snap);
        vm.prank(trader);
        router.swap(x.key, _in(false, 1e18, 900), abi.encode(treasury, type(uint256).max, "junk"));
        (uint256 b0, uint256 b1) = hook.potOf(x.key.toId());
        assertEq(a0, b0);
        assertEq(a1, b1);
    }

    // ------------------------------------------------------------------ native currency (D5)
    /// @notice an ETH / token pool: fees in ETH and in the token, the pot donated in ETH, and a JIT around a sweep
    /// takes nothing
    function test_D5_a_native_pool_pays_its_lps_in_eth_and_the_jit_nothing() public {
        PoolKey memory k = _initNativePool(IHooks(address(hook)), 0, 60, SQRT_PRICE_1_1, currency1);
        InRangeDonateWatcher w = new InRangeDonateWatcher(manager, router, liquidity, k, 30, true);
        InRangeLedger ledger = w.ledger();
        _fundNative(alice, 1e24);
        _fundNative(trader, 1e24);
        w.modifyAs(alice, -1200, 1200, 1e20, 1e24);
        JitRecipient jit = w.newJit();
        vm.deal(address(jit), 1e24);
        token1.mint(address(jit), 1e30);
        for (uint256 i = 0; i < 3; i++) {
            w.swapAs(trader, _in(true, 1e18, -900), 1e18); // ETH in: the fee in the token
            w.swapAs(trader, _in(false, 1e18, 900), 0); // token in: the fee in ETH
        }
        JitRecipient.Plan memory p;
        p.key = k;
        p.liquidity = 1e20;
        p.spacings = 1;
        p.payoutTarget = address(hook);
        p.payoutCall = abi.encodeWithSignature("sweep((address,address,uint24,int24,address))", k);
        JitRecipient.Result memory r = w.runJit(jit, p);
        assertEq(r.fees0 + r.fees1, 0, "the JIT took something on a native pool");
        (uint256 x0, uint256 x1) = ledger.excess(address(jit));
        assertEq(x0 + x1, 0);
        (uint256 r0, uint256 r1) = ledger.received(alice);
        (uint256 e0, uint256 e1) = ledger.entitled(alice);
        assertGt(r0, 0, "alice was paid no ETH");
        assertGe(r0 + 2, e0);
        assertGe(r1 + 2, e1);
        assertEq(hook.donated(Currency.wrap(address(0))), hook.feesTaken(Currency.wrap(address(0))));
    }
}
