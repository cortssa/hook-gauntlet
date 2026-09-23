// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title SimGasMeter - what one action would cost as its own transaction
/// @notice A binding reports `Fill.gasUsed`. It must be the gas the agent would pay to send that action on a chain, and
/// it must not depend on the test that runs it. This library builds that number from forge's record of the frame that
/// was just called: 21 000 intrinsic + the calldata (16 gas a non-zero byte, 4 a zero one) + the callee's own gas, less
/// the refund it earned, capped at a fifth of the whole (EIP-3529). Several calls sent as ONE transaction (a batch, a
/// re-balance) are added into one `Tx` and pay the intrinsic once.
///
/// WHY NOT `gasleft()` AROUND THE CALL. That window is in the TEST's frame. A scenario runs a whole tape as one forge
/// transaction, and a Solidity frame never frees memory: every word the binding, the ledger decoding and the agents'
/// views allocate stays, and the next word costs 3 + words/256 gas. The window charges that growth to whichever agent
/// happens to act, so the same action costs more late in a run than early, and more in a binding that reads more
/// (measured on a downstream binding, 2026-09-22: one agent's metered gas rose 17 % between two runs whose every
/// decision was identical, while the callee's own gas was equal to the unit). The window also carries the binding's own
/// bookkeeping and none of the intrinsic cost.
///
/// WHAT IT STILL IS: a LOWER bound. (1) Warm: the tape is one forge transaction, so a slot the harness touched before is
/// warm when the agent's transaction arrives; on a chain the first touch of each is 2 100 (slot) / 2 600 (account) more.
/// `vm.cool` would be the tool; on forge 1.8.1 it is not usable for this (it made a called contract's code read as empty
/// and changed a swap's outcome, measured downstream). (2) No L1 data fee, which is the chain's and not measurable here.
/// (3) A storage write is priced against the slot's value at the start of the TEST, not of the transaction, which can
/// only make it cheaper. The number never over-states what a sender pays.
library SimGasMeter {
    /// @dev forge's cheatcode address (`address(uint160(uint256(keccak256("hevm cheat code"))))`)
    address internal constant VM = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D;
    /// @notice what every transaction pays before its first opcode
    uint256 internal constant TX_BASE = 21_000;

    /// @notice one transaction being metered: the callees' own gas, their refunds, their calldata gas
    struct Tx {
        uint256 spent;
        int256 refunded;
        uint256 data;
    }

    /// @notice forge did not return a frame record this library can read
    error FrameGasUnreadable();

    /// @notice add the call that JUST returned or reverted - the last frame forge recorded - to `t`, with the calldata it
    /// was sent with. Call it before any other external call (a cheatcode call does not replace the record).
    /// Read by a raw staticcall and decoded by hand ON PURPOSE: forge 1.8.1 returns FIVE words for `lastFrameGas()` /
    /// `lastCallGas()` (limit, used, memory, refunded, remaining) while forge-std 1.16.2 declares its `Gas` struct with SIX
    /// (a trailing `gasStateUsed`), so the typed `vm.lastCallGas()` reverts in the decoder. Only the first four words are
    /// read here, which both layouts share.
    function addLastFrame(Tx memory t, bytes memory data) internal view {
        (bool ok, bytes memory r) = VM.staticcall(abi.encodeWithSignature("lastFrameGas()"));
        if (!ok || r.length < 128) revert FrameGasUnreadable();
        (, uint64 used,, int64 refunded) = abi.decode(r, (uint64, uint64, uint64, int64));
        t.spent += used;
        t.refunded += refunded;
        t.data += calldataGas(data);
    }

    /// @notice the calldata cost of `data` (EIP-2028: 16 a non-zero byte, 4 a zero byte)
    function calldataGas(bytes memory data) internal pure returns (uint256 g) {
        for (uint256 i = 0; i < data.length; i++) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    /// @notice what the sender pays for `t`: intrinsic + calldata + execution, less the refund capped at a fifth
    function total(Tx memory t) internal pure returns (uint256) {
        uint256 sum = TX_BASE + t.data + t.spent;
        uint256 refund = t.refunded > 0 ? uint256(t.refunded) : 0;
        uint256 cap = sum / 5;
        return sum - (refund < cap ? refund : cap);
    }

    /// @notice the common case: the call that just returned was the whole transaction
    function lastCall(bytes memory data) internal view returns (uint256) {
        Tx memory t;
        addLastFrame(t, data);
        return total(t);
    }
}
