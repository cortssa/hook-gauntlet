// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapEventReader} from "../src/SwapEventReader.sol";
import {CappedDynamicFeeHook} from "../src/examples/CappedDynamicFeeHook.sol";
import {DeltaFeeHook} from "../src/examples/DeltaFeeHook.sol";
import {ClaimsFeeHook} from "../src/examples/ClaimsFeeHook.sol";
import {IERC721Owner} from "./PeripheryHarness.sol";
import {PeripheryPools} from "./PeripheryPools.sol";
import {PeripheryPlans} from "./PeripheryPlans.sol";

/// @notice The three example hooks reached through Uniswap's periphery instead of the kit's routers (K17b): a position's
/// whole life through `PositionManager.modifyLiquidities` (mint, increase, decrease, burn), and swaps through a V4Router -
/// exact-in and exact-out, both directions, on an ERC-20 pool and on a native one - each with every party's books closing
/// to the wei, the router and the PositionManager ending square, the user paying or receiving exactly what it specified,
/// and the hook given `sender` = the periphery contract and the user's `hookData` byte for byte (read off the calldata).
/// Source manager: the pinned periphery (`MockV4Router`); fork: the deployed PositionManager and UniversalRouter.
abstract contract PeripheryExampleBase is PeripheryPools {
    PoolKey internal key;
    PoolKey internal nativeKey;
    address internal hookAddr;

    function _deployExampleHook() internal virtual returns (address);

    function _fee() internal view virtual returns (uint24) {
        return 3000;
    }

    /// @notice the callbacks the hook declares for one swap, and for initialise
    function _swapCallbacks() internal view virtual returns (uint256);
    function _initCallbacks() internal view virtual returns (uint256);

    /// @notice what the hook itself must show on one swap's books (the conservation and the router are checked for it)
    function _checkHookOnSwap(PeripheryBooks memory b, PoolKey memory k, RouterSwap memory s) internal virtual;

    function setUp() public virtual {
        _setUpPeripheryWorld();
        hookAddr = _deployExampleHook();
        key = _erc20Key(IHooks(hookAddr), _fee());
        nativeKey = _nativeKey(IHooks(hookAddr), _fee());
        _openPool(key);
        _openPool(nativeKey);
    }

    /// @notice initialise a third pool through the PositionManager: the hook's initialise callbacks, if it has any, come
    /// from the PositionManager
    function test_initialise_through_the_position_manager() public {
        PoolKey memory k = _erc20Key(IHooks(hookAddr), _fee());
        k.tickSpacing = 10;
        vm.startStateDiffRecording();
        _initPoolThroughPosm(k, _sqrtPriceOf(k));
        HookCall[] memory calls = _hookCallsIn(vm.stopAndReturnStateDiff(), hookAddr);
        assertEq(_assertHookCalls(calls, address(posm), "", "initialise"), _initCallbacks(), "initialise callbacks");
    }

    function test_a_position_through_the_position_manager_erc20_pool() public {
        _positionLifecycle(key, "erc20");
    }

    function test_a_position_through_the_position_manager_native_pool() public {
        _positionLifecycle(nativeKey, "native");
    }

    function test_swaps_through_the_router_erc20_pool() public {
        _fourSwaps(key, "erc20");
    }

    function test_swaps_through_the_router_native_pool() public {
        _fourSwaps(nativeKey, "native");
    }

    /// @notice mint, increase, decrease, burn - as lp2, with the user's hookData - and the books of each step
    function _positionLifecycle(PoolKey memory k, string memory label) internal {
        (int24 lower, int24 upper) = _fullRange(k.tickSpacing);
        uint256 liq = _liq() / 10;
        uint256 id = posm.nextTokenId();
        uint256 v = _posmValue(k, lp2);

        (PeripheryBooks memory b, HookCall[] memory calls) =
            _posmWithBooks(lp2, k, _mintPlan(k, lower, upper, liq), v);
        _checkLiquidityStep(b, calls, string.concat(label, ": mint"), true);
        assertEq(IERC721Owner(address(posm)).ownerOf(id), lp2, "the LP owns the token");
        assertEq(_managerLiquidityOf(k, id, lower, upper), uint128(liq), "mint: the manager's position (PositionManager, salt = id)");

        (b, calls) = _posmWithBooks(lp2, k, _increasePlan(k, id, liq), _posmValue(k, lp2));
        _checkLiquidityStep(b, calls, string.concat(label, ": increase"), true);
        assertEq(_managerLiquidityOf(k, id, lower, upper), uint128(2 * liq), "increase");

        (b, calls) = _posmWithBooks(lp2, k, _decreasePlan(k, id, liq / 2), 0);
        _checkLiquidityStep(b, calls, string.concat(label, ": decrease"), false);
        assertEq(_managerLiquidityOf(k, id, lower, upper), uint128(2 * liq - liq / 2), "decrease");

        (b, calls) = _posmWithBooks(lp2, k, _burnPlan(k, id), 0);
        _checkLiquidityStep(b, calls, string.concat(label, ": burn"), false);
        assertEq(_managerLiquidityOf(k, id, lower, upper), 0, "burn: nothing left in the manager");
        vm.expectRevert();
        IERC721Owner(address(posm)).ownerOf(id);
    }

    function _checkLiquidityStep(PeripheryBooks memory b, HookCall[] memory calls, string memory label, bool adding)
        internal
        view
    {
        _assertPeripheryConserved(b, label);
        // none of the three example hooks declares a liquidity callback: the hook is not called and holds what it held
        assertEq(_assertHookCalls(calls, address(posm), HOOK_DATA, label), 0, string.concat(label, ": a liquidity callback"));
        assertEq(b.hook0 + b.hookClaims0, 0, string.concat(label, ": the hook moved in currency0"));
        assertEq(b.hook1 + b.hookClaims1, 0, string.concat(label, ": the hook moved in currency1"));
        if (adding) {
            assertLt(b.user0, 0, string.concat(label, ": the LP paid no currency0"));
            assertLt(b.user1, 0, string.concat(label, ": the LP paid no currency1"));
        } else {
            assertGt(b.user0, 0, string.concat(label, ": the LP got no currency0"));
            assertGt(b.user1, 0, string.concat(label, ": the LP got no currency1"));
        }
    }

    function _mintPlan(PoolKey memory k, int24 lower, int24 upper, uint256 liq) internal view returns (bytes memory) {
        return PeripheryPlans.mint(k, lower, upper, liq, lp2, HOOK_DATA);
    }

    function _increasePlan(PoolKey memory k, uint256 id, uint256 liq) internal view returns (bytes memory) {
        return PeripheryPlans.increase(k, id, liq, lp2, HOOK_DATA);
    }

    function _decreasePlan(PoolKey memory k, uint256 id, uint256 liq) internal view returns (bytes memory) {
        return PeripheryPlans.decrease(k, id, liq, lp2, HOOK_DATA);
    }

    function _burnPlan(PoolKey memory k, uint256 id) internal view returns (bytes memory) {
        return PeripheryPlans.burn(k, id, lp2, HOOK_DATA);
    }

    /// @notice the four orientations, twice (the second round in the next block, so a hook with a per-block schedule
    /// or budget is in its second state), each with the books
    function _fourSwaps(PoolKey memory k, string memory label) internal {
        for (uint256 round = 0; round < 2; round++) {
            if (round == 1) vm.roll(block.number + 1);
            for (uint256 i = 0; i < 4; i++) {
                bool exactIn = i < 2;
                bool zeroForOne = i % 2 == 0;
                bytes memory hd = abi.encodePacked(HOOK_DATA, uint8(round), uint8(i));
                RouterSwap memory s = _swapOf(k, zeroForOne, exactIn, hd);
                (PeripheryBooks memory b, HookCall[] memory calls) = _routerSwapWithBooks(trader, k, s);
                string memory l = string.concat(label, exactIn ? " exact-in" : " exact-out", zeroForOne ? " 0->1" : " 1->0");
                _assertPeripheryConserved(b, l);
                assertEq(_assertHookCalls(calls, swapRouter, hd, l), _swapCallbacks(), string.concat(l, ": swap callbacks"));
                // the user paid (exact-in) or received (exact-out) exactly what it specified: the router settled the rest
                int256 userSpecified = (exactIn == zeroForOne) ? b.user0 : b.user1;
                assertEq(userSpecified, exactIn ? -int256(uint256(s.amount)) : int256(uint256(s.amount)), string.concat(l, ": specified"));
                // the manager kept the pool's delta, plus what it now owes the hook as claims
                assertEq(b.manager0 - b.hookClaims0, -b.pool0, string.concat(l, ": manager0"));
                assertEq(b.manager1 - b.hookClaims1, -b.pool1, string.concat(l, ": manager1"));
                _checkHookOnSwap(b, k, s);
            }
        }
    }

    /// @notice the hook's delta as the manager booked it, from the books: `pool - user` (the router is square)
    function _booked(PeripheryBooks memory b) internal pure returns (int256 h0, int256 h1) {
        return (b.pool0 - b.user0, b.pool1 - b.user1);
    }
}

contract CappedDynamicFeeHookPeripheryTest is PeripheryExampleBase {
    function _deployExampleHook() internal override returns (address) {
        return _deployHook(
            type(CappedDynamicFeeHook).creationCode, abi.encode(manager), Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        );
    }

    function _fee() internal pure override returns (uint24) {
        return LPFeeLibrary.DYNAMIC_FEE_FLAG;
    }

    function _swapCallbacks() internal pure override returns (uint256) {
        return 1;
    }

    function _initCallbacks() internal pure override returns (uint256) {
        return 1;
    }

    /// @notice it returns no delta: the hook holds nothing and the user settled exactly the pool's delta
    function _checkHookOnSwap(PeripheryBooks memory b, PoolKey memory, RouterSwap memory) internal pure override {
        (int256 h0, int256 h1) = _booked(b);
        assertEq(h0, 0, "capped: a delta in currency0");
        assertEq(h1, 0, "capped: a delta in currency1");
        assertEq(b.hook0 + b.hook1 + b.hookClaims0 + b.hookClaims1, 0, "capped: the hook holds something");
    }

    /// @notice the fee schedule reaches the pool through the router: base in the first block, flat within it, one step
    /// per swap of the previous block, base again after an idle block (the fee off the manager's `Swap` event). "Through
    /// the router" is checked on every swap, not assumed: the hook's one swap callback came with `sender` = the router
    /// (K17c, from the verifier V17b: with the harness's swaps sent through the kit's `MinimalRouter` this test used to
    /// stay green)
    function test_the_fee_schedule_through_the_router() public {
        CappedDynamicFeeHook h = CappedDynamicFeeHook(hookAddr);
        uint256 b0 = block.number;
        assertEq(_swapFee(), h.BASE_FEE(), "first block");
        assertEq(_swapFee(), h.BASE_FEE(), "same block");
        assertEq(_swapFee(), h.BASE_FEE(), "same block");
        vm.roll(b0 + 1);
        assertEq(_swapFee(), h.BASE_FEE() + 3 * h.STEP(), "three swaps in the previous block");
        vm.roll(b0 + 3);
        assertEq(_swapFee(), h.BASE_FEE(), "after an idle block");
    }

    function _swapFee() internal returns (uint24 fee) {
        vm.recordLogs();
        vm.startStateDiffRecording();
        _routerSwap(trader, key, _swapOf(key, true, true, HOOK_DATA));
        HookCall[] memory calls = _hookCallsIn(vm.stopAndReturnStateDiff(), hookAddr);
        assertEq(_assertHookCalls(calls, swapRouter, HOOK_DATA, "fee schedule"), 1, "fee schedule: the swap callback");
        bool found;
        (found, fee) = SwapEventReader.lastSwapFee(vm.getRecordedLogs(), address(manager));
        require(found, "no Swap event");
    }
}

contract DeltaFeeHookPeripheryTest is PeripheryExampleBase {
    uint256 internal rebates;

    function _deployExampleHook() internal override returns (address) {
        return _deployHook(
            type(DeltaFeeHook).creationCode,
            abi.encode(manager),
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
    }

    function _swapCallbacks() internal pure override returns (uint256) {
        return 2;
    }

    function _initCallbacks() internal pure override returns (uint256) {
        return 0;
    }

    /// @notice P1-P3 through the router: the hook received exactly its booked delta (it takes and settles inside its
    /// callbacks), the fee is exactly 0.30 % of the pool's unspecified amount on the unspecified side, the rebate is a
    /// payment on the specified side of at most 0.10 % of what was specified
    function _checkHookOnSwap(PeripheryBooks memory b, PoolKey memory, RouterSwap memory s) internal override {
        DeltaFeeHook h = DeltaFeeHook(payable(hookAddr));
        (int256 h0, int256 h1) = _booked(b);
        assertEq(b.hook0, h0, "delta: the hook's currency0 is not its booked delta");
        assertEq(b.hook1, h1, "delta: the hook's currency1 is not its booked delta");
        assertEq(b.hookClaims0 + b.hookClaims1, 0, "delta: claims");
        bool s0 = s.exactIn == s.zeroForOne;
        (int256 hookSpec, int256 hookUnspec, int256 poolUnspec) = s0 ? (h0, h1, b.pool1) : (h1, h0, b.pool0);
        assertEq(hookUnspec, int256(h.feeOf(_abs(poolUnspec))), "delta: the fee");
        assertLe(hookSpec, 0, "delta: a take on the specified side");
        assertLe(uint256(-hookSpec), h.nominalRebateOf(s.amount), "delta: a rebate above the nominal");
        if (hookSpec < 0) rebates++;
    }

    /// @notice the fee and the rebate both happened through the router, not only the fee
    function test_a_rebate_is_paid_through_the_router() public {
        _fourSwaps(key, "erc20");
        _fourSwaps(nativeKey, "native");
        assertGt(rebates, 0, "no rebate was paid through the router: the rebate path is untested");
    }
}

contract ClaimsFeeHookPeripheryTest is PeripheryExampleBase {
    address internal treasury = address(0x7EA5);

    function _deployExampleHook() internal override returns (address) {
        return _deployHook(
            type(ClaimsFeeHook).creationCode,
            abi.encode(manager, treasury),
            Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
    }

    function _swapCallbacks() internal pure override returns (uint256) {
        return 1;
    }

    function _initCallbacks() internal pure override returns (uint256) {
        return 0;
    }

    /// @notice C1-C2 through the router: the fee is held as claims, exactly the booked delta, 0.30 % of the pool's
    /// unspecified amount on the unspecified side; the hook's token balances do not move
    function _checkHookOnSwap(PeripheryBooks memory b, PoolKey memory, RouterSwap memory s) internal view override {
        ClaimsFeeHook h = ClaimsFeeHook(hookAddr);
        (int256 h0, int256 h1) = _booked(b);
        assertEq(b.hookClaims0, h0, "claims: currency0 claims are not the booked delta");
        assertEq(b.hookClaims1, h1, "claims: currency1 claims are not the booked delta");
        assertEq(b.hook0 + b.hook1, 0, "claims: the hook's token balance moved");
        bool s0 = s.exactIn == s.zeroForOne;
        (int256 claimSpec, int256 claimUnspec, int256 poolUnspec) = s0 ? (h0, h1, b.pool1) : (h1, h0, b.pool0);
        assertEq(claimSpec, 0, "claims: a claim on the specified side");
        assertEq(claimUnspec, int256(h.feeOf(_abs(poolUnspec))), "claims: the fee");
        assertGt(claimUnspec, 0, "claims: no fee");
    }
}
