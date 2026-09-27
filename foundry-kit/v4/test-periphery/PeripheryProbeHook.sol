// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IMsgSender} from "v4-periphery/src/interfaces/IMsgSender.sol";

/// @title PeripheryProbeHook - a test fixture, not an example
/// @notice Declares every callback that returns no delta and records, in each, what a hook author can read: the `sender`
/// argument, what `IMsgSender(sender).msgSender()` answers AT THAT MOMENT (the periphery's locker is transient: it is
/// only there during the call), the `hookData`, and the liquidity `salt`. It changes nothing. The three example hooks
/// ignore `sender` and `hookData`, so what they are GIVEN is read off the calldata (`PeripheryHarness._hookCallsIn`);
/// this probe is for the question those cannot answer - what a hook that asks for the user gets.
contract PeripheryProbeHook is IHooks {
    struct Seen {
        bytes4 selector;
        address sender;
        bool msgSenderAnswered;
        address msgSender;
        bytes hookData;
        bytes32 salt;
    }

    IPoolManager public immutable manager;
    Seen[] internal _seen;

    error NotTheManager();

    constructor(IPoolManager manager_) {
        manager = manager_;
        Hooks.validateHookPermissions(IHooks(address(this)), permissions());
    }

    function permissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.afterInitialize = true;
        p.beforeAddLiquidity = true;
        p.afterAddLiquidity = true;
        p.beforeRemoveLiquidity = true;
        p.afterRemoveLiquidity = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeDonate = true;
        p.afterDonate = true;
    }

    function flags() public pure returns (uint160) {
        return Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.AFTER_DONATE_FLAG;
    }

    function seenCount() external view returns (uint256) {
        return _seen.length;
    }

    function seenAt(uint256 i) external view returns (Seen memory) {
        return _seen[i];
    }

    function clear() external {
        delete _seen;
    }

    function _record(bytes4 selector, address sender, bytes memory hookData, bytes32 salt) internal {
        if (msg.sender != address(manager)) revert NotTheManager();
        Seen storage s = _seen.push();
        s.selector = selector;
        s.sender = sender;
        s.hookData = hookData;
        s.salt = salt;
        // what a hook that wants "the user" would do. A call, not an assumption: a contract without the function reverts
        try IMsgSender(sender).msgSender() returns (address who) {
            s.msgSenderAnswered = true;
            s.msgSender = who;
        } catch {}
    }

    function beforeInitialize(address sender, PoolKey calldata, uint160) external returns (bytes4) {
        _record(IHooks.beforeInitialize.selector, sender, "", 0);
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address sender, PoolKey calldata, uint160, int24) external returns (bytes4) {
        _record(IHooks.afterInitialize.selector, sender, "", 0);
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata p, bytes calldata d)
        external
        returns (bytes4)
    {
        _record(IHooks.beforeAddLiquidity.selector, sender, d, p.salt);
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata p,
        BalanceDelta,
        BalanceDelta,
        bytes calldata d
    ) external returns (bytes4, BalanceDelta) {
        _record(IHooks.afterAddLiquidity.selector, sender, d, p.salt);
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata p, bytes calldata d)
        external
        returns (bytes4)
    {
        _record(IHooks.beforeRemoveLiquidity.selector, sender, d, p.salt);
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata p,
        BalanceDelta,
        BalanceDelta,
        bytes calldata d
    ) external returns (bytes4, BalanceDelta) {
        _record(IHooks.afterRemoveLiquidity.selector, sender, d, p.salt);
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeSwap(address sender, PoolKey calldata, SwapParams calldata, bytes calldata d)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _record(IHooks.beforeSwap.selector, sender, d, 0);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address sender, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata d)
        external
        returns (bytes4, int128)
    {
        _record(IHooks.afterSwap.selector, sender, d, 0);
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address sender, PoolKey calldata, uint256, uint256, bytes calldata d) external returns (bytes4) {
        _record(IHooks.beforeDonate.selector, sender, d, 0);
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address sender, PoolKey calldata, uint256, uint256, bytes calldata d) external returns (bytes4) {
        _record(IHooks.afterDonate.selector, sender, d, 0);
        return IHooks.afterDonate.selector;
    }
}
