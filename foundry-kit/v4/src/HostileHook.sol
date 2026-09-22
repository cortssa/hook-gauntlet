// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title HostileHook
/// @notice The mirror image of `HostileERC20`, for the other side of the pool: a hook that answers whatever
/// a test tells it to answer, with every misbehaviour switchable at runtime.
///
/// It exists for two jobs:
///
/// 1. **Testing something else against a hook.** If your contract is a router, a periphery contract, a
///    second hook or a vault that swaps, then a hook is untrusted input to it. This is that input.
/// 2. **Building a WRONG address on purpose.** It declares nothing and validates nothing in its constructor,
///    so it can be mined to any flag set at all - including the ones the manager is supposed to refuse. A
///    guard you cannot build the wrong thing for is a guard you have not tested.
///
/// Because of job 2 it must NOT call `Hooks.validateHookPermissions`. That is deliberate, and it is the one
/// thing to copy from this file into nothing.
contract HostileHook is IHooks, IUnlockCallback {
    IPoolManager public immutable manager;

    /// @notice return a selector that is not the one the manager asked for. The manager treats any mismatch
    /// as an invalid hook return and reverts; a router that trusts the hook instead of the manager will not.
    bool public wrongSelector;
    /// @notice revert on every entry point.
    bool public revertAlways;
    /// @notice burn this much gas before answering. A hook that eats the frame turns a catchable failure
    /// into a dead transaction for whoever called it.
    uint256 public gasToBurn;
    /// @notice when non-zero, returned from `beforeSwap` as the LP fee override (raw, flags and all, so a
    /// test can return an invalid one on purpose).
    uint24 public rawFeeOverride;
    /// @notice re-enter from inside the callback. The manager is unlocked while the hook runs.
    bool public reenter;

    /// @notice where the re-entry goes, and what it carries. Default: `manager.unlock("")`.
    ///
    /// The first version of this file could only try `unlock`, and it could not tell a manager that REFUSES
    /// a nested unlock from one that allows it. Two reasons, both worth knowing:
    ///
    ///  1. the hook had no `unlockCallback`, so a permissive manager calling back into it reverted anyway,
    ///     and `reentriesSucceeded` was 0 against a manager with no lock at all. An audit built exactly that
    ///     fake manager and the counter still said "refused". A counter that cannot go up is not evidence;
    ///     `test_reentriesSucceeded_goes_to_one_against_a_manager_with_no_lock` is the test that says so;
    ///  2. `unlock` is the door that is CLOSED while a hook runs. The interesting doors -
    ///     `swap`, `take`, `donate`, `modifyLiquidity`, and whatever contract is under test - are open, and
    ///     the question "what happens when the hook uses them mid-callback" was never asked.
    ///
    /// So the re-entry is now a target plus calldata, with three setters that build the usual ones.
    address public reentryTarget;
    bytes public reentryData;

    uint256 public calls;
    uint256 public reentriesAttempted;
    uint256 public reentriesSucceeded;
    /// @notice the return data of the last re-entry attempt, successful or not. Read it in a test: "it
    /// reverted" and "it reverted with THAT" are different findings.
    bytes public lastReentryReturn;

    /// @dev one level only. Re-entering through `swap` would otherwise call this hook again, which would
    /// re-enter again, until the frame dies - and a test that runs out of gas measures nothing.
    bool private _inReentry;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function setWrongSelector(bool on) external {
        wrongSelector = on;
    }

    function setRevertAlways(bool on) external {
        revertAlways = on;
    }

    function setGasToBurn(uint256 g) external {
        gasToBurn = g;
    }

    function setRawFeeOverride(uint24 f) external {
        rawFeeOverride = f;
    }

    function setReenter(bool on) external {
        reenter = on;
    }

    /// @notice re-enter through `manager.unlock("")` - the door the manager keeps shut while a hook runs.
    /// This is the default, and it is the question "does this manager allow a nested lock".
    function setReentryUnlock() external {
        reentryTarget = address(0);
        reentryData = "";
    }

    /// @notice re-enter through `manager.swap` on `key` - a door that is OPEN while the hook runs, because
    /// the outer caller's lock is still held. What the manager does about the delta this creates, and who is
    /// left holding it, is the thing worth measuring.
    function setReentrySwap(PoolKey calldata key, SwapParams calldata params) external {
        reentryTarget = address(manager);
        reentryData = abi.encodeWithSelector(IPoolManager.swap.selector, key, params, bytes(""));
    }

    /// @notice re-enter through `manager.take`: ask the manager for currency mid-callback, against a delta
    /// nobody has settled. Also open while the hook runs.
    function setReentryTake(Currency currency, address to, uint256 amount) external {
        reentryTarget = address(manager);
        reentryData = abi.encodeWithSelector(IPoolManager.take.selector, currency, to, amount);
    }

    /// @notice re-enter through anything at all - most usefully the contract under test, which is the case
    /// the manager has no opinion about.
    function setReentryTarget(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    /// @notice So that a manager which ALLOWS a nested unlock can be told apart from one that refuses.
    /// Without it, `manager.unlock` calls back into a hook that cannot answer, the call reverts, and
    /// `reentriesSucceeded` stays 0 whatever the manager decided - the counter measured this contract's own
    /// missing function and called it the manager's refusal.
    function unlockCallback(bytes calldata) external pure override returns (bytes memory) {
        return "";
    }

    error Hostile();
    error ReentryTargetHasNoCode(address target);

    function _enter() private {
        calls += 1;
        if (revertAlways) revert Hostile();
        if (gasToBurn != 0) {
            uint256 target = gasleft() > gasToBurn ? gasleft() - gasToBurn : 0;
            while (gasleft() > target) {}
        }
        if (reenter && !_inReentry) {
            _inReentry = true;
            reentriesAttempted += 1;
            // Whether any of this is allowed is the manager's business, and this is how a test asks it the
            // question instead of assuming the answer. A low-level call, not a `try`, because the target is
            // arbitrary and its return type is not known here.
            address target = reentryTarget == address(0) ? address(manager) : reentryTarget;
            bytes memory payload =
                reentryTarget == address(0) ? abi.encodeWithSelector(IPoolManager.unlock.selector, bytes("")) : reentryData;
            // a call to an address with NO CODE returns ok = true: a target that was mistyped, or not deployed
            // yet, would be counted as a re-entry that succeeded, with nothing at the other end
            if (target.code.length == 0) revert ReentryTargetHasNoCode(target);
            (bool ok, bytes memory ret) = target.call(payload);
            lastReentryReturn = ret;
            if (ok) reentriesSucceeded += 1;
            _inReentry = false;
        }
    }

    function _sel(bytes4 real) private view returns (bytes4) {
        return wrongSelector ? bytes4(0xdeadbeef) : real;
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external override returns (bytes4) {
        _enter();
        return _sel(IHooks.beforeInitialize.selector);
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external override returns (bytes4) {
        _enter();
        return _sel(IHooks.afterInitialize.selector);
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        override
        returns (bytes4)
    {
        _enter();
        return _sel(IHooks.beforeAddLiquidity.selector);
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        _enter();
        return (_sel(IHooks.afterAddLiquidity.selector), BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        override
        returns (bytes4)
    {
        _enter();
        return _sel(IHooks.beforeRemoveLiquidity.selector);
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        _enter();
        return (_sel(IHooks.afterRemoveLiquidity.selector), BalanceDelta.wrap(0));
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _enter();
        return (_sel(IHooks.beforeSwap.selector), BeforeSwapDeltaLibrary.ZERO_DELTA, rawFeeOverride);
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        returns (bytes4, int128)
    {
        _enter();
        return (_sel(IHooks.afterSwap.selector), int128(0));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        override
        returns (bytes4)
    {
        _enter();
        return _sel(IHooks.beforeDonate.selector);
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        override
        returns (bytes4)
    {
        _enter();
        return _sel(IHooks.afterDonate.selector);
    }
}
