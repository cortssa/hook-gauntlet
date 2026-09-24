// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {HostileERC20} from "gauntlet-kit/HostileERC20.sol";
import {V4Harness} from "../../src/V4Harness.sol";
import {HookMiner} from "../../src/HookMiner.sol";
import {HostileHook} from "../../src/HostileHook.sol";
import {SwapEventReader} from "../../src/SwapEventReader.sol";
import {DeltaFeeHook} from "../../src/examples/DeltaFeeHook.sol";
import {ClaimsFeeHook} from "../../src/examples/ClaimsFeeHook.sol";
import {CappedDynamicFeeHook} from "../../src/examples/CappedDynamicFeeHook.sol";

/// @notice ITEM 4 of K15: the three example hooks, and the harness under them, at the EDGES - tick spacing 1 and the
/// maximum (32 767), prices near and AT the ends of the sqrt-price range, an LP fee of 0 and of 100 %, and a dynamic fee
/// at the manager's cap. Every other test in this module runs at spacing 60 (or 10) and a price of 1 or 4.
///
/// The battery: for each edge, each hook, amounts of 1 wei, 1e6 and 1e18 in the four orientations. A swap either STANDS,
/// and then its books close per party to the wei (swapper + hook + manager = 0 per currency, the hook's claims counted,
/// the hook's delta exactly its rule), or it is REFUSED for a reason the test names: the manager's
/// `PriceLimitAlreadyExceeded` (a price AT the end, a swap into the wall), or - `DeltaFeeHook` only - the hook's fee
/// `take` on the INPUT currency of an exact-out swap, which needs the manager to hold that currency before the swapper
/// has paid it (below). Anything else is a failure of the test. Numbers measured 2026-09-24, source manager.
contract ExampleHookEdgesTest is V4Harness {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 internal constant MAX_SPACING = 32_767;

    DeltaFeeHook internal delta;
    ClaimsFeeHook internal claims;
    CappedDynamicFeeHook internal capped;
    address internal provider = address(0xA11CE);
    address internal trader = address(0xB0B);
    address internal treasury = address(0x7EA5);

    struct Edge {
        string name;
        int24 spacing;
        uint160 sqrtPrice;
    }

    struct Tally {
        uint256 stood;
        uint256 atTheWall;
        uint256 feeNotHeld;
    }

    function setUp() public {
        _setUpManager();
        _deployCurrencies();
        _deployRouters();
        uint160 deltaFlags = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        (, bytes32 salt) = HookMiner.find(address(this), deltaFlags, type(DeltaFeeHook).creationCode, abi.encode(manager));
        delta = new DeltaFeeHook{salt: salt}(manager);
        (, salt) = HookMiner.find(
            address(this),
            Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG,
            type(ClaimsFeeHook).creationCode,
            abi.encode(manager, treasury)
        );
        claims = new ClaimsFeeHook{salt: salt}(manager, treasury);
        (, salt) = HookMiner.find(
            address(this),
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG,
            type(CappedDynamicFeeHook).creationCode,
            abi.encode(manager)
        );
        capped = new CappedDynamicFeeHook{salt: salt}(manager);
        _fundAndApprove(provider, 1e38);
        _fundAndApprove(trader, 1e38);
    }

    function _edges() internal pure returns (Edge[5] memory e) {
        e[0] = Edge("spacing 1, 100 ticks above MIN_TICK", 1, TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK + 100));
        e[1] = Edge("spacing 1, 100 ticks below MAX_TICK", 1, TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK - 100));
        e[2] = Edge("spacing 1, AT MIN_SQRT_PRICE", 1, TickMath.MIN_SQRT_PRICE);
        e[3] = Edge("spacing 1, AT MAX_SQRT_PRICE - 1", 1, TickMath.MAX_SQRT_PRICE - 1);
        e[4] = Edge("spacing 32767, price 1", MAX_SPACING, SQRT_PRICE_1_1);
    }

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

    /// @notice one swap as an external call, so that a refusal can be classified and the books read when it stands
    function swapAndCheck(PoolKey memory k, SwapParams memory p, uint8 which) external {
        require(msg.sender == address(this), "self only");
        SwapBooks memory b = _swapWithBooks(trader, k, p);
        int256 h0 = b.pool0 - b.caller0;
        int256 h1 = b.pool1 - b.caller1;
        // per party, per currency, claims counted: nothing created or destroyed
        assertEq(b.swapper0 + b.hook0 + b.manager0, 0, "currency0 created or destroyed");
        assertEq(b.swapper1 + b.hook1 + b.manager1, 0, "currency1 created or destroyed");
        assertEq(b.hook0 + b.hookClaims0, h0, "the hook's currency0 is not its booked delta");
        assertEq(b.hook1 + b.hookClaims1, h1, "the hook's currency1 is not its booked delta");
        bool s0 = (p.amountSpecified < 0) == p.zeroForOne;
        (int256 hookUnspec, int256 poolUnspec) = s0 ? (h1, b.pool1) : (h0, b.pool0);
        if (which == 2) {
            assertEq(h0, 0, "the capped hook moved currency0");
            assertEq(h1, 0, "the capped hook moved currency1");
        } else {
            assertEq(hookUnspec, int256(_abs(poolUnspec) * 30 / 10_000), "the hook's fee is not 0.30 % of the pool's unspecified");
        }
    }

    /// @notice the refusal of `DeltaFeeHook` taking a fee in a currency the manager does not hold enough of: the token's own
    /// `InsufficientBalance(manager)` from the manager's transfer, wrapped by the manager, wrapped again around `afterSwap`
    function _feeNotHeld(bytes memory err, address token) internal view returns (bool) {
        bytes memory inner = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            token,
            HostileERC20.transfer.selector,
            abi.encodeWithSelector(HostileERC20.InsufficientBalance.selector, address(manager)),
            abi.encodeWithSelector(CurrencyLibrary.ERC20TransferFailed.selector)
        );
        bytes memory outer = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(delta),
            IHooks.afterSwap.selector,
            inner,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
        return keccak256(err) == keccak256(outer);
    }

    function _battery(uint8 which) internal returns (Tally memory t) {
        Edge[5] memory e = _edges();
        uint256[3] memory amounts = [uint256(1), 1e6, 1e18];
        for (uint256 i = 0; i < e.length; i++) {
            uint256 snap = vm.snapshotState();
            PoolKey memory k;
            if (which == 0) k = _initPool(IHooks(address(delta)), 3000, e[i].spacing, e[i].sqrtPrice);
            else if (which == 1) k = _initPool(IHooks(address(claims)), 3000, e[i].spacing, e[i].sqrtPrice);
            else k = _initPool(IHooks(address(capped)), LPFeeLibrary.DYNAMIC_FEE_FLAG, e[i].spacing, e[i].sqrtPrice);
            _addFullRangeLiquidity(k, provider, 1e18);
            for (uint256 a = 0; a < amounts.length; a++) {
                for (uint256 o = 0; o < 4; o++) {
                    SwapParams memory p = _p(o < 2, o % 2 == 0, amounts[a]);
                    try this.swapAndCheck(k, p, which) {
                        t.stood += 1;
                    } catch (bytes memory err) {
                        if (bytes4(err) == Pool.PriceLimitAlreadyExceeded.selector) {
                            t.atTheWall += 1;
                        } else if (which == 0 && p.amountSpecified > 0) {
                            // exact-out: the fee is on the input, which the swapper has not paid yet
                            address input = Currency.unwrap(p.zeroForOne ? k.currency0 : k.currency1);
                            assertTrue(_feeNotHeld(err, input), string.concat(e[i].name, ": refused for another reason"));
                            t.feeNotHeld += 1;
                        } else {
                            console2.log(e[i].name, o, amounts[a]);
                            console2.logBytes(err);
                            fail();
                        }
                    }
                }
            }
            vm.revertToState(snap);
        }
        console2.log("stood / at the wall / fee not held:", t.stood, t.atTheWall, t.feeNotHeld);
    }

    /// @notice 60 swaps per hook (5 edges x 3 amounts x 4 orientations). Measured: 4 are the manager's
    /// `PriceLimitAlreadyExceeded` (a price AT an end, a swap of 1 wei or 1e6 into that wall); of the other 56, 48 stand
    /// and close to the wei and 8 - every exact-out swap whose input, at these prices, is more than the manager holds -
    /// are refused by the hook's own fee `take` (see the last test of this file)
    function test_the_delta_example_at_the_edges() public {
        Tally memory t = _battery(0);
        assertEq(t.stood, 48);
        assertEq(t.atTheWall, 4);
        assertEq(t.feeNotHeld, 8);
    }

    /// @notice the same 60 swaps: 56 stand and close per party (the fee a claim), 4 at the wall. No fee refusal: it mints
    function test_the_claims_example_at_the_edges() public {
        Tally memory t = _battery(1);
        assertEq(t.stood, 56);
        assertEq(t.atTheWall, 4);
        assertEq(t.feeNotHeld, 0);
    }

    /// @notice the same 60 swaps: 56 stand, the hook's delta zero in every one, 4 at the wall
    function test_the_capped_example_at_the_edges() public {
        Tally memory t = _battery(2);
        assertEq(t.stood, 56);
        assertEq(t.atTheWall, 4);
    }

    // ------------------------------------------------------------------ the harness at the two spacings
    /// @notice `_fullRange` at spacing 1 is the whole tick range; at 32 767 it stops at +-884 709, 2 563 ticks short of
    /// the ends, so a price near MIN or MAX is OUTSIDE the widest position that spacing allows: a swap there fills
    /// nothing. The harness computes the range, it does not assume 60 - and at the maximum spacing "full range" is not.
    function test_the_harness_full_range_at_spacing_1_and_at_the_maximum() public {
        (int24 lo, int24 hi) = _fullRange(1);
        assertEq(lo, TickMath.MIN_TICK);
        assertEq(hi, TickMath.MAX_TICK);
        (lo, hi) = _fullRange(MAX_SPACING);
        assertEq(lo, -884_709);
        assertEq(hi, 884_709);
        PoolKey memory k = _initPool(
            IHooks(address(delta)), 3000, MAX_SPACING, TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK + 100)
        );
        _addFullRangeLiquidity(k, provider, 1e18);
        SwapBooks memory b = _swapWithBooks(trader, k, _p(true, true, 1e6));
        assertEq(b.caller0, 0, "a swap outside the widest position took input");
        assertEq(b.caller1, 0, "a swap outside the widest position delivered output");
        _addFullRangeLiquidity(k, provider, -1e18);
    }

    // ------------------------------------------------------------------ fees: 0, 100 %, and a dynamic fee at the cap
    /// @notice an LP fee of 0 and of 100 % (`MAX_LP_FEE`, the most a static pool can have) under the two fee-taking
    /// examples: at 0 the hook's fee is still its 0.30 %; at 100 % an exact-in swap is all LP fee - the pool delivers
    /// nothing, the hook's fee on it is 0 - and an exact-out swap is refused by the manager (`InvalidFeeForExactOut`)
    function test_an_lp_fee_of_zero_and_of_one_hundred_percent() public {
        uint24[2] memory fees = [uint24(0), uint24(LPFeeLibrary.MAX_LP_FEE)];
        for (uint256 h = 0; h < 2; h++) {
            for (uint256 f = 0; f < 2; f++) {
                IHooks hook = h == 0 ? IHooks(address(delta)) : IHooks(address(claims));
                PoolKey memory k = _initPool(hook, fees[f], 60 + int24(int256(h * 2 + f)), SQRT_PRICE_1_1);
                _addFullRangeLiquidity(k, provider, 100e18);
                this.swapAndCheck(k, _p(true, true, 1e18), uint8(h));
                if (f == 1) {
                    SwapBooks memory b = _swapWithBooks(trader, k, _p(true, false, 1e18));
                    assertEq(b.pool0, 0, "a 100 % fee pool delivered output");
                    assertEq(b.pool0 - b.caller0, 0, "a fee on nothing");
                    vm.prank(trader);
                    vm.expectRevert(Pool.InvalidFeeForExactOut.selector);
                    router.swap(k, _p(false, true, 1e17), "");
                } else {
                    this.swapAndCheck(k, _p(false, false, 1e17), uint8(h));
                }
            }
        }
    }

    /// @notice a DYNAMIC fee at the manager's cap: a hook that overrides with exactly `MAX_LP_FEE` (100 %) is accepted on
    /// exact-in (the swapper gets nothing) and refused on exact-out, as the static fee is; one more is `LPFeeTooLarge`
    /// (`test/HostileHook.t.sol`). And the capped example at its OWN cap at spacing 32 767: every swap of a congested
    /// block is charged `MAX_FEE`, read off the manager's `Swap` event
    function test_a_dynamic_fee_at_the_cap() public {
        (, bytes32 salt) = HookMiner.find(
            address(this), Hooks.BEFORE_SWAP_FLAG, type(HostileHook).creationCode, abi.encode(manager)
        );
        HostileHook hostile = new HostileHook{salt: salt}(manager);
        PoolKey memory k = _initPool(IHooks(address(hostile)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, SQRT_PRICE_1_1);
        _addFullRangeLiquidity(k, provider, 100e18);
        hostile.setRawFeeOverride(uint24(LPFeeLibrary.MAX_LP_FEE) | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        SwapBooks memory b = _swapWithBooks(trader, k, _p(true, true, 1e18));
        assertEq(b.caller1, 0, "a 100 % dynamic fee delivered output");
        assertEq(b.caller0, -1e18);
        vm.prank(trader);
        vm.expectRevert(Pool.InvalidFeeForExactOut.selector);
        router.swap(k, _p(false, true, 1e17), "");

        PoolKey memory c = _initPool(IHooks(address(capped)), LPFeeLibrary.DYNAMIC_FEE_FLAG, MAX_SPACING, SQRT_PRICE_1_1);
        _addFullRangeLiquidity(c, provider, 100e18);
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(trader);
            router.swap(c, _p(true, i % 2 == 0, 1e15), "");
        }
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(capped.quoteNextFee(c), capped.MAX_FEE(), "ten swaps did not congest the next block to the cap");
        vm.recordLogs();
        vm.prank(trader);
        router.swap(c, _p(true, true, 1e15), "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool found, uint24 fee) = SwapEventReader.lastSwapFee(logs, address(manager));
        assertTrue(found);
        assertEq(fee, capped.MAX_FEE(), "the pool charged other than the cap");
    }

    // ------------------------------------------------------------------ arithmetic that breaks at the edge
    /// @notice the block cap above 2^96. Near the low end of the price range one unit of currency1 is worth ~1e32 of
    /// currency0, so one swap of 1e6 units of currency1 leaves the hook a fee of 5.5e34 of currency0 - more than a uint96
    /// holds. The cap used to be stored as `uint96(reserve * 10 %)`, and the cast truncated SILENTLY: measured, a cap of
    /// 17 430 635 726 297 566 524 129 938 969 where 10 % of the reserve is 5 506 216 269 052 069 231 642 641 590 390 297,
    /// and a rebate of 1e30 cut to that. (An 18-decimal token with a trillion-token supply has 1e30 units: the same cast
    /// truncates for a reserve above 7.9e29 of it at any price.) Red on the uint96 fields; the budget is uint256 now.
    function test_the_block_cap_holds_above_2_to_the_96() public {
        PoolKey memory k =
            _initPool(IHooks(address(delta)), 3000, 1, TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK + 100));
        _addFullRangeLiquidity(k, provider, 1e18);
        vm.prank(trader);
        router.swap(k, _p(true, false, 1e6), "");
        uint256 reserve = delta.reserveOf(currency0);
        assertGt(reserve, uint256(type(uint96).max) * 10, "test setup: the reserve is not above 2^96 x 10");
        vm.roll(vm.getBlockNumber() + 1);
        uint256 paid = delta.rebatesPaid(currency0);
        vm.prank(trader);
        router.swap(k, _p(true, true, 1e33), "");
        assertEq(delta.rebatesPaid(currency0) - paid, delta.nominalRebateOf(1e33), "the rebate was cut by a truncated cap");
        assertEq(delta.budgetOf(k.toId(), currency0).cap, reserve * 1_000 / 10_000, "the cap is not 10 % of the reserve");
    }

    /// @notice a LIMIT, measured, not a fix: `DeltaFeeHook` takes its fee in `afterSwap`, and on an exact-out swap the
    /// fee is in the INPUT currency - which the swapper pays only after the swap returns. The manager's `take` is a
    /// transfer out of what it holds NOW, so the fee needs the manager to hold that much of the input already. A pool
    /// whose liquidity is all on one side (a range above the price: only currency0) on a manager holding no currency1:
    /// the first exact-out swap buying currency0 dies in the hook's `take` (the token's `InsufficientBalance`); an
    /// exact-in swap brings currency1 in, and the same exact-out swap then stands. At the edges above the same refusal
    /// appears whenever the fee on the input exceeds the manager's whole inventory of it. `ClaimsFeeHook` mints its fee
    /// instead of taking it and has no such refusal (its battery above: none).
    function test_the_fee_on_an_input_the_manager_does_not_hold_yet_kills_an_exact_out_swap() public {
        PoolKey memory k = _initPool(IHooks(address(delta)), 3000, 60, SQRT_PRICE_1_1);
        vm.prank(provider);
        liquidity.modifyLiquidity(
            k, ModifyLiquidityParams({tickLower: 60, tickUpper: 6000, liquidityDelta: 1e20, salt: 0}), ""
        );
        assertEq(token1.trueBalanceOf(address(manager)), 0, "test setup: the manager holds currency1");
        SwapParams memory out = _p(false, false, 1e17);
        vm.prank(trader);
        try router.swap(k, out, "") {
            fail();
        } catch (bytes memory err) {
            assertTrue(_feeNotHeld(err, address(token1)), "refused, but not by the fee take");
        }
        vm.prank(trader);
        router.swap(k, _p(true, false, 1e17), "");
        this.swapAndCheck(k, out, 0);
    }
}
