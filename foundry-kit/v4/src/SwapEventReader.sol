// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @title SwapEventReader
/// @notice Reads what the POOL said about a swap, off the manager's own `Swap` event.
///
/// Why this exists at all: a hook that returns a fee has made a claim, and the only place the claim is
/// checkable from outside is the event the manager emits. A suite that asserts on the hook's own stored
/// `lastQuotedFee` is asking the hook whether the hook was right. Reading the event asks the manager.
///
/// The `fee` in the event is the total swap fee. With no protocol fee set - which is the case in this
/// module, because nothing here ever sets one - it is the LP fee, which is the number the hook returned. If
/// your project turns protocol fees on, this equality stops holding and every assertion built on it has to
/// be rewritten, not deleted.
library SwapEventReader {
    /// @notice the last `Swap` emitted by `manager` in the recorded logs.
    /// @return found false when the swap did not happen at all
    function lastSwapFee(Vm.Log[] memory logs, address manager) internal pure returns (bool found, uint24 fee) {
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory l = logs[i - 1];
            if (l.emitter == manager && l.topics.length > 0 && l.topics[0] == IPoolManager.Swap.selector) {
                (,,,,, uint24 f) = abi.decode(l.data, (int128, int128, uint160, uint128, int24, uint24));
                return (true, f);
            }
        }
        return (false, 0);
    }
}
