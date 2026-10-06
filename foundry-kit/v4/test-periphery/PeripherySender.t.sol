// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
// Inside the kit: imports are relative. In your project: see scripts/setup-deps.sh's import lines.

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MinimalRouter} from "../src/MinimalRouter.sol";
import {PeripheryPools} from "./PeripheryPools.sol";
import {PeripheryProbeHook} from "./PeripheryProbeHook.sol";

/// @notice the kit's own dumb router, which also says the user is anybody it likes
contract LyingRouter is MinimalRouter {
    address public immutable claimed;

    constructor(IPoolManager m, address claimed_) MinimalRouter(m) {
        claimed = claimed_;
    }

    function msgSender() external view returns (address) {
        return claimed;
    }
}

/// @notice WHO a hook sees when it is reached through Uniswap's periphery (K17b), on the source manager with the pinned
/// periphery and on the fork with the deployed one. A probe hook that declares every callback without a delta records,
/// in each, `sender`, `IMsgSender(sender).msgSender()` at that moment, `hookData` and the liquidity `salt`; the harness
/// reads the same calls off the calldata as a second source (`_hookCallsIn`). What a hook author must not assume is in
/// `doctrine/V4-ACCOUNTING.md` item 30 and `foundry-kit/v4/README.md`, "The periphery".
contract PeripherySenderTest is PeripheryPools {
    PeripheryProbeHook internal probe;
    PoolKey internal key;

    function setUp() public {
        _setUpPeripheryWorld();
        probe = PeripheryProbeHook(
            _deployHook(type(PeripheryProbeHook).creationCode, abi.encode(manager), _probeFlags())
        );
        key = _erc20Key(IHooks(address(probe)), 3000);
    }

    function test_the_probe_was_mined_for_exactly_its_flags() public view {
        assertEq(_probeFlags(), probe.flags());
        assertEq(uint160(address(probe)) & uint160((1 << 14) - 1), probe.flags());
    }

    function _seen(uint256 i) internal view returns (PeripheryProbeHook.Seen memory) {
        return probe.seenAt(i);
    }

    /// @notice initialise through `PositionManager.initializePool`: the hook's `sender` is the PositionManager, and
    /// `msgSender()` answers the zero address - `initializePool` runs outside the PositionManager's lock, so there is no
    /// user to name. A hook that needs the pool's creator cannot get it from here.
    function test_initialise_through_the_position_manager_the_hook_sees_the_position_manager_and_no_user() public {
        vm.prank(trader);
        _initPoolThroughPosm(key, _sqrtPriceOf(key));
        assertEq(probe.seenCount(), 2, "beforeInitialize and afterInitialize");
        for (uint256 i = 0; i < 2; i++) {
            PeripheryProbeHook.Seen memory s = _seen(i);
            assertEq(s.sender, address(posm), "initialise: sender is the PositionManager");
            assertTrue(s.msgSenderAnswered, "the PositionManager answers msgSender()");
            assertEq(s.msgSender, address(0), "initialise: no user behind it (outside the lock)");
        }
        assertEq(_seen(0).selector, IHooks.beforeInitialize.selector);
        assertEq(_seen(1).selector, IHooks.afterInitialize.selector);
    }

    /// @notice mint, increase, decrease, burn through `PositionManager.modifyLiquidities`: every liquidity callback has
    /// `sender` = the PositionManager (never the LP), `salt` = the token id, `hookData` as the LP wrote it, and
    /// `msgSender()` = the LP (the PositionManager's locker). The position itself is the PositionManager's in the manager.
    function test_liquidity_through_the_position_manager_the_hook_sees_the_position_manager_and_the_token_id() public {
        _openPool(key);
        probe.clear();
        (int24 lower, int24 upper) = _fullRange(key.tickSpacing);
        bytes[4] memory data = [bytes("mint: 1"), bytes("increase: 22"), bytes(HOOK_DATA), bytes("")];

        uint256 id = _posmMint(lp2, key, lower, upper, _liq() / 10, data[0]);
        _posmIncrease(lp2, key, id, _liq() / 10, data[1]);
        assertEq(_managerLiquidityOf(key, id, lower, upper), uint128(_liq() / 5), "the manager holds it as the PositionManager's, salt = token id");
        _posmDecrease(lp2, key, id, _liq() / 20, data[2]);
        _posmBurn(lp2, key, id, data[3]);

        // two callbacks per step, in order: before/after add (mint, increase), before/after remove (decrease, burn)
        assertEq(probe.seenCount(), 8, "four steps, two callbacks each");
        bytes4[4] memory before = [
            IHooks.beforeAddLiquidity.selector,
            IHooks.beforeAddLiquidity.selector,
            IHooks.beforeRemoveLiquidity.selector,
            IHooks.beforeRemoveLiquidity.selector
        ];
        for (uint256 i = 0; i < 8; i++) {
            PeripheryProbeHook.Seen memory s = _seen(i);
            if (i % 2 == 0) assertEq(s.selector, before[i / 2], "callback order");
            assertEq(s.sender, address(posm), "liquidity: sender is the PositionManager, not the LP");
            assertTrue(s.msgSenderAnswered, "the PositionManager answers msgSender()");
            assertEq(s.msgSender, lp2, "liquidity: msgSender() is the LP");
            assertEq(s.salt, bytes32(id), "liquidity: the salt is the token id");
            assertEq(s.hookData, data[i / 2], "liquidity: hookData arrives byte for byte");
        }
    }

    /// @notice exact-in and exact-out swaps through the router: `sender` = the router (never the trader), `msgSender()`
    /// = the trader, `hookData` byte for byte - checked twice, by the probe and off the calldata
    function test_swaps_through_the_router_the_hook_sees_the_router() public {
        _openPool(key);
        for (uint256 i = 0; i < 4; i++) {
            probe.clear();
            bytes memory hd = abi.encodePacked(HOOK_DATA, uint8(i));
            (PeripheryBooks memory b, HookCall[] memory calls) =
                _routerSwapWithBooks(trader, key, _swapOf(key, i % 2 == 0, i < 2, hd));
            _assertPeripheryConserved(b, "probe swap");
            assertEq(_assertHookCalls(calls, swapRouter, hd, "probe swap (calldata)"), 2, "beforeSwap and afterSwap");
            assertEq(probe.seenCount(), 2);
            for (uint256 j = 0; j < 2; j++) {
                PeripheryProbeHook.Seen memory s = _seen(j);
                assertEq(s.sender, swapRouter, "swap: sender is the router, not the trader");
                assertTrue(s.msgSenderAnswered, "the router answers msgSender()");
                assertEq(s.msgSender, trader, "swap: msgSender() is the trader");
                assertEq(s.hookData, hd, "swap: hookData arrives byte for byte");
            }
        }
    }

    /// @notice `msgSender()` is whatever the CALLER says: a router that names someone else is believed by any hook that
    /// asks without knowing the router. The same swap from the kit's own `MinimalRouter`, which has no `msgSender()`,
    /// makes the question revert - a hook that asks unguarded refuses every router that does not implement it.
    function test_msgSender_is_only_what_the_caller_claims() public {
        _openPool(key);
        address victim = address(0xD1E);
        LyingRouter liar = new LyingRouter(manager, victim);
        (address t0, address t1) = (Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
        _approveAll(trader, t0, address(liar));
        _approveAll(trader, t1, address(liar));
        _approveAll(trader, t0, address(router));
        _approveAll(trader, t1, address(router));
        SwapParams memory p = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(uint256(_amt(key.currency0))),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        probe.clear();
        vm.prank(trader);
        liar.swap(key, p, "");
        assertEq(probe.seenCount(), 2);
        assertEq(_seen(0).sender, address(liar));
        assertTrue(_seen(0).msgSenderAnswered);
        assertEq(_seen(0).msgSender, victim, "the hook was told the swap was the victim's");

        probe.clear();
        vm.prank(trader);
        router.swap(key, p, "");
        assertEq(probe.seenCount(), 2);
        assertEq(_seen(0).sender, address(router));
        assertFalse(_seen(0).msgSenderAnswered, "MinimalRouter has no msgSender(): the question reverts");
    }

    function _approveAll(address who, address token, address spender) internal {
        vm.prank(who);
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max));
        require(ok, "approve");
    }
}
