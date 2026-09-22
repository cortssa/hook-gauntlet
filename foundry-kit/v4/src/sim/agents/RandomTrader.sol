// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISimAgent, SimView, Intent, Fill} from "../ISimAgent.sol";

/// @notice "The world": a trader whose sizes and directions come from a SEEDED pseudo-random stream, so that a
/// scenario has variation between runs - and the same seed reproduces the same run. This is the sandbox's own
/// randomness, on purpose: the fuzzer's seed does not pin a draw once a corpus is on (the kit measured that), and a
/// result that cannot be replayed is a rumour. Report over several seeds; name the seeds.
///
/// `driftBps` tilts the coin: 5000 is fair, more than that leans to selling currency0 (a dump), less to buying.
contract RandomTrader is ISimAgent {
    string private _name;
    uint8 public immutable venue;
    uint256 public immutable seed;
    uint256 public immutable minSize;
    uint256 public immutable maxSize;
    uint256 public immutable everyPct; // probability, in per cent, of trading in a given step
    uint256 public immutable driftBps;
    uint256 private immutable _latency;

    SimView public last;
    uint256 public fills;
    /// @notice the unit this agent sizes its swaps in: false (default) = `amountIn` is in the input currency; true =
    /// in currency1 (quote) both ways, for a pair whose two currencies have very different units, where one size in the
    /// input currency cannot mean the same thing both ways. Set by the scenario BEFORE the agent is registered. A
    /// setter and not a constructor argument so that every scenario written before it keeps its meaning unchanged.
    bool public sizeInQuote;

    constructor(
        string memory name_,
        uint8 venue_,
        uint256 seed_,
        uint256 minSize_,
        uint256 maxSize_,
        uint256 everyPct_,
        uint256 driftBps_,
        uint256 latency_
    ) {
        _name = name_;
        venue = venue_;
        seed = seed_;
        minSize = minSize_;
        maxSize = maxSize_;
        everyPct = everyPct_;
        driftBps = driftBps_;
        _latency = latency_;
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

    function decide() external view returns (bool wants, Intent memory it) {
        // keyed by the seed and the step ONLY: two traders with the same seed make the same decisions, which is what
        // lets a test tell a trader that reads its seed from one that does not
        uint256 r = uint256(keccak256(abi.encode(seed, last.step)));
        if (r % 100 >= everyPct) return (false, it);
        it.venue = venue;
        it.zeroForOne = ((r >> 8) % 10_000) < driftBps;
        it.amountIn = minSize + ((r >> 24) % (maxSize - minSize + 1));
        it.amountInQuote = sizeInQuote;
        it.maxSlippageBps = 10_000;
        return (true, it);
    }

    function settle(Intent calldata, Fill calldata f) external {
        if (f.executed) fills += 1;
    }
}
