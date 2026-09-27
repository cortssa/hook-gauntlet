// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {MinimalRouter} from "./MinimalRouter.sol";
import {LiquidityHelper} from "./LiquidityHelper.sol";

/// @notice what the actor has just done; the observer is called after each, with the pool in the state it left
enum JitStep {
    PUSHED, // a swap that moved the price to the plan's target (before entering)
    ENTERED, // its position placed, exactly around the price
    WASHED, // a swap of its own inside the window (the trader variant)
    WASHED_BACK, // the swap back
    PAID_OUT, // the payout call returned
    EXITED, // its position removed; `lastFees0/1` are what the manager paid it for the position
    PUSHED_BACK // the price moved back to where the run found it
}

/// @notice the hook point a campaign's reference model uses to follow the actor: called after EVERY step, so a fee a
/// swap of the actor paid is attributed at the price that swap left, before anything else moves it. `lastSwap` is the
/// swap just made for PUSHED / WASHED / WASHED_BACK / PUSHED_BACK, zero otherwise.
interface IJitObserver {
    function onJitStep(JitStep step, SwapParams calldata lastSwap) external;
}

/// @title JitRecipient - the just-in-time recipient of a payout to "whoever is in range" (`HOOK-ATTACKS.md` class 20)
/// @notice An actor for any hook whose payout goes to in-range liquidity - a `donate` of accrued fees, a sweep, a reward
/// streamed to the active tick - or to traders by volume. It places a position EXACTLY around the current price just
/// before the payout, triggers the payout, and removes the position right after; optionally it first moves the price
/// into a range where nobody else is (then even a dust position is alone in range and takes everything a donation pays),
/// and optionally it is ALSO the trader inside its own window (wash + JIT: it pays a volume fee and is in range to be
/// paid back, the pattern both sides of the kit's A/B round found on a volume reward).
///
/// It is a fixture, not a searcher: it makes no decision. The campaign or the test decides what, when and how much; the
/// actor does it, as a contract (so a hook sees a contract, not a wallet), through the kit's `MinimalRouter` and
/// `LiquidityHelper` - so its position is, to the manager, the helper's, with salt
/// `liquidity.positionSalt(address(this), SALT)`.
///
/// HOOK POINTS - what a campaign for another hook plugs in (`foundry-kit/v4/README.md`, "Paying whoever is in range"):
///  * `Plan.payoutTarget` / `Plan.payoutCall`: the hook's payout entry point, as a call - `sweep(key)`, `distribute()`,
///    `claim(...)`. Empty target: the payout rides on something the actor already does (a swap or a liquidity change
///    whose callback pays), and nothing extra is called.
///  * `Plan.liquidity` and `Plan.spacings`: dust (1) or weight, one tick spacing wide or more. `rangeHoldingThePrice`
///    is the range it uses, readable before the run.
///  * `Plan.pushToSqrtPrice`: 0, or a price to move to first - the variant where the dust is ALONE in range - and
///    `Plan.pushBack` to return there after.
///  * `Plan.washAmount` / `Plan.washLimitSqrtPrice` / `Plan.washBack`: 0, or a swap of its own inside the window (sign
///    = direction: > 0 sells currency0) that stops at the limit price (0: none), and a swap back.
///  * `setObserver`: the reference model's callback (`IJitObserver`), called after every step.
///  * the steps one by one (`push`, `enter`, `wash`, `payout`, `exit`): for a campaign that interleaves other actors
///    between them. `run` does them all in ONE transaction, which is what an attacker does against a rule that only
///    looks at blocks.
/// It needs its own funds: ERC-20s minted or dealt to it, `approveToken` for each, ETH sent to it for a native pool.
contract JitRecipient {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    bytes32 public constant SALT = keccak256("JitRecipient");
    /// @notice the most a push or a wash may spend: the price limit decides where it stops, not the amount
    int256 internal constant PUSH_AMOUNT = -int256(uint256(type(uint128).max));

    IPoolManager public immutable manager;
    MinimalRouter public immutable router;
    LiquidityHelper public immutable liquidity;
    address public immutable owner;
    IJitObserver public observer;

    /// @notice the position it holds, if any (one at a time)
    int24 public tickLower;
    int24 public tickUpper;
    uint128 public placed;
    /// @notice what the manager paid the position on its last exit, and over every exit
    uint256 public lastFees0;
    uint256 public lastFees1;
    uint256 public collected0;
    uint256 public collected1;
    uint256 public runs;

    struct Plan {
        PoolKey key;
        uint128 liquidity;
        uint24 spacings;
        uint160 pushToSqrtPrice;
        bool pushBack;
        int256 washAmount;
        uint160 washLimitSqrtPrice;
        bool washBack;
        address payoutTarget;
        bytes payoutCall;
    }

    /// @notice one run: the range it used, what its position was paid, and its balance change per currency (what it
    /// spent on the push, the wash and the position's rounding included)
    struct Result {
        int24 tickLower;
        int24 tickUpper;
        uint256 fees0;
        uint256 fees1;
        int256 net0;
        int256 net1;
    }

    error NotTheOwner();
    error AlreadyIn();
    error NotIn();
    error PayoutFailed(bytes reason);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotTheOwner();
        _;
    }

    /// @param owner_ who drives it: the campaign's handler, a test, or the observer that follows it
    constructor(IPoolManager manager_, MinimalRouter router_, LiquidityHelper liquidity_, address owner_) {
        manager = manager_;
        router = router_;
        liquidity = liquidity_;
        owner = owner_;
    }

    receive() external payable {}

    function setObserver(IJitObserver o) external onlyOwner {
        observer = o;
    }

    function approveToken(address token) external onlyOwner {
        IERC20Minimal(token).approve(address(router), type(uint256).max);
        IERC20Minimal(token).approve(address(liquidity), type(uint256).max);
    }

    /// @notice the salt the manager sees for its position
    function positionSalt() public view returns (bytes32) {
        return liquidity.positionSalt(address(this), SALT);
    }

    /// @notice `spacings` tick spacings around the one that holds the current tick (1: exactly that one; 3: one more on
    /// each side; an even number leans up). `[lower, upper)` contains the tick, which is v4's "in range" (a position is
    /// active while `lower <= tick < upper`); clamped to the usable ticks of the spacing
    function rangeHoldingThePrice(PoolKey memory key, uint24 spacings) public view returns (int24 lower, int24 upper) {
        (, int24 tick,,) = manager.getSlot0(key.toId());
        int24 s = key.tickSpacing;
        int24 n = int24(uint24(spacings == 0 ? 1 : spacings));
        int24 q = tick / s;
        if (tick < 0 && tick % s != 0) q -= 1;
        lower = (q - (n - 1) / 2) * s;
        upper = lower + n * s;
        int24 minUsable = (TickMath.MIN_TICK / s) * s;
        int24 maxUsable = (TickMath.MAX_TICK / s) * s;
        if (lower < minUsable) (lower, upper) = (minUsable, minUsable + n * s);
        if (upper > maxUsable) (lower, upper) = (maxUsable - n * s, maxUsable);
    }

    // ------------------------------------------------------------------ the whole thing, in one transaction
    function run(Plan memory p) external onlyOwner returns (Result memory r) {
        int256[2] memory before = [_balance(p.key.currency0), _balance(p.key.currency1)];
        _runSteps(p, r);
        r.fees0 = lastFees0;
        r.fees1 = lastFees1;
        r.net0 = _balance(p.key.currency0) - before[0];
        r.net1 = _balance(p.key.currency1) - before[1];
        runs += 1;
    }

    /// @dev a function of its own: inline, the IR build (every test that inherits `V4Harness` compiles it under the
    /// manager's IR restriction) ran out of stack
    function _runSteps(Plan memory p, Result memory r) internal {
        (uint160 startPrice,,,) = manager.getSlot0(p.key.toId());
        if (p.pushToSqrtPrice != 0) _swapTo(p.key, p.pushToSqrtPrice, JitStep.PUSHED);
        (r.tickLower, r.tickUpper) = _enter(p.key, p.liquidity, p.spacings);
        if (p.washAmount != 0) _wash(p.key, p.washAmount, p.washLimitSqrtPrice, p.washBack);
        if (p.payoutTarget != address(0)) _payout(p.payoutTarget, p.payoutCall);
        _exit(p.key);
        if (p.pushToSqrtPrice != 0 && p.pushBack) _swapTo(p.key, startPrice, JitStep.PUSHED_BACK);
    }

    // ------------------------------------------------------------------ the steps, one call each
    function push(PoolKey memory key, uint160 toSqrtPrice) external onlyOwner {
        _swapTo(key, toSqrtPrice, JitStep.PUSHED);
    }

    function enter(PoolKey memory key, uint128 liq, uint24 spacings) external onlyOwner returns (int24, int24) {
        return _enter(key, liq, spacings);
    }

    function wash(PoolKey memory key, int256 amount, uint160 limitSqrtPrice, bool back) external onlyOwner {
        _wash(key, amount, limitSqrtPrice, back);
    }

    function payout(address target, bytes memory data) external onlyOwner {
        _payout(target, data);
    }

    function exit(PoolKey memory key) external onlyOwner returns (uint256, uint256) {
        _exit(key);
        return (lastFees0, lastFees1);
    }

    // ------------------------------------------------------------------ internals
    function _swapTo(PoolKey memory key, uint160 target, JitStep step) internal {
        (uint160 now_,,,) = manager.getSlot0(key.toId());
        if (target == now_) return;
        SwapParams memory sp =
            SwapParams({zeroForOne: target < now_, amountSpecified: PUSH_AMOUNT, sqrtPriceLimitX96: target});
        router.swap{value: _valueFor(key, sp.zeroForOne)}(key, sp, "");
        _tell(step, sp);
    }

    function _enter(PoolKey memory key, uint128 liq, uint24 spacings) internal returns (int24 lower, int24 upper) {
        if (placed != 0) revert AlreadyIn();
        (lower, upper) = rangeHoldingThePrice(key, spacings);
        uint256 value = key.currency0.isAddressZero() ? address(this).balance : 0;
        liquidity.modifyLiquidity{value: value}(
            key,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: int256(uint256(liq)), salt: SALT}),
            ""
        );
        (tickLower, tickUpper, placed) = (lower, upper, liq);
        _tell(JitStep.ENTERED, _none());
    }

    function _wash(PoolKey memory key, int256 amount, uint160 limit, bool back) internal {
        bool zeroForOne = amount > 0;
        uint256 size = amount > 0 ? uint256(amount) : uint256(-amount);
        if (limit == 0) limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        SwapParams memory sp = SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(size), sqrtPriceLimitX96: limit});
        BalanceDelta d = router.swap{value: _valueFor(key, zeroForOne)}(key, sp, "");
        _tell(JitStep.WASHED, sp);
        if (!back) return;
        int128 out = zeroForOne ? d.amount1() : d.amount0();
        if (out <= 0) return;
        SwapParams memory bp = SwapParams({
            zeroForOne: !zeroForOne,
            amountSpecified: -int256(out),
            sqrtPriceLimitX96: !zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        router.swap{value: _valueFor(key, !zeroForOne)}(key, bp, "");
        _tell(JitStep.WASHED_BACK, bp);
    }

    function _payout(address target, bytes memory data) internal {
        (bool ok, bytes memory reason) = target.call(data);
        if (!ok) revert PayoutFailed(reason);
        _tell(JitStep.PAID_OUT, _none());
    }

    function _exit(PoolKey memory key) internal {
        if (placed == 0) revert NotIn();
        (, BalanceDelta fees) = liquidity.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -int256(uint256(placed)), salt: SALT
            }),
            ""
        );
        lastFees0 = uint256(int256(fees.amount0()));
        lastFees1 = uint256(int256(fees.amount1()));
        collected0 += lastFees0;
        collected1 += lastFees1;
        placed = 0;
        _tell(JitStep.EXITED, _none());
    }

    /// @dev ETH as the input of a swap on a native pool: send it all, the router refunds the rest
    function _valueFor(PoolKey memory key, bool zeroForOne) internal view returns (uint256) {
        return key.currency0.isAddressZero() && zeroForOne ? address(this).balance : 0;
    }

    function _balance(Currency c) internal view returns (int256) {
        if (c.isAddressZero()) return int256(address(this).balance);
        return int256(IERC20Minimal(Currency.unwrap(c)).balanceOf(address(this)));
    }

    function _tell(JitStep step, SwapParams memory sp) internal {
        if (address(observer) != address(0)) observer.onJitStep(step, sp);
    }

    function _none() internal pure returns (SwapParams memory) {}
}
