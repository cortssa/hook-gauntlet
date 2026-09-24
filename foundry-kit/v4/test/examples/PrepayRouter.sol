// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice A router that PAYS FIRST: `sync` + transfer before the swap, `settle` after it. Legal in v4, and the shape of
/// any flow that moves the input before it knows the output. While its payment is in flight the manager's ONE synced
/// slot is its currency, and a hook that calls `sync` in between resets the checkpoint under it (P7).
contract PrepayRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    struct Call {
        PoolKey key;
        SwapParams params;
        address payer;
    }

    constructor(IPoolManager m) {
        manager = m;
    }

    /// @notice exact-in, zeroForOne only: pays `-amountSpecified` of currency0 before the swap
    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta d) {
        require(params.zeroForOne && params.amountSpecified < 0, "PrepayRouter: exact-in zeroForOne only");
        d = abi.decode(manager.unlock(abi.encode(Call(key, params, msg.sender))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not the manager");
        Call memory c = abi.decode(data, (Call));
        address t0 = Currency.unwrap(c.key.currency0);
        manager.sync(c.key.currency0);
        (bool ok,) = t0.call(
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)", c.payer, address(manager), uint256(-c.params.amountSpecified)
            )
        );
        require(ok, "PrepayRouter: transferFrom");
        BalanceDelta d = manager.swap(c.key, c.params, "");
        uint256 credited = manager.settle();
        // A router that pays BEFORE the swap has paid for the swap it asked for, not the one the pool filled: a pool
        // with no liquidity (or a price limit) fills less, and what it did not use is this router's own credit.
        // Left there, the unlock cannot close (`CurrencyNotSettled`, caught by the DeltaFeeHook campaign in CI on a
        // pool whose only provider had withdrawn). It goes back to the payer.
        int256 unused = int256(credited) + d.amount0();
        if (unused > 0) manager.take(c.key.currency0, c.payer, uint256(unused));
        if (d.amount1() > 0) manager.take(c.key.currency1, c.payer, uint256(uint128(d.amount1())));
        return abi.encode(d);
    }
}
