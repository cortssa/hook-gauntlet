// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISimAgent, SimView, Intent, Fill, VENUE_UNDER_TEST, VENUE_MAIN} from "../ISimAgent.sol";

/// @notice The stale-quote extractor. Watches the venue under test against the main market and, when the two PRICES
/// differ by more than `thresholdBps`, trades on the venue under test in the direction that pockets the difference:
/// buys currency0 there when it is cheaper than on the main market, sells it there when it is dearer.
///
/// `thresholdBps` is a PRICE difference in basis points (100 = 1 %). Set it above the round trip's cost - the venue's
/// fee and any tax, the main market's fee, half the spread - or the agent trades at a loss every step and its P&L
/// measures its own stupidity, not the stale quote (the kit measured exactly that on a venue with a 3 % tax and a
/// 0.5 % threshold: 197 trades in 200 steps, all red).
///
/// `closeOnMain`: false = the position is never closed; the ledger values the inventory at the main market's price,
/// which is the UPPER bound of what a stale quote is worth (no fee, no impact on the second leg, and the inventory rides
/// the world's moves until the end). true = the step after a fill on the venue, the agent sends the reverse trade to
/// the main market, at its own latency: it pays that market's fee and impact, and what it keeps is REALISED.
///
/// This is the attack that exists on a first-come-first-served chain: no mempool, no bundles - only seeing a public
/// price move and reaching the sequencer before the venue's quote has caught up. Its latency is therefore the number
/// that matters most in its results; run it at several.
contract Arbitrageur is ISimAgent {
    string private _name;
    uint256 public immutable size;
    uint256 public immutable thresholdBps;
    uint256 private immutable _latency;
    bool public immutable closeOnMain;

    SimView public last;
    uint256 public trades;
    uint256 public fillsOk;
    uint256 public closes;
    // the closing leg waiting to be sent (closeOnMain only): what the last venue fill bought, to sell on the main market
    bool internal pendingClose;
    bool internal pendingZeroForOne;
    uint256 internal pendingAmount;
    /// @notice the unit `size` is in: false (default) = the input currency; true = currency1 (quote) both ways, for a pair
    /// whose two currencies have very different units. It applies to the OPENING leg only - the closing leg is sized by
    /// what the opening leg delivered, never by `size`. Set by the scenario BEFORE the agent is registered. A setter and
    /// not a constructor argument so that every scenario written before it keeps its meaning unchanged.
    bool public sizeInQuote;

    constructor(string memory name_, uint256 size_, uint256 thresholdBps_, uint256 latency_, bool closeOnMain_) {
        _name = name_;
        size = size_;
        thresholdBps = thresholdBps_;
        _latency = latency_;
        closeOnMain = closeOnMain_;
    }

    function setSizeInQuote(bool on) external {
        sizeInQuote = on;
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function latency() external view returns (uint256) {
        return _latency;
    }

    function observe(SimView calldata v) external {
        last = v;
    }

    /// @dev prices compared as (sqrtPrice >> 48)^2: a price in Q96 with 48 bits of the sqrt dropped, which keeps the
    /// square inside uint256 and the ratio exact to far better than a basis point
    function decide() external returns (bool wants, Intent memory it) {
        if (pendingClose) {
            pendingClose = false;
            closes += 1;
            it.venue = VENUE_MAIN;
            it.zeroForOne = pendingZeroForOne;
            it.amountIn = pendingAmount;
            // `amountInQuote` stays false, whatever `sizeInQuote` says: `pendingAmount` is what the fill DELIVERED, so
            // it is already in the currency this leg sells. Flagging it would have the binding convert it again.
            it.maxSlippageBps = 10_000;
            return (true, it);
        }
        if (last.mainSqrtPriceX96 == 0 || last.sqrtPriceX96 == 0) return (false, it);
        uint256 venuePx = _px(last.sqrtPriceX96);
        uint256 mainPx = _px(last.mainSqrtPriceX96);
        it.venue = VENUE_UNDER_TEST;
        it.amountIn = size;
        it.amountInQuote = sizeInQuote; // the OPENING leg only: `size` is the scenario's unit
        it.maxSlippageBps = 10_000; // it knows what it is doing; the quote is the number it acts on
        if (venuePx * 10_000 < mainPx * (10_000 - thresholdBps)) {
            // currency0 is cheaper on the venue: buy it there (pay currency1)
            it.zeroForOne = false;
            trades += 1;
            return (true, it);
        }
        if (venuePx * 10_000 > mainPx * (10_000 + thresholdBps)) {
            // currency0 is dearer on the venue: sell it there
            it.zeroForOne = true;
            trades += 1;
            return (true, it);
        }
        return (false, it);
    }

    function settle(Intent calldata it, Fill calldata f) external {
        if (!f.executed) return;
        fillsOk += 1;
        if (closeOnMain && it.venue == VENUE_UNDER_TEST && f.amountOut > 0) {
            pendingClose = true;
            pendingZeroForOne = !it.zeroForOne;
            pendingAmount = f.amountOut;
        }
    }

    function _px(uint160 sqrtP) internal pure returns (uint256) {
        uint256 s = uint256(sqrtP) >> 48;
        return s * s;
    }
}
