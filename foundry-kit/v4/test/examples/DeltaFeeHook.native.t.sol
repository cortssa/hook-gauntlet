// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {HostileERC20} from "gauntlet-kit/HostileERC20.sol";
import {V4Harness} from "../../src/V4Harness.sol";
import {HookMiner} from "../../src/HookMiner.sol";
import {DeltaFeeHook} from "../../src/examples/DeltaFeeHook.sol";

/// @notice A payer with a payment IN FLIGHT: inside its unlock it syncs `synced`, sends `prepay` of it, swaps ETH in
/// (exact-in, zeroForOne) and only then settles - the synced currency, then the ETH - and takes its output plus the
/// `prepay` it believes it has credit for. `DeltaFeeHook.native.t.sol` points it at the pool's own token
contract SyncFirstRouter {
    IPoolManager public immutable manager;
    Currency public immutable synced;

    constructor(IPoolManager manager_, Currency synced_) {
        manager = manager_;
        synced = synced_;
    }

    function swapEthIn(PoolKey calldata key, uint256 amountIn, uint256 prepay) external payable returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(key, amountIn, prepay)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not the manager");
        (PoolKey memory key, uint256 amountIn, uint256 prepay) = abi.decode(data, (PoolKey, uint256, uint256));
        manager.sync(synced);
        if (prepay != 0) IERC20Minimal(Currency.unwrap(synced)).transfer(address(manager), prepay);
        BalanceDelta d = manager.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        manager.settle(); // the synced currency: credits what arrived since the sync
        manager.settle{value: uint256(uint128(-d.amount0()))}();
        uint256 owed = uint256(uint128(d.amount1()));
        if (Currency.unwrap(synced) == Currency.unwrap(key.currency1)) owed += prepay;
        else if (prepay != 0) manager.take(synced, address(this), prepay);
        manager.take(key.currency1, address(this), owed);
        return abi.encode(d);
    }

    receive() external payable {}
}

/// @notice The delta example on an ETH / USD-like pool (K14, promise P10): ETH as `currency0` (18 decimals), a 6-decimal
/// token as `currency1`, at 3 000 of it per ETH - a raw price of 3e-9, so a fee or a rebate computed on the wrong side
/// is off by a factor of about 3e8, not by a rounding error. The four orientations twice over: ETH on the SPECIFIED side
/// (the rebate is paid in ETH, `settle{value}`) and on the UNSPECIFIED side (the fee is taken in ETH, the manager's
/// `take` into the hook's `receive()`). Every number against the manager's own books (`_swapWithBooks`, ETH included).
contract DeltaFeeHookNativeTest is V4Harness {
    using PoolIdLibrary for PoolKey;

    /// @notice sqrt(3000e6 / 1e18) * 2^96: 3 000 units of a 6-decimal token per ETH
    uint160 internal constant SQRT_PRICE_3000_USD = 4339505179874779489431521;
    uint256 internal constant ETH_SWAP = 1e17;
    uint256 internal constant USD_SWAP = 300e6;

    DeltaFeeHook internal hook;
    HostileERC20 internal usd;
    Currency internal eth = Currency.wrap(address(0));
    Currency internal usdc;
    PoolKey internal key;
    address internal provider = address(0xA11CE);
    address internal trader = address(0xB0B);

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
        vm.label(address(hook), "DeltaFeeHook(native)");
        usd = new HostileERC20("USD-like", "USDL", 6);
        usdc = Currency.wrap(address(usd));
        vm.label(address(usd), "USDL");

        for (uint256 i = 0; i < 2; i++) {
            address who = i == 0 ? provider : trader;
            _fundNative(who, 3_000e18);
            usd.mint(who, 1e14);
            vm.startPrank(who);
            usd.approve(address(router), type(uint256).max);
            usd.approve(address(liquidity), type(uint256).max);
            vm.stopPrank();
        }
        key = _initNativePool(IHooks(address(hook)), 3000, 60, SQRT_PRICE_3000_USD, usdc);
        _addFullRangeLiquidity(key, provider, 1e17); // about 1 826 ETH and 5.48 M USDL
    }

    // ------------------------------------------------------------------ helpers
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

    /// @notice fees in both currencies, then a new block: a rebate needs a reserve, in the currency it is paid in
    function _fillReserves() internal {
        for (uint256 i = 0; i < 3; i++) {
            _swapWithBooks(trader, key, _p(true, true, 1e18)); // ETH in: the fee is USDL
            _swapWithBooks(trader, key, _p(true, false, 3_000e6)); // USDL in: the fee is ETH
        }
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @notice what an orientation expects, read before the swap. A struct, not locals: `forge coverage --ir-minimum`
    /// (the module's coverage command) stops at "stack too deep" on this function written with locals (measured)
    struct Expect {
        bool s0;
        Currency specified;
        Currency unspecified;
        uint256 resSpec;
        uint256 resUnspec;
        uint256 nominal;
    }

    function _orientation(bool exactIn, bool zeroForOne, string memory label) internal returns (SwapBooks memory b) {
        _fillReserves();
        Expect memory e;
        e.s0 = exactIn == zeroForOne; // ETH is the specified currency
        uint256 amount = e.s0 ? ETH_SWAP : USD_SWAP;
        SwapParams memory p = _p(exactIn, zeroForOne, amount);
        (e.specified, e.unspecified) = e.s0 ? (eth, usdc) : (usdc, eth);
        e.resSpec = hook.reserveOf(e.specified);
        e.resUnspec = hook.reserveOf(e.unspecified);
        e.nominal = hook.nominalRebateOf(amount);
        assertGt(e.nominal, 0);
        assertLe(
            e.nominal, hook.rebateBudgetLeft(key.toId(), e.specified), "test setup: the budget should allow the whole rebate"
        );

        b = _swapWithBooks(trader, key, p);
        _assertDeltas(e, p, b, label);
        _assertBooks(e, b, label);
    }

    /// @notice P2, P3: the hook's delta on each side, as the manager booked it
    function _assertDeltas(Expect memory e, SwapParams memory p, SwapBooks memory b, string memory label) internal view {
        int256 h0 = b.pool0 - b.caller0;
        int256 h1 = b.pool1 - b.caller1;
        (int256 spec, int256 unspec) = e.s0 ? (h0, h1) : (h1, h0);
        (int256 poolSpec, int256 poolUnspec) = e.s0 ? (b.pool0, b.pool1) : (b.pool1, b.pool0);
        console2.log(label);
        console2.log("  hook delta specified, unspecified:", vm.toString(spec), vm.toString(unspec));
        console2.log("  pool ETH, USDL                   :", vm.toString(b.pool0), vm.toString(b.pool1));
        console2.log("  swapper ETH, USDL                :", vm.toString(b.swapper0), vm.toString(b.swapper1));
        console2.log("  hook ETH, USDL                   :", vm.toString(b.hook0), vm.toString(b.hook1));

        // P3: the rebate, in the specified currency, negative, nominal
        assertEq(spec, -int256(e.nominal), string.concat(label, ": rebate is not -0.10 % of |amountSpecified|"));
        // P2: the fee, exact, in the unspecified currency - at this price the wrong side is 3e8 times off
        assertEq(unspec, int256(_abs(poolUnspec) * 30 / 10_000), string.concat(label, ": fee is not 0.30 % of unspecified"));
        assertGt(unspec, 0, string.concat(label, ": no fee"));
        assertEq(poolSpec, p.amountSpecified - int256(e.nominal), string.concat(label, ": pool's specified amount"));
        assertEq(e.s0 ? b.caller0 : b.caller1, p.amountSpecified, string.concat(label, ": swapper's specified side"));
        // the ledger follows the balances, ETH as tokens
        assertEq(hook.reserveOf(e.specified), e.resSpec - e.nominal, string.concat(label, ": specified reserve"));
        assertEq(hook.reserveOf(e.unspecified), e.resUnspec + uint256(unspec), string.concat(label, ": unspecified reserve"));
    }

    /// @notice P1, ETH included: the swapper's ETH net of the router's refund, the hook's ETH, the manager's ETH
    function _assertBooks(Expect memory, SwapBooks memory b, string memory label) internal view {
        assertEq(b.swapper0, b.caller0, string.concat(label, ": swapper's ETH is not the returned delta"));
        assertEq(b.hook0, b.pool0 - b.caller0, string.concat(label, ": hook's ETH is not its booked delta"));
        assertEq(b.hook1, b.pool1 - b.caller1, string.concat(label, ": hook's USDL is not its booked delta"));
        assertEq(b.swapper0 + b.hook0 + b.manager0, 0, string.concat(label, ": ETH created or destroyed"));
        assertEq(b.swapper1 + b.hook1 + b.manager1, 0, string.concat(label, ": USDL created or destroyed"));
        assertEq(b.manager0, -b.pool0, string.concat(label, ": manager's ETH"));
        assertEq(b.manager1, -b.pool1, string.concat(label, ": manager's USDL"));
        assertEq(address(router).balance, 0, string.concat(label, ": the router kept ETH"));
        assertEq(address(hook).balance, hook.reserveOf(eth), string.concat(label, ": the hook's ETH is not its ledger"));
        assertEq(usd.trueBalanceOf(address(hook)), hook.reserveOf(usdc), string.concat(label, ": USDL is not the ledger"));
    }

    // ------------------------------------------------------------------ ETH on the SPECIFIED side: the rebate in ETH
    function test_eth_specified_exact_in_eth_in_the_rebate_is_paid_in_eth() public {
        SwapBooks memory b = _orientation(true, true, "exact-in  zeroForOne: ETH in, specified");
        assertEq(b.hook0, -int256(hook.nominalRebateOf(ETH_SWAP)), "the rebate did not leave the hook in ETH");
    }

    function test_eth_specified_exact_out_eth_out_the_rebate_is_paid_in_eth() public {
        SwapBooks memory b = _orientation(false, false, "exact-out oneForZero: ETH out, specified");
        assertEq(b.hook0, -int256(hook.nominalRebateOf(ETH_SWAP)), "the rebate did not leave the hook in ETH");
    }

    // ------------------------------------------------------------------ ETH on the UNSPECIFIED side: the fee in ETH
    function test_eth_unspecified_exact_in_eth_out_the_fee_is_taken_in_eth() public {
        SwapBooks memory b = _orientation(true, false, "exact-in  oneForZero: ETH out, unspecified");
        assertGt(b.hook0, 0, "the fee did not reach the hook in ETH");
    }

    function test_eth_unspecified_exact_out_eth_in_the_fee_is_taken_in_eth() public {
        SwapBooks memory b = _orientation(false, true, "exact-out zeroForOne: ETH in, unspecified");
        assertGt(b.hook0, 0, "the fee did not reach the hook in ETH");
        assertGt(b.valueSent, uint256(-b.swapper0), "the exact-out swap got no refund");
    }

    /// @notice ITEM 14, THE FEE SIDE (found by the verifier V14): P7 protects a payment in flight from the hook's REBATE -
    /// with a currency synced the hook pays none - but not from its FEE. When the synced currency is the pool's own token
    /// and the fee is taken in it (ETH in, exact-in: the unspecified side is USDL), the hook's `take` moves the manager's
    /// USDL after the payer's checkpoint: with nothing sent yet the payer's `settle()` underflows (a bare `Panic(0x11)`),
    /// with 1 USDL sent it is credited 1 USDL less the fee and its books do not close (`CurrencyNotSettled`). Either way
    /// the payer's whole transaction dies - a denial of service, not a theft. Skipping the `take` alone would leave the
    /// hook's own delta open; keeping the fee as a claim (`mint`) while its currency is synced would move no balance, but
    /// changes the example's balance-read ledger and is not tried here. A LIMIT of the example, stated in the README; the
    /// control, an ERC-20 that is not in the pool synced, stands with the rebate skipped
    function test_a_payment_in_flight_in_the_fee_currency_dies_on_the_fee_take() public {
        _fillReserves();
        SyncFirstRouter other = new SyncFirstRouter(manager, currency0); // a harness token that is not in this pool
        vm.deal(address(other), 1e18);
        uint256 rebates = hook.rebatesPaid(eth);
        uint256 fees = hook.reserveOf(usdc);
        other.swapEthIn{value: ETH_SWAP}(key, ETH_SWAP, 0);
        assertEq(hook.rebatesPaid(eth), rebates, "P7: a rebate was paid while a payment was in flight");
        assertGt(hook.reserveOf(usdc), fees, "the control swap paid no fee");

        SyncFirstRouter same = new SyncFirstRouter(manager, usdc);
        vm.deal(address(same), 1e18);
        usd.mint(address(same), 1e6);
        vm.expectRevert(stdError.arithmeticError);
        same.swapEthIn{value: ETH_SWAP}(key, ETH_SWAP, 0);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        same.swapEthIn{value: ETH_SWAP}(key, ETH_SWAP, 1e6);
    }

    /// @notice TWO POOLS SHARING ETH (K15). ETH is on one side of almost every pool a hook serves, so a reserve kept per
    /// currency, hook-wide, was the common case: the ETH fees of this pool (ETH / USDL) paid the ETH rebates of any other
    /// pool on the hook. Pool B, ETH / token1, has earned nothing: a swap on it with ETH specified is paid no rebate, and
    /// this pool's ETH reserve does not move. Once pool B has earned ETH of its own, its rebate is paid out of THAT.
    /// Red with the rebate funded by the hook-wide reserve (mutant M13a in the README): pool B was paid 1e14 wei.
    function test_the_eth_reserve_of_one_pool_pays_no_eth_rebate_on_another() public {
        _fillReserves();
        PoolKey memory b = _initNativePool(IHooks(address(hook)), 3000, 60, 79228162514264337593543950336, currency1);
        token1.mint(provider, 1_000e18);
        token1.mint(trader, 1_000e18);
        vm.prank(provider);
        token1.approve(address(liquidity), type(uint256).max);
        vm.prank(trader);
        token1.approve(address(router), type(uint256).max);
        vm.deal(provider, 100e18);
        _addFullRangeLiquidity(b, provider, 10e18);
        uint256 reserveA = hook.poolReserveOf(key.toId(), eth);
        assertGt(reserveA, 0, "test setup: pool A earned no ETH");

        SwapBooks memory s = _swapWithBooks(trader, b, _p(true, true, 1e17)); // ETH in, exact-in: ETH specified
        assertEq(s.pool0 - s.caller0, 0, "pool B was paid an ETH rebate out of pool A's ETH fees");
        assertEq(hook.poolReserveOf(key.toId(), eth), reserveA, "pool A's ETH reserve paid for pool B");

        for (uint256 i = 0; i < 3; i++) {
            _swapWithBooks(trader, b, _p(true, false, 1e18)); // token1 in: the fee is ETH, pool B's own
        }
        vm.roll(vm.getBlockNumber() + 1);
        uint256 reserveB = hook.poolReserveOf(b.toId(), eth);
        assertGt(reserveB, 0, "pool B earned no ETH");
        s = _swapWithBooks(trader, b, _p(true, true, 1e17));
        uint256 expected = hook.nominalRebateOf(1e17) < reserveB / 10 ? hook.nominalRebateOf(1e17) : reserveB / 10;
        assertEq(s.pool0 - s.caller0, -int256(expected), "pool B's rebate is not out of its own ETH");
        assertEq(hook.poolReserveOf(key.toId(), eth), reserveA, "pool A's ETH reserve moved on pool B's swap");
        assertEq(address(hook).balance, hook.reserveOf(eth), "the hook's ETH is not its hook-wide ledger");
        assertEq(hook.reserveOf(eth), reserveA + hook.poolReserveOf(b.toId(), eth), "hook-wide != sum of the pools");
    }

    /// @notice the per-block cap in ETH: rebates of one block stop at 10 % of the ETH reserve, to the wei
    function test_the_eth_rebates_of_a_block_stop_at_the_cap() public {
        _fillReserves();
        uint256 cap = hook.reserveOf(eth) * 1_000 / 10_000;
        uint256 paid;
        for (uint256 i = 0; i < 12; i++) {
            SwapBooks memory b = _swapWithBooks(trader, key, _p(true, true, 1e18));
            paid += uint256(-(b.pool0 - b.caller0));
        }
        assertEq(paid, cap, "the ETH rebates of a block are not the cap to the wei");
        assertEq(hook.rebatesPaid(eth), cap);
        assertEq(address(hook).balance, hook.reserveOf(eth), "the hook's ETH is not its ledger");
    }
}
