// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {
    ISimAgent,
    ISimSearcher,
    SimView,
    Intent,
    Fill,
    VENUE_UNDER_TEST,
    KIND_SWAP,
    KIND_ADD_LIQUIDITY,
    KIND_REMOVE_LIQUIDITY
} from "../ISimAgent.sol";

/// @notice Just-in-time liquidity, as a searcher: for a swap about to execute, put a narrow position around the
/// current price in front of it, take it off behind it, and keep the fee the swap paid into that range. The passive
/// LP, whose liquidity was there all along, sees its share of that fee shrink to almost nothing for that swap.
///
/// Like the sandwicher it only exists under BUNDLE ordering, and unlike the sandwicher it does not move the price
/// against the victim - the victim gets a BETTER execution (more liquidity), the passive LP pays for it. Whether it
/// is profitable is the same question as always: fee earned against the inventory it is left holding at a price
/// the swap moved; the published rule of thumb is that it pays only when fee minus hedging cost is positive and
/// the swap is large (the Uniswap Labs post on JIT liquidity).
contract JitLP is ISimAgent, ISimSearcher {
    string private _name;
    int256 public immutable liquidity;
    /// @notice the smallest victim worth a position. Compared with `victim.amountIn` AS IS, so it is in the VICTIM's
    /// unit (`Intent.amountInQuote`), not converted - same reasoning as `Sandwicher.minVictim`.
    uint256 public immutable minVictim;
    int24 public immutable spacing;

    uint256 public wraps;
    int24 private lower;
    int24 private upper;
    bool private inPosition;

    constructor(string memory name_, int256 liquidity_, uint256 minVictim_, int24 spacing_) {
        _name = name_;
        liquidity = liquidity_;
        minVictim = minVictim_;
        spacing = spacing_;
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function latency() external pure returns (uint256) {
        return 0;
    }

    function observe(SimView calldata) external {}

    function decide() external pure returns (bool, Intent memory it) {
        return (false, it);
    }

    /// @notice one spacing below the current tick to one spacing above: the narrowest range that surely contains it
    function wrap(Intent calldata victim, SimView calldata v) external returns (Intent[] memory before_) {
        if (victim.venue != VENUE_UNDER_TEST || victim.kind != KIND_SWAP || victim.amountIn < minVictim) return before_;
        int24 tick = TickMath.getTickAtSqrtPrice(v.sqrtPriceX96);
        int24 base = (tick / spacing) * spacing;
        if (tick < 0 && base != tick) base -= spacing;
        lower = base - spacing;
        upper = base + 2 * spacing;
        wraps += 1;
        before_ = new Intent[](1);
        before_[0].venue = VENUE_UNDER_TEST;
        before_[0].kind = KIND_ADD_LIQUIDITY;
        before_[0].tickLower = lower;
        before_[0].tickUpper = upper;
        before_[0].liquidityDelta = liquidity;
    }

    function unwind(Intent calldata victim, Fill calldata, SimView calldata) external returns (Intent[] memory after_) {
        if (victim.venue != VENUE_UNDER_TEST || !inPosition) return after_;
        after_ = new Intent[](1);
        after_[0].venue = VENUE_UNDER_TEST;
        after_[0].kind = KIND_REMOVE_LIQUIDITY;
        after_[0].tickLower = lower;
        after_[0].tickUpper = upper;
        after_[0].liquidityDelta = -liquidity;
    }

    function settle(Intent calldata it, Fill calldata f) external {
        if (!f.executed) return;
        if (it.kind == KIND_ADD_LIQUIDITY) inPosition = true;
        if (it.kind == KIND_REMOVE_LIQUIDITY) inPosition = false;
    }
}
