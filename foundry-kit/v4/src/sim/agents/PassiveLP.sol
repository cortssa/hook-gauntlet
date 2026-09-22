// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISimAgent, SimView, Intent, Fill, KIND_ADD_LIQUIDITY, KIND_REMOVE_LIQUIDITY} from "../ISimAgent.sol";

/// @notice The liquidity provider who is not watching: puts a position on at the start, takes it off at `exitStep`,
/// and does nothing in between. Its P&L at the end - fees earned against what the price did to its inventory - is
/// the number every other agent's profit is ultimately taken from, and it is the number a hook that promises to
/// protect LPs is measured by.
///
/// ADAPT: on a hook that pulls from the LP's wallet by allowance, this agent's exposure is its ALLOWANCE, and the
/// binding should make it a parameter (unlimited, or capped at the inventory it means to expose) - it changes what
/// happens to the LP in a dump. On a v4 pool the position itself is the exposure, and the parameter is `liquidity`.
contract PassiveLP is ISimAgent {
    string private _name;
    uint8 public immutable venue;
    int24 public immutable tickLower;
    int24 public immutable tickUpper;
    int256 public immutable liquidity;
    uint256 public immutable exitStep;

    SimView public last;
    bool public added;
    bool public removed;

    constructor(
        string memory name_,
        uint8 venue_,
        int24 tickLower_,
        int24 tickUpper_,
        int256 liquidity_,
        uint256 exitStep_
    ) {
        _name = name_;
        venue = venue_;
        tickLower = tickLower_;
        tickUpper = tickUpper_;
        liquidity = liquidity_;
        exitStep = exitStep_;
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function latency() external pure returns (uint256) {
        return 0;
    }

    function observe(SimView calldata v) external {
        last = v;
    }

    function decide() external returns (bool wants, Intent memory it) {
        if (!added) {
            it.venue = venue;
            it.kind = KIND_ADD_LIQUIDITY;
            it.tickLower = tickLower;
            it.tickUpper = tickUpper;
            it.liquidityDelta = liquidity;
            return (true, it);
        }
        if (!removed && last.step >= exitStep) {
            it.venue = venue;
            it.kind = KIND_REMOVE_LIQUIDITY;
            it.tickLower = tickLower;
            it.tickUpper = tickUpper;
            it.liquidityDelta = -liquidity;
            return (true, it);
        }
        return (false, it);
    }

    function settle(Intent calldata it, Fill calldata f) external {
        if (!f.executed) return;
        if (it.kind == KIND_ADD_LIQUIDITY) added = true;
        if (it.kind == KIND_REMOVE_LIQUIDITY) removed = true;
    }
}
