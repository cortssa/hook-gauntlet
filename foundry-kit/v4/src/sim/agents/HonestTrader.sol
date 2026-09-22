// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISimAgent, SimView, Intent, Fill} from "../ISimAgent.sol";

/// @notice The simplest population member: trades a fixed size every N steps, alternating direction, with a
/// slippage rule and a latency. It has no information and no opinion; it is the swapper whose execution the
/// others' behaviour lands on. Every other agent is measured against what this one experiences.
///
/// ADAPT: an agent for YOUR hook decides on what it can observe (`SimView`), holds its own memory, and reports
/// whatever it wants counted through `settle`. Keep the three verbs and the ledger will do the rest.
contract HonestTrader is ISimAgent {
    string private _name;
    uint256 public immutable amount;
    uint256 public immutable everySteps;
    uint256 private immutable _latency;
    uint256 public immutable slippageBps;
    uint8 public immutable venue;

    SimView public last;
    bool public nextZeroForOne = true;
    uint256 public fills;
    uint256 public refusals;
    uint256 public totalShortfall;
    /// @notice the unit this agent sizes its swaps in: false (default) = `amountIn` is in the input currency; true =
    /// in currency1 (quote) both ways, for a pair whose two currencies have very different units, where one size in the
    /// input currency cannot mean the same thing both ways. Set by the scenario BEFORE the agent is registered. A
    /// setter and not a constructor argument so that every scenario written before it keeps its meaning unchanged.
    bool public sizeInQuote;

    constructor(
        string memory name_,
        uint256 amount_,
        uint256 everySteps_,
        uint256 latency_,
        uint256 slippageBps_,
        uint8 venue_
    ) {
        _name = name_;
        venue = venue_;
        amount = amount_;
        everySteps = everySteps_;
        _latency = latency_;
        slippageBps = slippageBps_;
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

    function decide() external returns (bool wants, Intent memory it) {
        if (last.step % everySteps != 0) return (false, it);
        it.venue = venue;
        it.zeroForOne = nextZeroForOne;
        it.amountIn = amount;
        it.amountInQuote = sizeInQuote;
        it.maxSlippageBps = slippageBps;
        nextZeroForOne = !nextZeroForOne;
        return (true, it);
    }

    function settle(Intent calldata it, Fill calldata f) external {
        if (!f.executed) {
            refusals += 1;
            return;
        }
        fills += 1;
        if (it.quotedOut > f.amountOut) totalShortfall += it.quotedOut - f.amountOut;
    }
}
