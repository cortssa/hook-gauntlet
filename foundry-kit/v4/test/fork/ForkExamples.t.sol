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
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {V4Harness} from "../../src/V4Harness.sol";
import {HookMiner} from "../../src/HookMiner.sol";
import {SwapEventReader} from "../../src/SwapEventReader.sol";
import {CappedDynamicFeeHook} from "../../src/examples/CappedDynamicFeeHook.sol";
import {DeltaFeeHook} from "../../src/examples/DeltaFeeHook.sol";
import {ClaimsFeeHook} from "../../src/examples/ClaimsFeeHook.sol";

/// @notice The three example hooks on a mainnet fork (K16): the deployed PoolManager, a FRESH pool of real currencies -
/// USDC / WETH, and ETH / USDC - each hook at an address mined on the fork (`_deployHook`), and the core cases of each
/// unit suite, re-run with real tokens. The unit suites themselves also run on the fork, unchanged, with the harness's
/// hostile tokens (`FOUNDRY_PROFILE=fork V4_MANAGER=fork`, README "The fork"); these are the cases where the currency
/// is the real one. Skipped with the reason anywhere but the fork.
///
/// Prices: 4 000 USDC per ETH, as a tick (193 380 for USDC/WETH, where USDC sorts first; -193 380 for ETH/USDC, where
/// ETH does). Full-range liquidity 1e16: about 632 000 USDC and 158 ETH. A swap is 400 USDC or 0.1 ETH, a fill 10x that.
abstract contract ForkPoolsBase is V4Harness {
    using PoolIdLibrary for PoolKey;

    int24 internal constant TICK_USDC_WETH = 193_380;
    int24 internal constant TICK_ETH_USDC = -193_380;
    int256 internal constant LIQ = 1e16;

    address internal provider = address(0xA11CE);
    address internal trader = address(0xB0B);
    Currency internal eth = Currency.wrap(address(0));

    function _fundActors() internal {
        Currency[3] memory cs = [realUsdc(), realWeth(), eth];
        for (uint256 i = 0; i < 3; i++) {
            uint256 amt = Currency.unwrap(cs[i]) == MAINNET_USDC ? 10_000_000e6 : 10_000e18;
            _fundReal(cs[i], provider, amt);
            _fundReal(cs[i], trader, amt);
        }
    }

    /// @notice one swap's size in `c`: 400 USDC or 0.1 ETH / WETH
    function _amt(Currency c) internal pure returns (uint256) {
        return Currency.unwrap(c) == MAINNET_USDC ? 400e6 : 1e17;
    }

    function _p(bool exactIn, bool zeroForOne, uint256 amount) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactIn ? -int256(amount) : int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    /// @notice a swap of `k` of the right size: its amount in whichever currency it specifies
    function _pk(PoolKey memory k, bool exactIn, bool zeroForOne, uint256 times) internal pure returns (SwapParams memory) {
        Currency specified = exactIn == zeroForOne ? k.currency0 : k.currency1;
        return _p(exactIn, zeroForOne, _amt(specified) * times);
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    function _initUsdcWeth(IHooks hook, uint24 fee) internal returns (PoolKey memory k) {
        k = _initRealPool(hook, fee, 60, TickMath.getSqrtPriceAtTick(TICK_USDC_WETH), realUsdc(), realWeth());
        _addFullRangeLiquidity(k, provider, LIQ);
    }

    function _initEthUsdc(IHooks hook, uint24 fee) internal returns (PoolKey memory k) {
        k = _initRealPool(hook, fee, 60, TickMath.getSqrtPriceAtTick(TICK_ETH_USDC), eth, realUsdc());
        _addFullRangeLiquidity(k, provider, LIQ);
    }

    /// @notice conservation on real balances: swapper + hook + manager == 0 in both currencies, and the swapper moved by
    /// exactly what the manager returned to the router
    function _assertConserved(SwapBooks memory b, string memory label) internal pure {
        assertEq(b.swapper0 + b.hook0 + b.manager0, 0, string.concat(label, ": currency0"));
        assertEq(b.swapper1 + b.hook1 + b.manager1, 0, string.concat(label, ": currency1"));
        assertEq(b.swapper0, b.caller0, string.concat(label, ": swapper0 != what the router was told"));
        assertEq(b.swapper1, b.caller1, string.concat(label, ": swapper1 != what the router was told"));
    }
}

contract CappedDynamicFeeHookForkTest is ForkPoolsBase {
    CappedDynamicFeeHook internal hook;
    PoolKey internal key;

    function setUp() public {
        _setUpV4OnFork();
        hook = CappedDynamicFeeHook(
            _deployHook(
                type(CappedDynamicFeeHook).creationCode,
                abi.encode(manager),
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
            )
        );
        _fundActors();
        key = _initUsdcWeth(IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG);
    }

    function _swapAndReadFee() internal returns (uint24 fee) {
        vm.recordLogs();
        vm.prank(trader);
        router.swap(key, _pk(key, true, true, 1), "");
        bool found;
        (found, fee) = SwapEventReader.lastSwapFee(vm.getRecordedLogs(), address(manager));
        require(found, "no Swap event");
    }

    function test_mined_on_the_fork_with_exactly_its_flags() public view {
        assertTrue(HookMiner.carriesExactly(address(hook), hook.requiredFlags()));
        assertEq(address(hook.manager()), MAINNET_POOL_MANAGER);
    }

    /// @notice the unit suite's schedule, with USDC in: base fee in the first block, flat inside a block, one step per
    /// swap of the previous block after it, back to base after an idle block
    function test_the_fee_schedule_on_a_real_pool() public {
        uint256 b0 = vm.getBlockNumber();
        assertEq(_swapAndReadFee(), hook.BASE_FEE(), "first block");
        assertEq(_swapAndReadFee(), hook.BASE_FEE(), "same block");
        assertEq(_swapAndReadFee(), hook.BASE_FEE(), "same block");
        vm.roll(b0 + 1);
        assertEq(_swapAndReadFee(), hook.BASE_FEE() + 3 * hook.STEP(), "three swaps last block");
        vm.roll(b0 + 3);
        assertEq(_swapAndReadFee(), hook.BASE_FEE(), "after an idle block");
    }

    function test_the_hook_never_holds_a_token_and_the_books_close() public {
        for (uint256 i = 0; i < 4; i++) {
            SwapBooks memory b = _swapWithBooks(trader, key, _pk(key, i < 2, i % 2 == 0, 1));
            _assertConserved(b, "capped");
            assertEq(b.manager0, -b.pool0, "manager0 != pool0");
            assertEq(b.manager1, -b.pool1, "manager1 != pool1");
        }
        assertEq(_trueBalance(realUsdc(), address(hook)) + _trueBalance(realWeth(), address(hook)), 0, "the hook holds a token");
    }
}

contract DeltaFeeHookForkTest is ForkPoolsBase {
    using PoolIdLibrary for PoolKey;

    DeltaFeeHook internal hook;
    PoolKey internal key; // USDC / WETH

    function setUp() public {
        _setUpV4OnFork();
        hook = DeltaFeeHook(
            _deployHook(
                type(DeltaFeeHook).creationCode,
                abi.encode(manager),
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                    | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            )
        );
        _fundActors();
        key = _initUsdcWeth(IHooks(address(hook)), 3000);
    }

    function _fillReserves(PoolKey memory k) internal {
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(trader);
            router.swap{value: k.currency0.isAddressZero() ? _amt(k.currency0) * 10 : 0}(k, _pk(k, true, true, 10), "");
            vm.prank(trader);
            router.swap(k, _pk(k, true, false, 10), "");
        }
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @notice the unit suite's `_orientation` (P1, P2, P3), on USDC / WETH or ETH / USDC
    function _orientation(PoolKey memory k, bool exactIn, bool zeroForOne, string memory label) internal {
        _fillReserves(k);
        SwapParams memory p = _pk(k, exactIn, zeroForOne, 1);
        bool s0 = exactIn == zeroForOne;
        Currency specified = s0 ? k.currency0 : k.currency1;
        Currency unspecified = s0 ? k.currency1 : k.currency0;
        uint256 nominal = hook.nominalRebateOf(_abs(p.amountSpecified));
        assertLe(nominal, hook.rebateBudgetLeft(k.toId(), specified), "test setup: the budget should allow the rebate");
        uint256 resSpec = hook.reserveOf(specified);
        uint256 resUnspec = hook.reserveOf(unspecified);

        SwapBooks memory b = _swapWithBooks(trader, k, p);
        int256 spec = s0 ? b.pool0 - b.caller0 : b.pool1 - b.caller1;
        int256 unspec = s0 ? b.pool1 - b.caller1 : b.pool0 - b.caller0;
        int256 poolSpec = s0 ? b.pool0 : b.pool1;
        int256 poolUnspec = s0 ? b.pool1 : b.pool0;
        console2.log(label, "hook delta spec / unspec:", vm.toString(spec), vm.toString(unspec));

        assertEq(spec, -int256(nominal), string.concat(label, ": rebate"));
        assertEq(unspec, int256(_abs(poolUnspec) * 30 / 10_000), string.concat(label, ": fee"));
        assertGt(unspec, 0, string.concat(label, ": no fee"));
        assertEq(poolSpec, p.amountSpecified - int256(nominal), string.concat(label, ": pool's specified amount"));
        assertEq(s0 ? b.caller0 : b.caller1, p.amountSpecified, string.concat(label, ": swapper's specified side"));
        assertEq(b.swapper0 + b.hook0 + b.manager0, 0, string.concat(label, ": currency0"));
        assertEq(b.swapper1 + b.hook1 + b.manager1, 0, string.concat(label, ": currency1"));
        assertEq(b.manager0, -b.pool0, string.concat(label, ": manager0"));
        assertEq(b.manager1, -b.pool1, string.concat(label, ": manager1"));
        assertEq(hook.reserveOf(specified), resSpec - nominal, string.concat(label, ": specified reserve"));
        assertEq(hook.reserveOf(unspecified), resUnspec + uint256(unspec), string.concat(label, ": unspecified reserve"));
        assertEq(hook.reserveOf(k.currency0), _trueBalance(k.currency0, address(hook)), "ledger0 != balance");
        assertEq(hook.reserveOf(k.currency1), _trueBalance(k.currency1, address(hook)), "ledger1 != balance");
    }

    function test_usdc_weth_exact_in_zero_for_one() public {
        _orientation(key, true, true, "USDC/WETH exact-in  USDC->WETH");
    }

    function test_usdc_weth_exact_in_one_for_zero() public {
        _orientation(key, true, false, "USDC/WETH exact-in  WETH->USDC");
    }

    function test_usdc_weth_exact_out_zero_for_one() public {
        _orientation(key, false, true, "USDC/WETH exact-out USDC->WETH");
    }

    function test_usdc_weth_exact_out_one_for_zero() public {
        _orientation(key, false, false, "USDC/WETH exact-out WETH->USDC");
    }

    function test_eth_usdc_exact_in_eth_in_rebate_in_eth() public {
        _orientation(_initEthUsdc(IHooks(address(hook)), 3000), true, true, "ETH/USDC exact-in  ETH->USDC");
    }

    function test_eth_usdc_exact_in_eth_out_fee_in_eth() public {
        _orientation(_initEthUsdc(IHooks(address(hook)), 3000), true, false, "ETH/USDC exact-in  USDC->ETH");
    }

    /// @notice P4 over a real stream: rebates never exceed fees, per currency, and the ledger is backed by the balance
    function test_rebates_never_exceed_fees_on_a_real_pool() public {
        _fillReserves(key);
        for (uint256 i = 0; i < 8; i++) {
            _swapWithBooks(trader, key, _pk(key, i % 4 < 2, i % 2 == 0, 1));
            if (i % 3 == 2) vm.roll(vm.getBlockNumber() + 1);
        }
        for (uint256 j = 0; j < 2; j++) {
            Currency c = j == 0 ? key.currency0 : key.currency1;
            assertLe(hook.rebatesPaid(c), hook.feesBooked(c), "rebates > fees");
            assertLe(hook.reserveOf(c), _trueBalance(c, address(hook)), "the ledger is not backed");
        }
    }
}

contract ClaimsFeeHookForkTest is ForkPoolsBase {
    ClaimsFeeHook internal hook;
    PoolKey internal key; // ETH / USDC, as in the unit suite (ETH on currency0)
    address internal treasury = address(0x7EA5);

    function setUp() public {
        _setUpV4OnFork();
        hook = ClaimsFeeHook(
            _deployHook(
                type(ClaimsFeeHook).creationCode,
                abi.encode(manager, treasury),
                Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            )
        );
        _fundActors();
        key = _initEthUsdc(IHooks(address(hook)), 3000);
    }

    /// @notice the unit suite's `_orientation` (C1, C2, C3) with ETH and USDC
    function _orientation(PoolKey memory k, bool exactIn, bool zeroForOne, string memory label) internal {
        SwapParams memory p = _pk(k, exactIn, zeroForOne, 1);
        bool s0 = exactIn == zeroForOne;
        SwapBooks memory b = _swapWithBooks(trader, k, p);
        int256 poolUnspec = s0 ? b.pool1 : b.pool0;
        uint256 fee = _abs(poolUnspec) * 30 / 10_000;
        console2.log(label, "claims 0 / 1:", vm.toString(b.hookClaims0), vm.toString(b.hookClaims1));
        assertEq(b.swapper0 + b.hook0 + b.manager0, 0, string.concat(label, ": currency0 balances"));
        assertEq(b.swapper1 + b.hook1 + b.manager1, 0, string.concat(label, ": currency1 balances"));
        assertEq(b.hook0 + b.hook1, 0, string.concat(label, ": the hook's balance moved (the fee is a claim)"));
        assertEq(b.swapper0, b.caller0, string.concat(label, ": swapper0"));
        assertEq(b.swapper1, b.caller1, string.concat(label, ": swapper1"));
        assertEq(b.hookClaims0, b.pool0 - b.caller0, string.concat(label, ": claims0 != booked"));
        assertEq(b.hookClaims1, b.pool1 - b.caller1, string.concat(label, ": claims1 != booked"));
        assertEq(b.manager0 - b.hookClaims0, -b.pool0, string.concat(label, ": manager's net 0"));
        assertEq(b.manager1 - b.hookClaims1, -b.pool1, string.concat(label, ": manager's net 1"));
        assertEq(s0 ? b.hookClaims1 : b.hookClaims0, int256(fee), string.concat(label, ": fee"));
        assertEq(s0 ? b.hookClaims0 : b.hookClaims1, 0, string.concat(label, ": a claim in the specified currency"));
        assertGt(fee, 0);
    }

    function test_eth_usdc_exact_in_eth_in_fee_is_a_usdc_claim() public {
        _orientation(key, true, true, "exact-in  ETH->USDC");
    }

    function test_eth_usdc_exact_in_eth_out_fee_is_an_eth_claim() public {
        _orientation(key, true, false, "exact-in  USDC->ETH");
    }

    function test_eth_usdc_exact_out_eth_in_fee_is_an_eth_claim() public {
        _orientation(key, false, true, "exact-out ETH->USDC");
    }

    function test_eth_usdc_exact_out_eth_out_fee_is_a_usdc_claim() public {
        _orientation(key, false, false, "exact-out USDC->ETH");
    }

    function test_usdc_weth_fee_is_a_weth_claim() public {
        _orientation(_initUsdcWeth(IHooks(address(hook)), 3000), true, true, "USDC/WETH exact-in USDC->WETH");
    }

    /// @notice C3 with real money: the treasury withdraws half of each claim, in ETH and in USDC, out of the manager's
    /// real balance, and the claims burn by exactly what was paid
    function test_withdrawal_pays_real_eth_and_real_usdc() public {
        for (uint256 i = 0; i < 3; i++) {
            _swapWithBooks(trader, key, _pk(key, true, true, 1));
            _swapWithBooks(trader, key, _pk(key, true, false, 1));
        }
        for (uint256 j = 0; j < 2; j++) {
            Currency c = j == 0 ? eth : realUsdc();
            uint256 claims = hook.claimsOf(c);
            assertGt(claims, 0, "nothing earned");
            assertEq(claims, hook.feesBooked(c));
            uint256 half = claims / 2;
            uint256 t0 = _trueBalance(c, treasury);
            uint256 m0 = _trueBalance(c, address(manager));
            vm.prank(treasury);
            hook.withdraw(c, treasury, half);
            assertEq(_trueBalance(c, treasury) - t0, half, "the treasury was not paid");
            assertEq(m0 - _trueBalance(c, address(manager)), half, "the manager did not pay it");
            assertEq(hook.claimsOf(c), claims - half, "claims not burned by what was paid");
        }
    }
}
