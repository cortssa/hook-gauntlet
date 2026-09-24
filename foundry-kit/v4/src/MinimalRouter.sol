// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";

/// @title MinimalRouter
/// @notice The dumbest router that can swap: unlock, swap, settle what it owes, take what it is owed.
///
/// It is a TEST FIXTURE, not a product, and being dumb is the point. A production router checks slippage,
/// nets multiple hops, uses ERC-6909 claims and permits, and has opinions about which currency to settle
/// first. Every one of those opinions can absorb a mistake the hook made - a router that reverts on its own
/// slippage check before the hook's arithmetic has a chance to show up hides the bug you were looking for.
/// So: no slippage check, no netting, no claims. Whatever the manager says the deltas are, this pays them.
///
/// The payer approves THIS CONTRACT, not the manager: `settle` transfers from the payer to the manager and
/// the router is the one making the call.
///
/// NATIVE CURRENCY (2026-09-24). A pool whose `currency0` is the zero address has ETH on that side. The swapper
/// sends ETH with the call (`msg.value`); the router pays the manager exactly what the RETURNED delta says, out of
/// that value (`settle{value: owed}`, no `sync`, as v4-core's `CurrencySettler` does), and refunds whatever is left
/// to the swapper AFTER the unlock has closed - so a swapper whose `receive()` runs code during the refund meets a
/// LOCKED manager. ETH owed TO the swapper is sent by the manager itself (`take`), INSIDE the unlock: that
/// `receive()` meets an OPEN manager. `test/NativeCounterparty.t.sol` measures what each can do. An exact-out swap
/// with ETH in cannot know its input in advance: send enough, and the rest comes back. Each rule a named revert:
///  * `msg.value` below what is owed -> `InsufficientValue(owed, value)`, before anything is paid;
///  * a refund that cannot be delivered -> `RefundFailed(to, reason)`, and the whole swap reverts. A contract that
///    cannot receive ETH can still swap ETH IN by sending exactly the input (nothing to refund); it cannot swap ETH OUT;
///  * ETH sent to a swap that has no ETH input is refunded in full, never kept.
/// The ETH it pays and refunds is the CALL's `msg.value`, counted, never `address(this).balance` (2026-09-24, from the
/// verifier V14): ETH that reaches the router any other way - a selfdestruct, a coinbase reward - is nobody's payment
/// and stays in the router for ever, instead of paying the next swapper's input and being refunded to it
/// (`test_stray_eth_in_the_router_pays_for_nobodys_swap`).
contract MinimalRouter is IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;

    error NotTheManager();
    error InsufficientValue(uint256 owed, uint256 value);
    error RefundFailed(address to, bytes reason);

    struct SwapCall {
        PoolKey key;
        SwapParams params;
        address payer;
        uint256 value;
        bytes hookData;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    /// @notice swap on behalf of `msg.sender`, who must have approved this router for an ERC-20 input currency, or
    /// sent at least the ETH input with the call (the rest is refunded after the unlock).
    /// @return delta the caller's balance delta as the manager computed it, hook deltas included
    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData)
        external
        payable
        returns (BalanceDelta delta)
    {
        bytes memory out = manager.unlock(abi.encode(SwapCall(key, params, msg.sender, msg.value, hookData)));
        uint256 ethPaid;
        (delta, ethPaid) = abi.decode(out, (BalanceDelta, uint256));
        _refund(msg.sender, msg.value - ethPaid);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotTheManager();
        SwapCall memory c = abi.decode(data, (SwapCall));

        BalanceDelta delta = manager.swap(c.key, c.params, c.hookData);

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();

        // Pay first, then collect. The order matters to a hostile token: a token that runs code on the way
        // in gets to run it while this router still owes the other currency.
        uint256 ethPaid;
        if (d0 < 0) ethPaid += _pay(c.key.currency0, c.payer, uint256(uint128(-d0)), c.value - ethPaid);
        if (d1 < 0) ethPaid += _pay(c.key.currency1, c.payer, uint256(uint128(-d1)), c.value - ethPaid);
        if (d0 > 0) c.key.currency0.take(manager, c.payer, uint256(uint128(d0)), false);
        if (d1 > 0) c.key.currency1.take(manager, c.payer, uint256(uint128(d1)), false);

        return abi.encode(delta, ethPaid);
    }

    /// @dev ETH is paid out of the swapper's `msg.value` (what is left of it), never out of whatever the router holds
    /// @return ethPaid the ETH this payment spent
    function _pay(Currency currency, address payer, uint256 amount, uint256 valueLeft) internal returns (uint256 ethPaid) {
        if (currency.isAddressZero()) {
            if (valueLeft < amount) revert InsufficientValue(amount, valueLeft);
            ethPaid = amount;
        }
        currency.settle(manager, payer, amount, false);
    }

    /// @dev after the unlock: the manager is locked again while `to` runs its `receive()`
    function _refund(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, bytes memory reason) = to.call{value: amount}("");
        if (!ok) revert RefundFailed(to, reason);
    }
}
