// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title DeltaFeeHook - A TOY. Do not copy its architecture into a product.
/// @notice The kit's worked example of a hook that RETURNS DELTAS: it moves value through the manager's books, holds
/// what it took as ERC-20, and pays some of it back out. `CappedDynamicFeeHook` next to it returns no delta at all.
///
/// What it does (the product, such as it is - a swap-fee pool that recycles itself into rebates):
///  * FEE, on the UNSPECIFIED side, after the swap: `FEE_BPS` of the pool's unspecified amount (the output of an
///    exact-in swap, the input of an exact-out one), returned from `afterSwap` as a POSITIVE delta and taken from
///    the manager to this contract in the same call. The swapper receives that much less, or pays that much more.
///  * REBATE, on the SPECIFIED side, before the swap: `REBATE_BPS` of `|amountSpecified|`, paid out of what the hook
///    already holds in the specified currency, returned from `beforeSwap` as a NEGATIVE specified delta and settled
///    by this contract in the same call. The pool swaps that much more input (exact-in) or delivers that much less
///    output that the hook tops up (exact-out): either way the swapper is better off by the rebate.
///  * CAP: on each pool and in each currency, rebates in one block total at most `REBATE_CAP_BPS` of what that pool
///    had left the hook in that currency when the block's first swap on the pool specified it. A rebate above what is
///    left is cut to what is left. Everything the hook keeps is kept PER POOL (P13): a pool's rebates are paid out of
///    that pool's fees.
///
/// The signs, once, because they are the whole difficulty (`doctrine/V4-ACCOUNTING.md`, "sign and side"):
///  * a hook's returned delta is the HOOK's delta: positive = the manager owes the hook (it must `take`), negative =
///    the hook owes the manager (it must `settle`). The manager moves the swapper by the opposite amount;
///  * "specified" is the currency of `amountSpecified`: currency0 when `(amountSpecified < 0) == zeroForOne`, else
///    currency1. exact-in (amountSpecified < 0) specifies the INPUT, exact-out the OUTPUT. Four orientations, and
///    the same fee code must pick the right currency in all four;
///  * a positive SPECIFIED delta shrinks what the pool swaps on exact-in and grows it on exact-out; a negative one
///    the opposite. The manager refuses one that would flip exact-in into exact-out (`HookDeltaExceedsSwapAmount`).
///
/// THE PROMISES (the SPEC, written before the tests; each is a named test or invariant):
///  P1  CONSERVATION, per swap and per currency: what the swapper paid + what the hook got + what the manager got = 0,
///      the manager's share equals the pool's own delta in the `Swap` event, and the swapper's equals the delta the
///      manager returned to the router - the hook's delta included, in all four orientations;
///  P2  THE FEE is exactly `floor(|pool's unspecified amount| * FEE_BPS / BPS)`, in the unspecified currency, never
///      in the specified one, and never negative;
///  P3  THE REBATE is at most `floor(|amountSpecified| * REBATE_BPS / BPS)`, in the specified currency, never
///      positive (the hook never TAKES on the specified side);
///  P4  NO FREE REBATE: per pool and per currency, rebates paid never exceed fees collected, and the hook never pays
///      out more than it holds by its own ledger (`poolReserveOf`; hook-wide `reserveOf`, their sum), which is never
///      more than its token balance;
///  P5  THE CAP: per pool, per currency and block, rebates paid <= `REBATE_CAP_BPS` of the pool's reserve at the
///      block's first swap on the pool that specified that currency;
///  P6  the hook ends every callback with its own delta squared: whatever it returns, it has taken or settled in
///      the same call, so the router settles only the swapper's side and the unlock closes;
///  P7  it never clobbers a payment in flight: if a currency is already synced when it wants to pay a rebate, it
///      pays none (a `sync` from here would reset another payer's checkpoint - `V4-ACCOUNTING.md` item 1);
///  P8  `onlyManager` on every entry point, `receive()` included (ETH arrives only from the manager's `take`);
///      `hookData` is never read;
///  P9  a rebate is paid only on a swap the pool fills completely: a swap stopped short by its price limit after a
///      rebate was paid is refused (`RebateOnPartialFill`). Added after its test went red on the first version: a
///      specified delta is committed before the pool knows its fill, and the swapper's specified side is
///      `pool - hook`, so a swap limited at the pool's price was paid the rebate for (almost) nothing.
///  P10 NATIVE CURRENCY (2026-09-24, K14; until then a native pool was refused at initialisation): with ETH as
///      `currency0` every promise above holds with ETH on either side. The fee in ETH arrives by the manager's `take`
///      (so the hook has a `receive()`, and it accepts ETH from the manager only); a rebate in ETH is paid with
///      `settle{value}` and no `sync`, and P7 still applies (with an ERC-20 synced, `settle{value}` would revert
///      `NonzeroNativeValue`, and a `sync` of ours would clobber the payment in flight). Both ledgers read the
///      hook's own ETH balance around each move, as they read a token balance.
///  P11 LIVENESS, the price of P9 - a LIMIT, stated (2026-09-24, K13b, from the verifier V13): while the rebate budget
///      of the specified currency lasts (and no payment is in flight, P7), EVERY swap the pool does not fill completely
///      is refused whole, not only the near-empty fills P9 was written for. A price limit is a partial fill waiting to
///      happen, and a limit quoted for the plain swap does not fit the swap with the rebate (the rebate makes the pool
///      swap more input, or deliver less output, than the quote). V13's sweep, 160 swaps of 1e16 to 4.9e18 with limits 0.0025 %
///      to 1 % of the sqrt price away from it, all four orientations, a funded hook: 17 filled with the rebate, 143 refused
///      `RebateOnPartialFill`, 0 stood without a rebate, 0 other reverts, 0 rebates on a partial fill. Once the budget
///      is spent (or with P7 skipping it) a partial fill stands again, as a plain swap. Tests:
///      `test_P11_with_a_rebate_budget_every_partial_fill_is_refused`,
///      `test_two_swaps_in_one_transaction_a_partial_second_with_no_rebate_left_stands`. The toy keeps the
///      refusal as its trade-off (a rebate that is not paid in full is not paid at all); no alternative is tested here.
///  P12 A PAYMENT THE CURRENCY CANNOT HIJACK (2026-09-24, K15): the rebate is sync + transfer + settle, and the transfer
///      runs the currency's own code (a token with transfer hooks) in the middle of it. Before settling, the hook checks
///      that the synced currency and the checkpoint its `sync` set are still the manager's, and refuses the swap if not
///      (`SettlementHijacked`). Without it, a `sync` from the token's callback left the rebate in the manager as nobody's,
///      and a `settle` + `take` from it KEPT the rebate, with the swap standing (measured: the swapper got no rebate, the
///      hook's reserve fell by it, the callback took 89 828 095 180 378). The token can still refuse service - it can
///      always revert its own transfer - it can no longer take the rebate. Tests:
///      `test_P12_a_currency_that_moves_the_checkpoint_mid_rebate_is_refused`,
///      `test_P12_a_resync_of_the_same_currency_before_the_move_is_harmless`.
///      Second half (2026-09-24, K15b, from the verifier V15): the slot and the checkpoint are not the payment. A callback
///      that `take`s x of the currency and pays for it with x of its OWN claims (`burn`) squares its books and leaves both
///      alone, and the hook's `settle` credits x less than it sent (measured on the hook with the first check only: the
///      swap stood, the pool's reserve fell by the rebate, 100 000 000 000 000, `rebatesPaid` rose by 0, the swapper got
///      nothing and neither did the callback - a loss with no beneficiary). So after settling, the hook compares what the
///      manager CREDITED it (`settle`'s return, which is exactly what the manager added to the hook's own delta) with what
///      left its balance, and refuses the swap if the credit is short (`RebateNotCredited`). The PRICE, measured: the hook
///      cannot tell that callback from a currency that charges a fee on the transfer, so a rebate in a fee-on-transfer
///      currency is refused whole too - on the exact-out swap whose output is that currency (an input in it already dies
///      on the router's own short payment), while the pool's budget in it lasts. Tests:
///      `test_P12_a_take_paid_with_the_callbacks_own_claims_mid_rebate_is_refused`,
///      `test_P12_price_a_rebate_in_a_currency_that_charges_on_transfer_is_refused`.
///  P13 PER POOL (2026-09-24, K15): the reserve and the block cap are kept per pool and currency. Until then they were
///      per currency, hook-wide, and anybody could create a pool on this hook with a worthless token of their own
///      against a currency another pool had earned, be its only provider, and swap the earned currency in: the rebate
///      came out of the other pool's fees, the hook's fee was paid in the worthless token, and the provider took the
///      rebate back out of its pool (measured: the whole block's cap of the earned currency, every block). With ETH on
///      one side of almost every pool, the common case. `reserveOf`, `feesBooked` and `rebatesPaid` stay hook-wide (the
///      ledger against the balance); `poolReserveOf`, `rebateBudgetLeft(id, c)` and `budgetOf(id, c)` are per pool.
///      Tests: `test/examples/DeltaFeeHook.multipool.t.sol` (three unit tests and a two-pool campaign),
///      `test_the_eth_reserve_of_one_pool_pays_no_eth_rebate_on_another`.
///
/// LIMIT, measured (K15, not fixed): the fee is TAKEN in `afterSwap`, and on an exact-out swap it is in the input
/// currency, which the swapper pays only after the swap returns. `take` is a transfer out of what the manager holds now,
/// so the fee needs the manager to hold that much of the input already: on a manager holding none of it (a pool whose
/// liquidity is all on the other side, and no other pool with that currency) the first exact-out swap into it dies in
/// the hook's `take`; at prices near the ends of the range the same refusal appears whenever the fee exceeds the
/// manager's whole inventory (`test_the_fee_on_an_input_the_manager_does_not_hold_yet_kills_an_exact_out_swap`,
/// `test_the_delta_example_at_the_edges`). `ClaimsFeeHook`, which mints its fee, has no such refusal.
///
/// Out of scope, declared: the protocol fee (the harness never sets one); a campaign on a native pool (the native pool
/// has unit tests, `test/examples/DeltaFeeHook.native.t.sol`; the invariant suite runs on two ERC-20s); tokens whose balance lies TO THE HOOK
/// (the ledger is by balance difference, so a token that lies to it about its own balance can move `reserveOf`). A swap
/// nested INSIDE another swap on a pool of this hook shares the one transient slot P9 reads: the verifier V13 ran it
/// (2026-09-24) and found no window, and since P12 a nested swap reached through the rebate's own transfer is refused
/// with the outer swap (`test_P12_a_currency_that_moves_the_checkpoint_mid_rebate_is_refused`, its last case).
contract DeltaFeeHook is IHooks {
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 public constant BPS = 10_000;
    /// @notice the hook's fee on the unspecified amount (30 = 0.30 %)
    uint256 public constant FEE_BPS = 30;
    /// @notice the rebate on the specified amount (10 = 0.10 %)
    uint256 public constant REBATE_BPS = 10;
    /// @notice per block and currency, rebates may total this share of the reserve (1 000 = 10 %)
    uint256 public constant REBATE_CAP_BPS = 1_000;

    IPoolManager public immutable manager;

    /// @notice what the hook holds in each currency by its OWN ledger: received minus sent, measured by balance
    /// difference around every transfer (a donation is not in it: donations fund nothing). HOOK-WIDE: the sum of
    /// `poolReserveOf` over every pool that has the currency
    mapping(Currency => uint256) public reserveOf;
    /// @notice the same ledger PER POOL (P13): what each pool's fees brought in, less what its rebates paid out. A pool's
    /// rebates are paid out of its own reserve only
    mapping(PoolId => mapping(Currency => uint256)) public poolReserveOf;
    /// @notice cumulative fees the manager booked to the hook, and cumulative rebates the manager credited it for,
    /// hook-wide (the per-pool books are `poolReserveOf`)
    mapping(Currency => uint256) public feesBooked;
    mapping(Currency => uint256) public rebatesPaid;

    /// @dev uint256 fields (P5 at the edges): the cap was a uint96, and `uint96(reserve * 10 %)` truncated silently for a
    /// reserve above ~7.9e29 of a currency - a trillion-token supply at 18 decimals, or any currency near an end of the
    /// price range (`test_the_block_cap_holds_above_2_to_the_96`)
    struct Budget {
        uint256 blockNumber;
        uint256 cap;
        uint256 used;
    }

    /// @dev per pool and currency (P13)
    mapping(PoolId => mapping(Currency => Budget)) internal _budget;

    /// @dev the rebate paid in `beforeSwap`, carried to `afterSwap` of the same swap in transient storage
    bytes32 private constant REBATE_IN_FLIGHT_SLOT = keccak256("DeltaFeeHook.rebateInFlight");

    error NotTheManager();
    error NotImplemented();
    error RebateOnPartialFill();
    /// @notice P12: between this hook's `sync` and its `settle`, something moved the manager's synced currency or its
    /// checkpoint - the currency's own transfer hook, re-entering the manager
    error SettlementHijacked();
    /// @notice P12, second half: the manager credited the hook less than left its balance for the rebate - a callback
    /// took from the payment in flight, or the currency charged on the transfer (the hook cannot tell them apart)
    error RebateNotCredited(uint256 sent, uint256 credited);

    event FeeTaken(PoolId indexed id, Currency indexed currency, uint256 booked, uint256 received);
    event Rebated(PoolId indexed id, Currency indexed currency, uint256 paid, uint256 sent);
    event RebateSkippedSynced(PoolId indexed id, Currency indexed synced);

    modifier onlyManager() {
        if (msg.sender != address(manager)) revert NotTheManager();
        _;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @notice ETH reaches the hook only as its fee, from the manager's `take` (P8, P10). A donation of ETH is refused,
    /// where a donation of a token cannot be: it would be outside the ledger either way.
    receive() external payable {
        if (msg.sender != address(manager)) revert NotTheManager();
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function requiredFlags() public pure returns (uint160) {
        return Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    }

    // ------------------------------------------------------------------ the arithmetic, pure
    /// @notice true when currency0 is the SPECIFIED currency of a swap with these parameters
    function specifiedIsCurrency0(SwapParams memory params) public pure returns (bool) {
        return (params.amountSpecified < 0) == params.zeroForOne;
    }

    function feeOf(uint256 unspecifiedAbs) public pure returns (uint256) {
        return unspecifiedAbs * FEE_BPS / BPS;
    }

    function nominalRebateOf(uint256 specifiedAbs) public pure returns (uint256) {
        return specifiedAbs * REBATE_BPS / BPS;
    }

    /// @notice the rebate budget still unspent in `currency` on pool `id` in THIS block (a block that has not begun yet
    /// for this pool and currency is quoted from the pool's reserve now, which is what its first swap will fix)
    function rebateBudgetLeft(PoolId id, Currency currency) public view returns (uint256) {
        Budget memory b = _budget[id][currency];
        if (b.blockNumber != block.number) return poolReserveOf[id][currency] * REBATE_CAP_BPS / BPS;
        return b.used >= b.cap ? 0 : b.cap - b.used;
    }

    function budgetOf(PoolId id, Currency currency) external view returns (Budget memory) {
        return _budget[id][currency];
    }

    // ------------------------------------------------------------------ the two callbacks it declares
    /// @notice the REBATE. Negative specified delta, settled here.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        onlyManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        Currency specified = specifiedIsCurrency0(params) ? key.currency0 : key.currency1;
        PoolId id = key.toId();
        uint256 rebate = _rebateAllowed(
            id, specified, params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified)
        );
        if (rebate == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        // P7: a payment is in flight (somebody synced and has not settled). Our `sync` would reset its checkpoint.
        Currency synced = manager.getSyncedCurrency();
        if (!synced.isAddressZero()) {
            emit RebateSkippedSynced(id, synced);
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 paid = _payRebate(id, specified, rebate);
        bytes32 slot = REBATE_IN_FLIGHT_SLOT;
        assembly ("memory-safe") {
            tstore(slot, paid)
        }
        // the hook's delta: it OWES the manager `paid` of the specified currency, which it has just settled
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(-int128(int256(paid)), 0), 0);
    }

    /// @dev fixes the block's budget of pool `id` at its first swap that specifies `specified` (before anything is
    /// paid), and returns the nominal rebate cut to what the pool's budget and the pool's reserve leave
    function _rebateAllowed(PoolId id, Currency specified, uint256 specifiedAbs) internal returns (uint256 rebate) {
        Budget storage b = _budget[id][specified];
        uint256 poolReserve = poolReserveOf[id][specified];
        if (b.blockNumber != block.number) {
            b.blockNumber = block.number;
            b.cap = poolReserve * REBATE_CAP_BPS / BPS;
            b.used = 0;
        }
        rebate = nominalRebateOf(specifiedAbs);
        uint256 left = b.used >= b.cap ? 0 : b.cap - b.used;
        if (rebate > left) rebate = left;
        if (rebate > poolReserve) rebate = poolReserve; // cannot happen while cap <= reserve; cheap
    }

    /// @dev sync, transfer, settle - and return what the MANAGER credited, not what we meant to send. ETH: `settle{value}`,
    /// no sync (P10). P12: the transfer runs the currency's own code, so before settling, the synced currency and the
    /// checkpoint our `sync` set must still be the manager's, and after it the manager must have credited all that left us
    function _payRebate(PoolId id, Currency specified, uint256 rebate) internal returns (uint256 paid) {
        uint256 balBefore = specified.balanceOfSelf();
        if (specified.isAddressZero()) {
            paid = manager.settle{value: rebate}();
        } else {
            manager.sync(specified);
            uint256 checkpoint = manager.getSyncedReserves();
            IERC20Minimal(Currency.unwrap(specified)).transfer(address(manager), rebate);
            if (
                Currency.unwrap(manager.getSyncedCurrency()) != Currency.unwrap(specified)
                    || manager.getSyncedReserves() != checkpoint
            ) revert SettlementHijacked();
            paid = manager.settle();
        }
        uint256 sent = balBefore - specified.balanceOfSelf();
        // P12, second half: a credit short of what left us is a payment somebody else emptied (take + burn from the
        // currency's callback) or a currency's transfer fee - either way the reserve would fall by more than the swapper got
        if (paid < sent) revert RebateNotCredited(sent, paid);

        // `sent` can exceed `rebate` only if the token takes more from the sender than it was told to; the ledger
        // follows the balance, and the budget counts what left (so the next rebate of the block sees less left)
        _budget[id][specified].used += sent;
        _debit(id, specified, sent);
        rebatesPaid[specified] += paid;
        emit Rebated(id, specified, paid, sent);
    }

    /// @dev both ledgers, the pool's and the hook-wide one, down by what left (never below zero)
    function _debit(PoolId id, Currency c, uint256 amount) internal {
        uint256 r = poolReserveOf[id][c];
        poolReserveOf[id][c] = amount > r ? 0 : r - amount;
        r = reserveOf[c];
        reserveOf[c] = amount > r ? 0 : r - amount;
    }

    /// @notice the FEE. Positive unspecified delta, taken here.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        override
        onlyManager
        returns (bytes4, int128)
    {
        // `delta` here is the POOL's delta (before any hook delta is subtracted from the swapper's)
        bool s0 = specifiedIsCurrency0(params);

        // P9: a rebate is paid only on a swap the pool FILLED. The rebate was committed in beforeSwap,
        // before the pool knew how much it would fill; the swapper's specified delta is `pool - hook`, so on a swap
        // limited at the pool's price (filled: ~nothing) the swapper was PAID the rebate in the currency it was
        // selling. The pool must have swapped exactly `amountSpecified - rebate` (the `amountToSwap` the manager
        // computed from our delta), or the whole swap is refused.
        _checkFilled(s0 ? delta.amount0() : delta.amount1(), params.amountSpecified);

        Currency unspecified = s0 ? key.currency1 : key.currency0;
        int128 u = s0 ? delta.amount1() : delta.amount0();
        uint256 fee = feeOf(u < 0 ? uint256(uint128(-u)) : uint256(uint128(u)));
        if (fee == 0) return (IHooks.afterSwap.selector, 0);

        uint256 balBefore = unspecified.balanceOfSelf();
        manager.take(unspecified, address(this), fee);
        uint256 received = unspecified.balanceOfSelf() - balBefore;

        PoolId id = key.toId();
        reserveOf[unspecified] += received;
        poolReserveOf[id][unspecified] += received;
        feesBooked[unspecified] += fee;
        emit FeeTaken(id, unspecified, fee, received);

        // the hook's delta: the manager OWES it `fee`, which it has just taken
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    /// @dev P9, and the slot cleared for the next swap of this transaction
    function _checkFilled(int256 poolSpecified, int256 amountSpecified) internal {
        bytes32 slot = REBATE_IN_FLIGHT_SLOT;
        uint256 inFlight;
        assembly ("memory-safe") {
            inFlight := tload(slot)
            tstore(slot, 0)
        }
        if (inFlight != 0 && poolSpecified != amountSpecified - int256(inFlight)) revert RebateOnPartialFill();
    }

    // ------------------------------------------------------------------ the ones it does not declare
    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        revert NotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert NotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
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

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
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
