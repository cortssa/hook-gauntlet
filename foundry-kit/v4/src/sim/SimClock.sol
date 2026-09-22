// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The target chain's cadence, as parameters, and the arithmetic that turns a step counter into what the
/// EVM will report. Pure functions: the scenario applies the results with `vm.roll` / `vm.warp`.
///
/// Why this exists at all: a hook whose rule is "per block" means something different on every chain. On an
/// Arbitrum-style L2 (`doctrine/UPSTREAM.md` 1b, checked against the chain's own documentation) `block.number` is
/// an ESTIMATE OF THE L1 BLOCK, updated only periodically, while the sequencer produces its own blocks many times
/// a second. So "one block" for the hook is ~12 s and spans on the order of a hundred sequencer blocks - and a
/// sandbox that rolls `block.number` once per intent is simulating a chain that does not exist. `HOOK-ATTACKS.md`,
/// the class "What your CHAIN changes".
library SimClock {
    struct Cadence {
        uint256 l2BlockMillis; // sequencer block time; 100 on the L2 this was written against, 12 000 on L1
        uint256 l1BlockMillis; // 12 000 on Ethereum
        bool blockNumberIsL1Estimate; // true on Arbitrum-style chains: block.number = L1 estimate
        uint256 genesisTimestamp;
        uint256 genesisBlockNumber; // what block.number reads at step 0
    }

    /// @notice Ethereum L1: block.number and the block clock are the same thing.
    function ethereumL1() internal pure returns (Cadence memory) {
        return Cadence({
            l2BlockMillis: 12_000,
            l1BlockMillis: 12_000,
            blockNumberIsL1Estimate: false,
            genesisTimestamp: 1_700_000_000,
            genesisBlockNumber: 20_000_000
        });
    }

    /// @notice An Arbitrum-style L2 with 100 ms sequencer blocks and block.number as an L1 estimate. The 100 ms
    /// figure is a parameter, not a fact about any chain: set it from the chain's own documentation - and then
    /// measure it. Measured on one such chain on 2026-09-22 from 300 consecutive blocks read over its RPC: 9.4 blocks
    /// per second on average, 10 in most seconds, no empty second; the block's `l1BlockNumber` field advanced once
    /// per ~100-120 L2 blocks, i.e. every ~12 s. Both numbers are what this preset assumes.
    function orbitStyleL2(uint256 l2BlockMillis) internal pure returns (Cadence memory) {
        return Cadence({
            l2BlockMillis: l2BlockMillis,
            l1BlockMillis: 12_000,
            blockNumberIsL1Estimate: true,
            genesisTimestamp: 1_700_000_000,
            genesisBlockNumber: 20_000_000
        });
    }

    /// @notice milliseconds since genesis after `step` L2 blocks
    function elapsedMillis(Cadence memory c, uint256 step) internal pure returns (uint256) {
        return step * c.l2BlockMillis;
    }

    function timestampAt(Cadence memory c, uint256 step) internal pure returns (uint256) {
        return c.genesisTimestamp + elapsedMillis(c, step) / 1000;
    }

    /// @notice what `block.number` should read at `step`
    function blockNumberAt(Cadence memory c, uint256 step) internal pure returns (uint256) {
        if (!c.blockNumberIsL1Estimate) return c.genesisBlockNumber + step;
        return c.genesisBlockNumber + elapsedMillis(c, step) / c.l1BlockMillis;
    }

    /// @notice how many L2 steps share one value of `block.number` (1 on L1; 120 for 100 ms blocks under 12 s L1 blocks)
    function stepsPerBlockNumber(Cadence memory c) internal pure returns (uint256) {
        if (!c.blockNumberIsL1Estimate) return 1;
        return c.l1BlockMillis / c.l2BlockMillis;
    }
}
