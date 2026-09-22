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
/// It also deliberately does NOT support the native currency. A hook that will see ETH as currency0 needs to
/// be tested with it, and that is a plumbing job (msg.value, refunds, re-entrancy on the refund) that this
/// module has not done yet. If you point this router at a native pool it will fail on the settle, loudly,
/// which is better than quietly testing something that is not the thing you ship.
///
/// The payer approves THIS CONTRACT, not the manager: `settle` transfers from the payer to the manager and
/// the router is the one making the call.
contract MinimalRouter is IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;

    error NotTheManager();
    error NativeCurrencyNotSupported();

    struct SwapCall {
        PoolKey key;
        SwapParams params;
        address payer;
        bytes hookData;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    /// @notice swap on behalf of `msg.sender`, who must have approved this router for the input currency.
    /// @return delta the caller's balance delta as the manager computed it, hook deltas included
    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData)
        external
        returns (BalanceDelta delta)
    {
        if (key.currency0.isAddressZero()) revert NativeCurrencyNotSupported();
        bytes memory out = manager.unlock(abi.encode(SwapCall(key, params, msg.sender, hookData)));
        delta = abi.decode(out, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotTheManager();
        SwapCall memory c = abi.decode(data, (SwapCall));

        BalanceDelta delta = manager.swap(c.key, c.params, c.hookData);

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();

        // Pay first, then collect. The order matters to a hostile token: a token that runs code on the way
        // in gets to run it while this router still owes the other currency.
        if (d0 < 0) c.key.currency0.settle(manager, c.payer, uint256(uint128(-d0)), false);
        if (d1 < 0) c.key.currency1.settle(manager, c.payer, uint256(uint128(-d1)), false);
        if (d0 > 0) c.key.currency0.take(manager, c.payer, uint256(uint128(d0)), false);
        if (d1 > 0) c.key.currency1.take(manager, c.payer, uint256(uint128(d1)), false);

        return abi.encode(delta);
    }
}
