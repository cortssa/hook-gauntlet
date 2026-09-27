// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title InRangeDonateHook - A TOY. Do not copy its architecture into a product.
/// @notice The kit's worked example of a hook that pays "whoever is in range" (`doctrine/HOOK-ATTACKS.md` class 20). It
/// takes a fee of `FEE_BPS` of the pool's unspecified amount in `afterSwap` (a positive delta, squared with an ERC-6909
/// claim, as `ClaimsFeeHook` does), KEEPS it, and later gives it to the pool's liquidity with `manager.donate` - which
/// pays the positions in range AT THE MOMENT OF THE DONATION, pro rata to their liquidity, and nobody else.
///
/// That last clause is the whole problem. A donation cannot tell the LPs who were in range while the fee was earned from a
/// position placed one call before it: a keeper-style `sweep` that donates "the pot" to whoever is in range when somebody
/// calls it is taken by a dust position placed just before the sweep (after pushing the price, or once the price has
/// left every honest range, the dust is ALONE in range and takes all of it). `test/examples/InRangeDonateHookNaive.sol`
/// is that first draft; this file is the defended one, and the defence is a rule about WHEN the pot is paid:
///
///   **the pot is donated before anything can change who is in range.** Only three things change the set of in-range
///   positions: a swap (the price moves), and adding or removing liquidity. The hook declares `beforeSwap`,
///   `beforeAddLiquidity` and `beforeRemoveLiquidity`, and each of them donates the pot FIRST. So between the moment a
///   fee enters the pot (the end of the swap that paid it) and the moment it is donated, the set of in-range positions
///   cannot have changed: the donation pays exactly the liquidity that was in range when the fee was taken.
///
/// THE PROMISES (the SPEC, before the tests; each a named test or invariant):
///  D1  THE FEE is `floor(|pool's unspecified amount| * FEE_BPS / BPS)`, in the unspecified currency, held as a claim
///      until it is paid; the hook's claims are, per currency, the sum of its pools' pots plus `unowned`.
///  D2  WHO IS PAID. A fee is owed to the positions in range at the moment the hook takes it - the price the swap that paid
///      it LEFT - in proportion to their liquidity; the "clock" of this liquidity-time is the fee itself, as it is for the
///      pool's own LP fee. No position receives more than that, and none less than that minus rounding, once the pot is
///      paid. A position placed after a fee was taken receives none of it, whoever calls what, in any order.
///  D3  A fee taken while NO liquidity is in range (the swap left the price where no position is) is owed to no LP: it
///      goes to `unowned`, which only `treasury` may withdraw. It never waits for the next position to arrive.
///  D4  The pot is paid before every swap, every liquidity change and on `sweep` (anyone may call it; it changes nothing
///      but timing). A pot is never donated to an empty range: if the liquidity it was owed to is gone it would be a bug
///      of D2, and the hook moves it to `unowned` instead of reverting the action that found it (never observed).
///  D5  `onlyManager` on every callback, `unlockCallback` included; `hookData` is never read; the native currency is
///      accepted.
///
/// WHAT IT DOES NOT PROMISE (measured in `test/examples/InRangeDonateHook.t.sol`, stated in `foundry-kit/v4/README.md`):
///  R1  the fee follows the END of its swap, not its path: `donate` can only pay the liquidity at one price. A trader who
///      ends a swap inside a range of its own (placed before, or a dust range placed beyond the honest ones) is paid its
///      own swap's fee back - a fee that honest liquidity along the path "earned" by any other rule. Bounded by that one
///      swap's fee; never an earlier one.
///  R2  just-in-time liquidity around somebody ELSE's swap (add, their swap, remove) takes its share of that swap's fee,
///      as it takes its share of the pool's own LP fee (`HOOK-ATTACKS.md` class 14). By D2 it is owed.
///  R3  dust PARKED beyond every honest range, before anything happens, takes 100 % of a STRANGER's swap fee whenever
///      that swap ends there: the dust is alone in range at the price the swap left, so D2 owes it the whole fee - a fee
///      that, without the dust, D3 gives to the treasury. Measured (verifier V18): 15 294 628 711 693 168 of
///      15 294 628 711 693 168, for liquidity 1. The same follows (reasoned, not measured) for dust placed just in time at
///      the price limit of a large swap seen before it lands. The WHO invariant cannot see it: it checks conformance to D2, and D2 is what pays. This is
///      the entitlement rule being exploitable, not the code breaking it: closing it means changing D2, not fixing this
///      contract. Pinned as it is, not promised:
///      `test_R3_dust_parked_beyond_every_honest_range_takes_a_strangers_whole_fee`.
///  R4  rounding: a donation of `d` to liquidity `L` pays each position `floor(floor(d * 2^128 / L) * l / 2^128)`; the
///      remainder stays in the manager, as for any donation.
contract InRangeDonateHook is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 public constant BPS = 10_000;
    uint256 public constant FEE_BPS = 30;

    IPoolManager public immutable manager;
    address public immutable treasury;

    /// @notice per pool: fees taken and not donated yet, [0] in the key's currency0, [1] in its currency1
    mapping(PoolId => uint256[2]) internal _pot;
    /// @notice fees taken while no liquidity was in range, not withdrawn yet (D3)
    mapping(Currency => uint256) public unowned;
    /// @notice ledgers, per currency, over every pool: every fee taken, what went to `unowned`, what was donated, what the
    /// treasury withdrew
    mapping(Currency => uint256) public feesTaken;
    mapping(Currency => uint256) public unownedTotal;
    mapping(Currency => uint256) public donated;
    mapping(Currency => uint256) public withdrawn;

    error NotTheManager();
    error NotTheTreasury();
    error NotImplemented();
    error MoreThanUnowned(uint256 asked, uint256 unowned);

    event FeeTaken(PoolId indexed id, Currency indexed currency, uint256 fee, bool owned);
    event PotDonated(PoolId indexed id, uint256 amount0, uint256 amount1);
    event PotUnowned(PoolId indexed id, uint256 amount0, uint256 amount1);
    event Withdrawn(Currency indexed currency, address indexed to, uint256 amount);

    enum Action {
        SWEEP,
        WITHDRAW
    }

    modifier onlyManager() {
        if (msg.sender != address(manager)) revert NotTheManager();
        _;
    }

    constructor(IPoolManager manager_, address treasury_) {
        manager = manager_;
        treasury = treasury_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeAddLiquidity = true;
        p.beforeRemoveLiquidity = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.afterSwapReturnDelta = true;
    }

    function requiredFlags() public pure returns (uint160) {
        return Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    }

    function feeOf(uint256 unspecifiedAbs) public pure returns (uint256) {
        return unspecifiedAbs * FEE_BPS / BPS;
    }

    /// @notice the pot of a pool: taken, not donated yet, owed to the liquidity in range now
    function potOf(PoolId id) external view returns (uint256 amount0, uint256 amount1) {
        return (_pot[id][0], _pot[id][1]);
    }

    // ------------------------------------------------------------------ the pot is paid before the set can change (D4)
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        override
        onlyManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _payThePot(key);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        override
        onlyManager
        returns (bytes4)
    {
        _payThePot(key);
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        override
        onlyManager
        returns (bytes4)
    {
        _payThePot(key);
        return IHooks.beforeRemoveLiquidity.selector;
    }

    // ------------------------------------------------------------------ the fee (D1, D2, D3)
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        override
        onlyManager
        returns (bytes4, int128)
    {
        bool s0 = (params.amountSpecified < 0) == params.zeroForOne;
        Currency unspecified = s0 ? key.currency1 : key.currency0;
        int128 u = s0 ? delta.amount1() : delta.amount0();
        uint256 fee = feeOf(u < 0 ? uint256(uint128(-u)) : uint256(uint128(u)));
        if (fee == 0) return (IHooks.afterSwap.selector, 0);

        PoolId id = key.toId();
        // the hook's delta: the manager owes it `fee`; squared with a claim, kept until the pot is paid
        manager.mint(address(this), unspecified.toId(), fee);
        feesTaken[unspecified] += fee;
        // D2/D3: owed to the liquidity in range at the price this swap left, or to nobody if there is none
        bool owned = manager.getLiquidity(id) != 0;
        if (owned) {
            _pot[id][s0 ? 1 : 0] += fee;
        } else {
            unowned[unspecified] += fee;
            unownedTotal[unspecified] += fee;
        }
        emit FeeTaken(id, unspecified, fee, owned);
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    // ------------------------------------------------------------------ anyone may pay a pool's pot now; the treasury
    /// @notice donate `key`'s pot to its in-range liquidity now. It changes nothing but timing: the set in range is the
    /// one the pot is owed to (D4)
    function sweep(PoolKey calldata key) external {
        manager.unlock(abi.encode(Action.SWEEP, abi.encode(key)));
    }

    /// @notice the treasury withdraws what nobody was in range to be owed (D3)
    function withdrawUnowned(Currency currency, address to, uint256 amount) external {
        if (msg.sender != treasury) revert NotTheTreasury();
        if (amount > unowned[currency]) revert MoreThanUnowned(amount, unowned[currency]);
        manager.unlock(abi.encode(Action.WITHDRAW, abi.encode(currency, to, amount)));
    }

    function unlockCallback(bytes calldata data) external override onlyManager returns (bytes memory) {
        (Action action, bytes memory args) = abi.decode(data, (Action, bytes));
        if (action == Action.SWEEP) {
            _payThePot(abi.decode(args, (PoolKey)));
        } else {
            (Currency currency, address to, uint256 amount) = abi.decode(args, (Currency, address, uint256));
            unowned[currency] -= amount;
            withdrawn[currency] += amount;
            manager.burn(address(this), currency.toId(), amount);
            manager.take(currency, to, amount);
            emit Withdrawn(currency, to, amount);
        }
        return "";
    }

    /// @dev donate the pot to the liquidity in range now and square the donation with the pot's claims: `donate` leaves
    /// the hook owing the amounts, `burn` credits it the same. Called only while the manager is unlocked.
    function _payThePot(PoolKey memory key) internal {
        PoolId id = key.toId();
        uint256 p0 = _pot[id][0];
        uint256 p1 = _pot[id][1];
        if (p0 == 0 && p1 == 0) return;
        delete _pot[id];
        if (manager.getLiquidity(id) == 0) {
            // unreachable while D4 holds (the set cannot change with a pot in it); never revert the action that found it
            unowned[key.currency0] += p0;
            unowned[key.currency1] += p1;
            unownedTotal[key.currency0] += p0;
            unownedTotal[key.currency1] += p1;
            emit PotUnowned(id, p0, p1);
            return;
        }
        manager.donate(key, p0, p1, "");
        if (p0 != 0) manager.burn(address(this), key.currency0.toId(), p0);
        if (p1 != 0) manager.burn(address(this), key.currency1.toId(), p1);
        donated[key.currency0] += p0;
        donated[key.currency1] += p1;
        emit PotDonated(id, p0, p1);
    }

    // ------------------------------------------------------------------ the ones it does not declare
    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        revert NotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert NotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert NotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert NotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert NotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert NotImplemented();
    }
}
