// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {V4Harness} from "../src/V4Harness.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {HostileHook} from "../src/HostileHook.sol";
import {MinimalRouter} from "../src/MinimalRouter.sol";
import {SwapEventReader} from "../src/SwapEventReader.sol";

/// @notice A contract that tries to swap with a CAPPED gas frame and then carries on with its own work.
/// It exists because you cannot test a gas-eating callee by reading `gasleft()` before and after the call in
/// the test contract - under Foundry that difference does not track what the callee spent (the same lesson is
/// written into `HostileERC20._burnFrame`). Test the CONSEQUENCE: a caller that budgeted for a swap can no
/// longer finish.
contract SwapVictim {
    MinimalRouter public immutable router;

    uint256 public swapsDone;
    uint256 public swapsRefused;
    bool public finishedItsOwnWork;

    constructor(MinimalRouter router_) {
        router = router_;
    }

    function swapWithBudget(PoolKey memory key, SwapParams memory params, uint256 budget) external {
        finishedItsOwnWork = false;
        try router.swap{gas: budget}(key, params, "") {
            swapsDone += 1;
        } catch {
            swapsRefused += 1;
        }
        // the work AFTER the call, which is the part a frame-eating callee takes away
        finishedItsOwnWork = true;
    }
}

/// @notice The one thing the harness has no fixture for: a donation straight into a pool. It is here rather
/// than in `src/` because only this file needs it - a donation is the cheapest way to make the manager call
/// `beforeDonate` and `afterDonate`, and those are two of the ten entry points a hostile hook has to answer
/// on.
contract DonateHelper is IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;

    struct DonateCall {
        PoolKey key;
        uint256 amount0;
        uint256 amount1;
        address payer;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function donate(PoolKey memory key, uint256 amount0, uint256 amount1) external {
        manager.unlock(abi.encode(DonateCall(key, amount0, amount1, msg.sender)));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "DonateHelper: not the manager");
        DonateCall memory c = abi.decode(data, (DonateCall));
        manager.donate(c.key, c.amount0, c.amount1, "");
        if (c.amount0 > 0) c.key.currency0.settle(manager, c.payer, c.amount0, false);
        if (c.amount1 > 0) c.key.currency1.settle(manager, c.payer, c.amount1, false);
        return "";
    }
}

/// @notice A "manager" with NO lock at all: it allows every nested unlock and calls straight back. It is
/// the control that shows `reentriesSucceeded` can move - without it, a counter that is 0 against every
/// manager ever tried is indistinguishable from a counter that cannot go up.
contract PermissiveManager {
    uint256 public unlocks;

    function unlock(bytes calldata data) external returns (bytes memory) {
        unlocks += 1;
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }
}

/// @notice stands in for the contract under test: something with a function that nobody expects to be
/// called in the middle of somebody else's swap.
contract ReentryVictim {
    uint256 public pokes;
    address public lastCaller;

    function poke() external {
        pokes += 1;
        lastCaller = msg.sender;
    }
}

/// @notice One test per switch on `HostileHook`, the way `test/HostileERC20.t.sol` has one per switch on the
/// token. A switchboard nobody flips is decoration: if a switch has no test showing the manager's or a
/// victim's observable reaction to it, nobody knows it still works, and the first person to rely on it finds
/// out the hard way.
///
/// Every test here drives the switch through a REAL pool on the manager under test (source or etched
/// fixture), never by calling the hook directly, because what is being measured is the manager's reaction,
/// not the hook's return value.
///
/// A note on the refusals. There is no bare `vm.expectRevert()` in this file, on purpose: a bare one passes on ANY
/// revert, including one from the wrong place, and that is how a test goes green for the wrong reason. The manager
/// answers a misbehaving hook in two different ways, and each is asserted exactly: its OWN error when it rejects what
/// the hook returned (`Hooks.InvalidHookResponse`, `LPFeeLibrary.LPFeeTooLarge`), and the ERC-7751 wrapper
/// `WrappedError(hook, selector, reason, HookCallFailed)` when the hook itself reverted.
contract HostileHookTest is V4Harness {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    HostileHook internal hostile;
    PoolKey internal key;

    address internal provider = address(0xA11CE);
    address internal trader = address(0xB0B);

    function setUp() public {
        _setUpManager();
        _deployCurrencies();
        _deployRouters();

        // Only `beforeSwap`. That is the entry point every switch below is observed through, and a hook with
        // fewer flags is a hook with fewer things that could explain a failure.
        (, bytes32 salt) =
            HookMiner.find(address(this), Hooks.BEFORE_SWAP_FLAG, type(HostileHook).creationCode, abi.encode(manager));
        hostile = new HostileHook{salt: salt}(manager);
        vm.label(address(hostile), "HostileHook");

        _fundAndApprove(provider, 1_000_000e18);
        _fundAndApprove(trader, 1_000_000e18);

        // a dynamic-fee pool, so that the `rawFeeOverride` switch has something to override. The hook never
        // calls `updateDynamicLPFee`, so the pool's own fee stays at zero until a swap overrides it.
        key = _initPool(IHooks(address(hostile)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, SQRT_PRICE_1_1);
        _addFullRangeLiquidity(key, provider, 100e18);
    }

    // ------------------------------------------------------------------ the baseline
    /// @notice with every switch off it is an ordinary hook that answers correctly, so that each test below
    /// changes exactly one thing.
    function test_with_no_switch_on_it_is_an_ordinary_hook() public {
        uint256 before = token1.balanceOf(trader);
        uint24 fee = _swapAndReadFee(1e16);

        assertEq(uint256(fee), 0, "nothing overrode the pool's own fee");
        assertGt(token1.balanceOf(trader), before, "the swap did not happen");
        assertEq(hostile.calls(), 1, "the manager did not reach the hook");
        assertEq(hostile.reentriesAttempted(), 0);
    }

    // ------------------------------------------------------------------ switch: wrongSelector
    /// @notice the hook answers with a selector the manager did not ask for. The manager treats any mismatch
    /// as an invalid answer and refuses the whole action - which is the reason a router must believe the
    /// manager and not the hook.
    function test_switch_wrong_selector_makes_the_manager_refuse_the_swap() public {
        hostile.setWrongSelector(true);

        uint256 before0 = token0.balanceOf(trader);
        uint256 before1 = token1.balanceOf(trader);

        vm.prank(trader);
        vm.expectRevert(Hooks.InvalidHookResponse.selector);
        router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e16, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );

        assertEq(token0.balanceOf(trader), before0, "the trader paid for a swap that was refused");
        assertEq(token1.balanceOf(trader), before1, "the trader was paid for a swap that was refused");

        // the refused attempt left NO trace, counter included: the manager rolled the whole action back, so
        // `hostile.calls()` is not evidence about what was attempted, only about what was allowed to stand.
        assertEq(hostile.calls(), 0, "a refused action should leave no state behind");

        hostile.setWrongSelector(false);
        _swapAndReadFee(1e16); // and the same pool works again once the switch is off
        assertEq(hostile.calls(), 1);
    }

    // ------------------------------------------------------------------ switch: revertAlways
    /// @notice the hook reverts on every entry point. A hook that reverts bricks its own pool: the manager
    /// has no "carry on without it" path, by design.
    function test_switch_revert_always_bricks_the_pool_until_it_is_turned_off() public {
        hostile.setRevertAlways(true);

        uint256 before0 = token0.balanceOf(trader);
        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hostile),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(HostileHook.Hostile.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e16, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        assertEq(token0.balanceOf(trader), before0, "value moved through a reverted swap");
        assertEq(hostile.calls(), 0, "the whole transaction was rolled back, counter included");

        hostile.setRevertAlways(false);
        _swapAndReadFee(1e16);
        assertEq(hostile.calls(), 1);
    }

    // ------------------------------------------------------------------ switch: gasToBurn
    /// @notice the hook eats the frame it was given. Measured as a consequence, never as a `gasleft()`
    /// difference in this contract: a victim that budgeted enough gas for a swap gets its budget eaten, and
    /// the swap it planned does not happen.
    function test_switch_gas_to_burn_takes_the_frame_away_from_whoever_called() public {
        SwapVictim victim = new SwapVictim(router);
        _fundAndApprove(address(victim), 1_000e18);

        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        uint256 budget = 2_000_000;

        victim.swapWithBudget(key, p, budget);
        assertEq(victim.swapsDone(), 1, "the budget was not enough even with the switch off: raise it");
        assertTrue(victim.finishedItsOwnWork());

        hostile.setGasToBurn(10_000_000); // more than the victim is willing to spend
        victim.swapWithBudget(key, p, budget);
        assertEq(victim.swapsRefused(), 1, "the frame-eating hook did not stop the swap");
        assertEq(victim.swapsDone(), 1, "the swap happened anyway");
        // the victim survives, because it capped the call. An uncapped caller would have died here, and that
        // is the whole argument for capping every call into code you do not control.
        assertTrue(victim.finishedItsOwnWork(), "the victim could not finish its own work");
    }

    // ------------------------------------------------------------------ switch: rawFeeOverride
    /// @notice the hook returns an LP fee override, raw, flags and all. Two halves, because the manager
    /// treats them very differently: a valid override is simply believed, and an out-of-range one is refused.
    function test_switch_raw_fee_override_is_believed_by_the_manager_when_it_is_valid() public {
        hostile.setRawFeeOverride(3000 | LPFeeLibrary.OVERRIDE_FEE_FLAG);

        assertEq(uint256(_swapAndReadFee(1e16)), 3000, "the pool did not charge what the hook told it to");

        // ...and it is the hook's word that decides, swap by swap, with nothing stored anywhere.
        hostile.setRawFeeOverride(50_000 | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        assertEq(uint256(_swapAndReadFee(1e16)), 50_000, "a hook can change its mind between two swaps");
    }

    function test_switch_raw_fee_override_above_the_maximum_is_refused_by_the_manager() public {
        hostile.setRawFeeOverride(uint24(LPFeeLibrary.MAX_LP_FEE + 1) | LPFeeLibrary.OVERRIDE_FEE_FLAG);

        uint256 before0 = token0.balanceOf(trader);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(LPFeeLibrary.LPFeeTooLarge.selector, uint24(LPFeeLibrary.MAX_LP_FEE + 1)));
        router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e16, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        assertEq(token0.balanceOf(trader), before0, "a fee above 100 % was charged to somebody");
    }

    /// @notice the other half of "raw": WITHOUT the override bit the number is not a fee at all, it is
    /// ignored, and the pool charges its own. A hook that returns `3000` and expects 0.3 % is returning
    /// nothing.
    function test_switch_raw_fee_override_without_the_override_bit_is_ignored() public {
        hostile.setRawFeeOverride(3000); // no OVERRIDE_FEE_FLAG
        assertEq(uint256(_swapAndReadFee(1e16)), 0, "a fee with no override bit was applied anyway");
    }

    // ------------------------------------------------------------------ switch: reenter
    /// @notice the hook calls `manager.unlock` from inside a callback. The manager is unlocked while a hook
    /// runs, and this is how a test asks it what it does about a second unlock instead of assuming.
    ///
    /// The answer here, measured: the attempt is made and REFUSED, and the swap that carried it completes.
    /// `reentriesSucceeded` is the number to watch in your own suite; make it an invariant - and read the
    /// test below this one before you do, because for a while that counter could not go up at all.
    function test_switch_reenter_is_attempted_and_refused_by_the_manager() public {
        hostile.setReenter(true);

        uint256 before1 = token1.balanceOf(trader);
        _swapAndReadFee(1e16);

        assertEq(hostile.reentriesAttempted(), 1, "the hook never tried to re-enter: the switch did nothing");
        assertEq(hostile.reentriesSucceeded(), 0, "the manager allowed a second unlock inside the first");
        assertGt(token1.balanceOf(trader), before1, "the outer swap did not complete");
    }

    /// @notice THE CONTROL FOR THE TEST ABOVE, and the reason this file has one at all.
    ///
    /// `reentriesSucceeded` was 0 against every manager anyone tried, including a "manager" with no lock at
    /// all that allowed the nested unlock and called straight back - because `HostileHook` had no
    /// `unlockCallback`, so the call-back into it reverted, and the counter recorded THIS CONTRACT'S missing
    /// function as the manager's refusal. An independent audit built exactly this fake and watched the
    /// counter say "refused" about a manager that refuses nothing.
    ///
    /// A counter that cannot go up is not evidence. This is the test that makes it go up, and it is what an
    /// invariant built on `reentriesSucceeded == 0` needs next to it to mean anything.
    function test_reentriesSucceeded_goes_to_one_against_a_manager_with_no_lock() public {
        PermissiveManager pm = new PermissiveManager();
        HostileHook h = new HostileHook(IPoolManager(address(pm)));
        h.setReenter(true);

        PoolKey memory k;
        SwapParams memory p;
        h.beforeSwap(address(this), k, p, "");

        assertEq(h.reentriesAttempted(), 1, "attempted");
        assertEq(h.reentriesSucceeded(), 1, "a manager that allows a nested unlock must be reported as allowing it");
        assertEq(pm.unlocks(), 1, "and the fake really was asked");
    }

    /// @notice the same hook, the same switch, against the REAL manager under test - in the two situations
    /// that are easy to confuse, because the counter reads differently in each and only one of them is
    /// re-entrancy.
    ///
    /// MEASURED, and it surprised the author: calling the hook DIRECTLY, with nobody holding the manager's
    /// lock, the unlock SUCCEEDS. Of course it does - a contract asking an idle manager for the lock is not
    /// re-entering anything, it is opening a transaction. The counter is not "did somebody misbehave", it
    /// is "did the call go through", and the difference matters for anyone who turns it into an invariant.
    /// (Before `HostileHook` had an `unlockCallback` this read 0 here as well, for the wrong reason: the
    /// callback into the hook reverted. Two different situations, one wrong number, no way to tell.)
    ///
    /// Inside a real swap, where the lock IS held, the same call is refused. That is the claim worth making.
    function test_the_real_manager_allows_an_unlock_from_idle_and_refuses_one_inside_a_swap() public {
        HostileHook h = new HostileHook(manager);
        h.setReenter(true);

        PoolKey memory k;
        SwapParams memory p;
        h.beforeSwap(address(this), k, p, ""); // nobody holds the lock: this is an ordinary unlock

        assertEq(h.reentriesAttempted(), 1, "attempted");
        assertEq(h.reentriesSucceeded(), 1, "an unlock with no lock held is not re-entrancy and must succeed");

        // ...and inside a real swap, where the manager is UNLOCKED, which is the question the switch exists
        // to ask. `hostile` is the hook the pool was built with, so the manager calls it mid-swap.
        hostile.setReenter(true);
        _swapAndReadFee(1e16);
        assertEq(hostile.reentriesAttempted(), 1);
        assertEq(hostile.reentriesSucceeded(), 0, "the real manager must refuse a SECOND unlock inside the first");
    }

    /// @notice re-entry through a door that IS open: `manager.take`, called from inside `beforeSwap` while
    /// the outer caller's lock is still held. `unlock` is the one door the manager keeps shut while a hook
    /// runs, and a hostile hook that can only knock on it is not asking the question anyone cares about.
    ///
    /// What is measured here, and it is not what a reader expects: the `take` SUCCEEDS as a call. The
    /// manager is unlocked, `take` is allowed, and it hands the hook currency against a negative delta that
    /// nothing has settled. The accounting only closes at the END of the outer `unlock`, so what actually
    /// happens is that the whole transaction - the trader's swap included - reverts there. The counter
    /// therefore reads 0 afterwards, because the state it lived in was rolled back with everything else.
    ///
    /// The lesson for a suite: "the manager refused it" and "the manager allowed it and then the
    /// transaction died" are different facts, and only one of them is a defence you can rely on. Measure
    /// the consequence (the outer call), not only the counter.
    function test_reentry_through_take_is_allowed_by_the_manager_and_kills_the_whole_transaction() public {
        hostile.setReenter(true);
        hostile.setReentryTake(key.currency1, address(hostile), 1e12);

        uint256 before0 = token0.balanceOf(trader);
        vm.prank(trader);
        // and by the EXACT error, not a bare expectation: the manager did not refuse the `take`, it refused
        // to close a set of books with a delta in them. Those are different answers and only one of them
        // would still be true if `take` started checking who is calling it.
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e16, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );

        assertEq(token0.balanceOf(trader), before0, "value moved through a transaction that reverted");
        assertEq(hostile.calls(), 0, "the rollback took the hook's own counters with it");
        assertEq(token1.balanceOf(address(hostile)), 0, "and the hook kept nothing");
    }

    /// @notice re-entry through `manager.swap`, on the pool the hook is mid-callback for. Two things fall
    /// out of it that are worth knowing before you write an invariant about either:
    ///
    ///  * the nested swap does NOT call the hook again. v4 skips a hook's callbacks when the hook itself is
    ///    the caller, so there is no recursion to guard against from the manager's side;
    ///  * it is otherwise allowed, and the transaction dies at the outer `unlock` for the same reason as the
    ///    `take` above - the hook is left holding a delta nobody settles.
    function test_reentry_through_swap_does_not_call_the_hook_again_and_still_kills_the_transaction() public {
        hostile.setReenter(true);
        hostile.setReentrySwap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -1e14, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1})
        );

        uint256 before1 = token1.balanceOf(trader);
        vm.prank(trader);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e16, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        assertEq(token1.balanceOf(trader), before1, "the trader was paid for a transaction that reverted");
    }

    /// @notice the default mode, and the setter that puts it back. Both exist so that a suite can switch the
    /// re-entry between the doors without rebuilding the hook.
    function test_the_reentry_mode_can_be_set_back_to_unlock() public {
        ReentryVictim victim = new ReentryVictim();
        hostile.setReenter(true);
        hostile.setReentryTarget(address(victim), abi.encodeCall(ReentryVictim.poke, ()));
        _swapAndReadFee(1e16);
        assertEq(victim.pokes(), 1);
        assertEq(hostile.reentriesSucceeded(), 1);

        hostile.setReentryUnlock();
        assertEq(hostile.reentryTarget(), address(0), "back to the manager");
        _swapAndReadFee(1e16);
        assertEq(victim.pokes(), 1, "the victim was not called a second time");
        assertEq(hostile.reentriesAttempted(), 2);
        assertEq(hostile.reentriesSucceeded(), 1, "and the nested unlock was refused, as before");
    }

    /// @notice re-entry into ANYTHING, which is the case the manager has no opinion about at all: while the
    /// hook runs, it can call the contract under test. If your contract has a function that must not be
    /// called mid-swap, this is the switch that calls it.
    function test_reentry_into_a_configurable_target_reaches_the_contract_under_test() public {
        ReentryVictim victim = new ReentryVictim();
        hostile.setReenter(true);
        hostile.setReentryTarget(address(victim), abi.encodeCall(ReentryVictim.poke, ()));

        _swapAndReadFee(1e16);

        assertEq(hostile.reentriesAttempted(), 1);
        assertEq(hostile.reentriesSucceeded(), 1, "the hook could not reach the target");
        assertEq(victim.pokes(), 1, "the target was never called mid-swap");
        assertEq(victim.lastCaller(), address(hostile), "and it was the hook that called it");
    }

    /// @notice a re-entry aimed at an address with NO CODE is a mistake in the test, not a re-entry that succeeded:
    /// a low-level call to an empty address returns `ok = true`. The hook refuses it, so `reentriesSucceeded` cannot
    /// be fed by a typo or by a target that is not deployed yet.
    function test_a_reentry_target_with_no_code_is_refused_and_never_counted_as_a_success() public {
        address nobody = address(0xC0FFEE);
        assertEq(nobody.code.length, 0);
        hostile.setReenter(true);
        hostile.setReentryTarget(nobody, abi.encodeCall(ReentryVictim.poke, ()));

        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hostile),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(HostileHook.ReentryTargetHasNoCode.selector, nobody),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e16, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        assertEq(hostile.reentriesSucceeded(), 0, "a call into nothing was counted as a re-entry that succeeded");
    }

    /// @notice one level only. Without the guard, a re-entry that comes back through any of this hook's own
    /// entry points re-enters again, and again, until the frame dies - and a test that runs out of gas has
    /// measured nothing. Here the hook is pointed straight at itself, which is the worst case.
    function test_the_reentry_is_one_level_deep_and_does_not_recurse() public {
        PoolKey memory k;
        SwapParams memory p;
        hostile.setReenter(true);
        hostile.setReentryTarget(
            address(hostile), abi.encodeCall(IHooks.beforeSwap, (address(this), k, p, ""))
        );

        _swapAndReadFee(1e16);

        assertEq(hostile.calls(), 2, "the manager's call plus exactly one re-entrant one");
        assertEq(hostile.reentriesAttempted(), 1, "the hook re-entered without a bound");
        assertEq(hostile.reentriesSucceeded(), 1, "and the inner call did go through");
    }

    // ------------------------------------------------------------------ all ten entry points
    /// @notice job 1 of this hook is to be untrusted INPUT to something else, and something else will call it
    /// wherever its address says it may be called. So: one hook mined with every action flag there is, one
    /// pool, and every entry point driven through the manager once.
    ///
    /// This is also the test that stops `HostileHook` rotting. Nine of its ten entry points were never
    /// executed by anything in this module - they compiled, and that was the whole of the evidence for them.
    function test_a_hook_mined_with_every_action_flag_answers_on_all_ten_entry_points() public {
        uint160 allActions = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_DONATE_FLAG | Hooks.AFTER_DONATE_FLAG;

        (, bytes32 salt) =
            HookMiner.find(address(this), allActions, type(HostileHook).creationCode, abi.encode(manager));
        HostileHook everything = new HostileHook{salt: salt}(manager);
        assertTrue(HookMiner.carriesExactly(address(everything), allActions), "not mined for exactly ten flags");

        // initialize: beforeInitialize + afterInitialize
        PoolKey memory k = _initPool(IHooks(address(everything)), 3000, 60, SQRT_PRICE_1_1);
        assertEq(everything.calls(), 2, "the manager did not call both initialize hooks");

        // add liquidity: beforeAddLiquidity + afterAddLiquidity
        _addFullRangeLiquidity(k, provider, 100e18);
        assertEq(everything.calls(), 4, "the manager did not call both add-liquidity hooks");

        // swap: beforeSwap + afterSwap
        vm.prank(trader);
        router.swap(
            k,
            SwapParams({zeroForOne: true, amountSpecified: -1e16, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        assertEq(everything.calls(), 6, "the manager did not call both swap hooks");

        // donate: beforeDonate + afterDonate
        DonateHelper donor = new DonateHelper(manager);
        token0.mint(address(this), 1e18);
        token1.mint(address(this), 1e18);
        token0.approve(address(donor), type(uint256).max);
        token1.approve(address(donor), type(uint256).max);
        donor.donate(k, 1e15, 1e15);
        assertEq(everything.calls(), 8, "the manager did not call both donate hooks");

        // remove liquidity: beforeRemoveLiquidity + afterRemoveLiquidity
        (int24 lower, int24 upper) = _fullRange(k.tickSpacing);
        vm.prank(provider);
        liquidity.modifyLiquidity(
            k,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: -50e18, salt: bytes32(0)}),
            ""
        );
        assertEq(everything.calls(), 10, "the manager did not call both remove-liquidity hooks");

        // and the switch reaches all ten: one wrong selector anywhere refuses the action it was in.
        everything.setWrongSelector(true);
        vm.expectRevert(Hooks.InvalidHookResponse.selector);
        _initPool(IHooks(address(everything)), 500, 10, SQRT_PRICE_1_1);
    }

    // ------------------------------------------------------------------ helpers
    function _swapAndReadFee(uint256 amountIn) internal returns (uint24) {
        vm.recordLogs();
        vm.prank(trader);
        router.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        (bool found, uint24 fee) = SwapEventReader.lastSwapFee(vm.getRecordedLogs(), address(manager));
        require(found, "no Swap event: the swap did not happen");
        return fee;
    }
}
