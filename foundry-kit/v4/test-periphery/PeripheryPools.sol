// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PeripheryHarness} from "./PeripheryHarness.sol";

/// @notice The world the periphery suites share, on either manager: the harness's world plus the periphery, three
/// funded actors that approved it, and the pools' currencies and sizes.
///
/// On the source (or fixture) manager: the harness's two hostile tokens (honest unless a test flips a switch; 18
/// decimals, price 1) and ETH; liquidity 1e21, a swap 1e18. On the fork: real USDC / WETH and ETH at 4 000 USDC per ETH
/// (ticks 193 380 and -193 380, as `test/fork/ForkExamples.t.sol`), liquidity 1e16 (about 632 000 USDC and 158 ETH), a
/// swap 400 USDC or 0.1 ETH - funded with `_fundReal`.
abstract contract PeripheryPools is PeripheryHarness {
    address internal provider = address(0xA11CE);
    address internal lp2 = address(0xC0FFEE);
    address internal trader = address(0xB0B);
    Currency internal eth = Currency.wrap(address(0));

    /// @notice what the tests pass as `hookData`: 70 bytes, so not a whole number of words (a decoder that pads or
    /// truncates is seen), different per call site
    bytes internal constant HOOK_DATA =
        "gauntlet/hookData: the user's bytes, passed through the periphery 0001";

    int24 internal constant TICK_USDC_WETH = 193_380;
    int24 internal constant TICK_ETH_USDC = -193_380;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    /// @notice the manager (source, fixture or fork, by `V4_MANAGER`), the harness's currencies and routers, the
    /// periphery, and the actors funded and approved
    function _setUpPeripheryWorld() internal {
        _setUpV4();
        _peripheryWorld();
    }

    /// @notice the same, for a suite that means nothing off the fork: SKIPS with the reason under any other manager
    function _setUpPeripheryWorldOnFork() internal {
        _setUpV4OnFork();
        _peripheryWorld();
    }

    function _peripheryWorld() private {
        _deployPeriphery();
        address[3] memory who = [provider, lp2, trader];
        for (uint256 i = 0; i < 3; i++) {
            if (peripheryIsDeployed) {
                _fundReal(realUsdc(), who[i], 10_000_000e6);
                _fundReal(realWeth(), who[i], 10_000e18);
                _fundReal(eth, who[i], 10_000e18);
                _approvePeriphery(who[i], realUsdc());
                _approvePeriphery(who[i], realWeth());
            } else {
                token0.mint(who[i], 1e24);
                token1.mint(who[i], 1e24);
                _fundNative(who[i], 1e24);
                _approvePeriphery(who[i], currency0);
                _approvePeriphery(who[i], currency1);
            }
        }
    }

    /// @notice the ERC-20 pool's two currencies, sorted
    function _pair() internal view returns (Currency, Currency) {
        if (!peripheryIsDeployed) return (currency0, currency1);
        (Currency a, Currency b) = (realUsdc(), realWeth());
        return Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
    }

    /// @notice the ERC-20 on the other side of ETH in the native pool
    function _nativeOther() internal view returns (Currency) {
        return peripheryIsDeployed ? realUsdc() : currency1;
    }

    function _keyOf(IHooks hook, uint24 fee, Currency a, Currency b) internal pure returns (PoolKey memory) {
        (Currency c0, Currency c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        return PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: 60, hooks: hook});
    }

    function _erc20Key(IHooks hook, uint24 fee) internal view returns (PoolKey memory) {
        (Currency a, Currency b) = _pair();
        return _keyOf(hook, fee, a, b);
    }

    function _nativeKey(IHooks hook, uint24 fee) internal view returns (PoolKey memory) {
        return _keyOf(hook, fee, eth, _nativeOther());
    }

    function _sqrtPriceOf(PoolKey memory k) internal view returns (uint160) {
        if (!peripheryIsDeployed) return SQRT_PRICE_1_1;
        return TickMath.getSqrtPriceAtTick(k.currency0.isAddressZero() ? TICK_ETH_USDC : TICK_USDC_WETH);
    }

    function _liq() internal view returns (uint256) {
        return peripheryIsDeployed ? 1e16 : 1e21;
    }

    /// @notice one swap's size in `c`
    function _amt(Currency c) internal view returns (uint128) {
        if (!peripheryIsDeployed) return 1e18;
        return Currency.unwrap(c) == MAINNET_USDC ? 400e6 : 1e17;
    }

    /// @notice a swap of the right size in whichever currency it specifies, with limits wide enough never to bind (the
    /// books, not the limits, are what the tests read)
    function _swapOf(PoolKey memory k, bool zeroForOne, bool exactIn, bytes memory hookData)
        internal
        view
        returns (RouterSwap memory s)
    {
        Currency specified = exactIn == zeroForOne ? k.currency0 : k.currency1;
        s.zeroForOne = zeroForOne;
        s.exactIn = exactIn;
        s.amount = _amt(specified);
        s.limit = exactIn ? 0 : s.amount * 4;
        if (!exactIn && !peripheryIsDeployed) s.limit = s.amount * 2;
        if (!exactIn && peripheryIsDeployed) {
            // exact-out: the input is the OTHER currency, at 4 000 USDC per ETH
            Currency input = zeroForOne ? k.currency0 : k.currency1;
            s.limit = Currency.unwrap(input) == MAINNET_USDC ? 1_000e6 : 1e18;
        }
        s.hookData = hookData;
    }

    /// @notice initialise `k` through the PositionManager and give it `provider`'s full-range position
    function _openPool(PoolKey memory k) internal returns (uint256 tokenId) {
        _initPoolThroughPosm(k, _sqrtPriceOf(k));
        (int24 lower, int24 upper) = _fullRange(k.tickSpacing);
        tokenId = _posmMint(provider, k, lower, upper, _liq(), "");
    }

    /// @notice `PeripheryProbeHook.flags()`, spelled out: the miner needs them before the hook exists. Every callback
    /// without a delta: before/after initialise, add, remove, swap, donate (bits 13 to 4)
    function _probeFlags() internal pure returns (uint160) {
        return uint160((1 << 13) | (1 << 12) | (1 << 11) | (1 << 10) | (1 << 9) | (1 << 8) | (1 << 7) | (1 << 6) | (1 << 5) | (1 << 4));
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }
}
