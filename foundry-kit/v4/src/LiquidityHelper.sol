// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";

/// @title LiquidityHelper
/// @notice Adds and removes liquidity inside its own unlock callback, and settles both deltas.
///
/// Same rule as `MinimalRouter`: it is a fixture and it is deliberately stupid. It does not track positions,
/// it does not mint anything to represent them, and it does not check that the amounts it just paid bear any
/// relation to the liquidity it asked for. The position belongs to THIS CONTRACT as far as the manager is
/// concerned (owner = the caller of `modifyLiquidity`), so a test that wants two providers with separate
/// positions gives them different `salt` values, or deploys two helpers.
///
/// Used for two jobs in the harness:
///  * seed the pool under test so that swaps have something to trade against;
///  * seed a HOOKLESS pool with the same currencies, so a test can compare "what the pool does" with "what
///    the pool does with the hook on it". Half the arithmetic findings in a hook are only visible as a
///    difference against the plain pool.
contract LiquidityHelper is IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;

    error NotTheManager();
    error NativeCurrencyNotSupported();

    struct ModifyCall {
        PoolKey key;
        ModifyLiquidityParams params;
        address payer;
        bytes hookData;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    /// @notice `msg.sender` must have approved this contract for both currencies when adding.
    /// @return callerDelta what the manager charged or paid this contract
    /// @return feesAccrued what the position earned since it was last touched
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        if (key.currency0.isAddressZero()) revert NativeCurrencyNotSupported();
        bytes memory out = manager.unlock(abi.encode(ModifyCall(key, params, msg.sender, hookData)));
        (callerDelta, feesAccrued) = abi.decode(out, (BalanceDelta, BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotTheManager();
        ModifyCall memory c = abi.decode(data, (ModifyCall));

        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = manager.modifyLiquidity(c.key, c.params, c.hookData);

        int128 d0 = callerDelta.amount0();
        int128 d1 = callerDelta.amount1();

        if (d0 < 0) c.key.currency0.settle(manager, c.payer, uint256(uint128(-d0)), false);
        if (d1 < 0) c.key.currency1.settle(manager, c.payer, uint256(uint128(-d1)), false);
        if (d0 > 0) c.key.currency0.take(manager, c.payer, uint256(uint128(d0)), false);
        if (d1 > 0) c.key.currency1.take(manager, c.payer, uint256(uint128(d1)), false);

        return abi.encode(callerDelta, feesAccrued);
    }
}
