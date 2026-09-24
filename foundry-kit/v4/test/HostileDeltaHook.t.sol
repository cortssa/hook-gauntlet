// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {V4Harness} from "../src/V4Harness.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {HostileHook} from "../src/HostileHook.sol";
import {PrepayRouter} from "./examples/PrepayRouter.sol";

/// @notice `PrepayRouter` with one "robustness" step more: after its own `settle` it reads its OWN open delta
/// (`currencyDelta`) and pays whatever the books still show it owing. A router written to "always close the unlock".
/// Exact-in zeroForOne only, like `PrepayRouter`.
contract TopUpPrepayRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    struct Call {
        PoolKey key;
        SwapParams params;
        address payer;
    }

    constructor(IPoolManager m) {
        manager = m;
    }

    function swap(PoolKey memory key, SwapParams memory params) external {
        require(params.zeroForOne && params.amountSpecified < 0, "TopUpPrepayRouter: exact-in zeroForOne only");
        manager.unlock(abi.encode(Call(key, params, msg.sender)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not the manager");
        Call memory c = abi.decode(data, (Call));
        _pay(c.key.currency0, c.payer, uint256(-c.params.amountSpecified));
        BalanceDelta d = manager.swap(c.key, c.params, "");
        manager.settle();
        if (d.amount1() > 0) manager.take(c.key.currency1, c.payer, uint256(uint128(d.amount1())));
        int256 open = manager.currencyDelta(address(this), c.key.currency0);
        if (open < 0) {
            _pay(c.key.currency0, c.payer, uint256(-open));
            manager.settle();
        }
        return "";
    }

    function _pay(Currency c, address payer, uint256 amount) internal {
        manager.sync(c);
        (bool ok,) = Currency.unwrap(c).call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", payer, address(manager), amount)
        );
        require(ok, "TopUpPrepayRouter: transferFrom");
    }
}

/// @notice ITEM 4 of the delta series (K13): `HostileHook` re-entering the manager WHILE IT HOLDS A DELTA - from inside
/// `afterSwap`, after it has taken its fee (so the manager's books show it owing that fee back) and before it returns
/// the delta that cancels it. What the manager allows there, what it refuses, and what a hook that re-enters has to
/// check, each measured with `reentriesSucceeded` readable AFTER the transaction (a re-entry the manager allowed and a
/// transaction that then died leave the same counter at 0 - the old `HostileHook` tests say why - so every "allowed"
/// below is one the hook also squared, and the transaction stood).
///
/// The measured answers (source manager only; the etched fixture has not run this file - the repo ships no fixture,
/// and `V4_MANAGER=fixture` without one SKIPS):
///  * `unlock` while holding: REFUSED (`AlreadyUnlocked`), the swap completes, the hook keeps its fee;
///  * `take` while holding: ALLOWED - a flash loan from the manager's reserves, mid-swap. It stands only if the hook
///    reads its own open delta afterwards and repays; a hook that trusts its own arithmetic instead (it "knows" it
///    holds exactly its fee) leaves the loan open and the manager refuses the whole swap (`CurrencyNotSettled`);
///  * `swap` on its own pool while holding: ALLOWED, and NOT seen by the hook (the manager skips a hook's callbacks
///    when the hook is the caller: no fee, no rebate, no check of its own). The hook trades on the pool it guards,
///    between the swapper's move and the end of the swapper's transaction; the same squaring rule applies;
///  * `settle()` while a ROUTER's payment is in flight (a router that pays first: `sync`, transfer, swap, `settle`):
///    ALLOWED, and it credits the router's transfer to the HOOK. The router's own `settle` then finds nothing synced
///    and credits nothing, its debt stays open, and the manager refuses the whole transaction - with or without the
///    hook's own-delta check: a denial of service against a router that settles once (K13b, from the verifier V13's
///    finding 3). Against a router that then pays whatever its books still show owing, the hook that takes the credit
///    it was handed keeps the router's first payment and the swapper pays twice: a theft.
contract HostileDeltaHookTest is V4Harness {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int128 internal constant FEE = 1e15;

    HostileHook internal hook;
    PoolKey internal key;
    address internal provider = address(0xA11CE);
    address internal trader = address(0xB0B);

    function setUp() public {
        _setUpManager();
        _deployCurrencies();
        _deployRouters();
        (, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG,
            type(HostileHook).creationCode,
            abi.encode(manager)
        );
        hook = new HostileHook{salt: salt}(manager);
        vm.label(address(hook), "HostileHook(holding)");
        key = _initPool(IHooks(address(hook)), 3000, 60, SQRT_PRICE_1_1);
        _fundAndApprove(provider, 1_000_000e18);
        _fundAndApprove(trader, 1_000_000e18);
        _addFullRangeLiquidity(key, provider, 100e18);
        token0.mint(address(hook), 10e18);
        token1.mint(address(hook), 10e18);

        // an honest fee hook: takes FEE of the unspecified side after the swap, and settles it in the same call
        hook.setDeltas(0, 0, FEE);
        hook.setSquareOwnDelta(true);
        hook.setReenterWhileHolding(true);
    }

    function _swapParams() internal pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
    }

    function test_baseline_the_hook_takes_its_fee_and_the_books_close() public {
        SwapBooks memory b = _swapWithBooks(trader, key, _swapParams());
        assertEq(b.hook1, FEE, "the hook did not get its fee");
        assertEq(b.caller1, b.pool1 - FEE, "the swapper was not charged the fee");
        assertEq(hook.reentriesAttempted(), 0);
    }

    /// @notice `unlock` while holding: refused, and the refusal is the manager's own error
    function test_unlock_while_holding_a_delta_is_refused_and_the_swap_stands() public {
        hook.setReenter(true); // default target: manager.unlock("")
        SwapBooks memory b = _swapWithBooks(trader, key, _swapParams());

        assertEq(hook.heldAtReentry1(), -int256(FEE), "the hook was not holding its fee when it re-entered");
        assertEq(hook.heldAtReentry0(), 0);
        assertEq(hook.reentriesAttempted(), 1);
        assertEq(hook.reentriesSucceeded(), 0, "the manager allowed a nested unlock while a hook held a delta");
        assertEq(bytes4(hook.lastReentryReturn()), IPoolManager.AlreadyUnlocked.selector, "refused, but not as expected");
        assertEq(b.hook1, FEE, "and the hook still got exactly its fee");
    }

    /// @notice `take` while holding, by a hook that CHECKS: it reads its own open delta after the re-entry and repays
    /// what the re-entry borrowed. The manager allowed the take, the books closed, and the counter survived.
    /// RED FIRST: the same test with `setCheckOwnDelta(true)` removed dies at the outer unlock (`CurrencyNotSettled`).
    function test_take_while_holding_is_a_flash_loan_that_stands_only_if_the_hook_checks_its_own_delta() public {
        hook.setReenter(true);
        hook.setReentryTake(key.currency0, address(hook), 1e16);
        hook.setCheckOwnDelta(true);
        uint256 hook0Before = token0.trueBalanceOf(address(hook));

        SwapBooks memory b = _swapWithBooks(trader, key, _swapParams());

        assertEq(hook.reentriesSucceeded(), 1, "the manager refused the take (it allowed it before)");
        assertEq(hook.heldAtReentry1(), -int256(FEE), "the hook was not holding its fee when it re-entered");
        assertEq(hook.residuesSquared(), 1, "the check found nothing to square: the take did not happen");
        assertEq(token0.trueBalanceOf(address(hook)), hook0Before, "the loan was not repaid in full");
        assertEq(b.hook1, FEE, "the hook's fee changed");
        assertEq(b.swapper0 + b.hook0 + b.manager0, 0, "currency0 created or destroyed");
    }

    /// @notice the other half, as a refusal: the hook that does NOT check leaves the loan open, and the manager
    /// refuses the WHOLE transaction - the swapper's swap included. The hook's own bug is the swapper's denial of service.
    function test_take_while_holding_without_the_check_kills_the_swappers_transaction() public {
        hook.setReenter(true);
        hook.setReentryTake(key.currency0, address(hook), 1e16);
        vm.prank(trader);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        router.swap(key, _swapParams(), "");
    }

    /// @notice `swap` on its own pool while holding: allowed, invisible to the hook, and it stands if the hook squares
    /// the nested swap's delta too. The hook traded on its own pool inside the swapper's transaction, with no fee of
    /// its own and none of its own checks - `V4-ACCOUNTING.md` item 2, now with a delta held across it.
    function test_swap_on_its_own_pool_while_holding_is_allowed_and_skips_the_hook() public {
        hook.setReenter(true);
        hook.setReentrySwap(
            key, SwapParams({zeroForOne: false, amountSpecified: -1e17, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1})
        );
        hook.setCheckOwnDelta(true);

        SwapBooks memory b = _swapWithBooks(trader, key, _swapParams());

        assertEq(hook.calls(), 2, "the nested swap called the hook: the manager did not skip its own hook");
        assertEq(hook.reentriesSucceeded(), 1, "the nested swap was refused");
        assertEq(hook.residuesSquared(), 1, "the nested swap left nothing to square");
        // the hook paid 1e17 of currency1 into its own pool and took currency0 out, fee-free from the hook's side
        assertLt(b.hook1, FEE, "the hook's currency1 did not pay for the nested swap");
        assertGt(b.hook0, 0, "the hook got no currency0 from the nested swap");
        assertEq(b.swapper0 + b.hook0 + b.manager0, 0, "currency0 created or destroyed");
        assertEq(b.swapper1 + b.hook1 + b.manager1, 0, "currency1 created or destroyed");
    }

    function test_swap_on_its_own_pool_while_holding_without_the_check_kills_the_transaction() public {
        hook.setReenter(true);
        hook.setReentrySwap(
            key, SwapParams({zeroForOne: false, amountSpecified: -1e17, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1})
        );
        vm.prank(trader);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        router.swap(key, _swapParams(), "");
    }

    /// @notice `settle()` while holding, against a router whose payment is IN FLIGHT (`PrepayRouter`: sync + transfer
    /// before the swap, `settle` after it). The hook's bare `settle()` credits whatever is synced and unpaid - the
    /// router's 1e18 of currency0 - to the HOOK, and clears the synced slot; the router's `settle` then credits nothing,
    /// its debt stays open, and the manager refuses the whole transaction. With the own-delta check the hook "squares"
    /// the credit by taking it, which changes nothing here: the router still owes. A denial of service, not a theft,
    /// against a router that settles ONCE (`V4-ACCOUNTING.md` item 16; the next test is the router that does not).
    /// Controls: the same prepaid swap with the hook not
    /// re-entering stands, and the same `settle()` against `MinimalRouter` (which pays after the swap: nothing in
    /// flight) credits nothing and the swap stands.
    function test_settle_while_a_router_payment_is_in_flight_kills_the_transaction() public {
        PrepayRouter pre = new PrepayRouter(manager);
        vm.prank(trader);
        token0.approve(address(pre), type(uint256).max);
        uint256 before0 = token0.trueBalanceOf(trader);
        uint256 hook1Before = token1.trueBalanceOf(address(hook));

        // control 1: nothing re-enters - the prepaid swap stands and the hook gets its fee
        vm.prank(trader);
        pre.swap(key, _swapParams());
        assertEq(before0 - token0.trueBalanceOf(trader), 1e18, "control: the prepaying swapper paid other than its input");
        assertEq(token1.trueBalanceOf(address(hook)) - hook1Before, uint256(uint128(FEE)), "control: the hook's fee");

        hook.setReenter(true);
        hook.setReentryTarget(address(manager), abi.encodeWithSelector(IPoolManager.settle.selector));
        for (uint256 check = 0; check < 2; check++) {
            hook.setCheckOwnDelta(check == 1);
            vm.prank(trader);
            vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
            pre.swap(key, _swapParams());
        }

        // control 2: the same settle() with nothing in flight credits nothing, and the swap stands
        hook.setCheckOwnDelta(false);
        uint256 hook0Before = token0.trueBalanceOf(address(hook));
        _swapWithBooks(trader, key, _swapParams());
        assertEq(hook.reentriesSucceeded(), 1, "control: the settle() re-entry was refused");
        assertEq(abi.decode(hook.lastReentryReturn(), (uint256)), 0, "control: settle() credited the hook something");
        assertEq(token0.trueBalanceOf(address(hook)), hook0Before, "control: the hook's currency0 moved");
    }

    /// @notice the same `settle()` against a router that TOPS UP: after its own `settle` credits nothing, it reads its
    /// open delta and pays it again (`TopUpPrepayRouter`, above). Now the unlock can close - and it does when the hook
    /// takes the credit it was handed (the own-delta check): the swapper pays its input TWICE, and the hook keeps the
    /// first payment. Without the check the hook's credit is left open and the transaction is refused, as before. So
    /// "a denial of service, not a theft" holds only for a router that settles once.
    function test_settle_while_a_topping_up_router_payment_is_in_flight_takes_the_first_payment() public {
        TopUpPrepayRouter top = new TopUpPrepayRouter(manager);
        vm.prank(trader);
        token0.approve(address(top), type(uint256).max);
        hook.setReenter(true);
        hook.setReentryTarget(address(manager), abi.encodeWithSelector(IPoolManager.settle.selector));

        // without the check: the hook's credit stays open, refused
        vm.prank(trader);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        top.swap(key, _swapParams());

        // with it: the hook takes the router's first payment, the router pays again, the unlock closes
        hook.setCheckOwnDelta(true);
        uint256 trader0 = token0.trueBalanceOf(trader);
        uint256 hook0 = token0.trueBalanceOf(address(hook));
        vm.prank(trader);
        top.swap(key, _swapParams());
        assertEq(trader0 - token0.trueBalanceOf(trader), 2e18, "the swapper did not pay its input twice");
        assertEq(token0.trueBalanceOf(address(hook)) - hook0, 1e18, "the hook did not keep the first payment");
        assertEq(hook.residuesSquared(), 1, "the hook's check squared nothing");
    }

    /// @notice the delta switches are inert without the flags: the same hook mined with `BEFORE_SWAP | AFTER_SWAP` only
    /// returns its deltas and the manager DISCARDS them (`V4-ACCOUNTING.md` item 5) - so a hook that took its fee is
    /// left owing it, and the swap dies. Returned values without the flag are not "ignored harmlessly".
    function test_deltas_without_the_return_delta_flags_are_discarded_and_a_squaring_hook_is_left_owing() public {
        (, bytes32 salt) = HookMiner.find(
            address(this), Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG, type(HostileHook).creationCode, abi.encode(manager)
        );
        HostileHook noFlags = new HostileHook{salt: salt}(manager);
        PoolKey memory k = _initPool(IHooks(address(noFlags)), 3000, 60, SQRT_PRICE_1_1);
        _addFullRangeLiquidity(k, provider, 100e18);
        noFlags.setDeltas(0, 0, FEE);
        noFlags.setSquareOwnDelta(true);
        vm.prank(trader);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        router.swap(k, _swapParams(), "");

        noFlags.setSquareOwnDelta(false); // and without squaring, the returned delta is simply lost: no fee
        uint256 before1 = token1.trueBalanceOf(address(noFlags));
        vm.prank(trader);
        router.swap(k, _swapParams(), "");
        assertEq(token1.trueBalanceOf(address(noFlags)), before1, "a delta without the flag moved value");
    }
}
