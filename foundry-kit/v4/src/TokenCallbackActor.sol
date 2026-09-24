// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IHostileTokenCallback} from "gauntlet-kit/HostileERC20.sol";

/// @title TokenCallbackActor
/// @notice The other end of a `HostileERC20` transfer callback, pointed at the MANAGER: the currency's own transfer hook
/// re-entering v4 while somebody is in the middle of paying it. A payment to the manager is `sync(c)`, a transfer of `c`,
/// `settle()` (v4-core's `CurrencySettler`, which `MinimalRouter` and the example hooks use); the token's callbacks run
/// INSIDE the transfer - `tokensToSend` before the balances move, `tokensReceived` after - so this contract acts between
/// the payer's `sync` and its `settle`, with the manager mid-accounting for that payment. Point it there with the
/// token's own switches: `setReceiveCallback(address(manager), actor, 1)` fires on the next transfer INTO the manager
/// (after the move), `setSendCallback(payer, actor, 1)` on the next transfer out of the payer (before it).
///
/// Doors (one per fire; `setDoor`), each a low-level call whose result is recorded and whose failure is SWALLOWED, so
/// that what happens to the payer is the manager's doing and the payer's, never this contract's revert:
///  * SYNC            - `sync(currency)`: another currency, the same one, or the zero address (which clears the slot);
///  * SETTLE          - a bare `settle()` in its own name: credits whatever the payer has sent since its `sync` to THIS;
///  * SETTLE_AND_TAKE - the same, then `take` of what it was credited, to itself: its own delta squared;
///  * SETTLE_AND_MINT - the same, then `mint` of it as a claim to itself: its own delta squared, no token leaves;
///  * TAKE            - `take(currency, this, amount)` against nothing: a delta left open;
///  * SWAP            - a swap on `setSwap`'s pool in its OWN name, its delta squared (ERC-20 by sync + transfer + settle);
///  * MINT            - `mint(this, currency, amount)` against nothing: a delta left open;
///  * UNLOCK          - `unlock("")`: a lock of its own.
/// It records, at the fire, whether the manager was unlocked, the synced currency before and after its door, what a
/// `settle` credited it, and its own open delta in `currency` after the door.
contract TokenCallbackActor is IHostileTokenCallback, IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    enum Door {
        NONE,
        SYNC,
        SETTLE,
        SETTLE_AND_TAKE,
        SETTLE_AND_MINT,
        TAKE,
        SWAP,
        MINT,
        UNLOCK
    }

    IPoolManager public immutable manager;
    Door public door;
    Currency public currency;
    uint256 public amount;
    PoolKey internal _key;
    SwapParams internal _params;

    uint256 public fired;
    uint256 public succeeded;
    bool public unlockedAtFire;
    Currency public syncedBefore;
    Currency public syncedAfter;
    uint256 public credited;
    int256 public deltaAfter;
    bytes public lastReturn;

    bool private _inFire;

    error NotTheManager();

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    /// @param currency_ the currency the door acts on (SYNC, TAKE, MINT, and the take / mint after a SETTLE)
    function setDoor(Door door_, Currency currency_, uint256 amount_) external {
        door = door_;
        currency = currency_;
        amount = amount_;
    }

    function setSwap(PoolKey calldata key, SwapParams calldata params) external {
        door = Door.SWAP;
        _key = key;
        _params = params;
    }

    function tokensToSend(address, address, uint256) external override {
        _fire();
    }

    function tokensReceived(address, address, uint256) external override {
        _fire();
    }

    function _fire() private {
        if (_inFire || door == Door.NONE) return;
        _inFire = true;
        fired += 1;
        unlockedAtFire = manager.isUnlocked();
        syncedBefore = manager.getSyncedCurrency();
        (bool ok, bytes memory ret) = _door();
        lastReturn = ret;
        if (ok) succeeded += 1;
        syncedAfter = manager.getSyncedCurrency();
        deltaAfter = manager.currencyDelta(address(this), currency);
        _inFire = false;
    }

    function _door() private returns (bool ok, bytes memory ret) {
        address m = address(manager);
        Door d = door;
        if (d == Door.SYNC) return m.call(abi.encodeWithSelector(IPoolManager.sync.selector, currency));
        if (d == Door.TAKE) {
            return m.call(abi.encodeWithSelector(IPoolManager.take.selector, currency, address(this), amount));
        }
        if (d == Door.MINT) {
            return m.call(abi.encodeWithSelector(IPoolManager.mint.selector, address(this), currency.toId(), amount));
        }
        if (d == Door.UNLOCK) return m.call(abi.encodeWithSelector(IPoolManager.unlock.selector, bytes("")));
        if (d == Door.SWAP) {
            if (!manager.isUnlocked()) return (false, "");
            return address(this).call(abi.encodeWithSelector(this.swapInOwnName.selector));
        }
        // the three that begin with a bare settle()
        (ok, ret) = m.call(abi.encodeWithSelector(IPoolManager.settle.selector));
        if (!ok) return (ok, ret);
        credited = abi.decode(ret, (uint256));
        if (credited == 0 || d == Door.SETTLE) return (ok, ret);
        if (d == Door.SETTLE_AND_TAKE) {
            return m.call(abi.encodeWithSelector(IPoolManager.take.selector, currency, address(this), credited));
        }
        return m.call(abi.encodeWithSelector(IPoolManager.mint.selector, address(this), currency.toId(), credited));
    }

    /// @notice the SWAP door's body, external so that its failure can be swallowed as one unit; only this contract
    function swapInOwnName() external {
        require(msg.sender == address(this), "TokenCallbackActor: self only");
        BalanceDelta d = manager.swap(_key, _params, "");
        _square(_key.currency0, d.amount0());
        _square(_key.currency1, d.amount1());
    }

    function _square(Currency c, int128 d) private {
        if (d < 0) {
            manager.sync(c);
            IERC20Minimal(Currency.unwrap(c)).transfer(address(manager), uint256(uint128(-d)));
            manager.settle();
        } else if (d > 0) {
            manager.take(c, address(this), uint256(uint128(d)));
        }
    }

    /// @notice the UNLOCK door's lock: does nothing, so that "the manager allowed a nested unlock" can be told apart
    function unlockCallback(bytes calldata) external view override returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotTheManager();
        return "";
    }
}
