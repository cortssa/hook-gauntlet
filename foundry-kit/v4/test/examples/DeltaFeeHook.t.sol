// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {V4Harness} from "../../src/V4Harness.sol";
import {HookMiner} from "../../src/HookMiner.sol";
import {MinimalRouter} from "../../src/MinimalRouter.sol";
import {DeltaFeeHook} from "../../src/examples/DeltaFeeHook.sol";
import {PrepayRouter} from "./PrepayRouter.sol";
import {TokenCallbackActor} from "../../src/TokenCallbackActor.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IHostileTokenCallback} from "gauntlet-kit/HostileERC20.sol";

/// @notice TWO swaps in ONE transaction, through the kit's own router: what a multicall or an aggregator does. Every
/// other test in this file runs each swap as its own top-level call, and forge clears transient storage between the
/// top-level calls of a test (measured by the verifier V13, 2026-09-24), so no other unit test ever sees what one swap
/// leaves in the hook's transient slot for the next. Fund it with `_fundAndApprove(address(two), ...)`.
contract TwoSwaps {
    MinimalRouter public immutable router;

    constructor(MinimalRouter router_) {
        router = router_;
    }

    function run(PoolKey calldata key, SwapParams calldata first, SwapParams calldata second)
        external
        returns (BalanceDelta d1, BalanceDelta d2)
    {
        d1 = router.swap(key, first, "");
        d2 = router.swap(key, second, "");
    }
}

/// @notice a door `TokenCallbackActor` does not have (the verifier V15's, 2026-09-24): from inside a transfer of the
/// currency, `take` x of it and pay for it with x of its OWN claims (`burn`). Its own books square, and it touches neither
/// the synced slot nor the checkpoint - P12's first check sees nothing - but the x it took came out of the balance the
/// payer's `settle` is about to read. `deposit` gives it claims first (sync + transfer + settle + mint, in its own lock).
contract TakeBurnActor is IHostileTokenCallback, IUnlockCallback {
    IPoolManager public immutable manager;
    Currency public immutable currency;
    uint256 public amount;
    uint256 public fired;
    bool public succeeded;
    bool private _inFire;

    constructor(IPoolManager manager_, Currency currency_) {
        manager = manager_;
        currency = currency_;
    }

    function arm(uint256 amount_) external {
        amount = amount_;
        fired = 0;
        succeeded = false;
    }

    function tokensToSend(address, address, uint256) external override {
        _fire();
    }

    function tokensReceived(address, address, uint256) external override {
        _fire();
    }

    function _fire() private {
        if (_inFire || amount == 0) return;
        _inFire = true;
        fired += 1;
        (succeeded,) = address(this).call(abi.encodeCall(this.takeAndBurn, ()));
        _inFire = false;
    }

    /// @notice the door, as one unit (its failure is swallowed); only this contract
    function takeAndBurn() external {
        require(msg.sender == address(this), "TakeBurnActor: self only");
        manager.take(currency, address(this), amount);
        manager.burn(address(this), currency.toId(), amount);
    }

    function deposit(uint256 amt) external {
        manager.unlock(abi.encode(amt));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "TakeBurnActor: manager only");
        uint256 amt = abi.decode(data, (uint256));
        manager.sync(currency);
        IERC20Minimal(Currency.unwrap(currency)).transfer(address(manager), amt);
        manager.mint(address(this), currency.toId(), manager.settle());
        return "";
    }
}

/// @notice Unit tests for the delta example: one per promise in the hook's header (P1-P9 and P11; P10, native
/// currency, is `DeltaFeeHook.native.t.sol`), and the arithmetic in all four orientations. Every number the hook claims is compared with what the MANAGER booked: the hook's delta is
/// `pool - caller`, the pool's delta off the `Swap` event, the caller's from the router (`V4Harness._swapWithBooks`).
contract DeltaFeeHookTest is V4Harness {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    /// @notice price 4 (currency1 per currency0): far enough from 1 that "fee of the input" and "fee of the output"
    /// are four times apart, which is the only place a side confusion shows
    uint160 internal constant SQRT_PRICE_4_1 = 158456325028528675187087900672;

    DeltaFeeHook internal hook;
    PoolKey internal key;
    address internal provider = address(0xA11CE);
    address internal trader = address(0xB0B);

    function setUp() public {
        _setUpV4();
        hook = DeltaFeeHook(
            _deployHook(
                type(DeltaFeeHook).creationCode,
                abi.encode(manager),
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                    | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            )
        );
        vm.label(address(hook), "DeltaFeeHook");
        _fundAndApprove(provider, 1_000_000e18);
        _fundAndApprove(trader, 1_000_000e18);
        key = _initPool(IHooks(address(hook)), 3000, 60, SQRT_PRICE_1_1);
        _addFullRangeLiquidity(key, provider, 100e18);
    }

    // ------------------------------------------------------------------ helpers
    function _p(bool exactIn, bool zeroForOne, uint256 amount) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactIn ? -int256(amount) : int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    /// @notice the hook's delta in the specified and the unspecified currency, as the MANAGER booked it
    function _hookDeltas(SwapParams memory p, SwapBooks memory b)
        internal
        pure
        returns (int256 spec, int256 unspec, int256 poolSpec, int256 poolUnspec)
    {
        bool s0 = (p.amountSpecified < 0) == p.zeroForOne;
        int256 h0 = b.pool0 - b.caller0;
        int256 h1 = b.pool1 - b.caller1;
        (spec, unspec) = s0 ? (h0, h1) : (h1, h0);
        (poolSpec, poolUnspec) = s0 ? (b.pool0, b.pool1) : (b.pool1, b.pool0);
    }

    /// @notice fill both reserves: three swaps each way, then a new block (a rebate needs a reserve, and a reserve needs
    /// fees: a fresh hook pays no rebate at all, which a suite that never funds it will never notice)
    function _fillReserves(PoolKey memory k) internal {
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(trader);
            router.swap(k, _p(true, true, 1e18), "");
            vm.prank(trader);
            router.swap(k, _p(true, false, 1e18), "");
        }
        vm.roll(vm.getBlockNumber() + 1);
    }

    // ------------------------------------------------------------------ the address and the entry points
    function test_the_address_carries_exactly_the_declared_flags() public view {
        assertTrue(HookMiner.carriesExactly(address(hook), hook.requiredFlags()));
    }

    function test_only_the_manager_may_call_the_hook() public {
        SwapParams memory p = _p(true, true, 1e18);
        vm.expectRevert(DeltaFeeHook.NotTheManager.selector);
        hook.beforeSwap(address(this), key, p, "");
        BalanceDelta d;
        vm.expectRevert(DeltaFeeHook.NotTheManager.selector);
        hook.afterSwap(address(this), key, p, d, "");
        // ETH, too, only from the manager (P8, P10): a stranger's ETH would sit outside the ledger
        vm.deal(address(this), 1 ether);
        (bool ok, bytes memory err) = address(hook).call{value: 1 ether}("");
        assertFalse(ok, "the hook accepted ETH from a stranger");
        assertEq(bytes4(err), DeltaFeeHook.NotTheManager.selector);
    }

    // ------------------------------------------------------------------ P2 and P3 on a fresh hook
    /// @notice a fresh hook holds nothing, so it pays no rebate - and it takes the fee, exactly, in the unspecified
    /// currency. The reserve is what it received.
    function test_a_fresh_hook_pays_no_rebate_and_takes_the_exact_fee() public {
        SwapParams memory p = _p(true, true, 1e18);
        SwapBooks memory b = _swapWithBooks(trader, key, p);
        (int256 spec, int256 unspec,, int256 poolUnspec) = _hookDeltas(p, b);
        assertEq(spec, 0, "a rebate out of an empty reserve");
        assertEq(unspec, int256(_abs(poolUnspec) * 30 / 10_000), "the fee is not 0.30 % of the pool's unspecified amount");
        assertEq(b.hook1, unspec, "the hook's balance is not the fee the manager booked");
        assertEq(hook.reserveOf(currency1), uint256(unspec), "the ledger is not what the hook received");
        assertEq(hook.feesBooked(currency1), uint256(unspec));
        assertEq(hook.reserveOf(currency0), 0);
    }

    // ------------------------------------------------------------------ P1, P2, P3 in all four orientations
    function _orientation(bool exactIn, bool zeroForOne, string memory label) internal {
        _fillReserves(key);
        SwapParams memory p = _p(exactIn, zeroForOne, 1e17);
        bool s0 = exactIn == zeroForOne;
        Currency specified = s0 ? currency0 : currency1;
        Currency unspecified = s0 ? currency1 : currency0;
        uint256 resSpecBefore = hook.reserveOf(specified);
        uint256 resUnspecBefore = hook.reserveOf(unspecified);
        uint256 nominal = hook.nominalRebateOf(1e17);
        assertLe(nominal, hook.rebateBudgetLeft(key.toId(), specified), "test setup: the budget should allow the whole rebate");

        SwapBooks memory b = _swapWithBooks(trader, key, p);
        (int256 spec, int256 unspec, int256 poolSpec, int256 poolUnspec) = _hookDeltas(p, b);
        console2.log(label);
        console2.log("  hook delta specified, unspecified:", vm.toString(spec), vm.toString(unspec));
        console2.log("  pool specified, unspecified      :", vm.toString(poolSpec), vm.toString(poolUnspec));

        // P3: the rebate is the nominal one, in the specified currency, and NEGATIVE (the hook paid)
        assertEq(spec, -int256(nominal), string.concat(label, ": rebate is not -0.10 % of |amountSpecified|"));
        // P2: the fee is exact, in the unspecified currency, and POSITIVE (the hook took)
        assertEq(unspec, int256(_abs(poolUnspec) * 30 / 10_000), string.concat(label, ": fee is not 0.30 % of unspecified"));
        assertGt(unspec, 0, string.concat(label, ": no fee"));
        // the rebate moved the POOL's amount: it swapped amountSpecified - rebate (more input, or less output)
        assertEq(poolSpec, p.amountSpecified - int256(nominal), string.concat(label, ": pool's specified amount"));
        // ...and not the swapper's: its specified side is exactly amountSpecified
        assertEq(s0 ? b.caller0 : b.caller1, p.amountSpecified, string.concat(label, ": swapper's specified side"));
        // P1: conservation over swapper, hook and manager, and the manager kept the pool's delta
        assertEq(b.swapper0 + b.hook0 + b.manager0, 0, string.concat(label, ": currency0"));
        assertEq(b.swapper1 + b.hook1 + b.manager1, 0, string.concat(label, ": currency1"));
        assertEq(b.manager0, -b.pool0, string.concat(label, ": manager0"));
        assertEq(b.manager1, -b.pool1, string.concat(label, ": manager1"));
        // the hook's ledger followed its balance
        assertEq(hook.reserveOf(specified), resSpecBefore - nominal, string.concat(label, ": specified reserve"));
        assertEq(hook.reserveOf(unspecified), resUnspecBefore + uint256(unspec), string.concat(label, ": unspecified reserve"));
    }

    function test_exact_in_zero_for_one() public {
        _orientation(true, true, "exact-in  zeroForOne");
    }

    function test_exact_in_one_for_zero() public {
        _orientation(true, false, "exact-in  oneForZero");
    }

    function test_exact_out_zero_for_one() public {
        _orientation(false, true, "exact-out zeroForOne");
    }

    function test_exact_out_one_for_zero() public {
        _orientation(false, false, "exact-out oneForZero");
    }

    /// @notice P2 where it can be told apart: at price 4 the output of a swap is four times its input, so a fee
    /// computed on the wrong side is off by a factor of four, not by a rounding error. At 1:1 it is off by the price
    /// impact and the LP fee, which an approximate check forgives.
    function test_the_fee_is_on_the_unspecified_side_at_a_price_far_from_one() public {
        PoolKey memory k = _initPool(IHooks(address(hook)), 500, 10, SQRT_PRICE_4_1);
        _addFullRangeLiquidity(k, provider, 100e18);
        for (uint256 i = 0; i < 4; i++) {
            SwapParams memory p = _p(i < 2, i % 2 == 0, 1e17);
            SwapBooks memory b = _swapWithBooks(trader, k, p);
            (, int256 unspec, int256 poolSpec, int256 poolUnspec) = _hookDeltas(p, b);
            assertEq(unspec, int256(_abs(poolUnspec) * 30 / 10_000), "the fee was not taken on the unspecified side");
            // and the two sides really are far apart here, or this test proves nothing
            assertTrue(_abs(poolUnspec) > 2 * _abs(poolSpec) || _abs(poolSpec) > 2 * _abs(poolUnspec), "price too near 1");
        }
    }

    // ------------------------------------------------------------------ P5: the cap
    function test_rebates_in_one_block_stop_at_the_cap_and_start_again_in_the_next() public {
        _fillReserves(key);
        uint256 reserve0 = hook.reserveOf(currency0);
        uint256 cap = reserve0 * 1_000 / 10_000;
        uint256 paidInBlock;
        uint256 cut;
        for (uint256 i = 0; i < 12; i++) {
            SwapParams memory p = _p(true, true, 1e18); // nominal rebate 1e15, cap about 9e14
            SwapBooks memory b = _swapWithBooks(trader, key, p);
            (int256 spec,,,) = _hookDeltas(p, b);
            paidInBlock += uint256(-spec);
            if (uint256(-spec) < hook.nominalRebateOf(1e18)) cut += 1;
        }
        assertEq(hook.budgetOf(key.toId(), currency0).cap, cap, "the cap is not 10 % of the reserve at the block's first swap");
        assertLe(paidInBlock, cap, "rebates in one block exceeded the cap");
        assertEq(paidInBlock, cap, "the cap was not spent to the wei (a cut rebate should take exactly what is left)");
        assertGt(cut, 0, "the cap never bit: the test proves nothing");
        assertEq(hook.rebateBudgetLeft(key.toId(), currency0), 0);

        vm.roll(vm.getBlockNumber() + 1);
        assertEq(hook.rebateBudgetLeft(key.toId(), currency0), hook.reserveOf(currency0) * 1_000 / 10_000, "the next block's budget");
        SwapParams memory q = _p(true, true, 1e17);
        SwapBooks memory c = _swapWithBooks(trader, key, q);
        (int256 spec2,,,) = _hookDeltas(q, c);
        assertEq(spec2, -int256(hook.nominalRebateOf(1e17)), "a new block pays again");
    }

    // ------------------------------------------------------------------ P4: no free rebate
    function test_rebates_never_exceed_fees_and_the_ledger_is_backed() public {
        _fillReserves(key);
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(trader);
            router.swap(key, _p(i % 3 != 0, i % 2 == 0, 3e17), "");
            if (i % 5 == 4) vm.roll(vm.getBlockNumber() + 1);
        }
        for (uint256 j = 0; j < 2; j++) {
            Currency c = j == 0 ? currency0 : currency1;
            assertGt(hook.rebatesPaid(c), 0, "no rebate was ever paid: the test proves nothing");
            assertLe(hook.rebatesPaid(c), hook.feesBooked(c), "rebates exceeded fees");
            assertEq(hook.reserveOf(c), hook.feesBooked(c) - hook.rebatesPaid(c), "ledger != fees - rebates (honest tokens)");
            assertEq((j == 0 ? token0 : token1).trueBalanceOf(address(hook)), hook.reserveOf(c), "balance != ledger");
        }
    }

    /// @notice P4 where the manager's number and the hook's differ: a currency that charges 1 % on every transfer. The
    /// manager BOOKS the fee (the hook's delta, which the hook returns); the hook RECEIVES 1 % less. The reserve - what
    /// funds every later rebate - is what arrived. A ledger that counted what was booked would promise rebates out of
    /// tokens the hook never got. Red with `reserveOf[unspecified] += fee` for `+= received` (the verifier's X1, which
    /// until 2026-09-24 only the campaign killed).
    function test_the_reserve_is_what_arrived_not_what_the_manager_booked() public {
        token1.setFeeBps(100); // currency1 is the OUTPUT of a zeroForOne swap: the fee is taken in it, and arrives short
        SwapParams memory p = _p(true, true, 1e18);
        SwapBooks memory b = _swapWithBooks(trader, key, p);
        (, int256 unspec,,) = _hookDeltas(p, b);
        assertGt(unspec, 0, "no fee was booked: the test proves nothing");
        assertEq(b.hook1, unspec - unspec * 100 / 10_000, "test setup: the fee did not arrive 1 % short");
        assertEq(hook.feesBooked(currency1), uint256(unspec), "feesBooked is not what the manager booked");
        assertEq(hook.reserveOf(currency1), uint256(b.hook1), "the reserve is not what arrived");
        assertEq(hook.reserveOf(currency1), token1.trueBalanceOf(address(hook)), "the ledger is not the balance");
    }

    /// @notice the swap the pool does not fill. A specified-side delta is committed in `beforeSwap`, before the pool
    /// knows how much it will fill; with a price limit at the pool's price it fills (almost) nothing, and the swapper's
    /// specified delta is `pool - hook`: the rebate, for a swap that did not happen. Seen red on the first version of
    /// this hook: the swapper received 906 067 445 652 208 of currency0 - the block's whole rebate budget
    /// (906 067 445 652 210; the nominal rebate, 1e15, is cut by the cap) less the 2 wei the pool took - and no
    /// currency1 at all (the pool's delta in the `Swap` event: -2 / 0). Re-measured 2026-09-24 with the check removed.
    /// Now refused.
    function test_a_swap_the_pool_does_not_fill_earns_no_rebate() public {
        _fillReserves(key);
        (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
        SwapParams memory p = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: sqrtP - 1});
        uint256 before0 = token0.trueBalanceOf(trader);
        vm.prank(trader);
        try router.swap(key, p, "") returns (BalanceDelta d) {
            console2.log("swapper's currency0 delta on a swap limited at the pool's price:", vm.toString(d.amount0()));
            assertLe(d.amount0(), 0, "the swapper was PAID in the currency it was selling: a rebate for nothing");
            assertLe(token0.trueBalanceOf(trader), before0, "the swapper ended richer in the currency it sold");
        } catch (bytes memory err) {
            assertEq(
                err,
                abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    address(hook),
                    IHooks.afterSwap.selector,
                    abi.encodeWithSelector(DeltaFeeHook.RebateOnPartialFill.selector),
                    abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                ),
                "refused, but not by the partial-fill check"
            );
        }
    }

    /// @notice and a partial fill with NO rebate (a fresh hook) still goes through: the check is about the rebate
    function test_a_partial_fill_without_a_rebate_is_allowed() public {
        (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
        vm.prank(trader);
        BalanceDelta d =
            router.swap(key, SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: sqrtP - 1e20}), "");
        assertGt(d.amount0(), -1e18, "the pool filled the whole amount: the limit did not bite");
        assertLt(d.amount0(), 0);
    }

    // ------------------------------------------------------------------ P6: what the hook returns is what moved
    /// @notice a currency that delivers short FROM the hook: the hook meant to pay 1e14 and the manager was credited
    /// 5e13. The hook returns what the MANAGER credited (`settle`'s return), so the books close and the swapper gets
    /// the rebate that actually arrived. A hook that returned what it meant to pay leaves the unlock open.
    function test_the_rebate_returned_is_what_the_manager_credited_not_what_was_meant() public {
        _fillReserves(key);
        token0.setShortDeliver(address(hook), 2);
        SwapParams memory p = _p(true, true, 1e17);
        SwapBooks memory b = _swapWithBooks(trader, key, p);
        (int256 spec,,,) = _hookDeltas(p, b);
        assertEq(spec, -int256(hook.nominalRebateOf(1e17) / 2), "the booked rebate is not what arrived");
        assertEq(b.hook0, spec, "the hook's balance moved by other than what the manager booked");
    }

    // ------------------------------------------------------------------ P7: a payment in flight
    /// @notice a router that pays first leaves ITS currency synced while the hook runs. The hook sees it and pays no
    /// rebate: its own `sync` would reset the router's checkpoint, the router's `settle` would then credit nothing, and
    /// the unlock would not close. Red against the hook with that check removed (`CurrencyNotSettled`).
    function test_a_router_that_pays_first_is_not_clobbered_by_the_rebate() public {
        _fillReserves(key);
        PrepayRouter pre = new PrepayRouter(manager);
        vm.prank(trader);
        token0.approve(address(pre), type(uint256).max);
        uint256 paid0 = hook.rebatesPaid(currency0);
        uint256 before0 = token0.trueBalanceOf(trader);
        vm.prank(trader);
        pre.swap(key, _p(true, true, 1e17));
        assertEq(hook.rebatesPaid(currency0), paid0, "a rebate was paid while a payment was in flight");
        assertEq(before0 - token0.trueBalanceOf(trader), 1e17, "the prepaying swapper paid other than its input");
    }

    // ------------------------------------------------------------------ P12: a currency that moves the checkpoint
    /// @notice the hook pays its rebate by sync + transfer + settle. A currency with a transfer hook runs code INSIDE that
    /// transfer (`TokenCallbackActor`, armed on the next transfer into the manager: the hook's own), and whatever moves the
    /// manager's synced slot or its checkpoint there makes the hook's `settle` credit nothing: `sync` of another currency,
    /// of the zero address, or of the same currency after the move (the rebate sits in the manager as nobody's), or a
    /// bare `settle` of its own - with `take` or `mint` after it, the callback KEEPS the rebate (measured on the hook
    /// before P12: the swap stood, the hook's reserve fell by the rebate, the swapper got none, the callback took
    /// 89 828 095 180 378). Now the hook checks that the slot and the checkpoint it set are still there before it
    /// settles, and refuses the swap (`SettlementHijacked`): the token can still deny service, it can no longer take
    /// the rebate. Red on the hook without the check: every row stands.
    function test_P12_a_currency_that_moves_the_checkpoint_mid_rebate_is_refused() public {
        _fillReserves(key);
        TokenCallbackActor actor = new TokenCallbackActor(manager);
        bytes memory refusal = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(DeltaFeeHook.SettlementHijacked.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
        TokenCallbackActor.Door[6] memory doors = [
            TokenCallbackActor.Door.SYNC,
            TokenCallbackActor.Door.SYNC,
            TokenCallbackActor.Door.SYNC,
            TokenCallbackActor.Door.SETTLE,
            TokenCallbackActor.Door.SETTLE_AND_TAKE,
            TokenCallbackActor.Door.SETTLE_AND_MINT
        ];
        Currency[6] memory on = [currency1, Currency.wrap(address(0)), currency0, currency0, currency0, currency0];
        for (uint256 i = 0; i < doors.length; i++) {
            actor.setDoor(doors[i], on[i], 0);
            token0.setReceiveCallback(address(manager), address(actor), 1);
            vm.prank(trader);
            vm.expectRevert(refusal);
            router.swap(key, _p(true, true, 1e17), "");
        }
        // and a swap NESTED inside this one, on this hook's own pool, from the rebate's transfer: the nested swapper
        // squares its books with a `sync` of its own, and the outer rebate is refused the same way
        token1.mint(address(actor), 1e18);
        actor.setSwap(key, _p(true, false, 1e16));
        token0.setReceiveCallback(address(manager), address(actor), 1);
        vm.prank(trader);
        vm.expectRevert(refusal);
        router.swap(key, _p(true, true, 1e17), "");
    }

    /// @notice the control: `sync` of the SAME currency BEFORE the balances move (the hook's own send callback) changes
    /// neither the slot nor the checkpoint - the rebate is paid in full and the swap stands
    function test_P12_a_resync_of_the_same_currency_before_the_move_is_harmless() public {
        _fillReserves(key);
        TokenCallbackActor actor = new TokenCallbackActor(manager);
        actor.setDoor(TokenCallbackActor.Door.SYNC, currency0, 0);
        token0.setSendCallback(address(hook), address(actor), 1);
        uint256 budget = hook.rebateBudgetLeft(key.toId(), currency0);
        uint256 paid0 = hook.rebatesPaid(currency0);
        SwapParams memory p = _p(true, true, 1e17);
        SwapBooks memory b = _swapWithBooks(trader, key, p);
        (int256 spec,,,) = _hookDeltas(p, b);
        assertEq(actor.fired(), 1, "the callback never fired");
        uint256 expected = hook.nominalRebateOf(1e17) < budget ? hook.nominalRebateOf(1e17) : budget;
        assertEq(spec, -int256(expected), "the rebate was not paid in full");
        assertEq(hook.rebatesPaid(currency0) - paid0, expected);
    }

    // ------------------------------------------------------------------ P12, second half: what the manager credited
    function _notCredited(uint256 sent, uint256 credited) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(DeltaFeeHook.RebateNotCredited.selector, sent, credited),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @notice P12's first check watches the synced slot and the checkpoint; a callback can leave both alone and still
    /// empty the payment: `take` x of the currency from the manager and pay for it with x of its own claims (`burn`). Its
    /// books square, the hook's `settle` then reads a balance x short of what it sent and credits the hook x less. Found by
    /// the verifier V15 (2026-09-24) on the hook with P12's first check only: the swap stood, the pool's reserve fell by the
    /// rebate (100 000 000 000 000), the swapper got none of it, `rebatesPaid` rose by 0, and the callback gained nothing -
    /// it swapped claims for tokens 1:1 - so the rebate was nobody's (`doctrine/SEVERITY.md`: still a loss). Now the hook
    /// compares what the manager credited with what left it, and refuses the swap if it is less (`RebateNotCredited`).
    /// Both moments (before the hook's balance moves, and after it reaches the manager), with x the whole rebate and half
    /// of it. Red on the hook without the second check: `next call did not revert as expected`.
    function test_P12_a_take_paid_with_the_callbacks_own_claims_mid_rebate_is_refused() public {
        _fillReserves(key);
        TakeBurnActor door = new TakeBurnActor(manager, currency0);
        token0.mint(address(door), 1e18);
        door.deposit(1e18);
        uint256 budget = hook.rebateBudgetLeft(key.toId(), currency0);
        uint256 nominal = hook.nominalRebateOf(1e17);
        uint256 r = nominal < budget ? nominal : budget;
        uint256 reserve = hook.poolReserveOf(key.toId(), currency0);
        uint256[2] memory xs = [r, r / 2];
        for (uint256 mv = 0; mv < 2; mv++) {
            for (uint256 j = 0; j < 2; j++) {
                door.arm(xs[j]);
                // one moment at a time: a refused swap rolls back the fire, so the other switch is set to 0 fires
                token0.setSendCallback(address(hook), address(door), mv == 0 ? 1 : 0);
                token0.setReceiveCallback(address(manager), address(door), mv == 1 ? 1 : 0);
                vm.prank(trader);
                vm.expectRevert(_notCredited(r, r - xs[j]));
                router.swap(key, _p(true, true, 1e17), "");
            }
        }
        assertEq(hook.poolReserveOf(key.toId(), currency0), reserve, "the pool's reserve moved");
        assertEq(manager.balanceOf(address(door), currency0.toId()), 1e18, "the callback's claims moved");
        // the control: disarmed, the same swap stands and is paid the whole rebate
        door.arm(0);
        SwapParams memory p = _p(true, true, 1e17);
        SwapBooks memory b = _swapWithBooks(trader, key, p);
        (int256 spec,,,) = _hookDeltas(p, b);
        assertEq(spec, -int256(r), "the control swap was not paid the rebate");
    }

    /// @notice the PRICE of that check, stated: the hook cannot tell a callback that took part of its payment from a
    /// currency that charges a fee on the transfer - both leave the manager crediting less than left the hook. A rebate
    /// in a fee-on-transfer currency is refused whole, like any short credit. Where it bites: the rebate is in the
    /// SPECIFIED currency, so on a swap whose input is that currency the router's own payment already arrives short
    /// (`CurrencyNotSettled`, before and after this check); what this check adds is the exact-out swap whose OUTPUT is that
    /// currency, which stood before it with the rebate less the token's fee (1 % here) and is now refused while the pool's
    /// rebate budget in that currency lasts.
    function test_P12_price_a_rebate_in_a_currency_that_charges_on_transfer_is_refused() public {
        _fillReserves(key);
        token1.setFeeBps(100);
        SwapParams memory p = _p(false, true, 1e17); // exact-out zeroForOne: currency1 is the output, and specified
        uint256 budget = hook.rebateBudgetLeft(key.toId(), currency1);
        uint256 nominal = hook.nominalRebateOf(1e17);
        uint256 r = nominal < budget ? nominal : budget;
        assertGt(r, 0, "test setup: no rebate budget in currency1");
        vm.prank(trader);
        vm.expectRevert(_notCredited(r, r - r * 100 / 10_000));
        router.swap(key, p, "");
    }

    // ------------------------------------------------------------------ P11: liveness, the price of P9
    function _price(PoolKey memory k) internal view returns (uint160 sqrtP) {
        (sqrtP,,,) = manager.getSlot0(k.toId());
    }

    /// @notice P11: while the rebate budget lasts, EVERY partial fill is refused, not only the ones P9 was written for.
    /// In each orientation: the full fill's end price (with the rebate) is measured, and the same swap limited at 1/4,
    /// 1/2, 3/4 and 999/1000 of the way there is refused `RebateOnPartialFill`; limited AT the end price it fills,
    /// with the rebate. (The verifier V13 measured the practical case: a limit quoted for the plain swap, which the
    /// rebate makes the pool overshoot, is refused.)
    function test_P11_with_a_rebate_budget_every_partial_fill_is_refused() public {
        _fillReserves(key);
        bytes memory refusal = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(DeltaFeeHook.RebateOnPartialFill.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
        for (uint256 o = 0; o < 4; o++) {
            bool exactIn = o < 2;
            bool zeroForOne = o % 2 == 0;
            SwapParams memory p = _p(exactIn, zeroForOne, 1e18);
            uint160 p0 = _price(key);
            uint256 snap = vm.snapshotState();
            vm.prank(trader);
            router.swap(key, p, "");
            uint160 pEnd = _price(key);
            vm.revertToState(snap);

            // 1/4, 1/2, 3/4 and 999/1000 of the way from the price to the full fill's end price
            uint256[4] memory num = [uint256(250), 500, 750, 999];
            for (uint256 k = 0; k < 4; k++) {
                p.sqrtPriceLimitX96 = zeroForOne
                    ? uint160(p0 - (p0 - pEnd) * num[k] / 1000)
                    : uint160(p0 + (pEnd - p0) * num[k] / 1000);
                vm.prank(trader);
                vm.expectRevert(refusal);
                router.swap(key, p, "");
            }
            bool s0 = exactIn == zeroForOne;
            uint256 paid = hook.rebatesPaid(s0 ? currency0 : currency1);
            // one sqrt-price unit short of the end price is NOT always a partial fill: the step that reaches the limit
            // rounds the amount it needs, and can need the whole amount. Measured (2026-09-24): it stands in both
            // exact-in orientations, as a FULL fill, and is refused in both exact-out ones. Either way, no partial
            // fill stands with a rebate.
            p.sqrtPriceLimitX96 = zeroForOne ? pEnd + 1 : pEnd - 1;
            snap = vm.snapshotState();
            vm.prank(trader);
            try router.swap(key, p, "") returns (BalanceDelta d) {
                assertEq(s0 ? d.amount0() : d.amount1(), p.amountSpecified, "one unit short: stood as a partial fill");
                console2.log("one unit short of the end price: stood, as a full fill; orientation", o);
            } catch (bytes memory err) {
                assertEq(err, refusal, "one unit short: refused, but not by P9");
                console2.log("one unit short of the end price: refused; orientation", o);
            }
            vm.revertToState(snap);
            // AT the end price: fills, with the rebate
            p.sqrtPriceLimitX96 = pEnd;
            snap = vm.snapshotState();
            vm.prank(trader);
            BalanceDelta dEnd = router.swap(key, p, "");
            assertEq(s0 ? dEnd.amount0() : dEnd.amount1(), p.amountSpecified, "limit at the end price");
            assertGt(hook.rebatesPaid(s0 ? currency0 : currency1), paid, "no rebate at the end price");
            vm.revertToState(snap);
        }
    }

    // ------------------------------------------------------------------ two swaps in one transaction
    /// @notice the transient slot that carries the rebate from `beforeSwap` to `afterSwap` must be EMPTY for the next
    /// swap of the same transaction. The first swap spends the block's whole rebate budget in currency0; the second,
    /// the same swap, gets no rebate and must fill as a plain swap. Red with the slot not cleared in `_checkFilled`
    /// (the verifier's X2, which until 2026-09-24 only the campaign's smoke test killed): the second swap reads the
    /// first one's rebate and is refused `RebateOnPartialFill`.
    function test_two_swaps_in_one_transaction_the_second_with_no_rebate_left() public {
        _fillReserves(key);
        TwoSwaps two = new TwoSwaps(router);
        _fundAndApprove(address(two), 1_000_000e18);
        SwapParams memory p = _p(true, true, 1e18);
        uint256 budget = hook.rebateBudgetLeft(key.toId(), currency0);
        assertLt(budget, hook.nominalRebateOf(1e18), "test setup: the first swap must spend the whole budget");
        uint256 paid0 = hook.rebatesPaid(currency0);

        (BalanceDelta d1, BalanceDelta d2) = two.run(key, p, p);

        assertEq(hook.rebatesPaid(currency0) - paid0, budget, "the first swap was not paid the block's whole budget");
        assertEq(hook.rebateBudgetLeft(key.toId(), currency0), 0);
        assertEq(d1.amount0(), -1e18, "first swap: the swapper's specified side");
        assertEq(d2.amount0(), -1e18, "second swap: the swapper's specified side");
    }

    /// @notice the same, where it matters for liveness: once the budget is spent, a PARTIAL fill stands again (P11's
    /// other half) - also as the second swap of a transaction that paid a rebate on its first. Red with X2.
    function test_two_swaps_in_one_transaction_a_partial_second_with_no_rebate_left_stands() public {
        _fillReserves(key);
        TwoSwaps two = new TwoSwaps(router);
        _fundAndApprove(address(two), 1_000_000e18);
        SwapParams memory p = _p(true, true, 1e18);
        uint256 snap = vm.snapshotState();
        vm.prank(trader);
        router.swap(key, p, "");
        uint160 pAfterFirst = _price(key);
        vm.revertToState(snap);
        // 0.01 % of sqrt price below where the first swap leaves it: 1e18 does not fit
        SwapParams memory q = _p(true, true, 1e18);
        q.sqrtPriceLimitX96 = uint160(uint256(pAfterFirst) * 9_999 / 10_000);

        (, BalanceDelta d2) = two.run(key, p, q);

        assertGt(d2.amount0(), -1e18, "the second swap filled completely: the limit did not bite");
        assertLt(d2.amount0(), 0);
        assertEq(_price(key), q.sqrtPriceLimitX96, "the second swap did not stop at its limit");
    }

    /// @notice and P9 still bites on the second swap: the first pays a rebate in currency0 and fills; the second, in
    /// the other direction with its own rebate in currency1, is limited one unit past the price and refused. The whole
    /// transaction goes with it.
    function test_P9_holds_on_the_second_swap_of_a_transaction() public {
        _fillReserves(key);
        TwoSwaps two = new TwoSwaps(router);
        _fundAndApprove(address(two), 1_000_000e18);
        SwapParams memory p = _p(true, true, 1e17);
        uint256 snap = vm.snapshotState();
        vm.prank(trader);
        router.swap(key, p, "");
        uint160 pAfterFirst = _price(key);
        vm.revertToState(snap);
        SwapParams memory q = _p(true, false, 1e17);
        q.sqrtPriceLimitX96 = pAfterFirst + 1;
        assertGt(hook.rebateBudgetLeft(key.toId(), currency1), 0, "test setup: the second swap must have a rebate budget");

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(DeltaFeeHook.RebateOnPartialFill.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        two.run(key, p, q);
    }
}
