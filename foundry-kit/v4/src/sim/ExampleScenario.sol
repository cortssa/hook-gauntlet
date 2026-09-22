// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {V4Harness} from "../V4Harness.sol";
import {HookMiner} from "../HookMiner.sol";
import {SwapEventReader} from "../SwapEventReader.sol";
import {CappedDynamicFeeHook} from "../examples/CappedDynamicFeeHook.sol";
import {ISimAgent, ISimSearcher, Intent, Fill, VENUE_MAIN, KIND_SWAP} from "./ISimAgent.sol";
import {SimEngine} from "./SimEngine.sol";

/// @title ExampleScenario - SimEngine bound to the kit's example hook
/// @notice The binding a project copies and adapts: which pool, which router, how a quote is obtained, how an
/// intent is executed, and how an agent is funded. Everything else is the engine's.
///
/// ADAPT: a project with its own router binds `_execute` to it; a project with an on-chain quoter or a lens binds
/// `_quote` to that instead of the snapshot-and-revert used here. Keep the verbs' contracts (a quote of 0 means
/// "would not execute"; a Fill with `executed = false` carries the revert selector) and the ledger and the report
/// keep working unchanged.
abstract contract ExampleScenario is V4Harness, SimEngine {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for *;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 internal constant CALL_GAS = 4_000_000;

    CappedDynamicFeeHook public hook;
    PoolKey internal key;
    /// @notice the MAIN MARKET: a plain v4 pool on the same currencies with no hook and a static fee - where the token
    /// "really" trades, pushed by the world's traders, and the market a stale quote on the hook's pool is stale AGAINST.
    /// Real AMM math in the same EVM, not a price stub. When a fork of the target chain is available this is the
    /// pool that exists there; until then it is this one.
    PoolKey internal mainKey;
    bool public hasMainMarket;
    address internal provider = address(0x11D0);

    /// @notice manager, currencies, routers, the example hook on a dynamic-fee pool, and one passive full-range
    /// provider. Set `cadence` before calling, or Ethereum L1 is assumed.
    function _setUpScenario(int256 liquidityAmount) internal {
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
        key = _initPool(IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, SQRT_PRICE_1_1);
        _fundAndApprove(provider, uint256(liquidityAmount) * 4);
        _addFullRangeLiquidity(key, provider, liquidityAmount);
        _initEngine();
        // said, not defaulted: this example runs on a local manager whose gas nobody pays, so its net P&L is its gross
        // one. A binding of a real chain prices gas here (`SimLedger.gasPriceQuoteE18`) and its dump shows the cost.
        ledger.setGasPrice(0);
    }

    /// @notice add the main market: a hookless pool at the same starting price, `fee` in hundredths of a bip
    /// (3000 = 0.30 %), with its own liquidity
    function _addMainMarket(uint24 fee, int256 liquidityAmount) internal {
        mainKey = _initPool(IHooks(address(0)), fee, 60, SQRT_PRICE_1_1);
        _fundAndApprove(provider, uint256(liquidityAmount) * 4);
        _addFullRangeLiquidity(mainKey, provider, liquidityAmount);
        hasMainMarket = true;
    }

    /// @notice an agent that is also a searcher (bundles under BUNDLE ordering)
    function _addSearcher(ISimAgent a, uint256 funding) internal {
        _addAgent(a, funding);
        _registerSearcher(ISimSearcher(address(a)));
    }

    /// @notice give an agent a wallet and put it on the books
    function _addAgent(ISimAgent a, uint256 funding) internal {
        _fundAndApprove(address(a), funding);
        _registerAgent(a);
    }

    // ------------------------------------------------------------------ the four verbs
    /// @notice what the swap would return NOW: run it in a snapshot and roll the state back. This is exactly what an
    /// off-chain quoter does (a revert-and-catch simulation), and it is the honest quote: the same code path, the
    /// same block, the same hook state.
    function _quote(Intent memory it) internal override returns (uint256 out) {
        uint256 snap = vm.snapshotState();
        (bool ok, uint256 got,,) = _swap(it);
        out = ok ? got : 0;
        vm.revertToState(snap);
    }

    function _execute(Intent memory it) internal override returns (Fill memory f) {
        if (it.kind != KIND_SWAP) return _modifyLiquidity(it);
        uint256 snap = vm.snapshotState();
        uint256 g = gasleft();
        (bool ok, uint256 got, uint256 used, bytes4 sel) = _swap(it);
        f.gasUsed = g - gasleft();
        if (ok && got < it.minOut) {
            // a router with a slippage check would have reverted; this one is minimal, so the check is here
            vm.revertToState(snap);
            f.executed = false;
            f.revertSelector = bytes4(keccak256("TooLittleReceived()"));
            return f;
        }
        f.executed = ok;
        f.amountOut = got;
        f.amountInUsed = used;
        f.revertSelector = sel;
        if (ok) {
            // recorded logs include frames that reverted (the quote's swap ran in a snapshot and its Swap event is
            // still here): the LAST Swap event is this execution's, which is why `lastSwapFee` takes the last
            (bool found, uint24 fee) = SwapEventReader.lastSwapFee(vm.getRecordedLogs(), address(manager));
            if (found) f.feeCharged = fee;
        }
    }

    /// @notice a liquidity change, executed as given, in the agent's own position (salt = the agent's address, so two
    /// agents on the same range never share one). No quote, no slippage rule: what it costs is what it costs.
    function _modifyLiquidity(Intent memory it) internal returns (Fill memory f) {
        PoolKey memory k = it.venue == VENUE_MAIN ? mainKey : key;
        uint256 g = gasleft();
        vm.prank(it.agent);
        try liquidity.modifyLiquidity{gas: CALL_GAS}(
            k,
            ModifyLiquidityParams({
                tickLower: it.tickLower,
                tickUpper: it.tickUpper,
                liquidityDelta: it.liquidityDelta,
                salt: bytes32(uint256(uint160(it.agent)))
            }),
            ""
        ) {
            f.executed = true;
        } catch (bytes memory err) {
            f.executed = false;
            f.revertSelector = err.length >= 4 ? bytes4(err) : bytes4(0);
        }
        f.gasUsed = g - gasleft();
    }

    function _sqrtPriceNow(uint8 venue) internal view override returns (uint160 sqrtP) {
        if (venue == VENUE_MAIN) {
            if (!hasMainMarket) return 0;
            (sqrtP,,,) = manager.getSlot0(mainKey.toId());
        } else {
            (sqrtP,,,) = manager.getSlot0(key.toId());
        }
    }

    /// @notice currency0 valued at the main market's price when there is one, else at the hook pool's own
    function _referencePriceX96() internal view override returns (uint256) {
        // (sqrtP >> 48)^2 == sqrtP^2 >> 96 up to the 48 dropped bits, and it cannot overflow: a pool parked at the edge
        // of its price range (a partial fill that hit MAX_SQRT_PRICE) has sqrtP ~ 2^160, whose square does not fit
        uint256 sp = uint256(_sqrtPriceNow(hasMainMarket ? VENUE_MAIN : 0)) >> 48;
        return sp * sp; // P in Q96
    }

    function _balances(address a) internal view override returns (uint256, uint256) {
        return (token0.balanceOf(a), token1.balanceOf(a));
    }

    /// @dev `used` is the input the pool actually took: less than `it.amountIn` when the price limit or the last tick of
    /// liquidity stopped the swap early (v4 leaves the rest unspent, a book refunds it)
    /// @notice an intent sized in quote (`Intent.amountInQuote`) reached a binding that has no conversion for it
    error QuoteSizedIntentUnsupported();

    function _swap(Intent memory it) internal returns (bool ok, uint256 out, uint256 used, bytes4 sel) {
        // both currencies of the example have the same unit and this binding does not convert: executing a quote-sized
        // sell as if its amount were currency0 is the silent wrong answer the flag exists to prevent
        if (it.amountInQuote && it.zeroForOne) revert QuoteSizedIntentUnsupported();
        vm.recordLogs();
        PoolKey memory k = it.venue == VENUE_MAIN ? mainKey : key;
        vm.prank(it.agent);
        try router.swap{gas: CALL_GAS}(
            k,
            SwapParams({
                zeroForOne: it.zeroForOne,
                amountSpecified: -int256(it.amountIn),
                sqrtPriceLimitX96: it.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        ) returns (BalanceDelta d) {
            int128 got = it.zeroForOne ? d.amount1() : d.amount0();
            int128 paid = it.zeroForOne ? d.amount0() : d.amount1();
            return (true, got > 0 ? uint256(uint128(got)) : 0, paid < 0 ? uint256(uint128(-paid)) : 0, bytes4(0));
        } catch (bytes memory err) {
            return (false, 0, 0, err.length >= 4 ? bytes4(err) : bytes4(0));
        }
    }
}
