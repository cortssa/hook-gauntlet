// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {V4Harness} from "../src/V4Harness.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {HostileHook} from "../src/HostileHook.sol";
import {MinimalRouter} from "../src/MinimalRouter.sol";
import {TokenCallbackActor} from "../src/TokenCallbackActor.sol";
import {PrepayRouter} from "./examples/PrepayRouter.sol";
import {TopUpPrepayRouter} from "./HostileDeltaHook.t.sol";
import {TakeBurnActor} from "./examples/DeltaFeeHook.t.sol";
import {IHostileTokenCallback} from "gauntlet-kit/HostileERC20.sol";

/// @notice RE-ENTRANCY THROUGH A CURRENCY'S OWN TRANSFER HOOK, DURING SETTLEMENT (K15). A payment to the manager is
/// `sync(c)`, a transfer of `c`, `settle()`; a token with transfer callbacks (`HostileERC20`'s send and receive callbacks)
/// runs code INSIDE the transfer - between the payer's `sync` and its `settle`, while the manager is mid-accounting for
/// that payment. `TokenCallbackActor` is that code, pointed at the manager. Every door below is the actor's, in its own
/// name; its failures are swallowed, so what happens to the payer is the manager's doing and the payer's.
///
/// The measured answers (source manager; the etched fixture has not run this file):
///  * against a payer that settles ONCE (`MinimalRouter`, paying currency0 of a 1e18 exact-in swap), EVERY door that
///    moves the synced slot or a delta kills the payer's whole transaction at the outer unlock (`CurrencyNotSettled`):
///    `sync` of another currency or of the zero address, before or after the balances move; `sync` of the SAME currency
///    AFTER the move (the checkpoint now includes the payment); a bare `settle` (it takes the payer's credit and resets
///    the slot); `settle` + `take` or `settle` + `mint` (the thief squares its own books, the payer's stay open); `take`
///    or `mint` against nothing; a swap in its own name (squaring it takes a `sync` of its own). Two doors leave the
///    payment standing: `sync` of the same currency BEFORE the move (the checkpoint does not change), and `unlock`
///    (`AlreadyUnlocked`, swallowed);
///  * against a payer that then pays whatever its books still show owing (`TopUpPrepayRouter`), `settle` + `take` is a
///    THEFT: the unlock closes, the swapper pays its input twice and the token's callback keeps the first payment;
///  * against a HOOK that pays its own delta (`HostileHook`, a negative specified delta squared by sync + transfer +
///    settle), `settle` + `take` on the hook's transfer leaves the hook's `settle` crediting nothing. A hook that trusts
///    its own arithmetic leaves its delta open and the swapper's transaction dies; a hook that reads its own delta
///    afterwards (`setCheckOwnDelta`) pays again and the swap stands - the hook paid twice, the token kept one payment;
///  * what a hook that READS the synced slot believes (`DeltaFeeHook`'s P7, "a currency is synced: a payment is in
///    flight"): a token that clears the slot (`sync(0)`) in the middle of a prepaying router's transfer makes the hook
///    believe nothing is in flight; the payer dies either way. The example's own payment is in
///    `test/examples/DeltaFeeHook.t.sol`, P12;
///  * two doors more, from the verifier V15 (2026-09-24), not in `TokenCallbackActor`: a `take` paid with the callback's
///    OWN claims (`take` x + `burn` x, `TakeBurnActor`) dies before and after the move, like every door that moves the
///    balance the payer's `settle` reads; `settleFor(the payer)` after the move STANDS and is harmless - it credits the
///    payer its own payment, the payer's own `settle` then credits 0, and its books close.
contract TokenReentryTest is V4Harness {
    using TransientStateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    PoolKey internal key;
    TokenCallbackActor internal actor;
    address internal provider = address(0xA11CE);
    address internal trader = address(0xB0B);

    function setUp() public {
        _setUpManager();
        _deployCurrencies();
        _deployRouters();
        _fundAndApprove(provider, 1_000_000e18);
        _fundAndApprove(trader, 1_000_000e18);
        key = _initPool(IHooks(address(0)), 3000, 60, SQRT_PRICE_1_1);
        _addFullRangeLiquidity(key, provider, 100e18);
        actor = new TokenCallbackActor(manager);
        vm.label(address(actor), "TokenCallbackActor");
        token0.mint(address(actor), 10e18);
        token1.mint(address(actor), 10e18);
    }

    function _exactIn0() internal pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
    }

    /// @dev arm the actor on the next transfer of token0 that pays the manager: AFTER the balances move (the manager's
    /// receive callback) or BEFORE (the payer's send callback)
    function _arm(bool afterMove, address payer) internal {
        if (afterMove) token0.setReceiveCallback(address(manager), address(actor), 1);
        else token0.setSendCallback(payer, address(actor), 1);
    }

    /// @return stood whether the router's swap stood; `err` the revert data if it did not
    function _routerSwap() internal returns (bool stood, bytes memory err) {
        vm.prank(trader);
        try router.swap(key, _exactIn0(), "") {
            stood = true;
        } catch (bytes memory e) {
            err = e;
        }
    }

    struct Row {
        string name;
        TokenCallbackActor.Door door;
        Currency currency;
        uint256 amount;
        bool standsBefore;
        bool standsAfter;
    }

    function _rows() internal view returns (Row[10] memory r) {
        Currency zero = Currency.wrap(address(0));
        r[0] = Row("sync(another currency)", TokenCallbackActor.Door.SYNC, currency1, 0, false, false);
        r[1] = Row("sync(the zero address)", TokenCallbackActor.Door.SYNC, zero, 0, false, false);
        r[2] = Row("sync(the same currency)", TokenCallbackActor.Door.SYNC, currency0, 0, true, false);
        r[3] = Row("settle()", TokenCallbackActor.Door.SETTLE, currency0, 0, false, false);
        r[4] = Row("settle() + take", TokenCallbackActor.Door.SETTLE_AND_TAKE, currency0, 0, false, false);
        r[5] = Row("settle() + mint", TokenCallbackActor.Door.SETTLE_AND_MINT, currency0, 0, false, false);
        r[6] = Row("take 1 wei", TokenCallbackActor.Door.TAKE, currency0, 1, false, false);
        r[7] = Row("mint 1 wei", TokenCallbackActor.Door.MINT, currency0, 1, false, false);
        r[8] = Row("unlock", TokenCallbackActor.Door.UNLOCK, currency0, 0, true, true);
        r[9] = Row("a swap in its own name", TokenCallbackActor.Door.SWAP, currency0, 0, false, false);
    }

    /// @notice THE TABLE: every door, before and after the balances move, against a payer that settles once. What
    /// stands and what dies; a death is always the manager's `CurrencyNotSettled` at the outer unlock (the payer's
    /// books did not close), never a refusal of the door itself. Control: nothing armed, the swap stands.
    function test_the_door_table_against_a_payer_that_settles_once() public {
        (bool stood,) = _routerSwap();
        assertTrue(stood, "control: the plain swap did not stand");
        Row[10] memory r = _rows();
        for (uint256 m = 0; m < 2; m++) {
            bool afterMove = m == 1;
            for (uint256 i = 0; i < r.length; i++) {
                uint256 snap = vm.snapshotState();
                if (r[i].door == TokenCallbackActor.Door.SWAP) {
                    actor.setSwap(
                        key,
                        SwapParams({zeroForOne: false, amountSpecified: -1e17, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1})
                    );
                } else {
                    actor.setDoor(r[i].door, r[i].currency, r[i].amount);
                }
                _arm(afterMove, trader);
                bytes memory err;
                (stood, err) = _routerSwap();
                bool expected = afterMove ? r[i].standsAfter : r[i].standsBefore;
                console2.log(afterMove ? "after the move: " : "before the move:", r[i].name, stood ? "STANDS" : "DIES");
                assertEq(stood, expected, string.concat(r[i].name, afterMove ? " (after the move)" : " (before the move)"));
                if (stood) {
                    assertEq(actor.fired(), 1, string.concat(r[i].name, ": the callback never fired"));
                    assertTrue(actor.unlockedAtFire(), "the callback ran with the manager locked");
                } else {
                    assertEq(bytes4(err), IPoolManager.CurrencyNotSettled.selector, string.concat(r[i].name, ": died otherwise"));
                }
                vm.revertToState(snap);
            }
        }
    }

    /// @notice the two that stand, read from inside: `sync` of the same currency before the move left the slot and the
    /// payment as they were, and `unlock` was refused by the manager (the actor swallowed `AlreadyUnlocked`)
    function test_the_doors_that_stand_left_the_payment_alone() public {
        actor.setDoor(TokenCallbackActor.Door.SYNC, currency0, 0);
        _arm(false, trader);
        uint256 before0 = token0.trueBalanceOf(trader);
        (bool stood,) = _routerSwap();
        assertTrue(stood);
        assertEq(before0 - token0.trueBalanceOf(trader), 1e18, "the payer paid other than its input");
        assertEq(Currency.unwrap(actor.syncedBefore()), Currency.unwrap(currency0), "the payer's sync was not in place");
        assertEq(Currency.unwrap(actor.syncedAfter()), Currency.unwrap(currency0));

        actor.setDoor(TokenCallbackActor.Door.UNLOCK, currency0, 0);
        _arm(true, trader);
        (stood,) = _routerSwap();
        assertTrue(stood);
        assertEq(actor.succeeded(), 1, "only the first door succeeded");
        assertEq(bytes4(actor.lastReturn()), IPoolManager.AlreadyUnlocked.selector, "unlock: refused, but not as expected");
    }

    /// @notice the same `settle` + `take` against a payer that TOPS UP (pays whatever its books still show owing after its
    /// own `settle`): the unlock closes, the swapper pays 2e18 for a 1e18 swap, and the token's callback keeps 1e18.
    /// Red with the actor disarmed (`the swapper did not pay its input twice`).
    function test_a_topping_up_payer_pays_twice_and_the_tokens_callback_keeps_one_payment() public {
        TopUpPrepayRouter top = new TopUpPrepayRouter(manager);
        vm.prank(trader);
        token0.approve(address(top), type(uint256).max);
        actor.setDoor(TokenCallbackActor.Door.SETTLE_AND_TAKE, currency0, 0);
        _arm(true, trader);
        uint256 trader0 = token0.trueBalanceOf(trader);
        uint256 actor0 = token0.trueBalanceOf(address(actor));

        vm.prank(trader);
        top.swap(key, _exactIn0());

        assertEq(trader0 - token0.trueBalanceOf(trader), 2e18, "the swapper did not pay its input twice");
        assertEq(token0.trueBalanceOf(address(actor)) - actor0, 1e18, "the token's callback did not keep the first payment");
        assertEq(actor.credited(), 1e18);
    }

    /// @notice what a hook that READS the synced slot believes. `PrepayRouter` pays currency0 first; the token's callback
    /// clears the slot (`sync(0)`) after the move. Seen from the pool, nothing is in flight; the prepaid 1e18 is in the
    /// manager with no checkpoint under it, and the router's `settle` credits nothing: the payer dies. With another
    /// currency synced instead the payer dies too (its `settle` credits nothing in currency0). Control: unarmed, it stands.
    function test_a_token_that_resyncs_during_a_prepayment_kills_the_payer() public {
        PrepayRouter pre = new PrepayRouter(manager);
        vm.prank(trader);
        token0.approve(address(pre), type(uint256).max);
        vm.prank(trader);
        pre.swap(key, _exactIn0());

        Currency[2] memory to = [Currency.wrap(address(0)), currency1];
        for (uint256 i = 0; i < 2; i++) {
            actor.setDoor(TokenCallbackActor.Door.SYNC, to[i], 0);
            _arm(true, trader);
            vm.prank(trader);
            vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
            pre.swap(key, _exactIn0());
        }
    }

    // ------------------------------------------------------------------ a HOOK paying its own delta
    function _payingHook() internal returns (HostileHook hook, PoolKey memory k) {
        (, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG,
            type(HostileHook).creationCode,
            abi.encode(manager)
        );
        hook = new HostileHook{salt: salt}(manager);
        k = _initPool(IHooks(address(hook)), 3000, 60, SQRT_PRICE_1_1);
        _addFullRangeLiquidity(k, provider, 100e18);
        token0.mint(address(hook), 10e18);
        hook.setDeltas(-1e15, 0, 0); // it PAYS 1e15 of the specified currency (currency0 on exact-in zeroForOne)
        hook.setSquareOwnDelta(true);
    }

    /// @notice a hook squares a negative delta by sync + transfer + settle, from `afterSwap`. The token's callback runs
    /// `settle` + `take` on the hook's transfer: the hook's `settle` credits nothing, its delta stays open. The hook that
    /// trusts its own arithmetic kills the swapper's transaction (`CurrencyNotSettled`); the hook that reads its own delta
    /// afterwards pays again, and the swap stands - the hook paid 2e15 for a 1e15 delta and the callback kept 1e15.
    /// RED FIRST: the "stands" half with `setCheckOwnDelta(true)` removed dies `CurrencyNotSettled`.
    function test_a_hook_paying_its_delta_meets_a_token_that_settles_and_takes() public {
        (HostileHook hook, PoolKey memory k) = _payingHook();
        actor.setDoor(TokenCallbackActor.Door.SETTLE_AND_TAKE, currency0, 0);

        // the hook that does not read its own delta afterwards
        _arm(true, address(hook));
        vm.prank(trader);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        router.swap(k, _exactIn0(), "");

        // the hook that does
        hook.setCheckOwnDelta(true);
        _arm(true, address(hook));
        uint256 hook0 = token0.trueBalanceOf(address(hook));
        uint256 actor0 = token0.trueBalanceOf(address(actor));
        SwapBooks memory b = _swapWithBooks(trader, k, _exactIn0());
        assertEq(hook.residuesSquared(), 1, "the hook's check found nothing to square");
        assertEq(hook0 - token0.trueBalanceOf(address(hook)), 2e15, "the hook did not pay twice");
        assertEq(token0.trueBalanceOf(address(actor)) - actor0, 1e15, "the callback did not keep the first payment");
        assertEq(b.caller0, -1e18, "the swapper's specified side");
        assertEq(b.swapper0 + b.hook0 + b.manager0 + 1e15, 0, "currency0: only the callback's 1e15 is outside the three");
    }

    /// @notice and a plain `sync` of another currency on the hook's transfer: the hook's `settle` credits nothing in
    /// currency0 (it measures currency1), its payment is left in the manager with no checkpoint under it. Without the
    /// check: dies. With it: the hook pays again and the first payment is nobody's - the manager holds 1e15 of currency0
    /// that no delta accounts for.
    function test_a_hook_paying_its_delta_meets_a_token_that_resyncs_another_currency() public {
        (HostileHook hook, PoolKey memory k) = _payingHook();
        actor.setDoor(TokenCallbackActor.Door.SYNC, currency1, 0);
        _arm(true, address(hook));
        vm.prank(trader);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        router.swap(k, _exactIn0(), "");

        hook.setCheckOwnDelta(true);
        _arm(true, address(hook));
        uint256 hook0 = token0.trueBalanceOf(address(hook));
        SwapBooks memory b = _swapWithBooks(trader, k, _exactIn0());
        assertEq(hook0 - token0.trueBalanceOf(address(hook)), 2e15, "the hook did not pay twice");
        assertEq(b.swapper0 + b.hook0 + b.manager0, 0, "currency0 is conserved over the three: the lost payment sits in the manager");
        assertEq(b.manager0, -b.pool0 + 1e15, "the manager holds 1e15 more than the pool's delta: nobody's");
    }

    /// @notice a stale synced slot left by a token callback on a DELIVERY (the manager's `take` to the swapper, which is
    /// not a payment): the slot outlives the unlock inside the transaction. Measured: after the swap the manager's synced
    /// currency is the one the callback synced, with the manager locked.
    function test_a_callback_on_a_delivery_leaves_the_synced_slot_behind() public {
        actor.setDoor(TokenCallbackActor.Door.SYNC, currency1, 0);
        StaleSlotProbe probe = new StaleSlotProbe(router, manager);
        _fundAndApprove(address(probe), 10e18);
        token1.setReceiveCallback(address(probe), address(actor), 1); // its OUTPUT, delivered by the manager's take
        Currency left = probe.swapAndReadSlot(key, _exactIn0());
        assertEq(Currency.unwrap(left), Currency.unwrap(currency1), "the callback's sync did not outlive the unlock");
        assertFalse(manager.isUnlocked());
        // and the stale checkpoint is harmless to the next payer: MinimalRouter syncs before it pays
        (bool stood,) = _routerSwap();
        assertTrue(stood);
    }

    /// @notice V15's two doors against the payer that settles once. `take` of 1e17 paid with 1e17 of the callback's own
    /// claims: the callback's books square, the payer's `settle` reads a balance 1e17 short, `CurrencyNotSettled`, both
    /// moments. `settleFor(router)`: before the move it credits the router 0 and resets the slot - dies; after the move it
    /// credits the router the whole payment, the router's own `settle` credits 0, and the swap stands with the swapper
    /// paying exactly its input and the router holding nothing.
    function test_two_more_doors_a_take_paid_with_own_claims_and_settle_for_the_payer() public {
        TakeBurnActor tb = new TakeBurnActor(manager, currency0);
        token0.mint(address(tb), 1e18);
        tb.deposit(1e18);
        bool stood;
        bytes memory err;
        for (uint256 m = 0; m < 2; m++) {
            tb.arm(1e17);
            token0.setSendCallback(trader, address(tb), m == 0 ? 1 : 0);
            token0.setReceiveCallback(address(manager), address(tb), m == 1 ? 1 : 0);
            (stood, err) = _routerSwap();
            assertFalse(stood, m == 0 ? "take + burn (before the move) stood" : "take + burn (after the move) stood");
            assertEq(bytes4(err), IPoolManager.CurrencyNotSettled.selector, "take + burn: not the payer's open books");
        }
        assertEq(manager.balanceOf(address(tb), currency0.toId()), 1e18, "the callback's claims moved");

        SettleForActor sf = new SettleForActor(manager);
        sf.arm(address(router));
        token0.setReceiveCallback(address(manager), address(0), 0);
        token0.setSendCallback(trader, address(sf), 1);
        (stood, err) = _routerSwap();
        assertFalse(stood, "settleFor(router) before the move stood");
        assertEq(bytes4(err), IPoolManager.CurrencyNotSettled.selector, "settleFor before the move: not the payer's open books");

        token0.setSendCallback(trader, address(0), 0);
        token0.setReceiveCallback(address(manager), address(sf), 1);
        uint256 paid0 = token0.trueBalanceOf(trader);
        (stood,) = _routerSwap();
        assertTrue(stood, "settleFor(router) after the move did not stand");
        assertEq(sf.fired(), 1, "the callback never fired");
        assertEq(sf.credited(), 1e18, "settleFor did not credit the router the whole payment");
        assertEq(paid0 - token0.trueBalanceOf(trader), 1e18, "the swapper paid other than its input");
        assertEq(token0.trueBalanceOf(address(router)), 0, "the router kept token0");
        assertEq(manager.balanceOf(address(router), currency0.toId()), 0, "the router holds a claim");
    }
}

/// @notice V15's `settleFor` door: from inside a transfer of the currency, `settleFor(beneficiary)` - whatever the
/// manager's balance has gained since the synced checkpoint, credited to somebody else. Failure recorded, swallowed.
contract SettleForActor is IHostileTokenCallback {
    IPoolManager public immutable manager;
    address public beneficiary;
    uint256 public fired;
    bool public succeeded;
    uint256 public credited;
    bool private _inFire;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function arm(address beneficiary_) external {
        beneficiary = beneficiary_;
        fired = 0;
        succeeded = false;
        credited = 0;
    }

    function tokensToSend(address, address, uint256) external override {
        _fire();
    }

    function tokensReceived(address, address, uint256) external override {
        _fire();
    }

    function _fire() private {
        if (_inFire || beneficiary == address(0)) return;
        _inFire = true;
        fired += 1;
        (bool ok, bytes memory ret) =
            address(manager).call(abi.encodeWithSelector(IPoolManager.settleFor.selector, beneficiary));
        succeeded = ok;
        if (ok) credited = abi.decode(ret, (uint256));
        _inFire = false;
    }
}

/// @notice swaps through the router and reads the manager's synced slot in the SAME transaction, after the unlock closed
/// (forge clears transient storage between a test's top-level calls, so the test cannot read it itself)
contract StaleSlotProbe {
    using TransientStateLibrary for IPoolManager;

    MinimalRouter public immutable router;
    IPoolManager public immutable manager;

    constructor(MinimalRouter router_, IPoolManager manager_) {
        router = router_;
        manager = manager_;
    }

    function swapAndReadSlot(PoolKey calldata key, SwapParams calldata p) external returns (Currency) {
        router.swap(key, p, "");
        return manager.getSyncedCurrency();
    }
}
