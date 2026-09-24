// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {V4Harness} from "../src/V4Harness.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {HostileHook} from "../src/HostileHook.sol";
import {SwapEventReader} from "../src/SwapEventReader.sol";

/// @notice THE COUNTER-EXAMPLE: a router that pays what the POOL's delta says - a quote taken on a snapshot of the same
/// swap, the `Swap` event's amounts, which is what a hookless quoter or an off-chain simulation of "the pool" gives -
/// instead of the delta the manager RETURNED to it. On a hook with no delta the two are the same number; on a hook
/// that returns one they differ by exactly the hook's delta, and the unlock does not close.
contract PoolQuoteRouter is IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;

    struct Call {
        PoolKey key;
        SwapParams params;
        address payer;
        int128 quoted0;
        int128 quoted1;
    }

    constructor(IPoolManager m) {
        manager = m;
    }

    function swapPaying(PoolKey memory key, SwapParams memory params, int128 quoted0, int128 quoted1) external {
        manager.unlock(abi.encode(Call(key, params, msg.sender, quoted0, quoted1)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not the manager");
        Call memory c = abi.decode(data, (Call));
        manager.swap(c.key, c.params, "");
        // settles the QUOTE, not the returned delta: the bug this contract exists to show
        if (c.quoted0 < 0) c.key.currency0.settle(manager, c.payer, uint256(uint128(-c.quoted0)), false);
        if (c.quoted1 < 0) c.key.currency1.settle(manager, c.payer, uint256(uint128(-c.quoted1)), false);
        if (c.quoted0 > 0) c.key.currency0.take(manager, c.payer, uint256(uint128(c.quoted0)), false);
        if (c.quoted1 > 0) c.key.currency1.take(manager, c.payer, uint256(uint128(c.quoted1)), false);
        return "";
    }
}

/// @notice ITEM 1 of the delta series (K13): the kit's harness and router against a hook that RETURNS DELTAS - a
/// `BeforeSwapDelta` on both sides and an after-swap delta - in all four orientations (exact-in / exact-out x
/// zeroForOne / oneForZero), with every party's books read from its own source (`V4Harness._swapWithBooks`).
///
/// Who settles what, measured here and not assumed:
///  * the HOOK settles its own delta, inside its own callback (`HostileHook.squareOwnDelta`: it takes a positive total,
///    pays a negative one). Nobody else can clear a positive hook delta: `take`, `mint` and `clear` act on `msg.sender`;
///  * the ROUTER settles the swapper's side, and the swapper's side is the delta the manager RETURNS, which the manager
///    has already moved by the hook's delta (`callerDelta = poolDelta - hookDelta`). `MinimalRouter` settles exactly
///    that, so it needs no change for a delta hook: the four tests below are green against it as it was;
///  * a router that settles anything else - here the pool's own delta, as a quote would give it - leaves the unlock
///    open and the manager refuses the whole transaction: the red half, `test_red_*`.
contract DeltaAccountingTest is V4Harness {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    // the hook's deltas, chosen so that it both TAKES and PAYS in every orientation: it pays 2e14 into the specified
    // side before the swap (a rebate), takes 1e14 of the unspecified side before the swap and 3e14 more after it
    int128 internal constant SPEC = -2e14;
    int128 internal constant UNSPEC_BEFORE = 1e14;
    int128 internal constant UNSPEC_AFTER = 3e14;
    int256 internal constant AMOUNT = 1e18;

    uint160 internal constant DELTA_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    HostileHook internal hook;
    PoolKey internal key;
    PoolQuoteRouter internal quoteRouter;
    address internal provider = address(0xA11CE);
    address internal trader = address(0xB0B);

    function setUp() public {
        _setUpManager();
        _deployCurrencies();
        _deployRouters();
        (, bytes32 salt) = HookMiner.find(address(this), DELTA_FLAGS, type(HostileHook).creationCode, abi.encode(manager));
        hook = new HostileHook{salt: salt}(manager);
        vm.label(address(hook), "HostileHook(deltas)");
        key = _initPool(IHooks(address(hook)), 3000, 60, SQRT_PRICE_1_1);
        _fundAndApprove(provider, 1_000_000e18);
        _fundAndApprove(trader, 1_000_000e18);
        _addFullRangeLiquidity(key, provider, 100e18);
        // the hook pays part of its delta, so it holds currency to pay with
        token0.mint(address(hook), 10e18);
        token1.mint(address(hook), 10e18);
        hook.setDeltas(SPEC, UNSPEC_BEFORE, UNSPEC_AFTER);
        hook.setSquareOwnDelta(true);

        quoteRouter = new PoolQuoteRouter(manager);
        vm.startPrank(trader);
        token0.approve(address(quoteRouter), type(uint256).max);
        token1.approve(address(quoteRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _params(bool exactIn, bool zeroForOne) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactIn ? -AMOUNT : AMOUNT,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    /// @notice the books of one orientation, asserted term by term. Every line is a separate claim, each from its own
    /// source: the router's return value, the manager's event, three true balances.
    function _checkOrientation(bool exactIn, bool zeroForOne, string memory label) internal {
        SwapParams memory p = _params(exactIn, zeroForOne);
        (int256 h0, int256 h1) = hook.bookedDelta(p);
        SwapBooks memory b = _swapWithBooks(trader, key, p);
        bool s0 = exactIn == zeroForOne; // currency0 is the specified currency

        console2.log(label);
        console2.log("  swapper paid(-)/got(+) c0, c1:", vm.toString(b.swapper0), vm.toString(b.swapper1));
        console2.log("  pool delta (Swap event)  c0, c1:", vm.toString(b.pool0), vm.toString(b.pool1));
        console2.log("  hook took(+)/paid(-)     c0, c1:", vm.toString(b.hook0), vm.toString(b.hook1));
        console2.log("  manager got              c0, c1:", vm.toString(b.manager0), vm.toString(b.manager1));

        // 1. the hook's balance moved by exactly the delta the manager booked for it, and that is the configured one
        assertEq(b.hook0, h0, string.concat(label, ": hook's currency0 is not its booked delta"));
        assertEq(b.hook1, h1, string.concat(label, ": hook's currency1 is not its booked delta"));
        assertEq(b.hook0, b.pool0 - b.caller0, string.concat(label, ": hook0 != pool0 - caller0 (the manager's rule)"));
        assertEq(b.hook1, b.pool1 - b.caller1, string.concat(label, ": hook1 != pool1 - caller1 (the manager's rule)"));
        // 2. the swapper paid exactly what the manager returned to the router - the hook's delta included
        assertEq(b.swapper0, b.caller0, string.concat(label, ": swapper0 is not the returned delta"));
        assertEq(b.swapper1, b.caller1, string.concat(label, ": swapper1 is not the returned delta"));
        // 3. the manager kept exactly the pool's delta: nothing of the hook's or the swapper's stuck to it
        assertEq(b.manager0, -b.pool0, string.concat(label, ": manager0 is not the pool's delta"));
        assertEq(b.manager1, -b.pool1, string.concat(label, ": manager1 is not the pool's delta"));
        // 4. conservation, per currency, over the three parties
        assertEq(b.swapper0 + b.hook0 + b.manager0, 0, string.concat(label, ": currency0 created or destroyed"));
        assertEq(b.swapper1 + b.hook1 + b.manager1, 0, string.concat(label, ": currency1 created or destroyed"));
        // 5. the swapper's SPECIFIED side is exactly amountSpecified (a full fill): a specified hook delta moves the
        //    pool's amount, never the swapper's
        assertEq(s0 ? b.caller0 : b.caller1, p.amountSpecified, string.concat(label, ": specified side != amountSpecified"));
        // 6. and the pool swapped amountSpecified + the hook's specified delta: `amountToSwap` in `Hooks.beforeSwap`
        assertEq(s0 ? b.pool0 : b.pool1, p.amountSpecified + SPEC, string.concat(label, ": pool's specified amount"));
        // 7. the hook's unspecified delta is the SUM of what beforeSwap and afterSwap returned, in the other currency
        assertEq(s0 ? h1 : h0, int256(UNSPEC_BEFORE) + UNSPEC_AFTER, string.concat(label, ": unspecified sum"));
    }

    function test_exact_in_zero_for_one_every_party_is_accounted() public {
        _checkOrientation(true, true, "exact-in  zeroForOne");
    }

    function test_exact_in_one_for_zero_every_party_is_accounted() public {
        _checkOrientation(true, false, "exact-in  oneForZero");
    }

    function test_exact_out_zero_for_one_every_party_is_accounted() public {
        _checkOrientation(false, true, "exact-out zeroForOne");
    }

    function test_exact_out_one_for_zero_every_party_is_accounted() public {
        _checkOrientation(false, false, "exact-out oneForZero");
    }

    // ------------------------------------------------------------------ the red half
    /// @notice quote the pool's delta on a snapshot (the swap done for real, its `Swap` event read, then rolled back)
    function _quotePool(SwapParams memory p) internal returns (int128 q0, int128 q1) {
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        vm.prank(trader);
        router.swap(key, p, "");
        bool found;
        (found, q0, q1) = SwapEventReader.lastSwapDelta(vm.getRecordedLogs(), address(manager));
        require(found, "no Swap event in the quote");
        vm.revertToState(snap);
    }

    function _redOrientation(bool exactIn, bool zeroForOne) internal {
        SwapParams memory p = _params(exactIn, zeroForOne);
        (int128 q0, int128 q1) = _quotePool(p);
        vm.prank(trader);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        quoteRouter.swapPaying(key, p, q0, q1);
    }

    function test_red_a_router_that_pays_the_pools_delta_is_refused_exact_in_zero_for_one() public {
        _redOrientation(true, true);
    }

    function test_red_a_router_that_pays_the_pools_delta_is_refused_exact_in_one_for_zero() public {
        _redOrientation(true, false);
    }

    function test_red_a_router_that_pays_the_pools_delta_is_refused_exact_out_zero_for_one() public {
        _redOrientation(false, true);
    }

    function test_red_a_router_that_pays_the_pools_delta_is_refused_exact_out_one_for_zero() public {
        _redOrientation(false, false);
    }

    /// @notice the control for the red half: the SAME quote router, the same pool, the hook's deltas set to zero - and
    /// it works. So the four refusals above are about the hook's delta, not about the counter-example being broken.
    function test_the_quote_router_is_fine_when_the_hook_returns_no_delta() public {
        hook.setDeltas(0, 0, 0);
        SwapParams memory p = _params(true, true);
        (int128 q0, int128 q1) = _quotePool(p);
        uint256 before1 = token1.trueBalanceOf(trader);
        vm.prank(trader);
        quoteRouter.swapPaying(key, p, q0, q1);
        assertEq(int256(token1.trueBalanceOf(trader)) - int256(before1), int256(q1), "paid the quote, got the quote");
    }

    /// @notice and the hook's side of the same rule: a hook that RETURNS a delta and does not settle it is refused by
    /// the manager at the end of the unlock - the router cannot rescue it, whatever it pays.
    function test_a_hook_that_returns_a_delta_and_does_not_settle_it_kills_the_swap() public {
        hook.setSquareOwnDelta(false);
        vm.prank(trader);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        router.swap(key, _params(true, true), "");
    }
}
