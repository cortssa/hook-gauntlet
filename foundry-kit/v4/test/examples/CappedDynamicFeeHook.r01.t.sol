// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {V4Harness} from "../../src/V4Harness.sol";
import {HookMiner} from "../../src/HookMiner.sol";
import {SwapEventReader} from "../../src/SwapEventReader.sol";
import {CappedDynamicFeeHook} from "../../src/examples/CappedDynamicFeeHook.sol";

/// @notice What a DISCOVERY round found on this hook (round r01, 2026-09-23, a fresh-context auditor), kept as tests.
///
/// F1 (medium): after a victim read `quoteNextFee` = 500, nine 1-wei swaps placed ahead of it IN THE SAME BLOCK pushed
/// its fee to 5 000 - 0.372 % less output on a 10-token swap, for ~1.35 M gas of dust. The suite had "charged ==
/// quoted" as an invariant and it was green, because it compared every swap with the quote read immediately before
/// it: the campaign produced the ordering (`swapBurst`), and nothing compared a swap with a quote read EARLIER in its
/// block. The first test below is the round's own test with its last assertion turned the right way up: it was seen
/// RED on the old rule (`5000 != 500`), and the fix is at the cause - the fee of a block is fixed by the block BEFORE it, so nothing placed
/// inside a block can move what that block charges. `src/examples/SPEC.md` has the story and the residual.
///
/// F2 (low): the hook accepts native-currency pools and the spec left it undecided. Decided in SPEC.md: ACCEPTED, the
/// hook moves no value and never reads a currency. The last test holds it to that on a real native swap, through
/// v4-core's own test routers (written when the kit's `MinimalRouter` still refused native currency; it accepts it
/// since 2026-09-24, and `test/NativeHarness.t.sol` holds it to that).
contract CappedDynamicFeeHookRound01 is V4Harness {
    uint160 internal constant P11 = 79228162514264337593543950336;
    CappedDynamicFeeHook internal hook;
    PoolKey internal keyA;
    address internal lp = address(0xA11CE);
    address internal victim = address(0xB0B);
    address internal attacker = address(0xBAD);

    function setUp() public {
        _setUpManager();
        _deployCurrencies();
        _deployRouters();
        (, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG,
            type(CappedDynamicFeeHook).creationCode,
            abi.encode(manager)
        );
        hook = new CappedDynamicFeeHook{salt: salt}(manager);
        _fundAndApprove(lp, 1_000_000e18);
        _fundAndApprove(victim, 1_000_000e18);
        _fundAndApprove(attacker, 1_000_000e18);
        keyA = _initPool(IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, P11);
        _addFullRangeLiquidity(keyA, lp, 100e18);
    }

    receive() external payable {}

    function _swap(PoolKey memory k, address who, uint256 amt, bool z) internal returns (uint24 fee, BalanceDelta d) {
        vm.recordLogs();
        vm.prank(who);
        d = router.swap(
            k,
            SwapParams({
                zeroForOne: z,
                amountSpecified: -int256(amt),
                sqrtPriceLimitX96: z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        bool found;
        (found, fee) = SwapEventReader.lastSwapFee(vm.getRecordedLogs(), address(manager));
        require(found, "no swap event");
    }

    /// @notice F1, the round's own test: quote, nine dust swaps by somebody else in the same block, then the victim.
    function test_r01_F1_nine_dust_swaps_ahead_of_a_victim_do_not_move_the_fee_it_was_quoted() public {
        uint256 notional = 10e18;
        uint24 quotedToVictim = hook.quoteNextFee(keyA);

        uint256 snap = vm.snapshotState();
        (uint24 feeClean, BalanceDelta dClean) = _swap(keyA, victim, notional, true);
        vm.revertToState(snap);

        for (uint256 i = 0; i < 9; i++) {
            _swap(keyA, attacker, 1, i % 2 == 0);
        }
        (uint24 feeHit, BalanceDelta dHit) = _swap(keyA, victim, notional, true);

        uint256 outClean = uint256(int256(dClean.amount1()));
        uint256 outHit = uint256(int256(dHit.amount1()));
        console2.log("F1 victim out, alone in the block     ", outClean);
        console2.log("F1 victim out, after nine dust swaps  ", outHit);
        console2.log("F1 fee alone / after the dust         ", feeClean, feeHit);
        assertEq(feeClean, quotedToVictim, "the victim alone was not charged its quote");
        assertEq(feeHit, quotedToVictim, "swaps placed ahead of the victim in its block moved the fee it was quoted");
        // the dust still moves the PRICE by a few wei, which is the pool, not the hook: bounded, not zero
        assertApproxEqAbs(outHit, outClean, 1e6, "the victim lost more than the dust's own price impact");
    }

    /// @notice F1's residual, stated as a test so that nobody reads the fix as more than it is. Congestion is still
    /// counted, and the dust still raises a fee: the fee of the NEXT block. But that fee is fixed before the next block
    /// begins, anyone can read it before trading, and nothing placed inside that block can move it again.
    function test_r01_F1_residual_the_dust_raises_the_next_blocks_fee_in_the_open_and_only_that() public {
        for (uint256 i = 0; i < 9; i++) {
            _swap(keyA, attacker, 1, i % 2 == 0);
        }
        vm.roll(block.number + 1);
        uint24 q = hook.quoteNextFee(keyA);
        assertEq(q, hook.MAX_FEE(), "nine swaps in the previous block set this block's fee at the cap");
        for (uint256 i = 0; i < 9; i++) {
            _swap(keyA, attacker, 1, i % 2 == 0);
        }
        (uint24 f,) = _swap(keyA, victim, 1e18, true);
        assertEq(f, q, "every swap in a block pays the fee that block was quoted at its start");
    }

    /// @notice F2, decided: a native-currency pool is ACCEPTED. The hook moves no value and reads no currency, so the
    /// claim is that nothing changes: a real swap each way, charged the quote, and the hook holds nothing afterwards.
    function test_r01_F2_a_native_currency_pool_is_accepted_and_charges_its_quote() public {
        PoolSwapTest swapper = new PoolSwapTest(manager);
        PoolModifyLiquidityTest provider = new PoolModifyLiquidityTest(manager);
        PoolKey memory nk = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: currency0,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(nk, P11);
        assertTrue(hook.poolState(PoolIdLibrary.toId(nk)).known, "the hook did not record the native pool");

        vm.deal(address(this), 1_000e18);
        token0.mint(address(this), 1_000e18);
        token0.approve(address(provider), type(uint256).max);
        token0.approve(address(swapper), type(uint256).max);
        (int24 lower, int24 upper) = _fullRange(60);
        provider.modifyLiquidity{value: 200e18}(
            nk, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 100e18, salt: 0}), ""
        );

        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        for (uint256 i = 0; i < 3; i++) {
            bool z = i % 2 == 0;
            uint24 q = hook.quoteNextFee(nk);
            vm.recordLogs();
            swapper.swap{value: z ? 1e17 : 0}(
                nk,
                SwapParams({
                    zeroForOne: z,
                    amountSpecified: -1e17,
                    sqrtPriceLimitX96: z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ts,
                ""
            );
            (bool found, uint24 charged) = SwapEventReader.lastSwapFee(vm.getRecordedLogs(), address(manager));
            assertTrue(found, "no Swap event on the native pool");
            assertEq(charged, q, "on a native pool the hook quoted one fee and the pool charged another");
        }
        assertEq(address(hook).balance, 0, "the hook holds native currency");
        assertEq(token0.balanceOf(address(hook)), 0, "the hook holds the token");
    }
}
