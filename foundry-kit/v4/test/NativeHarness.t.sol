// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {V4Harness} from "../src/V4Harness.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {HostileHook} from "../src/HostileHook.sol";
import {MinimalRouter} from "../src/MinimalRouter.sol";
import {LiquidityHelper} from "../src/LiquidityHelper.sol";

/// @notice The harness on a NATIVE pool (K14): ETH as `currency0`, a harness token as `currency1`. Until 2026-09-24 the
/// router and the liquidity helper refused such a pool (`NativeCurrencyNotSupported`); every test here was seen red
/// against a router with that refusal put back. What is measured, per swap, each from its own source
/// (`_swapWithBooks`): the swapper's ETH net of the router's refund, the manager's ETH, the hook's ETH, the pool's own
/// delta off the `Swap` event - on a hookless pool, and on one whose hook returns deltas and settles them in ETH.
contract NativeHarnessTest is V4Harness {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int256 internal constant AMOUNT = 1e18;
    int128 internal constant SPEC = -2e14;
    int128 internal constant UNSPEC_BEFORE = 1e14;
    int128 internal constant UNSPEC_AFTER = 3e14;

    PoolKey internal plain;
    PoolKey internal hooked;
    HostileHook internal hook;
    address internal provider = address(0xA11CE);
    address internal trader = address(0xB0B);

    function setUp() public {
        _setUpManager();
        _deployCurrencies();
        _deployRouters();
        _fundAndApprove(provider, 1_000_000e18);
        _fundAndApprove(trader, 1_000_000e18);
        _fundNative(provider, 1_000e18);
        _fundNative(trader, 1_000e18);

        plain = _initNativePool(IHooks(address(0)), 3000, 60, SQRT_PRICE_1_1, currency1);
        _addFullRangeLiquidity(plain, provider, 100e18);

        (, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG,
            type(HostileHook).creationCode,
            abi.encode(manager)
        );
        hook = new HostileHook{salt: salt}(manager);
        vm.label(address(hook), "HostileHook(native deltas)");
        hooked = _initNativePool(IHooks(address(hook)), 3000, 60, SQRT_PRICE_1_1, currency1);
        _addFullRangeLiquidity(hooked, provider, 100e18);
        vm.deal(address(hook), 10e18);
        token1.mint(address(hook), 10e18);
        hook.setDeltas(SPEC, UNSPEC_BEFORE, UNSPEC_AFTER);
        hook.setSquareOwnDelta(true);
    }

    function _params(bool exactIn, bool zeroForOne) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactIn ? -AMOUNT : AMOUNT,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    /// @notice every party's books around one swap on a native pool, asserted term by term
    function _check(PoolKey memory key, bool exactIn, bool zeroForOne, string memory label)
        internal
        returns (SwapBooks memory b)
    {
        SwapParams memory p = _params(exactIn, zeroForOne);
        b = _swapWithBooks(trader, key, p);
        bool s0 = exactIn == zeroForOne;

        console2.log(label);
        console2.log("  swapper ETH, token1 :", vm.toString(b.swapper0), vm.toString(b.swapper1));
        console2.log("  pool (event)        :", vm.toString(b.pool0), vm.toString(b.pool1));
        console2.log("  hook                :", vm.toString(b.hook0), vm.toString(b.hook1));
        console2.log("  manager             :", vm.toString(b.manager0), vm.toString(b.manager1));
        console2.log("  ETH sent with the call:", b.valueSent);

        // the swapper's ETH, net of the refund, is exactly the returned delta - whatever it sent
        assertEq(b.swapper0, b.caller0, string.concat(label, ": swapper's ETH is not the returned delta"));
        assertEq(b.swapper1, b.caller1, string.concat(label, ": swapper's token1 is not the returned delta"));
        // the manager kept exactly the pool's delta, in ETH as in the token
        assertEq(b.manager0, -b.pool0, string.concat(label, ": manager's ETH is not the pool's delta"));
        assertEq(b.manager1, -b.pool1, string.concat(label, ": manager's token1 is not the pool's delta"));
        // the hook moved by exactly what the manager booked for it
        assertEq(b.hook0, b.pool0 - b.caller0, string.concat(label, ": hook's ETH != pool - caller"));
        assertEq(b.hook1, b.pool1 - b.caller1, string.concat(label, ": hook's token1 != pool - caller"));
        // conservation, ETH included
        assertEq(b.swapper0 + b.hook0 + b.manager0, 0, string.concat(label, ": ETH created or destroyed"));
        assertEq(b.swapper1 + b.hook1 + b.manager1, 0, string.concat(label, ": token1 created or destroyed"));
        // a full fill: the swapper's specified side is exactly amountSpecified
        assertEq(s0 ? b.caller0 : b.caller1, p.amountSpecified, string.concat(label, ": specified side"));
        // and the router kept nothing: no ETH, no token
        assertEq(address(router).balance, 0, string.concat(label, ": the router kept ETH"));
        assertEq(token1.trueBalanceOf(address(router)), 0, string.concat(label, ": the router kept token1"));
    }

    // ------------------------------------------------------------------ a hookless native pool, four orientations
    function test_native_plain_exact_in_eth_in() public {
        _check(plain, true, true, "plain exact-in  ETH in");
    }

    function test_native_plain_exact_in_eth_out() public {
        _check(plain, true, false, "plain exact-in  ETH out");
    }

    /// @notice ETH in, amount not known in advance: the harness sends the swapper's whole ETH balance and the router
    /// refunds the rest after the unlock
    function test_native_plain_exact_out_eth_in_refunds_the_rest() public {
        SwapBooks memory b = _check(plain, false, true, "plain exact-out ETH in");
        assertEq(b.valueSent, 1_000e18 - 0, "the harness did not send the whole balance");
        assertLt(uint256(-b.swapper0), b.valueSent, "nothing was refunded");
    }

    function test_native_plain_exact_out_eth_out() public {
        _check(plain, false, false, "plain exact-out ETH out");
    }

    // ------------------------------------------------------------------ a hook that returns deltas, settled in ETH
    function test_native_hook_deltas_exact_in_eth_in() public {
        SwapBooks memory b = _check(hooked, true, true, "hooked exact-in  ETH in (ETH specified)");
        assertEq(b.hook0, SPEC, "the hook's ETH rebate");
    }

    function test_native_hook_deltas_exact_in_eth_out() public {
        SwapBooks memory b = _check(hooked, true, false, "hooked exact-in  ETH out (ETH unspecified)");
        assertEq(b.hook0, int256(UNSPEC_BEFORE) + UNSPEC_AFTER, "the hook's ETH fee");
    }

    function test_native_hook_deltas_exact_out_eth_in() public {
        SwapBooks memory b = _check(hooked, false, true, "hooked exact-out ETH in (ETH unspecified)");
        assertEq(b.hook0, int256(UNSPEC_BEFORE) + UNSPEC_AFTER, "the hook's ETH fee");
    }

    function test_native_hook_deltas_exact_out_eth_out() public {
        SwapBooks memory b = _check(hooked, false, false, "hooked exact-out ETH out (ETH specified)");
        assertEq(b.hook0, SPEC, "the hook's ETH rebate");
    }

    // ------------------------------------------------------------------ value: too much, too little, none needed
    function test_excess_eth_on_an_exact_in_swap_is_refunded() public {
        SwapBooks memory b = _swapWithBooks(trader, plain, _params(true, true), 3e18);
        assertEq(b.swapper0, -AMOUNT, "the swapper paid other than its input: the excess was kept");
        assertEq(address(router).balance, 0);
    }

    function test_eth_sent_to_a_swap_with_no_eth_input_comes_back_whole() public {
        SwapBooks memory b = _swapWithBooks(trader, plain, _params(true, false), 2e18);
        assertEq(b.swapper0, b.caller0, "the swapper's ETH is not exactly what it bought");
        assertGt(b.swapper0, 0);
        assertEq(address(router).balance, 0);
    }

    function test_eth_sent_to_an_erc20_pool_comes_back_whole() public {
        PoolKey memory k = _initPool(IHooks(address(0)), 3000, 60, SQRT_PRICE_1_1);
        _addFullRangeLiquidity(k, provider, 100e18);
        uint256 before = trader.balance;
        vm.prank(trader);
        router.swap{value: 5e17}(k, _params(true, true), "");
        assertEq(trader.balance, before, "ETH sent to a pool with no ETH in it was kept");
        assertEq(address(router).balance, 0);
    }

    function test_too_little_eth_is_a_named_refusal_before_anything_is_paid() public {
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(MinimalRouter.InsufficientValue.selector, uint256(AMOUNT), uint256(5e17)));
        router.swap{value: 5e17}(plain, _params(true, true), "");
    }

    /// @notice ETH that reaches the router other than as a swap's `msg.value` (a selfdestruct, a coinbase reward; forced
    /// here with `vm.deal`) is nobody's payment. Until 2026-09-24 the router paid and refunded out of its whole balance,
    /// so the next swapper's input was paid with it and the rest refunded to that swapper (the verifier V14 measured a
    /// swap sent with no value receiving 9e17). Now it pays out of `msg.value` only: the stray ETH stays where it is
    function test_stray_eth_in_the_router_pays_for_nobodys_swap() public {
        vm.deal(address(router), 1e18);
        SwapParams memory p = SwapParams({zeroForOne: true, amountSpecified: -1e17, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(MinimalRouter.InsufficientValue.selector, uint256(1e17), uint256(0)));
        router.swap(plain, p, "");
        uint256 before = trader.balance;
        vm.prank(trader);
        router.swap{value: 3e17}(plain, p, "");
        assertEq(before - trader.balance, 1e17, "the swapper paid other than its own input, or was refunded the stray ETH");
        assertEq(address(router).balance, 1e18, "the stray ETH moved");
    }

    // ------------------------------------------------------------------ liquidity with ETH on one side
    function test_native_liquidity_add_and_remove_books_to_the_wei() public {
        (int24 lower, int24 upper) = _fullRange(60);
        ModifyLiquidityParams memory add =
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 10e18, salt: bytes32("k14")});
        uint256 eth0 = provider.balance;
        uint256 tok0 = token1.trueBalanceOf(provider);
        uint256 mgr0 = address(manager).balance;
        vm.prank(provider);
        (BalanceDelta d,) = liquidity.modifyLiquidity{value: 50e18}(plain, add, "");
        assertLt(d.amount0(), 0);
        assertEq(int256(provider.balance) - int256(eth0), d.amount0(), "the provider's ETH is not the charged delta");
        assertEq(int256(token1.trueBalanceOf(provider)) - int256(tok0), d.amount1(), "token1");
        assertEq(int256(address(manager).balance) - int256(mgr0), -d.amount0(), "the manager's ETH");
        assertEq(address(liquidity).balance, 0, "the helper kept ETH");

        add.liquidityDelta = -10e18;
        uint256 eth1 = provider.balance;
        vm.prank(provider);
        (BalanceDelta r,) = liquidity.modifyLiquidity(plain, add, "");
        assertGt(r.amount0(), 0);
        assertEq(int256(provider.balance) - int256(eth1), r.amount0(), "the provider's ETH on removal");
        // what came back is what went in, less rounding in the manager's favour (no swaps in between)
        assertLe(uint256(uint128(r.amount0())), uint256(uint128(-d.amount0())));
        assertGe(uint256(uint128(r.amount0())) + 2, uint256(uint128(-d.amount0())));
    }

    /// @notice the helper: the same rule as the router's. Stray ETH neither pays a provider's deposit nor comes back to it
    function test_stray_eth_in_the_helper_pays_for_nobodys_deposit() public {
        vm.deal(address(liquidity), 1e18);
        (int24 lower, int24 upper) = _fullRange(60);
        ModifyLiquidityParams memory add =
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1e17, salt: bytes32("stray")});
        vm.prank(provider);
        vm.expectPartialRevert(LiquidityHelper.InsufficientValue.selector);
        liquidity.modifyLiquidity(plain, add, "");
        uint256 before = provider.balance;
        vm.prank(provider);
        (BalanceDelta d,) = liquidity.modifyLiquidity{value: 5e17}(plain, add, "");
        assertEq(int256(provider.balance) - int256(before), d.amount0(), "the provider paid other than it was charged");
        assertEq(address(liquidity).balance, 1e18, "the stray ETH moved");
    }

    function test_too_little_eth_for_liquidity_is_a_named_refusal() public {
        (int24 lower, int24 upper) = _fullRange(60);
        vm.prank(provider);
        vm.expectPartialRevert(LiquidityHelper.InsufficientValue.selector);
        liquidity.modifyLiquidity{value: 1}(
            plain, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 10e18, salt: 0}), ""
        );
    }
}
