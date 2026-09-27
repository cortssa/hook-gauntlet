// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {InRangeLedger} from "../../src/InRangeLedger.sol";
import {JitRecipient} from "../../src/JitRecipient.sol";
import {InRangeDonateHook} from "../../src/examples/InRangeDonateHook.sol";
import {InRangeDonateHookNaive} from "../examples/InRangeDonateHookNaive.sol";
import {InRangeDonateWatcher} from "../examples/InRangeDonateWatcher.sol";
import {ForkPoolsBase} from "./ForkExamples.t.sol";

/// @notice The JIT-recipient actor and the WHO check on a mainnet fork (K18). Two parts.
///
/// 1. `InRangeDonateHook` and its first draft on a FRESH pool of real USDC / WETH (a hook cannot be attached to a pool
///    that exists: the hook is part of the pool's key), LP fee 0, spacing 60, 4 000 USDC per ETH (tick 193 380), honest
///    liquidity on [-1200, +1200] and [0, +2400] ticks around it: the unit suite's three JIT scenarios with real tokens.
/// 2. The actor against REAL liquidity: the chain's own ETH / USDC 0.05 % pool (no hook, spacing 10) at block
///    26 050 000. A donation to it stands for a naive payout of fees its LPs earned; the actor places a position of one
///    tick spacing around the price just before the donation and leaves after it. What it takes, and what it had to put
///    in to take it, measured against the liquidity the chain has in range there - and, in the defended order (the
///    payout BEFORE anybody can arrive), nothing. The reference model's `WORLD` stands for every LP the chain has there.
/// Skipped with the reason anywhere but the fork.
contract ForkInRangeDonateTest is ForkPoolsBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    InRangeDonateHook internal hook;
    InRangeDonateHookNaive internal naive;
    address internal lp2 = address(0xB0B0);
    address internal treasury = address(0x7EA5);

    struct W {
        PoolKey key;
        InRangeDonateWatcher w;
        InRangeLedger l;
        JitRecipient jit;
        address h;
    }

    function setUp() public {
        _setUpV4OnFork();
        _fundActors();
        _fundReal(realUsdc(), lp2, 10_000_000e6);
        _fundReal(realWeth(), lp2, 10_000e18);
        hook = InRangeDonateHook(
            _deployHook(
                type(InRangeDonateHook).creationCode,
                abi.encode(manager, treasury),
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                    | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            )
        );
        naive = InRangeDonateHookNaive(
            _deployHook(
                type(InRangeDonateHookNaive).creationCode,
                abi.encode(manager),
                Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            )
        );
    }

    // ------------------------------------------------------------------ part 1: the example hook on real currencies
    function _world(address h) internal returns (W memory x) {
        x.h = h;
        x.key = _initRealPool(IHooks(h), 0, 60, TickMath.getSqrtPriceAtTick(TICK_USDC_WETH), realUsdc(), realWeth());
        x.w = new InRangeDonateWatcher(manager, router, liquidity, x.key, 30, true);
        x.l = x.w.ledger();
        x.w.modifyAs(provider, TICK_USDC_WETH - 1200, TICK_USDC_WETH + 1200, 1e15, 0);
        x.w.modifyAs(lp2, TICK_USDC_WETH, TICK_USDC_WETH + 2400, 5e14, 0);
        x.jit = x.w.newJit();
        _fundReal(realUsdc(), address(x.jit), 100_000_000e6);
        _fundReal(realWeth(), address(x.jit), 100_000e18);
    }

    /// @notice USDC in (price down) and WETH in (price up), 4 000 USDC or 1 WETH, never past 900 ticks from the start
    function _trading(W memory x) internal {
        for (uint256 i = 0; i < 4; i++) {
            x.w.swapAs(trader, _to(true, 4_000e6, TICK_USDC_WETH - 900), 0);
            x.w.swapAs(trader, _to(false, 1e18, TICK_USDC_WETH + 900), 0);
        }
    }

    function _to(bool zeroForOne, uint256 amount, int24 limitTick) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(limitTick)
        });
    }

    function _plan(W memory x, uint128 liq) internal pure returns (JitRecipient.Plan memory p) {
        p.key = x.key;
        p.liquidity = liq;
        p.spacings = 1;
        p.payoutTarget = x.h;
        p.payoutCall = abi.encodeCall(InRangeDonateHook.sweep, (x.key));
    }

    function _excess(W memory x, address who) internal view returns (uint256) {
        (uint256 a, uint256 b) = x.l.excess(who);
        return a + b;
    }

    function _took(JitRecipient.Result memory r) internal pure returns (uint256) {
        return r.fees0 + r.fees1;
    }

    /// @notice the three scenarios of the unit suite, on real USDC / WETH: naive - the actor takes a share (around the
    /// sweep), the whole pot (dust after a push to where nobody is), and more than its own fees (wash + JIT); defended -
    /// nothing, nothing, and only its share of its own fees
    function test_on_real_usdc_and_weth_the_actor_takes_from_the_naive_hook_and_nothing_owed_to_others_from_the_defended()
        public
    {
        for (uint256 i = 0; i < 2; i++) {
            address h = i == 0 ? address(naive) : address(hook);
            string memory who = i == 0 ? "naive" : "defended";
            uint256 snap = vm.snapshotState();

            W memory x = _world(h);
            _trading(x);
            JitRecipient.Result memory r = x.w.runJit(x.jit, _plan(x, 1e15));
            console2.log(who, "- JIT around the sweep took (USDC, WETH):", r.fees0, r.fees1);
            if (i == 0) assertGt(_excess(x, address(x.jit)), 0, "naive: the WHO check did not see the JIT");
            else assertEq(_took(r), 0, "defended: the JIT took something");

            JitRecipient.Plan memory p = _plan(x, 1);
            p.pushToSqrtPrice = TickMath.getSqrtPriceAtTick(TICK_USDC_WETH + 3000);
            p.pushBack = true;
            _trading(x);
            (uint256 pot0, uint256 pot1) = i == 0 ? naive.potOf(x.key.toId()) : hook.potOf(x.key.toId());
            r = x.w.runJit(x.jit, p);
            console2.log(who, "- the pot before the push (USDC, WETH):", pot0, pot1);
            console2.log(who, "- dust after the push took (USDC, WETH):", r.fees0, r.fees1);
            if (i == 0) {
                assertGe(r.fees0 + 1, pot0, "naive: the dust did not take the whole USDC pot");
                assertGe(r.fees1 + 1, pot1, "naive: the dust did not take the whole WETH pot");
            } else {
                assertEq(_took(r), 0, "defended: the dust took something");
            }

            _trading(x);
            p = _plan(x, 1e16);
            p.washAmount = -1e18; // sells 1 WETH, and back
            p.washBack = true;
            r = x.w.runJit(x.jit, p);
            console2.log(who, "- wash + JIT took (USDC, WETH):", r.fees0, r.fees1);
            console2.log(who, "- wash + JIT balance change (USDC, WETH):");
            console2.logInt(r.net0);
            console2.logInt(r.net1);
            if (i == 1) {
                assertEq(_excess(x, address(x.jit)), 0, "defended: the actor was paid more than it was in range for");
                (uint256 y0, uint256 y1) = x.l.shortfall(provider, 0, 0);
                (uint256 z0, uint256 z1) = x.l.shortfall(lp2, 0, 0);
                assertEq(y0 + y1 + z0 + z1, 0, "defended: an honest LP was paid less than it was in range for");
            } else {
                assertGt(_excess(x, address(x.jit)), 0, "naive: the WHO check did not see wash + JIT");
            }
            assertEq(x.l.disagreements(), 0);
            vm.revertToState(snap);
        }
    }

    // ------------------------------------------------------------------ part 2: the actor against the chain's liquidity
    function _ethUsdc500() internal view returns (PoolKey memory k) {
        k = PoolKey({currency0: eth, currency1: realUsdc(), fee: 500, tickSpacing: 10, hooks: IHooks(address(0))});
    }

    /// @notice a donation of 1 ETH + 2 700 USDC to the chain's ETH / USDC 0.05 % pool, EARNED by the LPs in range before
    /// the actor arrives (the model is told so first). In the naive order - the actor places one tick spacing of
    /// liquidity equal to what the chain has in range, then the donation lands, then it leaves - it takes about half; with
    /// nine times that, about nine tenths; with dust, nothing measurable (the chain's LPs are in range with it). In the
    /// defended order - the payout first - it takes nothing at any size. Measured: the chain's in-range liquidity, the
    /// capital each position needed, the share taken
    function test_against_the_real_eth_usdc_pool_a_jit_takes_its_liquidity_share_of_a_payout_it_did_not_earn() public {
        PoolKey memory k = _ethUsdc500();
        uint128 real = manager.getLiquidity(k.toId());
        assertGt(real, 0, "the chain's pool has nothing in range at this block");
        (, int24 tick,,) = manager.getSlot0(k.toId());
        console2.log("ETH/USDC 0.05 %: liquidity in range at block 26 050 000:", real);
        console2.log("  tick");
        console2.logInt(tick);

        InRangeDonateWatcher w = new InRangeDonateWatcher(manager, router, liquidity, k, 0, false);
        InRangeLedger l = w.ledger();
        JitRecipient jit = w.newJit();
        vm.deal(address(jit), 100_000e18);
        _fundReal(realUsdc(), address(jit), 1_000_000_000e6);
        address donor = address(w.donor());
        vm.deal(donor, 100e18);
        _fundReal(realUsdc(), donor, 1_000_000e6);

        uint128[3] memory sizes = [uint128(1), real, real * 9];
        for (uint256 i = 0; i < 3; i++) {
            uint256 snap = vm.snapshotState();
            // naive order: the payout was earned by the chain's LPs; the actor arrives; the payout lands; it leaves
            l.accrue(1e18, 2_700e6);
            uint256 eth0 = address(jit).balance;
            uint256 usdc0 = IERC20Minimal(MAINNET_USDC).balanceOf(address(jit));
            w.jitEnter(jit, sizes[i], 1);
            uint256 ethIn = eth0 - address(jit).balance;
            uint256 usdcIn = usdc0 - IERC20Minimal(MAINNET_USDC).balanceOf(address(jit));
            _donate(w, k, 1e18, 2_700e6);
            (uint256 f0, uint256 f1) = w.jitExit(jit);
            console2.log("naive order, JIT liquidity", sizes[i]);
            console2.log("  it put in (wei ETH, USDC units):", ethIn, usdcIn);
            console2.log("  it took of 1e18 wei ETH and 2 700e6 USDC units:", f0, f1);
            (uint256 x0, uint256 x1) = l.excess(address(jit));
            assertGt(x0 + x1, 0, "the WHO check did not see the JIT on the chain's pool");
            if (i == 0) {
                assertLe(f0, uint256(1e18) / real + 1, "dust took more than its liquidity's share");
            } else {
                // its share is its liquidity's: about 1/2 and 9/10, to the manager's rounding
                assertApproxEqRel(f0, uint256(1e18) * sizes[i] / (uint256(sizes[i]) + real), 1e12, "not its liquidity share");
            }
            vm.revertToState(snap);

            // defended order: the payout lands BEFORE anybody can arrive; then the actor comes and goes
            snap = vm.snapshotState();
            l.accrue(1e18, 2_700e6);
            _donate(w, k, 1e18, 2_700e6);
            w.jitEnter(jit, sizes[i], 1);
            (f0, f1) = w.jitExit(jit);
            assertEq(f0 + f1, 0, "the defended order paid the actor");
            (x0, x1) = l.excess(address(jit));
            assertEq(x0 + x1, 0);
            vm.revertToState(snap);
        }
    }

    function _donate(InRangeDonateWatcher w, PoolKey memory k, uint256 a0, uint256 a1) internal {
        w.donor().donate(k, a0, a1);
    }
}
