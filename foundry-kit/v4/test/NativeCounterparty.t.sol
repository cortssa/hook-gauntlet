// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {V4Harness} from "../src/V4Harness.sol";
import {HostileHook} from "../src/HostileHook.sol";
import {HostileNativeActor} from "../src/HostileNativeActor.sol";
import {MinimalRouter} from "../src/MinimalRouter.sol";
import {LiquidityHelper} from "../src/LiquidityHelper.sol";

/// @notice A HOSTILE NATIVE COUNTERPARTY (K14): a swapper or provider that is a contract whose `receive()` reverts,
/// re-enters, or eats every unit of gas. ETH is delivered at two moments, and they are not alike:
///  * the manager's `take` of ETH owed to the swapper (ETH OUT) runs its `receive()` INSIDE the unlock: the manager is
///    UNLOCKED and every open door (`take`, `swap`, `settle`, `sync`) is open to it, in its own name;
///  * the router's refund of excess ETH (ETH IN, too much sent) runs it AFTER the unlock: the manager is LOCKED, and the
///    only way back in is a lock of its own (a whole new transaction-within-the-transaction).
/// For each: what the manager does, what a hook on the pool sees (`HostileHook.swapsSeen`, `lastSwapSender`), and what
/// survives. Every test was seen red against a mutant of the thing it measures (see the README, "Native currency").
contract NativeCounterpartyTest is V4Harness {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    HostileHook internal hook;
    PoolKey internal key;
    HostileNativeActor internal actor;
    address internal provider = address(0xA11CE);

    function setUp() public {
        _setUpV4();
        _fundAndApprove(provider, 1_000_000e18);
        _fundNative(provider, 1_000e18);
        hook = HostileHook(
            _deployHook(
                type(HostileHook).creationCode, abi.encode(manager), Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            )
        );
        vm.label(address(hook), "HostileHook(observer)");
        key = _initNativePool(IHooks(address(hook)), 3000, 60, SQRT_PRICE_1_1, currency1);
        _addFullRangeLiquidity(key, provider, 100e18);

        actor = new HostileNativeActor(manager);
        vm.label(address(actor), "HostileNativeActor");
        vm.deal(address(actor), 100e18);
        token1.mint(address(actor), 100e18);
        actor.approve(address(token1), address(router));
        actor.approve(address(token1), address(liquidity));
    }

    // ------------------------------------------------------------------ helpers
    function _ethOut() internal pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: false, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1});
    }

    function _ethIn(int256 amountSpecified) internal pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: true, amountSpecified: amountSpecified, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
    }

    struct World {
        uint256 actorEth;
        uint256 actorTok;
        uint256 mgrEth;
        uint256 mgrTok;
        uint256 hookSwaps;
    }

    function _world() internal view returns (World memory w) {
        w.actorEth = address(actor).balance;
        w.actorTok = token1.trueBalanceOf(address(actor));
        w.mgrEth = address(manager).balance;
        w.mgrTok = token1.trueBalanceOf(address(manager));
        w.hookSwaps = hook.swapsSeen();
    }

    /// @notice a refused transaction left nothing behind: not in the manager, not in the hook, not in the actor
    function _assertNothingMoved(World memory a, string memory label) internal view {
        World memory b = _world();
        assertEq(b.actorEth, a.actorEth, string.concat(label, ": the actor's ETH moved"));
        assertEq(b.actorTok, a.actorTok, string.concat(label, ": the actor's token moved"));
        assertEq(b.mgrEth, a.mgrEth, string.concat(label, ": the manager's ETH moved"));
        assertEq(b.mgrTok, a.mgrTok, string.concat(label, ": the manager's token moved"));
        assertEq(b.hookSwaps, a.hookSwaps, string.concat(label, ": the hook kept a record of a swap that did not happen"));
        assertFalse(manager.isUnlocked(), string.concat(label, ": the manager was left unlocked"));
    }

    function _nativeTransferFailed(bytes memory inner) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(actor),
            bytes4(0),
            inner,
            abi.encodeWithSelector(CurrencyLibrary.NativeTransferFailed.selector)
        );
    }

    // ------------------------------------------------------------------ the honest contract: where each receipt happens
    function test_honest_receipt_of_eth_out_is_inside_the_unlock_and_a_refund_is_after_it() public {
        actor.swap(router, key, _ethOut(), 0);
        assertEq(actor.receives(), 1);
        assertTrue(actor.unlockedAtLastReceive(), "ETH out was not delivered inside the unlock");

        actor.swap(router, key, _ethIn(1e17), 5e17); // exact-out 0.1 token1, ETH in, far too much sent
        assertEq(actor.receives(), 2, "no refund arrived");
        assertFalse(actor.unlockedAtLastReceive(), "the refund was delivered while the manager was unlocked");
        assertEq(address(router).balance, 0, "the router kept ETH");
    }

    // ------------------------------------------------------------------ REVERT: a contract that cannot receive ETH
    /// @notice it can still swap ETH IN, if it sends exactly the input: nothing to refund, nothing delivered to it
    function test_reverting_receiver_can_swap_eth_in_when_it_sends_exactly_the_input() public {
        actor.setMode(HostileNativeActor.Mode.REVERT);
        uint256 before = address(actor).balance;
        actor.swap(router, key, _ethIn(-1e18), 1e18);
        assertEq(before - address(actor).balance, 1e18);
        assertEq(hook.swapsSeen(), 1);
    }

    /// @notice ...and not with one wei too many: the refund fails and the whole swap, the manager's part included, goes
    function test_reverting_receiver_with_excess_eth_loses_the_whole_swap_to_its_refund() public {
        actor.setMode(HostileNativeActor.Mode.REVERT);
        World memory w = _world();
        vm.expectRevert(
            abi.encodeWithSelector(
                MinimalRouter.RefundFailed.selector,
                address(actor),
                abi.encodeWithSelector(HostileNativeActor.Refused.selector)
            )
        );
        actor.swap(router, key, _ethIn(-1e18), 1e18 + 1);
        _assertNothingMoved(w, "refund refused");
    }

    /// @notice ETH OUT to a contract that refuses it: the MANAGER's `take` fails, inside the unlock, after the hook's
    /// `afterSwap` ran. The error is v4's own wrapped error (who, and why); the hook's view of the swap is rolled back.
    function test_reverting_receiver_cannot_take_eth_out_and_the_hook_sees_nothing() public {
        actor.setMode(HostileNativeActor.Mode.REVERT);
        World memory w = _world();
        vm.expectRevert(_nativeTransferFailed(abi.encodeWithSelector(HostileNativeActor.Refused.selector)));
        actor.swap(router, key, _ethOut(), 0);
        _assertNothingMoved(w, "ETH out refused");
    }

    /// @notice a PROVIDER that cannot receive ETH: it can add (sending exactly what is charged) and cannot remove - and
    /// nobody else can remove it either (a stranger with no approvals, same pool, same range, same salt, is refused and
    /// paid nothing): the position is stuck, not lost, until the provider can receive
    function test_reverting_provider_can_add_exactly_and_can_never_remove() public {
        (int24 lower, int24 upper) = _fullRange(60);
        ModifyLiquidityParams memory add =
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1e18, salt: bytes32("actor")});
        // what the manager will charge, read on a snapshot
        uint256 snap = vm.snapshotState();
        (BalanceDelta d,) = actor.modifyLiquidity(liquidity, key, add, 10e18);
        vm.revertToState(snap);
        uint256 exact = uint256(uint128(-d.amount0()));

        actor.setMode(HostileNativeActor.Mode.REVERT);
        vm.expectPartialRevert(LiquidityHelper.RefundFailed.selector);
        actor.modifyLiquidity(liquidity, key, add, exact + 1);
        actor.modifyLiquidity(liquidity, key, add, exact);
        uint128 liq = manager.getLiquidity(key.toId());

        add.liquidityDelta = -1e18;
        vm.expectRevert(_nativeTransferFailed(abi.encodeWithSelector(HostileNativeActor.Refused.selector)));
        actor.modifyLiquidity(liquidity, key, add, 0);
        assertEq(manager.getLiquidity(key.toId()), liq, "the position moved");

        // the stranger: until 2026-09-24 the helper owned every position and paid whoever called, so this removal
        // STOOD and the stranger kept the provider's ETH and token1 (the verifier V14 measured it). Now the helper acts
        // on the stranger's OWN position at that salt, which is empty: the manager refuses to take liquidity below zero
        address stranger = address(0xBAD);
        vm.prank(stranger);
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        liquidity.modifyLiquidity(key, add, "");
        assertEq(manager.getLiquidity(key.toId()), liq, "a stranger removed the provider's position");
        assertEq(stranger.balance, 0, "a stranger was paid the provider's ETH");
        assertEq(token1.trueBalanceOf(stranger), 0, "a stranger was paid the provider's token1");

        actor.setMode(HostileNativeActor.Mode.HONEST);
        actor.modifyLiquidity(liquidity, key, add, 0);
        assertEq(manager.getLiquidity(key.toId()), liq - 1e18, "an honest receive() did not get the position back");
    }

    /// @notice the helper keeps each caller's positions apart: the same pool, range and salt from two callers are two
    /// positions, and neither can remove more than its own
    function test_two_callers_with_the_same_salt_hold_two_positions() public {
        (int24 lower, int24 upper) = _fullRange(60);
        address other = address(0x0DD);
        _fundAndApprove(other, 10e18);
        _fundNative(other, 10e18);
        // the provider already holds 100e18 at salt 0 over the full range (setUp)
        vm.prank(other);
        liquidity.modifyLiquidity{value: 10e18}(
            key, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1e18, salt: 0}), ""
        );
        uint128 liq = manager.getLiquidity(key.toId());
        (uint128 mine,,) =
            manager.getPositionInfo(key.toId(), address(liquidity), lower, upper, liquidity.positionSalt(other, 0));
        (uint128 theirs,,) =
            manager.getPositionInfo(key.toId(), address(liquidity), lower, upper, liquidity.positionSalt(provider, 0));
        assertEq(mine, 1e18, "the second caller's position, as the manager books it");
        assertEq(theirs, 100e18, "the first caller's position, as the manager books it");
        vm.prank(other);
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        liquidity.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: -2e18, salt: 0}), ""
        );
        assertEq(manager.getLiquidity(key.toId()), liq, "a caller removed more than it added");
        // and each takes back exactly its own
        vm.prank(other);
        liquidity.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: -1e18, salt: 0}), ""
        );
        vm.prank(provider);
        liquidity.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: -100e18, salt: 0}), ""
        );
        assertEq(manager.getLiquidity(key.toId()), 0, "the pool kept liquidity nobody owns");
    }

    // ------------------------------------------------------------------ REENTER, inside the unlock (ETH out)
    /// @notice `unlock` from inside `take`: refused (`AlreadyUnlocked`); its `receive()` swallows the refusal and the
    /// swap stands
    function test_reentry_by_unlock_during_take_is_refused_and_the_swap_stands() public {
        actor.setMode(HostileNativeActor.Mode.REENTER);
        actor.setReentryCall(address(manager), abi.encodeWithSelector(IPoolManager.unlock.selector, bytes("")));
        actor.swap(router, key, _ethOut(), 0);
        assertTrue(actor.unlockedAtLastReceive());
        assertEq(actor.reentriesSucceeded(), 0);
        assertEq(bytes4(actor.lastReentryReturn()), IPoolManager.AlreadyUnlocked.selector);
        assertEq(hook.swapsSeen(), 1);
    }

    /// @notice `take` from inside `take`: ALLOWED - the manager pays it 1 ETH of the pool's reserves in its own name -
    /// and the transaction then dies at the outer unlock, because nobody settles the actor's new debt
    function test_reentry_by_take_during_take_is_allowed_and_kills_the_transaction() public {
        actor.setMode(HostileNativeActor.Mode.REENTER);
        actor.setReentryCall(
            address(manager),
            abi.encodeWithSelector(IPoolManager.take.selector, Currency.wrap(address(0)), address(actor), 1e18)
        );
        World memory w = _world();
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        actor.swap(router, key, _ethOut(), 0);
        _assertNothingMoved(w, "take during take");
    }

    /// @notice a whole SWAP from inside `take`, in the actor's own name, its own delta squared: it stands. The hook sees
    /// two swaps in one unlock, the second from a sender that is not the router, placed after the first swap's
    /// `afterSwap` and before the router has finished settling it
    function test_reentry_by_swap_during_take_stands_and_the_hook_sees_a_second_sender() public {
        actor.setMode(HostileNativeActor.Mode.REENTER);
        actor.setReentrySwap(key, _ethIn(-1e17));
        World memory w = _world();
        BalanceDelta outer = actor.swap(router, key, _ethOut(), 0);
        World memory v = _world();

        assertEq(actor.reentriesSucceeded(), 1);
        assertEq(hook.swapsSeen(), w.hookSwaps + 2, "the hook did not see the nested swap");
        assertEq(hook.lastSwapSender(), address(actor), "the nested swap's sender is not the actor");
        BalanceDelta inner = actor.reentrySwapDelta();
        assertEq(inner.amount0(), -1e17);
        // books over the two swaps: the actor moved by both deltas, the manager by their opposite
        int256 actorEth = int256(v.actorEth) - int256(w.actorEth);
        int256 actorTok = int256(v.actorTok) - int256(w.actorTok);
        assertEq(actorEth, int256(outer.amount0()) + inner.amount0(), "the actor's ETH");
        assertEq(actorTok, int256(outer.amount1()) + inner.amount1(), "the actor's token");
        assertEq(int256(v.mgrEth) - int256(w.mgrEth), -actorEth, "ETH created or destroyed");
        assertEq(int256(v.mgrTok) - int256(w.mgrTok), -actorTok, "token created or destroyed");
    }

    /// @notice `settle{value}` and then `mint` of the ETH claim to itself, from inside `take`: the two net to zero and it
    /// STANDS - the recipient turns its ETH into a claim in the middle of somebody else's swap, with the manager's ETH
    /// and its claims issued both up by the same amount. (Found by the verifier V14; item 17 did not say `mint`.)
    function test_reentry_by_settle_and_mint_during_take_stands_and_turns_eth_into_a_claim() public {
        actor.setMode(HostileNativeActor.Mode.REENTER);
        actor.setReentrySettleAndMint(1e17, 1e17);
        World memory w = _world();
        BalanceDelta d = actor.swap(router, key, _ethOut(), 0);
        World memory v = _world();
        assertTrue(actor.unlockedAtLastReceive());
        assertEq(actor.reentriesSucceeded(), 1, "settle + mint during take was refused");
        assertEq(manager.balanceOf(address(actor), 0), 1e17, "the actor holds no ETH claim");
        assertEq(int256(v.actorEth) - int256(w.actorEth), int256(d.amount0()) - 1e17, "the actor's ETH");
        assertEq(int256(v.mgrEth) - int256(w.mgrEth), -int256(d.amount0()) + 1e17, "the manager's ETH");
        assertEq(hook.swapsSeen(), w.hookSwaps + 1, "the hook saw other than one swap");
    }

    /// @notice ...and either half alone leaves the recipient's own delta open: the transaction dies at the outer unlock
    function test_reentry_by_settle_alone_or_mint_alone_during_take_kills_the_transaction() public {
        actor.setMode(HostileNativeActor.Mode.REENTER);
        World memory w = _world();
        actor.setReentrySettleAndMint(1e17, 0);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        actor.swap(router, key, _ethOut(), 0);
        _assertNothingMoved(w, "settle alone during take");
        actor.setReentrySettleAndMint(0, 1e17);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        actor.swap(router, key, _ethOut(), 0);
        _assertNothingMoved(w, "mint alone during take");
    }

    // ------------------------------------------------------------------ REENTER, after the unlock (the refund)
    /// @notice during the router's refund the manager is LOCKED: a `take` is refused (`ManagerLocked`) - the door that
    /// is open during ETH OUT is shut here, because the router refunds after the unlock
    function test_reentry_by_take_during_refund_meets_a_locked_manager() public {
        actor.setMode(HostileNativeActor.Mode.REENTER);
        actor.setReentryCall(
            address(manager),
            abi.encodeWithSelector(IPoolManager.take.selector, Currency.wrap(address(0)), address(actor), 1e18)
        );
        actor.swap(router, key, _ethIn(1e17), 5e17);
        assertFalse(actor.unlockedAtLastReceive(), "the refund came while the manager was unlocked");
        assertEq(actor.reentriesSucceeded(), 0);
        assertEq(bytes4(actor.lastReentryReturn()), IPoolManager.ManagerLocked.selector);
    }

    /// @notice ...and the way back in is a lock of its own: a second swap, in its own name, inside the first
    /// transaction. It stands; the hook sees two swaps and the second sender
    function test_reentry_by_its_own_unlock_during_refund_stands() public {
        actor.setMode(HostileNativeActor.Mode.REENTER);
        actor.setReentrySwap(key, _ethIn(-1e17));
        World memory w = _world();
        actor.swap(router, key, _ethIn(1e17), 5e17);
        assertEq(actor.reentriesSucceeded(), 1, "its own unlock was refused");
        assertEq(hook.swapsSeen(), w.hookSwaps + 2);
        assertEq(hook.lastSwapSender(), address(actor));
        assertEq(address(router).balance, 0);
    }

    // ------------------------------------------------------------------ BURN_GAS
    /// @notice a `receive()` that eats all the gas: the manager forwards all it has to the ETH transfer (`call(gas(),
    /// ...)`), the receiver burns it, and the 1/64 left is enough for v4's wrapped error. The transaction's sender -
    /// here the actor itself - pays for all of it
    function test_gas_burning_receiver_of_eth_out_costs_the_whole_gas_and_the_swap() public {
        actor.setMode(HostileNativeActor.Mode.BURN_GAS);
        World memory w = _world();
        uint256 g = gasleft();
        try actor.swap{gas: 5_000_000}(router, key, _ethOut(), 0) {
            assertTrue(false, "a receive() that burns all gas took ETH");
        } catch (bytes memory err) {
            uint256 used = g - gasleft();
            console2.log("gas used by the refused ETH-out swap, of 5 000 000 forwarded:", used);
            assertEq(err, _nativeTransferFailed(""), "not v4's NativeTransferFailed, with an empty reason");
            // measured 4 664 718 (ETH out, five frames deep) and 4 884 379 (refund): each frame keeps 1/64 of its gas
            assertGt(used, 4_500_000, "the receiver did not eat the gas");
        }
        _assertNothingMoved(w, "gas burner, ETH out");
    }

    function test_gas_burning_receiver_of_a_refund_costs_the_whole_gas_and_the_swap() public {
        actor.setMode(HostileNativeActor.Mode.BURN_GAS);
        World memory w = _world();
        uint256 g = gasleft();
        try actor.swap{gas: 5_000_000}(router, key, _ethIn(-1e18), 2e18) {
            assertTrue(false, "a receive() that burns all gas took a refund");
        } catch (bytes memory err) {
            uint256 used = g - gasleft();
            console2.log("gas used by the refused refund, of 5 000 000 forwarded:", used);
            assertEq(err, abi.encodeWithSelector(MinimalRouter.RefundFailed.selector, address(actor), bytes("")));
            // measured 4 664 718 (ETH out, five frames deep) and 4 884 379 (refund): each frame keeps 1/64 of its gas
            assertGt(used, 4_500_000, "the receiver did not eat the gas");
        }
        _assertNothingMoved(w, "gas burner, refund");
    }
}
