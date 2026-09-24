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
/// relation to the liquidity it asked for.
///
/// POSITIONS ARE THE CALLER'S (2026-09-24, from the verifier V14). To the manager every position is THIS CONTRACT's
/// (its `owner` is whoever calls `modifyLiquidity` on it), and the helper pays whoever calls it - so until this date a
/// stranger with no approvals could name another provider's pool, range and salt, remove the position and keep what
/// it paid out. The helper now gives the manager the salt `positionSalt(msg.sender, salt)`: the same pool, range and
/// salt from two callers are two positions, and a caller can only ever touch its own
/// (`test_two_callers_with_the_same_salt_hold_two_positions`). A hook sees that derived salt in its liquidity
/// callbacks, and a test reading a position from the manager asks for it with `positionSalt`.
///
/// Used for two jobs in the harness:
///  * seed the pool under test so that swaps have something to trade against;
///  * seed a HOOKLESS pool with the same currencies, so a test can compare "what the pool does" with "what
///    the pool does with the hook on it". Half the arithmetic findings in a hook are only visible as a
///    difference against the plain pool.
///
/// NATIVE CURRENCY (2026-09-24): the rules of `MinimalRouter`. Adding to a pool with ETH as `currency0` pays the ETH
/// the manager charges out of `msg.value` (the amount is the manager's, not the caller's guess: send enough) and
/// refunds the rest after the unlock; removing sends ETH to the provider through the manager's `take`, inside the
/// unlock. A provider that cannot receive ETH can add (sending exactly what is charged) and can NEVER remove through
/// this helper: its position stays in the pool until it can receive, and nobody else can remove it meanwhile
/// (measured, `test/NativeCounterparty.t.sol`). ETH is paid and refunded out of the call's `msg.value`, counted, never
/// out of the helper's balance: ETH that reaches it any other way is nobody's and stays here
/// (`test_stray_eth_in_the_helper_pays_for_nobodys_deposit`).
contract LiquidityHelper is IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;

    error NotTheManager();
    error InsufficientValue(uint256 owed, uint256 value);
    error RefundFailed(address to, bytes reason);

    struct ModifyCall {
        PoolKey key;
        ModifyLiquidityParams params;
        address payer;
        uint256 value;
        bytes hookData;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    /// @notice the salt the manager sees for `owner`'s position with salt `salt`: every caller has positions of its own
    function positionSalt(address owner, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(owner, salt));
    }

    /// @notice `msg.sender` must have approved this contract for both ERC-20 currencies when adding, and send at least
    /// the ETH the manager will charge when one side is native (the rest comes back after the unlock). It acts on
    /// `msg.sender`'s own position only (`positionSalt(msg.sender, params.salt)`).
    /// @return callerDelta what the manager charged or paid this contract
    /// @return feesAccrued what the position earned since it was last touched
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        payable
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        params.salt = positionSalt(msg.sender, params.salt);
        bytes memory out = manager.unlock(abi.encode(ModifyCall(key, params, msg.sender, msg.value, hookData)));
        uint256 ethPaid;
        (callerDelta, feesAccrued, ethPaid) = abi.decode(out, (BalanceDelta, BalanceDelta, uint256));
        uint256 left = msg.value - ethPaid;
        if (left != 0) {
            (bool ok, bytes memory reason) = msg.sender.call{value: left}("");
            if (!ok) revert RefundFailed(msg.sender, reason);
        }
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotTheManager();
        ModifyCall memory c = abi.decode(data, (ModifyCall));

        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = manager.modifyLiquidity(c.key, c.params, c.hookData);

        int128 d0 = callerDelta.amount0();
        int128 d1 = callerDelta.amount1();

        uint256 ethPaid;
        if (d0 < 0) ethPaid += _pay(c.key.currency0, c.payer, uint256(uint128(-d0)), c.value - ethPaid);
        if (d1 < 0) ethPaid += _pay(c.key.currency1, c.payer, uint256(uint128(-d1)), c.value - ethPaid);
        if (d0 > 0) c.key.currency0.take(manager, c.payer, uint256(uint128(d0)), false);
        if (d1 > 0) c.key.currency1.take(manager, c.payer, uint256(uint128(d1)), false);

        return abi.encode(callerDelta, feesAccrued, ethPaid);
    }

    /// @dev ETH is paid out of the provider's `msg.value` (what is left of it), never out of whatever the helper holds
    /// @return ethPaid the ETH this payment spent
    function _pay(Currency currency, address payer, uint256 amount, uint256 valueLeft) internal returns (uint256 ethPaid) {
        if (currency.isAddressZero()) {
            if (valueLeft < amount) revert InsufficientValue(amount, valueLeft);
            ethPaid = amount;
        }
        currency.settle(manager, payer, amount, false);
    }
}
