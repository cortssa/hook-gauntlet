// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISimAgent, ISimSearcher, SimView, Intent, Fill, VENUE_UNDER_TEST} from "../ISimAgent.sol";

/// @notice The classic sandwich, as a searcher: for a victim swap on the venue under test, trade the same direction
/// in front of it (pushing the price against the victim) and reverse behind it (selling into the price the victim
/// moved). Front-run size is a multiple of the victim's; the back-run sells exactly what the front-run bought.
///
/// It only exists under BUNDLE ordering: under FCFS the engine never asks it, and its line in the ledger says
/// "decided 0". Run the same scenario under both orderings and the difference in its P&L is what the ordering
/// model is worth to it - on a first-come-first-served sequencer, nothing.
///
/// Sizing here is the crudest possible (a fixed multiple); real bots search the front-run size against the pool
/// state (binary search is what public implementations converge on). That search is a straightforward
/// addition - and a hook whose fee rises with same-block volume is the thing that makes it stop early.
contract Sandwicher is ISimAgent, ISimSearcher {
    string private _name;
    uint256 public immutable multipleBps; // front-run size = victim.amountIn * multipleBps / 10000
    /// @notice do not bother below this size. Compared with `victim.amountIn` AS IS, so it is in the VICTIM's unit
    /// (`Intent.amountInQuote`): set it for the population the scenario runs. Not converted, on purpose - the only
    /// price a searcher sees at `wrap` is the one it is about to move, and a threshold that silently changed meaning
    /// with it would be worse than one that says what it compares. A population mixing quote-sized and input-sized
    /// victims needs a threshold per unit, which this agent does not have.
    uint256 public immutable minVictim;

    uint256 public wraps;
    uint256 public frontBought; // what the last front-run returned, the amount the back-run sells
    bool private frontZeroForOne;

    constructor(string memory name_, uint256 multipleBps_, uint256 minVictim_) {
        _name = name_;
        multipleBps = multipleBps_;
        minVictim = minVictim_;
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function latency() external pure returns (uint256) {
        return 0;
    }

    function observe(SimView calldata) external {}

    /// @notice a pure searcher: it never trades on its own, only around others
    function decide() external pure returns (bool, Intent memory it) {
        return (false, it);
    }

    function wrap(Intent calldata victim, SimView calldata) external returns (Intent[] memory before_) {
        if (victim.venue != VENUE_UNDER_TEST || victim.amountIn < minVictim) return before_;
        wraps += 1;
        frontZeroForOne = victim.zeroForOne;
        frontBought = 0;
        before_ = new Intent[](1);
        before_[0].venue = VENUE_UNDER_TEST;
        before_[0].zeroForOne = victim.zeroForOne;
        before_[0].amountIn = victim.amountIn * multipleBps / 10_000;
        // a multiple of the victim's size is in the victim's unit, and says so. The back leg sells what this one
        // delivered, so it never carries the flag (the arbitrageur's closing leg, the same rule)
        before_[0].amountInQuote = victim.amountInQuote;
        before_[0].maxSlippageBps = 10_000;
    }

    function unwind(Intent calldata victim, Fill calldata, SimView calldata) external returns (Intent[] memory after_) {
        if (victim.venue != VENUE_UNDER_TEST || frontBought == 0) return after_;
        after_ = new Intent[](1);
        after_[0].venue = VENUE_UNDER_TEST;
        after_[0].zeroForOne = !frontZeroForOne;
        after_[0].amountIn = frontBought;
        after_[0].maxSlippageBps = 10_000;
        frontBought = 0;
    }

    /// @dev the front-run's fill tells the back-run its size; the back-run's fill is just P&L
    function settle(Intent calldata it, Fill calldata f) external {
        if (f.executed && it.zeroForOne == frontZeroForOne && frontBought == 0) frontBought = f.amountOut;
    }
}
