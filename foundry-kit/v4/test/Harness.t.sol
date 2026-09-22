// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {V4Harness} from "../src/V4Harness.sol";
import {MinimalRouter} from "../src/MinimalRouter.sol";
import {LiquidityHelper} from "../src/LiquidityHelper.sol";

/// @notice The harness's own smoke test: a pool with no hook, liquidity in it, a swap through the dumb
/// router. If this is red, nothing a hook test says means anything, because the fixtures are broken.
contract HarnessTest is V4Harness {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    address internal provider = address(0xA11CE);
    address internal trader = address(0xB0B);

    PoolKey internal key;

    function setUp() public {
        _setUpManager();
        _deployCurrencies();
        _deployRouters();

        _fundAndApprove(provider, 1_000_000e18);
        _fundAndApprove(trader, 1_000_000e18);

        key = _initPool(IHooks(address(0)), 3000, 60, SQRT_PRICE_1_1);
        _addFullRangeLiquidity(key, provider, 10e18);
    }

    function test_full_range_is_computed_from_the_tick_spacing() public pure {
        (int24 lower, int24 upper) = _fullRange(60);
        assertEq(lower, (TickMath.MIN_TICK / 60) * 60);
        assertEq(upper, (TickMath.MAX_TICK / 60) * 60);
        assertEq(lower % 60, 0);
        assertEq(upper % 60, 0);

        (int24 lower1, int24 upper1) = _fullRange(1);
        assertEq(lower1, TickMath.MIN_TICK);
        assertEq(upper1, TickMath.MAX_TICK);
    }

    function test_liquidity_arrived_in_the_manager() public view {
        assertGt(token0.balanceOf(address(manager)), 0, "the manager holds no currency0");
        assertGt(token1.balanceOf(address(manager)), 0, "the manager holds no currency1");
    }

    function test_a_swap_moves_the_traders_balances_the_right_way() public {
        uint256 pre0 = token0.balanceOf(trader);
        uint256 pre1 = token1.balanceOf(trader);

        vm.prank(trader);
        BalanceDelta delta = router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e16, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );

        assertEq(delta.amount0(), -1e16, "an exact-input swap spent something other than the input");
        assertGt(delta.amount1(), 0, "the trader was given nothing");
        assertEq(pre0 - token0.balanceOf(trader), 1e16, "the trader did not pay the input");
        assertEq(token1.balanceOf(trader) - pre1, uint256(uint128(delta.amount1())), "the output did not arrive");
    }

    /// @notice the router is a fixture, and a fixture that keeps value is a fixture that hides a leak.
    function test_the_router_and_the_helper_end_empty() public {
        vm.prank(trader);
        router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e16, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        assertEq(token0.balanceOf(address(router)), 0, "router kept currency0");
        assertEq(token1.balanceOf(address(router)), 0, "router kept currency1");
        assertEq(token0.balanceOf(address(liquidity)), 0, "liquidity helper kept currency0");
        assertEq(token1.balanceOf(address(liquidity)), 0, "liquidity helper kept currency1");
    }

    /// @notice only the manager may call back into the router. Anything else is somebody pretending.
    /// @dev by SELECTOR, not by a bare `expectRevert`. Both of these would also "pass" if the call failed
    /// because the calldata could not be decoded, or because a later line reverted first - neither of which
    /// says anything about who is allowed to call back.
    function test_the_router_refuses_a_callback_from_anyone_else() public {
        vm.expectRevert(MinimalRouter.NotTheManager.selector);
        router.unlockCallback("");
        vm.expectRevert(LiquidityHelper.NotTheManager.selector);
        liquidity.unlockCallback("");
    }
}
