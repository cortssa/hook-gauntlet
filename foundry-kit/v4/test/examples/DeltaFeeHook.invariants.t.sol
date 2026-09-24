// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {HostileERC20} from "gauntlet-kit/HostileERC20.sol";
import {HandlerBase, InvariantAsserts, IBalanceReader, YES, NO} from "gauntlet-kit/InvariantBase.sol";
import {V4Harness} from "../../src/V4Harness.sol";
import {HookMiner} from "../../src/HookMiner.sol";
import {MinimalRouter} from "../../src/MinimalRouter.sol";
import {LiquidityHelper} from "../../src/LiquidityHelper.sol";
import {SwapEventReader} from "../../src/SwapEventReader.sol";
import {DeltaFeeHook} from "../../src/examples/DeltaFeeHook.sol";
import {PrepayRouter} from "./PrepayRouter.sol";

// ADAPT: a worked TOY. What carries over to a hook that returns deltas is the per-swap BOOKS: every swap is read from
// three independent sources - the delta the manager returned to the router (the swapper's side), the pool's own delta
// off the `Swap` event, and true token balances - and the hook's delta is DERIVED (`pool - caller`), never asked of the
// hook. The hook's own ledger (`reserveOf`, `feesBooked`, `rebatesPaid`) is then held to that derivation.

/// @notice balances with every switch of the token ignored. Only the invariants see it.
contract DeltaTruthReader is IBalanceReader {
    HostileERC20 private immutable token;

    constructor(HostileERC20 t) {
        token = t;
    }

    function balanceOf(address who) external view returns (uint256) {
        return token.trueBalanceOf(who);
    }
}

/// @notice Drives the pool and the currencies against the delta hook, and keeps a model of its fee, rebate and cap.
contract DeltaFeeHandler is HandlerBase, InvariantAsserts {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable manager;
    DeltaFeeHook public immutable hook;
    MinimalRouter public immutable router;
    LiquidityHelper public immutable liquidity;
    HostileERC20 public immutable token0;
    HostileERC20 public immutable token1;
    /// @notice a router that pays FIRST (sync + transfer before the swap): the payment in flight the hook must not clobber
    PrepayRouter public immutable prepay;

    PoolKey internal key;
    int24 internal tickLower;
    int24 internal tickUpper;

    uint256 private constant CALL_GAS = 4_000_000;
    uint256 private constant MAX_SWAP = 5e17;
    uint256 private constant MAX_MINT = 1_000e18;
    /// @notice wei either side of the pool's capacity where the forecast below does not commit: the pool walks its one
    /// range in up to ~60 steps (one per bitmap word) and rounds each in its own favour, the forecast in one step
    uint256 private constant FILL_EDGE = 1_000;

    /// @notice what the handler predicts of P9 for a swap with no price limit, BEFORE it is sent
    enum Fill {
        NoRebate, // no rebate will be paid (budget spent, reserve empty, or a payment in flight - P7): P9 cannot fire
        Whole, // a rebate, and the pool's one range can fill the rebated swap: a P9 refusal is the hook's delta
        Short, // a rebate, and the pool cannot fill it (the scarce side runs out before the range ends): P9 predicted
        Edge // within FILL_EDGE wei of the capacity: rounding decides, the forecast does not
    }

    // ---------------------------------------------------------------- the per-swap checks: every one must stay 0
    /// @notice per currency, swapper + hook + manager + fee sink + token reserve moved by other than 0, or the manager
    /// moved by other than the pool's own delta (P1)
    uint256 public booksBroken;
    /// @notice the hook's balance rose by MORE than the delta the manager booked for it
    uint256 public hookAboveBooked;
    /// @notice the hook's unspecified delta was not exactly 0.30 % of the pool's unspecified amount (P2)
    uint256 public feeWrong;
    /// @notice the hook's specified delta was positive (a take on the specified side) or above the nominal rebate (P3)
    uint256 public rebateWrong;
    /// @notice rebates of one block and currency exceeded the model's cap (P5)
    uint256 public capBroken;
    /// @notice a rebate paid on a swap whose specified side was not exactly `amountSpecified` (P9)
    uint256 public freeRebate;
    /// @notice the handler's own P9 forecast was wrong about a swap that stood (the check on the classifier itself)
    uint256 public forecastWrong;
    uint256 public lastBrokenAt;
    string public lastBroken;

    // ---------------------------------------------------------------- the model, from the manager's books only
    /// @notice per currency (0, 1): fees and rebates as the MANAGER booked them, and the reserve they imply
    uint256[2] public ghostFees;
    uint256[2] public ghostRebates;
    uint256[2] internal _modelBlock;
    uint256[2] internal _modelCap;
    uint256[2] internal _modelUsed;

    uint256 public swapsOk;
    uint256 public exactOutOk;
    uint256 public rebatesSeen;
    /// @notice false once any hostile switch is turned on, true again after `calmDown`. With every switch off, a swap
    /// the manager refuses as `CurrencyNotSettled` can only be the hook leaving its own books open - PROVIDED both
    /// routers close their own: the prepaying one did not, on a swap the pool filled short, until CI caught it
    /// (`test_ci_replay_a_prepaid_swap_on_a_pool_emptied_of_liquidity`). A surprise here names a suspect, not a culprit.
    bool public calm = true;

    uint256 public minted0;
    uint256 public minted1;
    mapping(address => uint256) public liquidityOf;

    constructor(
        IPoolManager manager_,
        DeltaFeeHook hook_,
        MinimalRouter router_,
        LiquidityHelper liquidity_,
        HostileERC20 t0,
        HostileERC20 t1,
        PoolKey memory key_,
        int24 lower,
        int24 upper
    ) {
        manager = manager_;
        hook = hook_;
        router = router_;
        liquidity = liquidity_;
        token0 = t0;
        token1 = t1;
        key = key_;
        tickLower = lower;
        tickUpper = upper;
        prepay = new PrepayRouter(manager_);
        for (uint256 i = 0; i < 5; i++) _addActor(address(uint160(0x6000 + i)));
    }

    function holders() public view returns (address[] memory out) {
        out = new address[](actors.length + 7);
        out[actors.length + 6] = address(prepay);
        for (uint256 i = 0; i < actors.length; i++) out[i] = actors[i];
        out[actors.length] = address(manager);
        out[actors.length + 1] = address(hook);
        out[actors.length + 2] = address(router);
        out[actors.length + 3] = address(liquidity);
        out[actors.length + 4] = token0.FEE_SINK();
        out[actors.length + 5] = token0.RESERVE();
    }

    function modelOf(uint256 c) external view returns (uint256 blockNumber, uint256 cap, uint256 used) {
        return (_modelBlock[c], _modelCap[c], _modelUsed[c]);
    }

    // ---------------------------------------------------------------- funding
    function seed(uint256 amount, int256 liq) external {
        address a = actors[0];
        _mintAndApprove(a, amount);
        vm.prank(a);
        liquidity.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liq, salt: _saltOf(a)}),
            ""
        );
        liquidityOf[a] += uint256(liq);
    }

    function _saltOf(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _mintAndApprove(address a, uint256 amount) internal {
        token0.mint(a, amount);
        token1.mint(a, amount);
        minted0 += amount;
        minted1 += amount;
        _noteMint(amount * 2);
        vm.startPrank(a);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token0.approve(address(liquidity), type(uint256).max);
        token1.approve(address(liquidity), type(uint256).max);
        token0.approve(address(prepay), type(uint256).max);
        vm.stopPrank();
    }

    function fund(uint256 actorSeed, uint256 amount) public countedSetter("fund") {
        _mintAndApprove(_actor(actorSeed), bound(amount, 0, MAX_MINT));
    }

    // ---------------------------------------------------------------- the swaps: all four orientations
    function swap(uint256 actorSeed, uint256 amount, uint256 dirWord, uint256 exactInWord) public counted("swap") {
        if (_doSwap(_actor(actorSeed), bound(amount, 1, MAX_SWAP), _bit(dirWord), _bit(exactInWord), false)) {
            _noteSuccess("swap");
        }
    }

    /// @notice many swaps in ONE block on the same specified currency, so the block's rebate budget is actually spent.
    /// The cap is 10 % of the reserve and a rebate is 0.10 % of the amount: with a reserve of a few 1e15 and swaps near
    /// MAX_SWAP the cap bites after one or two swaps - but only if they land in the same block, which single swaps
    /// between `nextBlock`s rarely do.
    function swapBurst(uint256 actorSeed, uint256 amount, uint256 n, uint256 modeWord) public counted("swapBurst") {
        address a = _actor(actorSeed);
        uint256 count = bound(n, 2, 10);
        uint256 size = bound(amount, MAX_SWAP / 10, MAX_SWAP);
        bool zeroForOne = _bit(modeWord);
        bool exactIn = _bitOneIn(modeWord >> 8, 2);
        bool any;
        for (uint256 i = 0; i < count; i++) {
            if (_doSwap(a, size, zeroForOne, exactIn, false)) any = true;
        }
        if (any) _noteSuccess("swapBurst");
    }

    /// @notice a swap whose price limit sits right next to the pool's price: the pool fills a sliver of it. With a
    /// rebate in play the hook must refuse it (P9); without one it goes through.
    function swapLimited(uint256 actorSeed, uint256 amount, uint256 dirWord) public counted("swapLimited") {
        if (_doSwap(_actor(actorSeed), bound(amount, 1e15, MAX_SWAP), _bit(dirWord), true, true)) {
            _noteSuccess("swapLimited");
        }
    }

    /// @notice exact-in zeroForOne through the router that PAYS FIRST (P7): while its payment is in flight currency0 is
    /// synced, and the hook must pay no rebate (its own `sync` would reset the router's checkpoint). The swap must
    /// stand, the rebate must be 0, and the books are checked like any other swap's.
    function swapPrepaid(uint256 actorSeed, uint256 amount) public counted("swapPrepaid") {
        SwapParams memory p = _paramsFor(bound(amount, 1, MAX_SWAP), true, true, false);
        if (_prepaid(_actor(actorSeed), p)) _noteSuccess("swapPrepaid");
    }

    /// @notice the same router with a PRICE LIMIT below the pool's price: the pool stops at the limit having used part
    /// of the prepayment, and the router must hand back exactly the rest (not all it was credited, not nothing). With
    /// only unlimited prepaid swaps the campaign saw "used all" and "used nothing", where both answers coincide: a
    /// router returning its whole credit instead of the unused part survived it (found by the verifier).
    function swapPrepaidLimited(uint256 actorSeed, uint256 amount, uint256 limitWord)
        public
        counted("swapPrepaidLimited")
    {
        SwapParams memory p = _paramsFor(bound(amount, 1e12, MAX_SWAP), true, true, false);
        (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
        uint160 step = sqrtP >> bound(limitWord, 8, 24); // 0.4 % to 6e-8 of the sqrt price below it
        if (step == 0) step = 1;
        p.sqrtPriceLimitX96 = sqrtP - step > TickMath.MIN_SQRT_PRICE ? sqrtP - step : TickMath.MIN_SQRT_PRICE + 1;
        if (_prepaid(_actor(actorSeed), p)) _noteSuccess("swapPrepaidLimited");
    }

    /// @dev exact-in zeroForOne through the router that pays first; true if the swap stood
    function _prepaid(address a, SwapParams memory p) internal returns (bool ok) {
        uint256 reserveBefore = ghostFees[0] - ghostRebates[0];
        uint256 rebatesBefore = hook.rebatesPaid(Currency.wrap(address(token0)));
        Pre memory pre = _snap(a);
        vm.recordLogs();
        vm.prank(a);
        try prepay.swap{gas: CALL_GAS}(key, p) returns (BalanceDelta d) {
            ok = true;
            swapsOk += 1;
            if (hook.rebatesPaid(Currency.wrap(address(token0))) != rebatesBefore) {
                rebateWrong += 1;
                _broken("P7: a rebate was paid while the router's payment was in flight");
            }
            if (rebatesBefore > 0) _noteReached("prepaid swap with a rebate budget");
            // the pool filled less than was prepaid (no liquidity left, or the price limit): the router must have
            // handed the rest back, which P1 below checks from the payer's true balance
            if (d.amount0() != p.amountSpecified) _noteReached("prepaid swap filled short, the unused prepayment returned");
            if (d.amount0() != p.amountSpecified && d.amount0() != 0) {
                _noteReached("prepaid swap stopped by its price limit: part used, exactly the rest returned");
            }
            _checkSwap(a, p, d, pre, 0, reserveBefore);
        } catch (bytes memory err) {
            // a payment in flight: the hook pays no rebate (P7), so P9 has nothing to refuse
            _classifyPoolFailure(err, false, Fill.NoRebate);
        }
    }

    struct Pre {
        int256[2] actor;
        int256[2] hook;
        int256[2] mgr;
        int256[2] sink;
        int256[2] res;
    }

    function _snap(address a) internal view returns (Pre memory p) {
        for (uint256 c = 0; c < 2; c++) {
            HostileERC20 t = c == 0 ? token0 : token1;
            p.actor[c] = int256(t.trueBalanceOf(a));
            p.hook[c] = int256(t.trueBalanceOf(address(hook)));
            p.mgr[c] = int256(t.trueBalanceOf(address(manager)));
            p.sink[c] = int256(t.trueBalanceOf(t.FEE_SINK()));
            p.res[c] = int256(t.trueBalanceOf(t.RESERVE()));
        }
    }

    function _paramsFor(uint256 amount, bool zeroForOne, bool exactIn, bool limited)
        internal
        view
        returns (SwapParams memory p)
    {
        p.zeroForOne = zeroForOne;
        p.amountSpecified = exactIn ? -int256(amount) : int256(amount);
        if (!limited) {
            p.sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        } else {
            (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
            uint160 step = sqrtP >> 24;
            if (step == 0) step = 1;
            p.sqrtPriceLimitX96 = zeroForOne ? sqrtP - step : sqrtP + step;
        }
    }

    function _broken(string memory why) internal {
        lastBroken = why;
        lastBrokenAt = callsTotal;
    }

    function _doSwap(address a, uint256 amount, bool zeroForOne, bool exactIn, bool limited) internal returns (bool ok) {
        SwapParams memory p = _paramsFor(amount, zeroForOne, exactIn, limited);
        uint256 sc = exactIn == zeroForOne ? 0 : 1; // index of the specified currency
        uint256 reserveBefore = ghostFees[sc] - ghostRebates[sc];
        Pre memory pre = _snap(a);
        Forecast memory f = _forecastFill(p, sc);

        vm.recordLogs();
        vm.prank(a);
        try router.swap{gas: CALL_GAS}(key, p, "") returns (BalanceDelta d) {
            ok = true;
            swapsOk += 1;
            if (!exactIn) exactOutOk += 1;
            _checkSwap(a, p, d, pre, sc, reserveBefore);
            if (!limited) _checkForecast(f, sc);
        } catch (bytes memory err) {
            _classifyPoolFailure(err, limited, f.fill);
        }
    }

    struct Forecast {
        Fill fill;
        uint256 rebate; // the rebate P9's arithmetic says the hook will pay
        uint256 paidBefore; // the hook's `rebatesPaid` of the specified currency before the swap
    }

    /// @notice the forecast is held to every swap that STOOD, so it cannot drift into an excuse: a swap it called
    /// "short" must not stand, and the rebate the hook paid must be the one it computed. Without this a forecast that
    /// said "short" too often would turn every P9 refusal back into "expected" - the blind spot it replaced.
    function _checkForecast(Forecast memory f, uint256 sc) internal {
        uint256 paid = hook.rebatesPaid(Currency.wrap(address(sc == 0 ? token0 : token1))) - f.paidBefore;
        if (f.fill == Fill.Short || paid != f.rebate) {
            forecastWrong += 1;
            _broken("the P9 forecast disagreed with a swap that stood (the pool filled a swap called short, or another rebate was paid)");
        }
    }

    /// @notice P9's own arithmetic, done by the handler before the swap. The hook refuses a rebated swap unless the pool
    /// fills exactly `amountSpecified - rebate`: exact-in, the pool must TAKE `|amountSpecified| + rebate` of the input;
    /// exact-out, it must DELIVER `|amountSpecified| - rebate` of the output. Whether it can is a question about ONE
    /// currency: how far the pool's single range (every position in this suite is the same full range) lets the price
    /// travel in the swap's direction, and what that travel is worth in the specified currency. Liquidity alone does
    /// not answer it - a pool of 1e18 liquidity whose price sits near one end holds almost none of one side (the
    /// verifier's case: an exact-out of 4.5e17 of currency0 from a pool holding 1.9e17 of it). Nor does the manager's
    /// balance: it also holds donations and the providers' fees, which no swap can reach, and it bounds only outputs.
    function _forecastFill(SwapParams memory p, uint256 sc) internal view returns (Forecast memory f) {
        PoolId id = key.toId();
        Currency specified = Currency.wrap(address(sc == 0 ? token0 : token1));
        f.paidBefore = hook.rebatesPaid(specified);
        uint256 specAbs = p.amountSpecified < 0 ? uint256(-p.amountSpecified) : uint256(p.amountSpecified);
        // the rebate the hook will compute: nominal, cut to the block's budget and the pool's reserve (nothing is
        // synced before a MinimalRouter swap, so P7 does not apply here)
        uint256 rebate = hook.nominalRebateOf(specAbs);
        uint256 left = hook.rebateBudgetLeft(id, specified);
        if (rebate > left) rebate = left;
        uint256 poolReserve = hook.poolReserveOf(id, specified);
        if (rebate > poolReserve) rebate = poolReserve;
        // the hook's own transfers set to deliver short (`setShortDeliver` on the hook): the manager is credited, and
        // the rebate IS, only what arrived - and P9 compares the fill with that
        (,,, uint256 div,,,) = (sc == 0 ? token0 : token1).moveSwitch(address(hook));
        if (div > 1) rebate = rebate / div;
        f.rebate = rebate;
        if (rebate == 0) return f; // Fill.NoRebate
        f.fill = _fillOf(p, specAbs, rebate);
    }

    /// @dev can the pool's one range fill the rebated swap, from the price now to the range's end
    function _fillOf(SwapParams memory p, uint256 specAbs, uint256 rebate) internal view returns (Fill) {
        PoolId id = key.toId();

        // the range's liquidity (not the active liquidity: the price may sit outside the range) and the price, clamped
        // to the range: a swap walks through the empty part for free and then through the range
        (, int128 net) = manager.getTickLiquidity(id, tickLower);
        uint128 liq = net > 0 ? uint128(net) : 0;
        uint160 lo = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 hi = TickMath.getSqrtPriceAtTick(tickUpper);
        (uint160 sp,,,) = manager.getSlot0(id);
        if (sp < lo) sp = lo;
        if (sp > hi) sp = hi;
        uint160 end = p.zeroForOne ? lo : hi;

        uint256 need;
        uint256 cap;
        if (p.amountSpecified < 0) {
            need = specAbs + rebate;
            uint256 inNet = p.zeroForOne
                ? SqrtPriceMath.getAmount0Delta(end, sp, liq, true)
                : SqrtPriceMath.getAmount1Delta(sp, end, liq, true);
            uint256 fee = key.fee;
            cap = inNet + (inNet * fee + (1e6 - fee) - 1) / (1e6 - fee); // the LP fee on top, rounded up as the pool does
        } else {
            need = specAbs - rebate;
            cap = p.zeroForOne
                ? SqrtPriceMath.getAmount1Delta(end, sp, liq, false)
                : SqrtPriceMath.getAmount0Delta(sp, end, liq, false);
        }
        if (need + FILL_EDGE < cap) return Fill.Whole;
        if (need > cap + FILL_EDGE) return Fill.Short;
        return Fill.Edge;
    }

    function _checkSwap(address a, SwapParams memory p, BalanceDelta d, Pre memory pre, uint256 sc, uint256 reserveBefore)
        internal
    {
        (bool found, int128 pool0, int128 pool1) = SwapEventReader.lastSwapDelta(vm.getRecordedLogs(), address(manager));
        if (!found) {
            booksBroken += 1;
            _broken("a successful swap left no Swap event");
            return;
        }
        int256[2] memory pool = [int256(pool0), int256(pool1)];
        int256[2] memory caller = [int256(d.amount0()), int256(d.amount1())];
        Pre memory post = _snap(a);

        // P1, per currency, from true balances: nothing created or destroyed across the five parties a swap touches,
        // and the manager kept exactly the pool's delta
        for (uint256 c = 0; c < 2; c++) {
            int256 moved = (post.actor[c] - pre.actor[c]) + (post.hook[c] - pre.hook[c]) + (post.mgr[c] - pre.mgr[c])
                + (post.sink[c] - pre.sink[c]) + (post.res[c] - pre.res[c]);
            if (moved != 0 || post.mgr[c] - pre.mgr[c] != -pool[c]) {
                booksBroken += 1;
                _broken("P1: a swap's books do not balance");
            }
            // the hook never ends a swap richer than the manager booked it
            if (post.hook[c] - pre.hook[c] > pool[c] - caller[c]) {
                hookAboveBooked += 1;
                _broken("the hook's balance rose above its booked delta");
            }
        }

        uint256 uc = 1 - sc;
        int256 hSpec = pool[sc] - caller[sc];
        int256 hUnspec = pool[uc] - caller[uc];
        uint256 poolUnspecAbs = pool[uc] < 0 ? uint256(-pool[uc]) : uint256(pool[uc]);
        uint256 specAbs = p.amountSpecified < 0 ? uint256(-p.amountSpecified) : uint256(p.amountSpecified);

        // P2: the fee, exact, on the unspecified side
        if (hUnspec != int256(poolUnspecAbs * 30 / 10_000)) {
            feeWrong += 1;
            _broken("P2: the fee is not 0.30 % of the pool's unspecified amount");
        }
        if (hUnspec > 0) _noteReached("fee taken");
        // P3: the rebate, never a take, never above nominal
        if (hSpec > 0 || uint256(-hSpec) > specAbs * 10 / 10_000) {
            rebateWrong += 1;
            _broken("P3: the specified delta is a take, or above the nominal rebate");
            return;
        }
        uint256 rebate = uint256(-hSpec);

        // P5: the cap, modelled from the manager's books: fixed at the block's first successful swap on this
        // specified currency, from the reserve those books imply before it
        uint256 bn = vm.getBlockNumber();
        if (_modelBlock[sc] != bn) {
            _modelBlock[sc] = bn;
            _modelCap[sc] = reserveBefore * 1_000 / 10_000;
            _modelUsed[sc] = 0;
        }
        _modelUsed[sc] += rebate;
        if (_modelUsed[sc] > _modelCap[sc]) {
            capBroken += 1;
            _broken("P5: rebates in one block exceeded the cap");
        }

        if (rebate > 0) {
            rebatesSeen += 1;
            _noteReached("rebate paid");
            if (p.amountSpecified > 0) _noteReached("rebate on an exact-out swap");
            if (rebate < specAbs * 10 / 10_000) _noteReached("rebate cut by the block cap");
            // P9: a rebate only on a swap whose specified side is exactly what was asked
            if (caller[sc] != p.amountSpecified) {
                freeRebate += 1;
                _broken("P9: a rebate was paid on a swap the pool did not fill");
            }
        }
        if (p.amountSpecified > 0 && hUnspec > 0) _noteReached("fee on an exact-out swap");

        ghostFees[uc] += uint256(hUnspec);
        ghostRebates[sc] += rebate;
    }

    /// @notice what a refused swap means. Expected: a currency misbehaving, liquidity gone, a partial fill refused
    /// (P9). Unexpected: the manager rejecting what the hook RETURNED, a panic or a guard of the hook's own firing on a
    /// real swap, and - while every hostile switch is off - `CurrencyNotSettled`, which then can only be the hook
    /// leaving its own delta open (with a switch on, the router's own payment can arrive short and cause it).
    function _classifyPoolFailure(bytes memory err, bool limited, Fill forecast) internal {
        if (err.length >= 4) {
            bytes4 sel = bytes4(err);
            if (sel == Hooks.InvalidHookResponse.selector || sel == Hooks.HookDeltaExceedsSwapAmount.selector) {
                _unexpectedRevert("swap: the manager REJECTED what the hook returned");
                return;
            }
            if (sel == IPoolManager.CurrencyNotSettled.selector && calm) {
                _unexpectedRevert("swap: CurrencyNotSettled with every switch off - somebody's delta was left open");
                return;
            }
            if (sel == CustomRevert.WrappedError.selector && err.length >= 36) {
                (address target,, bytes memory reason,) = abi.decode(_tail(err), (address, bytes4, bytes, bytes));
                if (target == address(hook)) {
                    bytes4 inner = reason.length >= 4 ? bytes4(reason) : bytes4(0);
                    if (inner == DeltaFeeHook.RebateOnPartialFill.selector) {
                        // P9 is a GUARD of the hook's, and a guard can hide a bug: a hook whose own delta is wrong (a
                        // flipped sign, the wrong slot) moves the pool's specified amount and trips P9 on every swap
                        // with a rebate. (Measured: with every P9 refusal "expected", a sign-flipped rebate survived
                        // the whole campaign.) So a swap with no price limit is held to the forecast made before it
                        // was sent (`_forecastFill`, P9's own arithmetic against what the pool's range can fill):
                        // refused where the pool could fill it whole, or where no rebate was due at all, is a
                        // surprise. The forecast used to be "liquidity >= 1e18 fills any swap", which is false when
                        // the price sits near one end of the range (the verifier's red, pinned as
                        // `test_replay_P9_an_unlimited_exact_out_the_pool_cannot_fill_is_a_predicted_refusal`).
                        if (!limited) {
                            if (forecast == Fill.Whole) {
                                _unexpectedRevert("swap: P9 refused an UNLIMITED swap the pool could fill whole - the hook's own delta moved the fill");
                                return;
                            }
                            if (forecast == Fill.NoRebate) {
                                _unexpectedRevert("swap: P9 refused a swap on which no rebate was due");
                                return;
                            }
                            _noteReached(
                                forecast == Fill.Short
                                    ? "P9 refused an unlimited swap: predicted"
                                    : "P9 refused an unlimited swap at the pool's edge (within rounding)"
                            );
                        }
                        _noteReached("partial fill refused");
                        _expectedRevert();
                        return;
                    }
                    if (
                        inner == bytes4(0x4e487b71) // Panic(uint256)
                            || inner == DeltaFeeHook.NotTheManager.selector || inner == DeltaFeeHook.NotImplemented.selector
                    ) {
                        _unexpectedRevert("swap: the HOOK failed on its own (panic or its own guard)");
                        return;
                    }
                }
            }
        }
        _expectedRevert();
    }

    function _tail(bytes memory err) internal pure returns (bytes memory out) {
        out = new bytes(err.length - 4);
        for (uint256 i = 0; i < out.length; i++) out[i] = err[i + 4];
    }

    // ---------------------------------------------------------------- liquidity and the clock
    function addLiquidity(uint256 actorSeed, uint256 liq) public counted("addLiquidity") {
        address a = _actor(actorSeed);
        uint256 amount = bound(liq, 1e12, 1e18);
        vm.prank(a);
        try liquidity.modifyLiquidity{gas: CALL_GAS}(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(amount),
                salt: _saltOf(a)
            }),
            ""
        ) {
            liquidityOf[a] += amount;
            _noteSuccess("addLiquidity");
        } catch {
            _expectedRevert();
        }
    }

    function removeLiquidity(uint256 actorSeed, uint256 liq) public counted("removeLiquidity") {
        address a = _actor(actorSeed);
        uint256 have = liquidityOf[a];
        if (have == 0) {
            _expectedRevert();
            return;
        }
        uint256 amount = bound(liq, 1, have);
        vm.prank(a);
        try liquidity.modifyLiquidity{gas: CALL_GAS}(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(amount),
                salt: _saltOf(a)
            }),
            ""
        ) {
            liquidityOf[a] = have - amount;
            _noteSuccess("removeLiquidity");
        } catch {
            _expectedRevert();
        }
    }

    function nextBlock(uint256 n) public countedSetter("nextBlock") {
        uint256 blocks = bound(n, 1, 3);
        vm.roll(vm.getBlockNumber() + blocks);
        vm.warp(vm.getBlockTimestamp() + blocks * 12);
    }

    /// @notice the hook's own views, read mid-campaign: the budget it quotes can never exceed the cap of its reserve
    function readBudget(uint256 whichWord) public counted("readBudget") {
        Currency c = _bit(whichWord) ? Currency.wrap(address(token1)) : Currency.wrap(address(token0));
        try hook.rebateBudgetLeft(key.toId(), c) returns (uint256 left) {
            require(left <= hook.reserveOf(c), "the hook quotes a rebate budget above what it holds");
            _noteSuccess("readBudget");
        } catch {
            _unexpectedRevert("rebateBudgetLeft reverted");
        }
    }

    // ---------------------------------------------------------------- the strange actors
    /// @notice tokens pushed at the hook. They fund NO rebate (the ledger counts only what the hook received from the
    /// manager): "no free rebate" has to survive a hook that is richer than its books.
    function donateToHook(uint256 amount, uint256 whichWord) public countedSetter("donateToHook") {
        bool which = _bit(whichWord);
        uint256 v = bound(amount, 0, 1e18);
        HostileERC20 t = which ? token1 : token0;
        t.mint(address(hook), v);
        _noteDonation(address(hook), address(t), v);
        if (which) minted1 += v;
        else minted0 += v;
    }

    function donateToManager(uint256 amount, uint256 whichWord) public countedSetter("donateToManager") {
        bool which = _bit(whichWord);
        uint256 v = bound(amount, 0, 1e18);
        HostileERC20 t = which ? token1 : token0;
        t.mint(address(manager), v);
        _noteDonation(address(manager), address(t), v);
        if (which) minted1 += v;
        else minted0 += v;
    }

    // ---------------------------------------------------------------- the currencies misbehaving (biased to honest)
    function setFeeOnTransfer(uint256 bps, uint256 whichWord) public countedSetter("setFeeOnTransfer") {
        uint256 v = bound(bps, 0, 500);
        uint256 fee = v <= 250 ? 0 : v;
        if (fee != 0) calm = false;
        (_bit(whichWord) ? token1 : token0).setFeeBps(fee);
    }

    function setPaused(uint256 onWord, uint256 whichWord) public countedSetter("setPaused") {
        bool on = _bitOneIn(onWord, 4);
        if (on) calm = false;
        (_bit(whichWord) ? token1 : token0).setPaused(on);
    }

    /// @notice short delivery FROM an actor or FROM THE HOOK: the hook's rebate transfer arriving short is the case
    /// where "return what the manager credited, not what you meant to pay" matters (P6)
    function setShortDeliver(uint256 whoSeed, uint256 div, uint256 whichWord) public countedSetter("setShortDeliver") {
        address who = _bitOneIn(whoSeed >> 8, 3) ? address(hook) : _actor(whoSeed);
        uint256 dv = bound(div, 0, 4);
        // the hook's OWN transfers delivering short cannot make the router's payment short: the books must still close
        // (P6), so a CurrencyNotSettled then is still a surprise - `calm` tracks only what can short the router's side
        if (dv > 1 && who != address(hook)) calm = false;
        (_bit(whichWord) ? token1 : token0).setShortDeliver(who, dv);
    }

    function setManagerBlocked(uint256 onWord, uint256 whichWord) public countedSetter("setManagerBlocked") {
        bool on = _bitOneIn(onWord, 4);
        if (on) calm = false;
        (_bit(whichWord) ? token1 : token0).setBlockIncoming(address(manager), on);
    }

    function calmDown() public countedSetter("calmDown") {
        token0.setPaused(false);
        token1.setPaused(false);
        token0.setFeeBps(0);
        token1.setFeeBps(0);
        token0.setBlockIncoming(address(manager), false);
        token1.setBlockIncoming(address(manager), false);
        token0.setShortDeliver(address(hook), 0);
        token1.setShortDeliver(address(hook), 0);
        for (uint256 i = 0; i < actors.length; i++) {
            token0.setShortDeliver(actors[i], 0);
            token1.setShortDeliver(actors[i], 0);
        }
        calm = true;
    }
}

contract DeltaFeeHookInvariants is V4Harness, InvariantAsserts {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    DeltaFeeHook internal hook;
    DeltaFeeHandler internal handler;
    DeltaTruthReader internal truth0;
    DeltaTruthReader internal truth1;
    PoolKey internal key;

    function setUp() public {
        _setUpManager();
        _deployCurrencies();
        _deployRouters();
        (, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG,
            type(DeltaFeeHook).creationCode,
            abi.encode(manager)
        );
        hook = new DeltaFeeHook{salt: salt}(manager);
        key = _initPool(IHooks(address(hook)), 3000, 60, SQRT_PRICE_1_1);
        (int24 lower, int24 upper) = _fullRange(60);
        truth0 = new DeltaTruthReader(token0);
        truth1 = new DeltaTruthReader(token1);
        handler = new DeltaFeeHandler(manager, hook, router, liquidity, token0, token1, key, lower, upper);
        handler.seed(100_000e18, 50e18);

        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](17);
        sel[15] = DeltaFeeHandler.swapPrepaid.selector;
        sel[16] = DeltaFeeHandler.swapPrepaidLimited.selector;
        sel[0] = DeltaFeeHandler.fund.selector;
        sel[1] = DeltaFeeHandler.swap.selector;
        sel[2] = DeltaFeeHandler.swapBurst.selector;
        sel[3] = DeltaFeeHandler.swapLimited.selector;
        sel[4] = DeltaFeeHandler.addLiquidity.selector;
        sel[5] = DeltaFeeHandler.removeLiquidity.selector;
        sel[6] = DeltaFeeHandler.nextBlock.selector;
        sel[7] = DeltaFeeHandler.readBudget.selector;
        sel[8] = DeltaFeeHandler.donateToHook.selector;
        sel[9] = DeltaFeeHandler.donateToManager.selector;
        sel[10] = DeltaFeeHandler.setFeeOnTransfer.selector;
        sel[11] = DeltaFeeHandler.setPaused.selector;
        sel[12] = DeltaFeeHandler.setShortDeliver.selector;
        sel[13] = DeltaFeeHandler.setManagerBlocked.selector;
        sel[14] = DeltaFeeHandler.calmDown.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        assertEq(sel.length, 17, "the selector list and the handler have drifted apart");
    }

    function afterInvariant() public virtual {
        handler.writeCensus("DeltaFeeHook");
        handler.printCallSummary();
        handler.printReachSummary();
        console2.log("CAMPAIGN swapsOk", handler.swapsOk());
        console2.log("CAMPAIGN exactOutOk", handler.exactOutOk());
        console2.log("CAMPAIGN rebatesSeen", handler.rebatesSeen());
    }

    function _reason(string memory what) internal view returns (string memory) {
        return string.concat(what, " (last: ", handler.lastBroken(), ")");
    }

    // ------------------------------------------------------------------ the hook's promises
    /// @notice P1: every swap's books balance per currency over swapper, hook, manager, fee sink and token reserve, the
    /// manager keeps exactly the pool's delta, and the hook never gains more than the manager booked for it
    function invariant_every_swap_balances_and_the_hook_gets_only_its_booked_delta() public view {
        assertEq(handler.booksBroken(), 0, _reason("P1"));
        assertEq(handler.hookAboveBooked(), 0, _reason("hook above its booked delta"));
    }

    /// @notice P2: the fee is exactly 0.30 % of the pool's unspecified amount, in the unspecified currency
    function invariant_the_fee_is_exact_and_on_the_unspecified_side() public view {
        assertEq(handler.feeWrong(), 0, _reason("P2"));
    }

    /// @notice P3 and P5: the specified delta is never a take, never above nominal, and a block's rebates in a currency
    /// never exceed 10 % of the reserve the manager's books implied at the block's first swap on it
    function invariant_the_rebate_is_bounded_and_capped_per_block() public view {
        assertEq(handler.rebateWrong(), 0, _reason("P3"));
        assertEq(handler.capBroken(), 0, _reason("P5"));
    }

    /// @notice P4 and P9: NO FREE REBATE. Per currency: rebates never exceed fees (in the manager's books), the hook's
    /// own ledger agrees with those books, it holds exactly its ledger plus what was pushed at it, and no rebate was
    /// paid on a swap the pool did not fill
    function invariant_no_free_rebate() public view {
        assertEq(handler.freeRebate(), 0, _reason("P9"));
        for (uint256 c = 0; c < 2; c++) {
            Currency cur = Currency.wrap(address(c == 0 ? token0 : token1));
            IBalanceReader t = IBalanceReader(address(c == 0 ? truth0 : truth1));
            assertLe(handler.ghostRebates(c), handler.ghostFees(c), "P4: rebates exceeded fees");
            assertEq(hook.feesBooked(cur), handler.ghostFees(c), "the hook's fee ledger disagrees with the manager");
            assertEq(hook.rebatesPaid(cur), handler.ghostRebates(c), "the hook's rebate ledger disagrees with the manager");
            assertEq(
                t.balanceOf(address(hook)),
                hook.reserveOf(cur) + handler.ghostDonated(address(hook), address(c == 0 ? token0 : token1)),
                "the hook holds other than its ledger plus donations"
            );
            assertLe(hook.rebateBudgetLeft(key.toId(), cur), hook.reserveOf(cur), "a budget above the reserve");
        }
    }

    function invariant_the_router_and_the_helper_are_empty_between_actions() public view {
        assertEq(token0.trueBalanceOf(address(router)), 0, "router kept currency0");
        assertEq(token1.trueBalanceOf(address(router)), 0, "router kept currency1");
        assertEq(token0.trueBalanceOf(address(liquidity)), 0, "helper kept currency0");
        assertEq(token1.trueBalanceOf(address(liquidity)), 0, "helper kept currency1");
    }

    /// @notice the generic one, WITH the hook in the holder list: a delta hook holds value, and a conservation check
    /// that leaves it out reports its whole balance as tokens destroyed
    function invariant_currency0_is_conserved() public view {
        assertConserved(IBalanceReader(address(truth0)), handler.holders(), handler.minted0(), "currency0");
    }

    function invariant_currency1_is_conserved() public view {
        assertConserved(IBalanceReader(address(truth1)), handler.holders(), handler.minted1(), "currency1");
    }

    function invariant_no_unexplained_reverts() public view {
        assertEq(
            handler.revertsUnexpected(),
            0,
            string.concat("the handler met a failure it did not predict: ", handler.lastUnexpected())
        );
        // the prediction is held to the swaps that stood too, or "predicted" could become a blanket excuse
        assertEq(handler.forecastWrong(), 0, _reason("the P9 forecast"));
    }

    // ------------------------------------------------------------------ shrunk sequences from the campaign
    /// @notice the campaign's first catch in CI (two runs, two seeds, the same three calls; `doctrine/NEXT.md` row 5):
    /// the only provider takes ALL its liquidity out, another actor is funded, and a prepaid exact-in swap runs on a
    /// pool with no liquidity. The pool fills nothing, so the prepaying router has paid for a swap that did not
    /// happen: its prepayment must come back to the payer, or the unlock cannot close.
    function test_ci_replay_a_prepaid_swap_on_a_pool_emptied_of_liquidity() public {
        // run 36013019422, seed 0x9684d3bc...3dac: removeLiquidity binds 3e21 to the whole 50e18
        handler.removeLiquidity(1_000_000_000, 3_000_000_000_000_000_000_000);
        assertEq(manager.getLiquidity(key.toId()), 0, "replay: the pool still has liquidity");
        handler.fund(165_577_562_928_883_747_114_875_185_255_186, 654_755_058_787);
        address payer = address(0x6001); // actor 23 956 % 5
        uint256 before0 = token0.trueBalanceOf(payer);
        handler.swapPrepaid(23_956, 147_028_384);
        invariant_no_unexplained_reverts();
        assertEq(handler.successesOf("swapPrepaid"), 1, "replay: the prepaid swap did not stand");
        assertEq(token0.trueBalanceOf(payer), before0, "replay: the payer lost its prepayment to a swap that filled nothing");
        handler.assertReached("prepaid swap filled short, the unused prepayment returned", 1);
        _allInvariants();
    }

    /// @notice the same catch from run 36010657863 (seed 0x1649f0c6...8579): the whole liquidity again, 128 wei prepaid
    function test_ci_replay_a_prepaid_swap_on_a_pool_emptied_of_liquidity_second_run() public {
        handler.removeLiquidity(
            33_000_754_858_910_868_398_267_428_534_851_208_763_725_614_360_198_736_648_331_173_735_321_529_483_265,
            100_000_000_000_000_000_000_000
        );
        assertEq(manager.getLiquidity(key.toId()), 0, "replay: the pool still has liquidity");
        handler.fund(20_125_707_078_920_429_269_254_013_612_690_055_421, 5_423);
        address payer = address(0x6001); // actor 1 996 % 5
        uint256 before0 = token0.trueBalanceOf(payer);
        handler.swapPrepaid(1_996, 128);
        invariant_no_unexplained_reverts();
        assertEq(handler.successesOf("swapPrepaid"), 1, "replay: the prepaid swap did not stand");
        assertEq(token0.trueBalanceOf(payer), before0, "replay: the payer lost its prepayment to a swap that filled nothing");
        _allInvariants();
    }

    /// @notice the campaign's second catch, found by the verifier on the same seeds (a red in the HANDLER, not in the
    /// hook): liquidity drained to almost nothing, a burst pushes the price far to one side, liquidity comes back, and a
    /// second burst of exact-out swaps asks the pool for more of the scarce currency than it holds. The pool fills
    /// short, the hook refuses the rebated swap (P9) - correctly. The handler used to call that refusal a surprise
    /// because the pool's liquidity was >= 1e18; liquidity says nothing about how much of ONE currency the pool holds.
    /// Seven calls, shrunk from seed 0x9684d3bc...3dac (the first CI run's) on the tree before the router fix.
    function test_replay_P9_an_unlimited_exact_out_the_pool_cannot_fill_is_a_predicted_refusal() public {
        handler.fund(1, 1_000_000_000_000_000_000_000);
        handler.addLiquidity(6756, 9188);
        handler.removeLiquidity(255, 1_000_000_000_000_000_000_000);
        handler.swapBurst(
            21_000, 61678357398080765210293718086378416697372618187842506566286863523773954249005, 1_000_000_000_000, 500
        );
        handler.addLiquidity(255, 1_000_000_000_000_000_000_000);
        handler.swapBurst(
            4_004_159_087,
            1_700_000_000,
            49959367603673595303297320131006763953537934668055001659846536947750116786176,
            57896044618658097711785492504343953926634992332820282019728792003956564819968
        );
        handler.setFeeOnTransfer(725, 15);
        invariant_no_unexplained_reverts();
        handler.assertReached("P9 refused an unlimited swap: predicted", 1);
        _allInvariants();
    }

    /// @notice the same refusal on the tree WITH the router fix, nine calls shrunk from seed 0x5eed (red on the
    /// verifier's bench, green on the fixer's with identical files: a pinned seed is evidence on one bench only)
    function test_replay_P9_the_same_refusal_after_the_router_fix() public {
        handler.fund(1, 1_000_000_000_000_000_000_000);
        handler.swap(1, 500_000_000_000_000_000, 2, 1);
        handler.addLiquidity(0, 100_000_000_000_000_000);
        handler.removeLiquidity(0, 98079714615416886934934209737619787751609303819750539264);
        handler.swapBurst(96, 10_620, 1_971, 14);
        handler.setShortDeliver(485053260817066172746253684029974021, 4_738, 1_996);
        handler.nextBlock(3_892);
        handler.swapBurst(
            16, 36271603392835451902015514392751374211422416918959581591278453706336191381505, 654_755_058_787, 100
        );
        handler.setPaused(24_049, 8);
        invariant_no_unexplained_reverts();
        handler.assertReached("P9 refused an unlimited swap: predicted", 1);
        _allInvariants();
    }

    /// @notice a prepaid swap the pool stops at its PRICE LIMIT: part of the prepayment used, the rest the router's
    /// credit. The payer must end exactly where the router that pays afterwards leaves it on the same state - which
    /// kills a router that hands back its whole credit instead of the unused part (with every earlier prepaid swap the
    /// pool used all of it or none of it, and the two answers coincide).
    function test_a_prepaid_swap_stopped_by_its_price_limit_pays_exactly_what_the_pool_used() public {
        handler.fund(1, 1_000e18);
        address payer = address(0x6001); // actor 1 % 5
        (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: -5e17, sqrtPriceLimitX96: sqrtP - (sqrtP >> 12)});

        // both routers straight at the pool, each from the same state and undone afterwards (the handler's model of
        // the hook's books counts only the swaps it drives)
        uint256 snap = vm.snapshotState();
        vm.prank(payer);
        BalanceDelta paidAfter = router.swap(key, p, "");
        uint256 payerAfterMinimal = token0.trueBalanceOf(payer);
        vm.revertToState(snap);

        snap = vm.snapshotState();
        PrepayRouter prepay = handler.prepay();
        uint256 before0 = token0.trueBalanceOf(payer);
        vm.prank(payer);
        BalanceDelta d = prepay.swap(key, p);
        assertTrue(d.amount0() < 0 && d.amount0() > p.amountSpecified, "not a partial fill that used something");
        assertEq(d.amount0(), paidAfter.amount0(), "the two routers filled differently");
        assertEq(int256(token0.trueBalanceOf(payer)) - int256(before0), d.amount0(), "the payer paid other than the pool used");
        assertEq(token0.trueBalanceOf(payer), payerAfterMinimal, "the prepaying router left the payer elsewhere");
        assertEq(token0.trueBalanceOf(address(prepay)), 0, "the prepaying router kept currency0");
        vm.revertToState(snap);

        // and the campaign's action on the same shape
        handler.swapPrepaidLimited(1, 5e17, 12);
        handler.assertReached("prepaid swap stopped by its price limit: part used, exactly the rest returned", 1);
        _allInvariants();
    }

    function _allInvariants() internal view {
        invariant_every_swap_balances_and_the_hook_gets_only_its_booked_delta();
        invariant_the_fee_is_exact_and_on_the_unspecified_side();
        invariant_the_rebate_is_bounded_and_capped_per_block();
        invariant_no_free_rebate();
        invariant_the_router_and_the_helper_are_empty_between_actions();
        invariant_currency0_is_conserved();
        invariant_currency1_is_conserved();
        invariant_no_unexplained_reverts();
    }

    // ------------------------------------------------------------------ non vacuity
    function test_handler_smoke() public {
        handler.fund(1, 1_000e18);
        handler.fund(2, 1_000e18);
        // a fresh hook holds nothing: fill both reserves first, or no rebate can ever be paid
        for (uint256 i = 0; i < 4; i++) {
            handler.swap(1, 5e17, i, YES);
        }
        handler.nextBlock(1);
        handler.swap(1, 1e17, YES, NO); // exact-out, zeroForOne: rebate + fee on the input
        handler.swap(2, 1e17, NO, NO); // exact-out, oneForZero
        handler.swapBurst(1, 5e17, 8, 1 | (1 << 8)); // exact-in bursts until the cap cuts
        handler.nextBlock(1);
        handler.swapLimited(2, 5e17, YES); // a rebate in play: refused (P9)
        handler.swapPrepaid(2, 1e17); // a payment in flight: no rebate (P7)
        handler.swapPrepaidLimited(2, 5e17, 12); // stopped by its limit: part used, the rest returned
        handler.readBudget(NO);
        handler.addLiquidity(0, 1e17);
        handler.removeLiquidity(0, 1e16);
        handler.donateToHook(1e17, NO);
        handler.donateToManager(1e17, YES);
        handler.nextBlock(1);
        handler.setShortDeliver(1 << 8, 2, NO); // the HOOK's token0 transfers deliver half
        handler.swap(2, 1e17, YES, YES); // exact-in zeroForOne: the hook pays a token0 rebate, short
        handler.setFeeOnTransfer(400, NO);
        handler.swap(1, 1e17, YES, YES);
        handler.setPaused(YES, YES);
        handler.swap(1, 1e17, NO, YES);
        handler.setManagerBlocked(YES, NO);
        handler.swap(1, 1e17, YES, YES);
        handler.calmDown();
        handler.swap(0, 1e17, NO, YES);

        handler.printCallSummary();
        handler.printReachSummary();
        handler.assertExercised("swap", 6);
        handler.assertExercised("swapBurst", 1);
        handler.assertReached("fee taken", 5);
        handler.assertReached("rebate paid", 3);
        handler.assertReached("rebate on an exact-out swap", 1);
        handler.assertReached("fee on an exact-out swap", 1);
        handler.assertReached("rebate cut by the block cap", 1);
        handler.assertReached("partial fill refused", 1);
        handler.assertReached("prepaid swap with a rebate budget", 1);
        handler.assertExercised("swapPrepaid", 1);
        handler.assertExercised("swapPrepaidLimited", 1);
        handler.assertReached("prepaid swap stopped by its price limit: part used, exactly the rest returned", 1);
        assertGt(handler.exactOutOk(), 1, "no exact-out swap succeeded");
        assertGt(handler.revertsExpected(), 0, "the hostile branches were never reached");

        invariant_every_swap_balances_and_the_hook_gets_only_its_booked_delta();
        invariant_the_fee_is_exact_and_on_the_unspecified_side();
        invariant_the_rebate_is_bounded_and_capped_per_block();
        invariant_no_free_rebate();
        invariant_the_router_and_the_helper_are_empty_between_actions();
        invariant_currency0_is_conserved();
        invariant_currency1_is_conserved();
        invariant_no_unexplained_reverts();
    }
}
