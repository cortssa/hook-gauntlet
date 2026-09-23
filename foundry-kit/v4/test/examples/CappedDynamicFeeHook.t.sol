// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {V4Harness} from "../../src/V4Harness.sol";
import {HookMiner} from "../../src/HookMiner.sol";
import {SwapEventReader} from "../../src/SwapEventReader.sol";
import {CappedDynamicFeeHook} from "../../src/examples/CappedDynamicFeeHook.sol";

/// @notice Unit tests for the worked example. One case per line of its threat model, plus the arithmetic.
///
/// ADAPT: the shape to steal is the last section - the three tests that read what the hook SAID (the quote,
/// the event) and compare it with what the pool DID. A suite that only follows the money passes while the
/// quote lies, and the quote is the part other people's software trusts.
contract CappedDynamicFeeHookTest is V4Harness {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    CappedDynamicFeeHook internal hook;
    PoolKey internal key;

    address internal provider = address(0xA11CE);
    address internal trader = address(0xB0B);

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
        vm.label(address(hook), "CappedDynamicFeeHook");

        _fundAndApprove(provider, 1_000_000e18);
        _fundAndApprove(trader, 1_000_000e18);

        key = _initPool(IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, SQRT_PRICE_1_1);
        _addFullRangeLiquidity(key, provider, 100e18);
    }

    // ------------------------------------------------------------------ the arithmetic
    function test_the_fee_schedule_climbs_and_then_stops() public view {
        assertEq(hook.feeForCongestion(0), hook.BASE_FEE());
        assertEq(hook.feeForCongestion(1), hook.BASE_FEE() + hook.STEP());
        assertEq(hook.feeForCongestion(2), hook.BASE_FEE() + 2 * hook.STEP());
        assertEq(hook.feeForCongestion(9), hook.MAX_FEE());
        assertEq(hook.feeForCongestion(10), hook.MAX_FEE());
        assertEq(hook.feeForCongestion(type(uint32).max), hook.MAX_FEE(), "the cap has to hold at the top too");
    }

    function testFuzz_the_fee_is_never_above_the_cap_or_below_the_base(uint32 n) public view {
        uint24 fee = hook.feeForCongestion(n);
        assertLe(fee, hook.MAX_FEE());
        assertGe(fee, hook.BASE_FEE());
        assertLe(fee, LPFeeLibrary.MAX_LP_FEE, "a fee above 100% is not a fee");
    }

    // ------------------------------------------------------------------ what the pool actually charged
    function test_the_first_block_of_a_pool_pays_the_base_fee() public {
        assertEq(_swapAndReadFee(1e16), hook.BASE_FEE());
    }

    /// @notice the rule since round r01 (F1): swaps inside a block do not move that block's fee
    function test_every_swap_in_a_block_pays_the_same_fee() public {
        assertEq(_swapAndReadFee(1e16), hook.BASE_FEE());
        assertEq(_swapAndReadFee(1e16), hook.BASE_FEE(), "the second swap of a block paid more than the first");
        assertEq(_swapAndReadFee(1e16), hook.BASE_FEE(), "the third swap of a block paid more than the first");
    }

    /// @dev every roll in this file that follows another in the same test is from `vm.getBlockNumber()`, never from
    /// `block.number`: the optimizer treats `block.number` as constant for the whole transaction and may re-read it
    /// wherever it is used. Measured here: with `vm.roll(block.number + 1)` twice the second roll went nowhere, and
    /// with `uint256 b0 = vm.getBlockNumber(); ... vm.roll(b0 + 2)` it went to block 4 - `b0` was NUMBER again, after the
    /// first roll. A test that rolls twice has to hold the block number in something the optimizer cannot re-read.
    function test_the_next_block_pays_one_step_more_per_swap_of_the_previous_block() public {
        uint256 b0 = vm.getBlockNumber();
        for (uint256 i = 0; i < 3; i++) _swapAndReadFee(1e16);
        vm.roll(b0 + 1);
        assertEq(_swapAndReadFee(1e16), hook.BASE_FEE() + 3 * hook.STEP(), "three swaps last block, three steps now");
        assertEq(_swapAndReadFee(1e16), hook.BASE_FEE() + 3 * hook.STEP(), "and the same for the rest of the block");
        vm.roll(b0 + 2);
        assertEq(_swapAndReadFee(1e16), hook.BASE_FEE() + 2 * hook.STEP(), "two swaps last block, two steps now");
    }

    function test_congestion_cannot_push_the_fee_past_the_cap() public {
        for (uint256 i = 0; i < 20; i++) {
            assertLe(_swapAndReadFee(1e15), hook.MAX_FEE(), "the pool charged more than the cap");
        }
        vm.roll(block.number + 1);
        uint24 last;
        for (uint256 i = 0; i < 20; i++) {
            last = _swapAndReadFee(1e15);
            assertLe(last, hook.MAX_FEE(), "the pool charged more than the cap");
        }
        assertEq(last, hook.MAX_FEE(), "twenty swaps in the previous block should have set the cap");
    }

    function test_a_block_after_an_idle_one_starts_again_at_the_base() public {
        _swapAndReadFee(1e16);
        _swapAndReadFee(1e16);
        vm.roll(block.number + 2); // the block in between saw no swap
        assertEq(hook.quoteNextFee(key), hook.BASE_FEE(), "the quote carried congestion across an idle block");
        assertEq(_swapAndReadFee(1e16), hook.BASE_FEE(), "the fee carried congestion across an idle block");
    }

    /// @dev Defence (b) says the counter saturates. Nobody can make four billion swaps in a test, so the state
    /// is written directly - and this test exists because a mutant that let the counter wrap SURVIVED the
    /// whole suite. A defence that is claimed in the threat model and killed by no test is only a comment.
    function test_the_counter_saturates_at_the_top_instead_of_wrapping_back_to_the_base() public {
        _swapAndReadFee(1e16);
        PoolId id = PoolIdLibrary.toId(key);
        bytes32 slot = keccak256(abi.encode(PoolId.unwrap(id), uint256(0)));
        uint256 word = uint256(vm.load(address(hook), slot));
        // known (8 bits) | blockNumber (64) | swapsInBlock (32) | blockFee (24), packed from the low end
        assertEq(uint32(word >> 72), hook.poolState(id).swapsInBlock, "the storage layout moved: fix the offset");
        assertEq(uint32(word >> 72), 1);

        vm.store(address(hook), slot, bytes32(word | (uint256(type(uint32).max) << 72)));
        assertEq(hook.poolState(id).swapsInBlock, type(uint32).max);

        assertEq(_swapAndReadFee(1e16), hook.BASE_FEE(), "the fee of a block moved inside it");
        assertEq(hook.poolState(id).swapsInBlock, type(uint32).max, "the counter wrapped");
        vm.roll(block.number + 1);
        assertEq(_swapAndReadFee(1e16), hook.MAX_FEE(), "a wrapped counter drops the next block's fee to the base");
    }

    // ------------------------------------------------------------------ the quote (the read nobody fuzzes)
    function test_the_quote_is_what_the_next_swap_is_charged() public {
        for (uint256 i = 0; i < 8; i++) {
            if (i == 4) vm.roll(block.number + 1); // both sides of a block boundary: a base block, then a stepped one
            uint24 quoted = hook.quoteNextFee(key);
            uint24 charged = _swapAndReadFee(1e16);
            assertEq(charged, quoted, "the hook quoted one fee and the pool charged another");
        }
    }

    function test_the_quote_refuses_a_pool_the_hook_has_never_seen() public {
        PoolKey memory stranger = _poolKey(IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 10);
        vm.expectRevert(CappedDynamicFeeHook.UnknownPool.selector);
        hook.quoteNextFee(stranger);
    }

    // ------------------------------------------------------------------ the threat model, case by case
    /// @notice case 1: hookData is attacker input. Nothing reads it, so nothing can be fooled by it.
    function testFuzz_hook_data_changes_nothing(bytes calldata hookData) public {
        vm.assume(hookData.length < 4096);
        uint24 quoted = hook.quoteNextFee(key);
        vm.prank(trader);
        vm.recordLogs();
        router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            hookData
        );
        assertEq(_feeFromLastSwapEvent(), quoted, "hookData moved the fee");
    }

    /// @notice case 4: a pool the hook has never seen. `beforeSwap` refuses rather than quoting from
    /// another pool's counter.
    function test_beforeSwap_refuses_an_unknown_pool() public {
        PoolKey memory stranger = _poolKey(IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 10);
        vm.prank(address(manager));
        vm.expectRevert(CappedDynamicFeeHook.UnknownPool.selector);
        hook.beforeSwap(
            trader,
            stranger,
            SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
    }

    /// @notice case 5: the entry points belong to the manager.
    function test_only_the_manager_may_call_the_hook() public {
        vm.prank(trader);
        vm.expectRevert(CappedDynamicFeeHook.NotTheManager.selector);
        hook.beforeSwap(
            trader,
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );

        vm.prank(trader);
        vm.expectRevert(CappedDynamicFeeHook.NotTheManager.selector);
        hook.afterInitialize(trader, key, SQRT_PRICE_1_1, 0);
    }

    /// @notice case 5 again, from BOTH SIDES of the manager's address.
    ///
    /// This test exists because a mutation survived the suite above: `msg.sender != address(manager)` changed
    /// to `msg.sender < address(manager)`, and every caller the suite had ever used - `0xB0B`, `0xA11CE`,
    /// `address(this)` - happens to sort below the manager, so the broken guard still refused all of them.
    /// Half a guard looks exactly like a whole one until somebody deploys above you. An address is not an
    /// ordering, and the general form of this test is: whenever a rule is `a != b`, try an `a` on each side.
    function test_a_caller_above_the_managers_address_is_refused_too() public {
        address below = address(uint160(address(manager)) - 1);
        address above = address(uint160(address(manager)) + 1);
        assertTrue(below < address(manager) && above > address(manager), "the two probes are not on both sides");

        SwapParams memory sp =
            SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        vm.prank(below);
        vm.expectRevert(CappedDynamicFeeHook.NotTheManager.selector);
        hook.beforeSwap(trader, key, sp, "");

        vm.prank(above);
        vm.expectRevert(CappedDynamicFeeHook.NotTheManager.selector);
        hook.beforeSwap(trader, key, sp, "");

        vm.prank(above);
        vm.expectRevert(CappedDynamicFeeHook.NotTheManager.selector);
        hook.afterInitialize(trader, key, SQRT_PRICE_1_1, 0);
    }

    /// @notice the same shape on the other `!=` in the hook: a pool key naming a hook that sorts ABOVE this
    /// one. `test_afterInitialize_refuses_a_pool_that_names_another_hook` uses `0xDEAD`, which sorts below
    /// every mined address, so `address(key.hooks) < address(this)` survived as well.
    function test_afterInitialize_refuses_a_pool_naming_a_hook_above_this_one() public {
        PoolKey memory notMine =
            _poolKey(IHooks(address(uint160(address(hook)) + 1)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60);
        assertTrue(address(notMine.hooks) > address(hook), "the probe is not above this hook");

        vm.prank(address(manager));
        vm.expectRevert(CappedDynamicFeeHook.NotMyPool.selector);
        hook.afterInitialize(address(this), notMine, SQRT_PRICE_1_1, 0);
    }

    /// @notice the hook's rule is "the stored block IS this block", not "the stored block is not ahead of
    /// this one", and the quote and the execution have to agree on which.
    ///
    /// Two mutations survived the suite here - `s.blockNumber == block.number` -> `>=` in the quote, and
    /// `s.blockNumber != block.number` -> `<` in `beforeSwap` - and both are invisible while the block number
    /// only ever grows. They stop being invisible the moment the stored number is AHEAD of the current one,
    /// which is what a `uint64` truncation, a re-org replay in a test, or a fork pinned behind a cached state
    /// looks like. No chain rolls backwards; the point is that the hook was never relying on the chain for
    /// this, it was relying on an identity, and an identity is what gets asserted.
    function test_a_stored_block_ahead_of_the_current_one_resets_and_the_quote_agrees() public {
        uint256 b0 = vm.getBlockNumber();
        vm.roll(b0 + 9);
        _swapAndReadFee(1e16);
        _swapAndReadFee(1e16);
        vm.roll(b0 + 10);
        // the stored block now carries a fee that is NOT the base, so a stale read of it is visible
        assertEq(_swapAndReadFee(1e16), hook.BASE_FEE() + 2 * hook.STEP());
        assertEq(hook.poolState(PoolIdLibrary.toId(key)).swapsInBlock, 1, "the counter did not move");

        vm.roll(b0 + 5); // the hook's stored block is now AHEAD of block.number

        uint24 quoted = hook.quoteNextFee(key);
        assertEq(quoted, hook.BASE_FEE(), "a stored block that is not this block is stale, whichever side");
        assertEq(_swapAndReadFee(1e16), quoted, "the hook quoted one fee and the pool charged another");
        assertEq(_swapAndReadFee(1e16), quoted, "and the block's fee did not move inside it");
        // ... and the state really moved to THIS block: its two swaps set the next block's fee
        vm.roll(b0 + 6);
        quoted = hook.quoteNextFee(key);
        assertEq(quoted, hook.BASE_FEE() + 2 * hook.STEP(), "the swaps after the roll-back were not counted");
        assertEq(_swapAndReadFee(1e16), quoted, "the hook quoted one fee and the pool charged another");
    }

    // ------------------------------------------------------------------ the premises of the equivalents
    /// @notice `examples/MUTANTS.md` argues that `|` -> `+` and `|` -> `^` on the flag pair, and on the fee
    /// override, are EQUIVALENT mutants - the three operators agree when the operands share no bits. That
    /// argument is only as good as its premise, and a premise nobody asserts is a premise that rots the next
    /// time Uniswap renumbers a flag or raises the fee ceiling. So the premise is a test.
    function test_the_premises_behind_the_equivalent_mutants_still_hold() public view {
        uint160 a = Hooks.AFTER_INITIALIZE_FLAG;
        uint160 b = Hooks.BEFORE_SWAP_FLAG;
        assertEq(uint256(a & b), 0, "the two flags now share a bit: | + and ^ no longer agree");

        assertLt(
            uint256(hook.MAX_FEE()),
            uint256(LPFeeLibrary.OVERRIDE_FEE_FLAG),
            "a capped fee can now reach the override bit: | + and ^ no longer agree"
        );
        assertEq(
            uint256(hook.MAX_FEE() | LPFeeLibrary.OVERRIDE_FEE_FLAG),
            uint256(hook.MAX_FEE()) + uint256(LPFeeLibrary.OVERRIDE_FEE_FLAG)
        );
    }

    /// @notice case 6: a static-fee pool. The manager wraps a hook's revert (ERC-7751
    /// `WrappedError(target, selector, reason, details)`), so the selector at the top belongs to the
    /// wrapper and not to anything in this repository - which is what a bare `vm.expectRevert()` here used
    /// to hide. The wrapper is unwrapped instead: the target must be THIS hook, the inner reason must be
    /// THIS hook's `NotADynamicFeePool`, and the manager's own explanation must be `HookCallFailed`. The
    /// hook's revert is also asserted directly, below, because the two are different claims.
    function test_a_static_fee_pool_cannot_use_this_hook() public {
        PoolKey memory staticKey = _poolKey(IHooks(address(hook)), 3000, 60);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterInitialize.selector,
                abi.encodeWithSelector(CappedDynamicFeeHook.NotADynamicFeePool.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(staticKey, SQRT_PRICE_1_1);
    }

    function test_afterInitialize_itself_refuses_a_static_fee_pool() public {
        PoolKey memory staticKey = _poolKey(IHooks(address(hook)), 3000, 60);
        vm.prank(address(manager));
        vm.expectRevert(CappedDynamicFeeHook.NotADynamicFeePool.selector);
        hook.afterInitialize(address(this), staticKey, SQRT_PRICE_1_1, 0);
    }

    function test_afterInitialize_refuses_a_pool_that_names_another_hook() public {
        PoolKey memory notMine = _poolKey(IHooks(address(0xDEAD)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60);
        vm.prank(address(manager));
        vm.expectRevert(CappedDynamicFeeHook.NotMyPool.selector);
        hook.afterInitialize(address(this), notMine, SQRT_PRICE_1_1, 0);
    }

    /// @notice case 3 and defence (c): the hook has no delta permissions, so it cannot end an action holding
    /// value, whatever the currencies do.
    function test_the_hook_never_holds_a_token() public {
        for (uint256 i = 0; i < 5; i++) _swapAndReadFee(1e16);
        assertEq(token0.balanceOf(address(hook)), 0, "the hook kept currency0");
        assertEq(token1.balanceOf(address(hook)), 0, "the hook kept currency1");
    }

    /// @notice the twelve entry points it did not declare. If the address ever carries a flag it should not,
    /// the call lands here and fails visibly instead of returning a selector and pretending.
    function test_every_undeclared_entry_point_reverts() public {
        ModifyLiquidityParams memory mp =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1, salt: bytes32(0)});
        SwapParams memory sp =
            SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        vm.expectRevert(CappedDynamicFeeHook.NotImplemented.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);
        vm.expectRevert(CappedDynamicFeeHook.NotImplemented.selector);
        hook.beforeAddLiquidity(address(this), key, mp, "");
        vm.expectRevert(CappedDynamicFeeHook.NotImplemented.selector);
        hook.afterAddLiquidity(address(this), key, mp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
        vm.expectRevert(CappedDynamicFeeHook.NotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), key, mp, "");
        vm.expectRevert(CappedDynamicFeeHook.NotImplemented.selector);
        hook.afterRemoveLiquidity(address(this), key, mp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
        vm.expectRevert(CappedDynamicFeeHook.NotImplemented.selector);
        hook.afterSwap(address(this), key, sp, BalanceDelta.wrap(0), "");
        vm.expectRevert(CappedDynamicFeeHook.NotImplemented.selector);
        hook.beforeDonate(address(this), key, 0, 0, "");
        vm.expectRevert(CappedDynamicFeeHook.NotImplemented.selector);
        hook.afterDonate(address(this), key, 0, 0, "");
    }

    /// @notice the permissions the hook declares are the bits its address carries. Checked here as well as
    /// in the constructor, because this is the assertion that names the two.
    function test_the_address_carries_exactly_what_the_hook_declares() public view {
        assertTrue(HookMiner.carriesExactly(address(hook), hook.requiredFlags()), "address and declaration disagree");
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterInitialize && p.beforeSwap, "declared the wrong two");
        assertFalse(p.beforeSwapReturnDelta || p.afterSwapReturnDelta, "no delta permissions, ever");
    }

    // ------------------------------------------------------------------ helpers
    /// @dev swap once as the trader and return the fee the POOL reports having charged, read off its own
    /// event rather than from the hook. The two agreeing is a claim, and this is how it is tested.
    function _swapAndReadFee(uint256 amountIn) internal returns (uint24) {
        vm.recordLogs();
        vm.prank(trader);
        router.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        return _feeFromLastSwapEvent();
    }

    /// @dev the protocol fee is zero in this harness (nobody ever sets one), so the `fee` in the event is
    /// the LP fee, which is the number the hook returned. If you turn protocol fees on, this stops being
    /// true and the assertion has to change with it.
    function _feeFromLastSwapEvent() internal returns (uint24 fee) {
        bool found;
        (found, fee) = SwapEventReader.lastSwapFee(vm.getRecordedLogs(), address(manager));
        require(found, "no Swap event: the swap did not happen");
    }
}
