// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {HostileERC20} from "gauntlet-kit/HostileERC20.sol";
import {HandlerBase, InvariantAsserts} from "gauntlet-kit/InvariantBase.sol";
import {V4Harness} from "../../src/V4Harness.sol";
import {MinimalRouter} from "../../src/MinimalRouter.sol";
import {LiquidityHelper} from "../../src/LiquidityHelper.sol";
import {DeltaFeeHook} from "../../src/examples/DeltaFeeHook.sol";

/// @notice what the multi-pool tests share: the delta example serving TWO pools that have one currency in common
/// (`shared`, the harness's token0): pool A = token0 / token1, pool B = token0 / token2. A hook serves every pool that
/// names it - nobody asks the hook first - so pool B can be anybody's.
abstract contract MultiPoolBase is V4Harness {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    DeltaFeeHook internal hook;
    HostileERC20 internal token2;
    PoolKey internal poolA;
    PoolKey internal poolB;
    address internal provider = address(0xA11CE);
    address internal trader = address(0xB0B);

    function _deployMultiPool() internal {
        _setUpV4();
        hook = DeltaFeeHook(
            _deployHook(
                type(DeltaFeeHook).creationCode,
                abi.encode(manager),
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                    | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            )
        );
        token2 = new HostileERC20("Hostile C", "HOSC", 18);
        vm.label(address(token2), "token2");
        _fundAndApprove(provider, 1_000_000e18);
        _fundAndApprove(trader, 1_000_000e18);
        _mintAndApprove(token2, provider, 1_000_000e18);
        _mintAndApprove(token2, trader, 1_000_000e18);
        poolA = _initPool(IHooks(address(hook)), 3000, 60, SQRT_PRICE_1_1);
        poolB = _pairKey(address(token0), address(token2));
        manager.initialize(poolB, SQRT_PRICE_1_1);
        _addFullRangeLiquidity(poolA, provider, 100e18);
        _addFullRangeLiquidity(poolB, provider, 100e18);
    }

    function _mintAndApprove(HostileERC20 t, address who, uint256 amount) internal {
        t.mint(who, amount);
        vm.startPrank(who);
        t.approve(address(router), type(uint256).max);
        t.approve(address(liquidity), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice a pool of `a` and `b` on the hook, sorted as v4 requires, fee 0.30 %, spacing 60
    function _pairKey(address a, address b) internal view returns (PoolKey memory) {
        (address lo, address hi) = a < b ? (a, b) : (b, a);
        return PoolKey({
            currency0: Currency.wrap(lo),
            currency1: Currency.wrap(hi),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    /// @notice swap `amount` of `input` IN (exact-in) or OUT of the other currency (exact-out, `input` still paid) on `k`
    function _params(PoolKey memory k, address input, bool exactIn, uint256 amount)
        internal
        pure
        returns (SwapParams memory)
    {
        bool zeroForOne = Currency.unwrap(k.currency0) == input;
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactIn ? -int256(amount) : int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    /// @notice the hook's rebate on this swap, as the manager booked it (the negative of its specified delta)
    function _rebateOf(SwapParams memory p, SwapBooks memory b) internal pure returns (uint256) {
        bool s0 = (p.amountSpecified < 0) == p.zeroForOne;
        int256 spec = s0 ? b.pool0 - b.caller0 : b.pool1 - b.caller1;
        return spec < 0 ? uint256(-spec) : 0;
    }

    /// @notice fees into the hook from `k` in both of its currencies: three swaps each way, then a new block
    function _earnOn(PoolKey memory k) internal {
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(trader);
            router.swap(k, _params(k, Currency.unwrap(k.currency0), true, 1e18), "");
            vm.prank(trader);
            router.swap(k, _params(k, Currency.unwrap(k.currency1), true, 1e18), "");
        }
        vm.roll(vm.getBlockNumber() + 1);
    }
}

/// @notice ITEM 3 of K15, the unit half: what the delta example's per-currency state does when two pools share a currency.
/// Until K15 its reserve and its per-block cap were keyed by CURRENCY, hook-wide; the three tests below were red on that
/// hook (the numbers are in the README, "Two pools, one currency") and the hook now keys both by pool AND currency.
contract DeltaFeeHookMultiPoolTest is MultiPoolBase {
    using PoolIdLibrary for PoolKey;

    function setUp() public {
        _deployMultiPool();
    }

    /// @notice a pool's rebates are paid out of THAT pool's fees. Pool A earns token0; pool B has earned nothing; a swap
    /// on pool B that specifies token0 gets no rebate. Red on the hook-wide reserve: pool B was paid out of pool A's
    /// token0 fees.
    function test_a_swap_on_one_pool_is_not_paid_out_of_another_pools_reserve() public {
        _earnOn(poolA);
        uint256 shared = hook.reserveOf(currency0);
        assertGt(shared, 0, "test setup: pool A earned no token0");
        SwapParams memory p = _params(poolB, address(token0), true, 1e17);
        SwapBooks memory b = _swapWithBooks(trader, poolB, p);
        assertEq(_rebateOf(p, b), 0, "pool B was paid a rebate out of pool A's fees");
        assertGe(hook.reserveOf(currency0), shared, "pool A's token0 reserve paid for pool B");
    }

    /// @notice the per-block cap is a pool's own. Both pools earn; in the next block pool B's swaps spend ITS whole cap in
    /// token0; a swap on pool A in the same block is still paid its full rebate. Red on the hook-wide cap: pool A got 0.
    function test_one_pools_swaps_do_not_spend_another_pools_block_cap() public {
        _earnOn(poolA);
        _earnOn(poolB);
        uint256 cut;
        for (uint256 i = 0; i < 12; i++) {
            SwapParams memory q = _params(poolB, address(token0), true, 1e18);
            SwapBooks memory c = _swapWithBooks(trader, poolB, q);
            if (_rebateOf(q, c) < hook.nominalRebateOf(1e18)) cut += 1;
        }
        assertGt(cut, 0, "test setup: pool B never reached its cap");
        SwapParams memory p = _params(poolA, address(token0), true, 1e17);
        SwapBooks memory b = _swapWithBooks(trader, poolA, p);
        assertEq(_rebateOf(p, b), hook.nominalRebateOf(1e17), "pool B's swaps spent pool A's block cap");
    }

    /// @notice the drain, by a pool nobody approved. Anybody can create a pool on this hook with a currency of their own
    /// (`evil`, worthless: they mint it) against the shared one, be its only liquidity provider, and swap the shared
    /// currency in: the rebate is paid in the shared currency, the hook's fee in `evil`, the swap's input and the rebate
    /// both end in the pool, and the provider takes them back out. Measured on the hook-wide reserve: the attacker
    /// ended the block with exactly the shared currency's cap for the block (10 % of what pool A had earned) more than
    /// it started with, and pool A's reserve paid for it. With the reserve per pool, the attacker's pool has earned no
    /// token0 and pays none: the attacker ends with at most what it started with.
    function test_a_pool_nobody_approved_cannot_drain_the_rebates_another_pool_earned() public {
        _earnOn(poolA);
        uint256 shared = hook.reserveOf(currency0);
        address attacker = address(0xBAD);
        HostileERC20 evil = new HostileERC20("Evil", "EVIL", 18);
        _mintAndApprove(evil, attacker, 1_000_000e18);
        token0.mint(attacker, 1_000e18);
        vm.startPrank(attacker);
        token0.approve(address(router), type(uint256).max);
        token0.approve(address(liquidity), type(uint256).max);
        vm.stopPrank();
        uint256 attacker0 = token0.trueBalanceOf(attacker);

        PoolKey memory k = _pairKey(address(token0), address(evil));
        manager.initialize(k, SQRT_PRICE_1_1);
        _addFullRangeLiquidity(k, attacker, 100e18);
        for (uint256 i = 0; i < 12; i++) {
            vm.prank(attacker);
            router.swap(k, _params(k, address(token0), true, 1e18), "");
        }
        _addFullRangeLiquidity(k, attacker, -100e18);

        int256 gain = int256(token0.trueBalanceOf(attacker)) - int256(attacker0);
        console2.log("attacker's token0 gain over one block:", vm.toString(gain));
        console2.log("pool A's token0 reserve before / after:", shared, hook.reserveOf(currency0));
        assertLe(gain, 0, "a pool nobody approved drained the rebates pool A earned");
        assertGe(hook.reserveOf(currency0), shared, "pool A's reserve paid for the attacker's pool");
    }
}

/// @notice The multi-pool campaign: two pools on one `DeltaFeeHook`, sharing token0. Every swap is read from the hook's
/// TRUE balances in the pool's two currencies (honest tokens: its balance moves by exactly its booked delta), and booked
/// to (pool, currency): a gain is a fee, a loss a rebate. The model is the manager's books, never the hook's ledger.
contract DeltaFeeMultiPoolHandler is HandlerBase {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant CAP_BPS = 1_000;
    uint256 internal constant BPS = 10_000;

    DeltaFeeHook public immutable hook;
    MinimalRouter public immutable router;
    HostileERC20[3] internal tokens; // token0 (shared), token1 (pool A), token2 (pool B)
    PoolKey[2] internal keys;

    /// @notice per pool and per token index: fees the hook received, rebates it paid, from its true balances
    mapping(uint256 => mapping(uint256 => uint256)) public ghostFees;
    mapping(uint256 => mapping(uint256 => uint256)) public ghostRebates;
    /// @notice the model of each pool's per-block cap, per token: the block, the cap fixed at the block's first swap on
    /// that pool that specified the token, what was paid since
    mapping(uint256 => mapping(uint256 => uint256)) internal _capBlock;
    mapping(uint256 => mapping(uint256 => uint256)) internal _cap;
    mapping(uint256 => mapping(uint256 => uint256)) internal _used;
    uint256 public capBroken;
    uint256 public foreignRebate;
    string public lastCapBroken;
    string public lastForeignRebate;

    constructor(
        DeltaFeeHook hook_,
        MinimalRouter router_,
        HostileERC20 t0,
        HostileERC20 t1,
        HostileERC20 t2,
        PoolKey memory a,
        PoolKey memory b
    ) {
        hook = hook_;
        router = router_;
        tokens = [t0, t1, t2];
        keys[0] = a;
        keys[1] = b;
        for (uint256 i = 0; i < 3; i++) {
            address actor = address(uint160(0xC0FFEE + i));
            _addActor(actor);
            for (uint256 t = 0; t < 3; t++) {
                tokens[t].mint(actor, 1_000_000e18);
                vm.prank(actor);
                tokens[t].approve(address(router), type(uint256).max);
            }
        }
    }

    function keyOf(uint256 p) external view returns (PoolKey memory) {
        return keys[p];
    }

    /// @notice the token index (0, 1, 2) of a currency of pool `p`
    function _idx(uint256 p, Currency c) internal view returns (uint256) {
        if (Currency.unwrap(c) == address(tokens[0])) return 0;
        return p == 0 ? 1 : 2;
    }

    /// @notice what pool `p` has left the hook in token `t`, by its own books (0 if it paid out more than it earned: the
    /// per-pool invariant reports that)
    function ghostReserve(uint256 p, uint256 t) public view returns (uint256) {
        return ghostFees[p][t] > ghostRebates[p][t] ? ghostFees[p][t] - ghostRebates[p][t] : 0;
    }

    function swap(uint256 actorSeed, uint256 poolWord, uint256 amount, uint256 dirWord, uint256 exactInWord)
        public
        counted("swap")
    {
        if (_swap(actorSeed, poolWord % 2, bound(amount, 1e12, 1e18), _bit(dirWord), _bit(exactInWord))) {
            _noteSuccess("swap");
        }
    }

    /// @notice several swaps on one pool in one block, the same way: what reaches a pool's cap
    function swapBurst(uint256 actorSeed, uint256 poolWord, uint256 amount, uint256 n) public counted("swapBurst") {
        n = bound(n, 2, 12);
        bool all = true;
        for (uint256 i = 0; i < n; i++) {
            if (!_swap(actorSeed, poolWord % 2, bound(amount, 1e16, 1e18), _bit(poolWord >> 1), true)) all = false;
        }
        if (all) _noteSuccess("swapBurst");
    }

    function nextBlock(uint256 n) public countedSetter("nextBlock") {
        vm.roll(vm.getBlockNumber() + bound(n, 1, 3));
    }

    /// @return ok the swap stood (any failure is unexplained: every swap here is unlimited on a liquid pool)
    function _swap(uint256 actorSeed, uint256 p, uint256 amount, bool zeroForOne, bool exactIn)
        internal
        returns (bool ok)
    {
        address a = _actor(actorSeed);
        PoolKey memory k = keys[p];
        SwapParams memory sp = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactIn ? -int256(amount) : int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        uint256 i0 = _idx(p, k.currency0);
        uint256 i1 = _idx(p, k.currency1);
        uint256 h0 = tokens[i0].trueBalanceOf(address(hook));
        uint256 h1 = tokens[i1].trueBalanceOf(address(hook));
        bool s0 = exactIn == zeroForOne;
        uint256 iSpec = s0 ? i0 : i1;
        // the model's cap for (p, specified), fixed before anything is paid, from the MANAGER's books of pool p alone
        if (_capBlock[p][iSpec] != block.number) {
            _capBlock[p][iSpec] = block.number;
            _cap[p][iSpec] = ghostReserve(p, iSpec) * CAP_BPS / BPS;
            _used[p][iSpec] = 0;
        }
        vm.prank(a);
        try router.swap(k, sp, "") {
            ok = true;
        } catch (bytes memory err) {
            _unexpectedRevert(string.concat("a plain swap on pool ", vm.toString(p), " failed: ", vm.toString(err)));
            return false;
        }
        uint256 post0 = tokens[i0].trueBalanceOf(address(hook));
        uint256 post1 = tokens[i1].trueBalanceOf(address(hook));
        _book(p, i0, h0, post0);
        _book(p, i1, h1, post1);
        (uint256 preSpec, uint256 postSpec) = s0 ? (h0, post0) : (h1, post1);
        uint256 rebate = preSpec > postSpec ? preSpec - postSpec : 0;
        if (rebate > 0) {
            _noteReached(p == 0 ? "rebate paid on pool A" : "rebate paid on pool B");
            _used[p][iSpec] += rebate;
            if (_used[p][iSpec] > _cap[p][iSpec]) {
                capBroken += 1;
                lastCapBroken = string.concat(
                    "pool ",
                    vm.toString(p),
                    " paid ",
                    vm.toString(_used[p][iSpec]),
                    " of token",
                    vm.toString(iSpec),
                    " in a block whose cap, from its own books, is ",
                    vm.toString(_cap[p][iSpec])
                );
            }
            if (ghostRebates[p][iSpec] > ghostFees[p][iSpec]) {
                foreignRebate += 1;
                lastForeignRebate = string.concat(
                    "pool ", vm.toString(p), " paid rebates in token", vm.toString(iSpec), " beyond the fees it earned"
                );
            }
        }
        if (rebate > 0 && rebate < hook.nominalRebateOf(amount)) _noteReached("rebate cut by a pool's cap");
    }

    /// @dev a gain of the hook in a currency is a fee of this pool, a loss a rebate (one of each at most per swap)
    function _book(uint256 p, uint256 t, uint256 pre, uint256 post) internal {
        if (post > pre) {
            ghostFees[p][t] += post - pre;
            if (t == 0) _noteReached("fee in the shared currency");
        } else if (pre > post) {
            ghostRebates[p][t] += pre - post;
        }
    }
}

contract DeltaFeeHookMultiPoolInvariants is MultiPoolBase, InvariantAsserts {
    using PoolIdLibrary for PoolKey;

    DeltaFeeMultiPoolHandler internal handler;

    function setUp() public {
        _deployMultiPool();
        handler = new DeltaFeeMultiPoolHandler(hook, router, token0, token1, token2, poolA, poolB);
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](3);
        sel[0] = DeltaFeeMultiPoolHandler.swap.selector;
        sel[1] = DeltaFeeMultiPoolHandler.swapBurst.selector;
        sel[2] = DeltaFeeMultiPoolHandler.nextBlock.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    function afterInvariant() public {
        handler.writeCensus("DeltaFeeHook-multipool");
        handler.printCallSummary();
        handler.printReachSummary();
    }

    /// @notice PER POOL, per currency: a pool's rebates never exceed the fees THAT pool earned (in the manager's books)
    function invariant_per_pool_no_rebate_beyond_its_own_fees() public view {
        assertEq(handler.foreignRebate(), 0, handler.lastForeignRebate());
        for (uint256 p = 0; p < 2; p++) {
            for (uint256 t = 0; t < 3; t++) {
                assertLe(handler.ghostRebates(p, t), handler.ghostFees(p, t), "a pool paid out of another pool's fees");
            }
        }
    }

    /// @notice PER POOL, per currency and block: a pool's rebates stay under 10 % of what that pool had earned
    function invariant_per_pool_block_cap() public view {
        assertEq(handler.capBroken(), 0, handler.lastCapBroken());
    }

    /// @notice PER CURRENCY: the hook holds exactly what the pools left it, summed over the pools that have the currency
    /// (token0 is in both), and its hook-wide ledger says the same
    function invariant_per_currency_the_hook_holds_what_its_pools_left_it() public view {
        HostileERC20[3] memory t = [token0, token1, token2];
        uint256[3] memory expected = [
            handler.ghostFees(0, 0) + handler.ghostFees(1, 0) - handler.ghostRebates(0, 0) - handler.ghostRebates(1, 0),
            handler.ghostFees(0, 1) - handler.ghostRebates(0, 1),
            handler.ghostFees(1, 2) - handler.ghostRebates(1, 2)
        ];
        for (uint256 i = 0; i < 3; i++) {
            assertEq(t[i].trueBalanceOf(address(hook)), expected[i], "the hook holds other than its pools left it");
            assertEq(hook.reserveOf(Currency.wrap(address(t[i]))), expected[i], "the hook-wide ledger disagrees");
        }
    }

    /// @notice the hook's own per-pool ledger (`poolReserveOf`, P13) against the manager's books of each pool. Added with
    /// P13, so it was never run against the hook-wide reserve (it does not compile there); the three above were, red
    function invariant_the_hooks_per_pool_ledger_is_the_managers() public view {
        HostileERC20[3] memory t = [token0, token1, token2];
        PoolKey[2] memory k = [poolA, poolB];
        for (uint256 p = 0; p < 2; p++) {
            for (uint256 i = 0; i < 3; i++) {
                if (i == 2 - p) continue; // pool A has no token2, pool B no token1
                assertEq(
                    hook.poolReserveOf(k[p].toId(), Currency.wrap(address(t[i]))),
                    handler.ghostFees(p, i) - handler.ghostRebates(p, i),
                    "the hook's per-pool ledger disagrees with the manager's books of that pool"
                );
            }
        }
    }

    function invariant_no_unexplained_reverts() public view {
        assertEq(handler.revertsUnexpected(), 0, handler.lastUnexpected());
    }

    /// @notice non-vacuity: pool A earns, pool B is paid a rebate only once it has earned in its own right, both reach a
    /// cap, and every invariant holds
    function test_multipool_handler_smoke() public {
        for (uint256 i = 0; i < 4; i++) {
            handler.swap(i, 0, 5e17, i, 1); // pool A only, both ways
        }
        handler.nextBlock(1);
        handler.swap(0, 1, 5e17, 1, 1); // pool B, token0 in: specified = the shared currency, pool B has earned nothing
        for (uint256 i = 0; i < 4; i++) {
            handler.swap(i, 1, 5e17, i, 1); // pool B earns
        }
        handler.nextBlock(1);
        handler.swapBurst(0, 1 | 2, 1e18, 12); // pool B, token0 in, until its cap cuts
        handler.swapBurst(1, 0 | 2, 1e18, 12); // pool A, token0 in, same block
        handler.printReachSummary();
        handler.assertReached("rebate paid on pool A", 1);
        handler.assertReached("rebate paid on pool B", 1);
        handler.assertReached("rebate cut by a pool's cap", 2);
        invariant_per_pool_no_rebate_beyond_its_own_fees();
        invariant_per_pool_block_cap();
        invariant_per_currency_the_hook_holds_what_its_pools_left_it();
        invariant_the_hooks_per_pool_ledger_is_the_managers();
        invariant_no_unexplained_reverts();
    }
}
