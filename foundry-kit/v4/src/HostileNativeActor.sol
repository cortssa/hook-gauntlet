// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {MinimalRouter} from "./MinimalRouter.sol";
import {LiquidityHelper} from "./LiquidityHelper.sol";

/// @title HostileNativeActor
/// @notice A swapper or liquidity provider that is a CONTRACT, and whose `receive()` does what a test tells it to - the
/// native-currency counterpart of `HostileERC20`'s callbacks. ETH is the one currency whose every delivery runs the
/// recipient's code, so a pool with ETH on one side has a hostile counterparty on every payment out: the manager's
/// `take` of ETH to it, INSIDE the unlock, and a router's refund to it, after.
///
/// Modes of `receive()`:
///  * HONEST   - accepts;
///  * REVERT   - reverts with `Refused()`: a contract that cannot receive ETH (or will not);
///  * REENTER  - calls back out once (`setReentryCall`: any target and calldata, the result recorded; or
///               `setReentrySwap`: a swap on the manager in its OWN name, its own delta settled - directly when the
///               manager is unlocked, through its own `unlock` when it is not; or `setReentrySettleAndMint`: ETH paid
///               in with `settle{value}` and/or a claim minted to itself, each skipped when zero) and accepts;
///  * BURN_GAS - spins until the frame runs out of gas: whoever sent the ETH is left with 1/64 of what it forwarded.
///
/// It records, at every receipt, whether the manager was unlocked at that moment (`unlockedAtLastReceive`, read from the
/// manager's own transient slot) - the fact the whole native question turns on.
contract HostileNativeActor is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    enum Mode {
        HONEST,
        REVERT,
        REENTER,
        BURN_GAS
    }

    IPoolManager public immutable manager;
    Mode public mode;

    address public reentryTarget;
    bytes public reentryData;
    bool public reentryIsSwap;
    bool public reentryIsSettleMint;
    uint256 public reentrySettleValue;
    uint256 public reentryMintAmount;
    PoolKey internal _reKey;
    SwapParams internal _reParams;

    uint256 public receives;
    uint256 public valueReceived;
    bool public unlockedAtLastReceive;
    uint256 public reentriesAttempted;
    uint256 public reentriesSucceeded;
    bytes public lastReentryReturn;
    /// @notice the delta of the swap it made in its own name while re-entering (zero if none)
    BalanceDelta public reentrySwapDelta;

    bool private _inReceive;

    error Refused();
    error NotTheManager();

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    // ------------------------------------------------------------------ switches
    function setMode(Mode m) external {
        mode = m;
    }

    function setReentryCall(address target, bytes calldata data) external {
        reentryIsSwap = false;
        reentryIsSettleMint = false;
        reentryTarget = target;
        reentryData = data;
    }

    /// @notice re-enter by SWAPPING on `key` in its own name, and settling its own delta
    function setReentrySwap(PoolKey calldata key, SwapParams calldata params) external {
        reentryIsSwap = true;
        reentryIsSettleMint = false;
        _reKey = key;
        _reParams = params;
    }

    /// @notice re-enter by paying `settleValue` of ETH into the manager (`settle{value}`, no `sync`) and then minting
    /// `mintAmount` of the ETH claim to itself - the two net to zero when equal; either is skipped when zero
    function setReentrySettleAndMint(uint256 settleValue, uint256 mintAmount) external {
        reentryIsSwap = false;
        reentryIsSettleMint = true;
        reentrySettleValue = settleValue;
        reentryMintAmount = mintAmount;
    }

    function approve(address token, address spender) external {
        IERC20Minimal(token).approve(spender, type(uint256).max);
    }

    // ------------------------------------------------------------------ acting as swapper and provider
    function swap(MinimalRouter router, PoolKey calldata key, SwapParams calldata params, uint256 value)
        external
        returns (BalanceDelta)
    {
        return router.swap{value: value}(key, params, "");
    }

    function modifyLiquidity(LiquidityHelper helper, PoolKey calldata key, ModifyLiquidityParams calldata params, uint256 value)
        external
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        return helper.modifyLiquidity{value: value}(key, params, "");
    }

    // ------------------------------------------------------------------ the receipt
    receive() external payable {
        receives += 1;
        valueReceived += msg.value;
        unlockedAtLastReceive = manager.isUnlocked();
        if (mode == Mode.REVERT) revert Refused();
        if (mode == Mode.BURN_GAS) {
            while (true) {}
        }
        if (mode == Mode.REENTER && !_inReceive) {
            _inReceive = true;
            reentriesAttempted += 1;
            if (reentryIsSettleMint) {
                bool ok = true;
                bytes memory ret;
                if (reentrySettleValue != 0) {
                    (ok, ret) = address(manager).call{value: reentrySettleValue}(
                        abi.encodeWithSelector(IPoolManager.settle.selector)
                    );
                }
                if (ok && reentryMintAmount != 0) {
                    (ok, ret) = address(manager).call(
                        abi.encodeWithSelector(IPoolManager.mint.selector, address(this), uint256(0), reentryMintAmount)
                    );
                }
                lastReentryReturn = ret;
                if (ok) reentriesSucceeded += 1;
            } else if (reentryIsSwap) {
                if (manager.isUnlocked()) {
                    _swapInOwnName();
                    reentriesSucceeded += 1;
                } else {
                    // the manager is locked (a refund after the unlock closed): open a lock of its own
                    (bool ok, bytes memory ret) =
                        address(manager).call(abi.encodeWithSelector(IPoolManager.unlock.selector, bytes("")));
                    lastReentryReturn = ret;
                    if (ok) reentriesSucceeded += 1;
                }
            } else {
                (bool ok, bytes memory ret) = reentryTarget.call(reentryData);
                lastReentryReturn = ret;
                if (ok) reentriesSucceeded += 1;
            }
            _inReceive = false;
        }
    }

    function unlockCallback(bytes calldata) external override returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotTheManager();
        _swapInOwnName();
        return "";
    }

    /// @dev swap on the manager as `msg.sender == this`, then square its own delta: pay what it owes (ETH from its own
    /// balance, an ERC-20 by sync + transfer + settle), take what it is owed
    function _swapInOwnName() private {
        BalanceDelta d = manager.swap(_reKey, _reParams, "");
        reentrySwapDelta = d;
        _square(_reKey.currency0, d.amount0());
        _square(_reKey.currency1, d.amount1());
    }

    function _square(Currency c, int128 d) private {
        if (d < 0) {
            uint256 owed = uint256(uint128(-d));
            if (c.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                manager.sync(c);
                IERC20Minimal(Currency.unwrap(c)).transfer(address(manager), owed);
                manager.settle();
            }
        } else if (d > 0) {
            manager.take(c, address(this), uint256(uint128(d)));
        }
    }
}
