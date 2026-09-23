// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {HostileERC20} from "gauntlet-kit/HostileERC20.sol";
import {HandlerBase, InvariantAsserts, IBalanceReader, YES, NO} from "gauntlet-kit/InvariantBase.sol";
import {V4Harness} from "../../src/V4Harness.sol";
import {HookMiner} from "../../src/HookMiner.sol";
import {MinimalRouter} from "../../src/MinimalRouter.sol";
import {LiquidityHelper} from "../../src/LiquidityHelper.sol";
import {SwapEventReader} from "../../src/SwapEventReader.sol";
import {CappedDynamicFeeHook} from "../../src/examples/CappedDynamicFeeHook.sol";

// ADAPT: a worked TOY, not a template to fill in. The actions and the invariants below belong to a hook
// whose only job is to quote a fee. Yours come from your hook: derive them with doctrine/INVARIANTS.md
// (backwards, from who can lose what) and doctrine/FUZZ-ACTIONS.md (one action per entry point, plus the
// clock, plus the currency misbehaving mid-campaign, plus the strange actors, plus the reads).
//
// What carries over is the SHAPE:
//   * every call into the system wrapped in try/catch AND capped in gas, because `fail_on_revert = true`;
//   * the clock as an action, because this hook's whole rule is per-block;
//   * the hostile currency switched mid-campaign, not in setUp;
//   * the QUOTE compared against what the pool's own event says it charged, every single swap;
//   * _noteSuccess() on every action, and a smoke test that proves the campaign is not vacuous.

/// @notice the truth reader: balances with every switch of the token ignored. Only the invariants see it.
contract TruthReader is IBalanceReader {
    HostileERC20 private immutable token;

    constructor(HostileERC20 t) {
        token = t;
    }

    function balanceOf(address who) external view returns (uint256) {
        return token.trueBalanceOf(who);
    }
}

/// @notice Drives the pool and the currencies against the hook.
contract CappedFeeHandler is HandlerBase, InvariantAsserts {
    IPoolManager public immutable manager;
    CappedDynamicFeeHook public immutable hook;
    MinimalRouter public immutable router;
    LiquidityHelper public immutable liquidity;
    HostileERC20 public immutable token0;
    HostileERC20 public immutable token1;
    IBalanceReader public immutable truth0;
    IBalanceReader public immutable truth1;

    PoolKey internal key;
    int24 internal tickLower;
    int24 internal tickUpper;

    /// @dev a token that eats the gas frame turns a catchable failure into a dead run, and
    /// `fail_on_revert = true` would then blame the handler for the behaviour of the currency.
    uint256 private constant CALL_GAS = 4_000_000;
    uint256 private constant MAX_SWAP = 5e17;
    uint256 private constant MAX_MINT = 1_000e18;

    // ---------------------------------------------------------------- ghosts specific to this hook
    /// @notice the highest fee the POOL was ever seen to charge, read from the manager's event.
    uint24 public maxFeeCharged;
    /// @notice times the fee the pool charged differed from the fee the hook had just quoted. Must stay 0.
    uint256 public quoteMismatches;
    /// @notice times the quote and the charge were compared at all. If this is 0 the check above is vacuous.
    uint256 public quoteChecks;
    uint256 public swapsOk;
    uint256 public capReached;
    /// @notice THE GROWTH RULE'S GHOSTS (round r01, finding F1). The first quote read in each block, and the times any
    /// later quote or charge IN THAT BLOCK differed from it. "charged == quoted" above compares a swap with the quote
    /// read immediately before it, and was green while a victim who read its quote EARLIER in the block could be
    /// charged ten times that quote by anyone placing swaps in between. This compares every swap with the block's
    /// first quote instead. Must stay 0.
    uint256 public quoteBlock;
    uint24 public firstQuoteOfBlock;
    uint256 public inBlockFeeMoves;
    /// @notice times a victim's quote, read before somebody else's dust in the same block, was not what it was charged
    uint256 public victimQuoteBroken;
    uint256 public victimChecks;
    /// @notice liquidity this handler believes each actor has in the pool, by the salt it used.
    mapping(address => uint256) public liquidityOf;
    /// @notice everything created out of nothing, PER CURRENCY. `HandlerBase.ghostMinted` is one counter and
    /// there are two currencies here; conservation has to be closed for each of them separately.
    uint256 public minted0;
    uint256 public minted1;

    constructor(
        IPoolManager manager_,
        CappedDynamicFeeHook hook_,
        MinimalRouter router_,
        LiquidityHelper liquidity_,
        HostileERC20 t0,
        HostileERC20 t1,
        IBalanceReader truth0_,
        IBalanceReader truth1_,
        PoolKey memory key_,
        int24 lower,
        int24 upper
    ) {
        manager = manager_;
        hook = hook_;
        router = router_;
        liquidity = liquidity_;
        token0 = t0;
        token1 = t1;
        truth0 = truth0_;
        truth1 = truth1_;
        key = key_;
        tickLower = lower;
        tickUpper = upper;
        for (uint256 i = 0; i < 5; i++) _addActor(address(uint160(0x5000 + i)));
    }

    function poolKey() public view returns (PoolKey memory) {
        return key;
    }

    /// @notice every address either currency can reach. A conservation assertion over an incomplete list is
    /// not a weaker check, it is a wrong one.
    function holders() public view returns (address[] memory out) {
        out = new address[](actors.length + 6);
        for (uint256 i = 0; i < actors.length; i++) out[i] = actors[i];
        out[actors.length] = address(manager);
        out[actors.length + 1] = address(hook);
        out[actors.length + 2] = address(router);
        out[actors.length + 3] = address(liquidity);
        out[actors.length + 4] = token0.FEE_SINK();
        out[actors.length + 5] = token0.RESERVE();
    }

    // ---------------------------------------------------------------- funding (not a fuzz target)
    /// @notice called once from setUp so that the opening liquidity is on the ghost ledger too.
    function seed(uint256 amount, int256 liq) external {
        address a = actors[0];
        _mintAndApprove(a, amount);
        vm.prank(a);
        liquidity.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liq,
                salt: _saltOf(a)
            }),
            ""
        );
        liquidityOf[a] += uint256(liq);
    }

    function _saltOf(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _mintAndApprove(address a, uint256 amount) internal {
        token0.mint(a, amount);
        token1.mint(a, amount);
        minted0 += amount;
        minted1 += amount;
        _noteMint(amount * 2);
        vm.startPrank(a);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token0.approve(address(liquidity), type(uint256).max);
        token1.approve(address(liquidity), type(uint256).max);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- actions: the entry points
    function fund(uint256 actorSeed, uint256 amount) public counted("fund") {
        _mintAndApprove(_actor(actorSeed), bound(amount, 0, MAX_MINT));
        _noteSuccess("fund");
    }

    /// @notice the action the whole hook exists for. Reads the quote first, swaps, then compares the quote
    /// with the fee the MANAGER says it charged.
    function swap(uint256 actorSeed, uint256 amount, uint256 zeroForOneWord) public counted("swap") {
        bool zeroForOne = _bit(zeroForOneWord);
        if (_doSwap(_actor(actorSeed), bound(amount, 1, MAX_SWAP), zeroForOne)) _noteSuccess("swap");
    }

    /// @notice MANY swaps inside ONE block.
    ///
    /// This action exists because of a measurement, and it is the most useful thing in this file to copy.
    /// With only the single `swap` above, a campaign of 4 096 calls spread over fifteen actions almost never
    /// produced ten swaps between two `nextBlock`s - so the fee never reached its cap, and the invariant
    /// that says "the pool never charged more than the cap" passed without ever being near it. A mutant that
    /// removed the cap altogether still went green in the fuzz run. That is the vacuous pass, caught in the
    /// act.
    ///
    /// The fix is not a bigger campaign, it is an action that reaches the state: one call, many swaps, no
    /// block change in between (and, since round r01, one block step after them, where they are charged). Ask of your own hook: which of my rules only bites after N things happen in
    /// a row, and does my handler have an action that does N things in a row?
    function swapBurst(uint256 actorSeed, uint256 amount, uint256 n) public counted("swapBurst") {
        address a = _actor(actorSeed);
        // The cap needs NINE swaps in a block (`BASE_FEE + 9 * STEP == MAX_FEE`), and since round r01 it is paid in
        // the block AFTER them. A uniform 2..14 burst is long enough only about a third of the time, and then only if
        // the currencies let every one of those swaps through. Measured on a fresh corpus (the first rule, same
        // shape): the campaign reached the cap in as few as 3 of 65 runs, and a campaign that never reaches the
        // boundary cannot tell a capped hook from an uncapped one - which is exactly the mutant this action exists
        // to kill.
        //
        // So half the bursts are deliberately long enough, and every burst ends by stepping ONE block and swapping
        // once, which is where the congestion it built is charged. Having written an action that does N things in
        // a row, make sure it does N and not "on average, fewer than N" - and that it reaches the place where N
        // things are paid for.
        uint256 count = _bitOneIn(n, 2) ? bound(n, 10, 14) : bound(n, 2, 14);
        uint256 size = bound(amount, 1, MAX_SWAP / 8);
        bool any;
        for (uint256 i = 0; i < count; i++) {
            if (_doSwap(a, size, i % 2 == 0)) any = true;
        }
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
        if (_doSwap(a, size, true)) any = true;
        if (any) _noteSuccess("swapBurst");
    }

    /// @notice the fee the last successful swap was charged (read by `dustAheadOfVictim`)
    uint24 internal lastCharged;

    /// @notice record the first quote of a block; any later quote in the same block that differs is a move
    function _noteQuoteInBlock(uint24 q) internal {
        // the cheatcode, not `block.number`: `swapBurst` rolls the block and then swaps in the same frame, and the
        // optimizer may reuse a read of `block.number` taken before the roll
        uint256 bn = vm.getBlockNumber();
        if (bn != quoteBlock) {
            quoteBlock = bn;
            firstQuoteOfBlock = q;
        } else if (q != firstQuoteOfBlock) {
            inBlockFeeMoves += 1;
        }
    }

    /// @notice F1's ORDERING, as an action (round r01). A victim reads its quote; somebody else places `n` dust swaps
    /// in the same block; then the victim swaps and is compared with the quote IT read, not one read just before its
    /// swap. `swapBurst` produces the interleaving too, but only `invariant_the_fee_never_moves_inside_a_block` asks
    /// about it; this action puts F1's exact shape in the campaign, with the victim's own check and a reach boundary,
    /// so that the census says how often the ordering the round found was actually tried.
    function dustAheadOfVictim(uint256 victimSeed, uint256 attackerSeed, uint256 n, uint256 amount)
        public
        counted("dustAheadOfVictim")
    {
        address v = _actor(victimSeed);
        address x = _actor(attackerSeed);
        uint24 quotedToVictim;
        try hook.quoteNextFee(key) returns (uint24 q) {
            quotedToVictim = q;
        } catch {
            _unexpectedRevert("quoteNextFee reverted on a pool the hook was initialised with");
            return;
        }
        _noteQuoteInBlock(quotedToVictim);
        uint256 dust = bound(n, 1, 12);
        uint256 dustOk;
        for (uint256 i = 0; i < dust; i++) {
            if (_doSwap(x, 1, i % 2 == 0)) dustOk += 1;
        }
        if (_doSwap(v, bound(amount, 1, MAX_SWAP), true)) {
            victimChecks += 1;
            if (lastCharged != quotedToVictim) victimQuoteBroken += 1;
            if (dustOk > 0) _noteReached("victim traded after dust in its block");
            _noteSuccess("dustAheadOfVictim");
        }
    }

    function _doSwap(address a, uint256 amount, bool zeroForOne) internal returns (bool ok) {
        int256 amountIn = int256(amount);

        uint24 quoted;
        try hook.quoteNextFee(key) returns (uint24 q) {
            quoted = q;
        } catch {
            // `_unexpectedRevert` RECORDS now, it does not revert (see HandlerBase), so this branch has to
            // stop by itself: comparing the execution against a quote that never arrived would report a
            // second, invented finding on top of the real one.
            _unexpectedRevert("quoteNextFee reverted on a pool the hook was initialised with");
            return false;
        }
        _noteQuoteInBlock(quoted);

        vm.recordLogs();
        vm.prank(a);
        try router.swap{gas: CALL_GAS}(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amountIn,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        ) {
            swapsOk += 1;
            ok = true;
            (bool found, uint24 charged) = SwapEventReader.lastSwapFee(vm.getRecordedLogs(), address(manager));
            lastCharged = 0; // a swap that left no Swap event is compared as 0, never as the previous swap's fee
            if (found) {
                quoteChecks += 1;
                // AROUND THE ACTION: what the hook SAID, against what the pool DID.
                if (charged != quoted) quoteMismatches += 1;
                if (charged != firstQuoteOfBlock) inBlockFeeMoves += 1;
                lastCharged = charged;
                if (charged > maxFeeCharged) maxFeeCharged = charged;
                if (charged == hook.MAX_FEE()) {
                    capReached += 1;
                    // the reach census (doctrine/EVIDENCE.md 7). The success census says swaps happened; this
                    // says they happened at the boundary the hook's whole promise is about.
                    _noteReached("fee at the cap");
                }
                if (charged == hook.BASE_FEE()) _noteReached("fee at the base");
                if (charged > hook.BASE_FEE() && charged < hook.MAX_FEE()) _noteReached("fee between the two");
            }
        } catch (bytes memory err) {
            // a refused swap is behaviour: no liquidity left, a paused currency, a fee on transfer that
            // makes the settlement short, a currency that ate the frame. All predicted by the model -
            // UNLESS the failure came out of the hook, which `_classifyPoolFailure` tells apart.
            _classifyPoolFailure(err, "swap");
        }
    }

    /// @notice `catch { _expectedRevert(); }` files EVERY failure under "predicted", and a panic inside the hook
    /// would be filed there with the rest. The manager tells the two apart for us: a revert that came out of a
    /// hook arrives wrapped (ERC-7751 `WrappedError(target, selector, reason, details)`) with the hook as the
    /// target. THIS hook has no reason to refuse a swap or a liquidity change on a pool it accepted, so a wrapped
    /// error that names it is a surprise.
    ///
    /// That is only HALF of how a hook fails. A hook that does not revert but RETURNS something wrong - the wrong
    /// selector, a fee above the maximum - is rejected by the manager with an error OF THE MANAGER, unwrapped, and
    /// an earlier version of this function filed that under "predicted": a mutant that answered with another
    /// selector from its fifth swap in a block went green in 3 campaigns out of 3, and the boundary the hook's
    /// whole promise is about ("fee at the cap") silently left the census. So the two manager errors that can only
    /// mean "the hook's answer was bad" are surprises here too. Everything else - the currencies, the manager's
    /// other checks, a dead frame - is what the model predicts. Yours may refuse on purpose: then list the
    /// selectors it declares, in both directions.
    function _classifyPoolFailure(bytes memory err, string memory where) internal {
        if (err.length >= 4) {
            bytes4 sel = bytes4(err);
            if (sel == Hooks.InvalidHookResponse.selector || sel == LPFeeLibrary.LPFeeTooLarge.selector) {
                _unexpectedRevert(string.concat(where, ": the manager REJECTED what the hook returned"));
                return;
            }
        }
        if (err.length >= 36 && bytes4(err) == CustomRevert.WrappedError.selector) {
            address target;
            assembly {
                target := mload(add(err, 36))
            }
            if (target == address(hook)) {
                _unexpectedRevert(string.concat(where, ": the HOOK reverted, and nothing in its model says it may"));
                return;
            }
        }
        _expectedRevert();
    }

    function addLiquidity(uint256 actorSeed, uint256 liq) public counted("addLiquidity") {
        address a = _actor(actorSeed);
        uint256 amount = bound(liq, 1e12, 1e18);

        vm.prank(a);
        try liquidity.modifyLiquidity{gas: CALL_GAS}(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(amount),
                salt: _saltOf(a)
            }),
            ""
        ) {
            liquidityOf[a] += amount;
            _noteSuccess("addLiquidity");
        } catch (bytes memory err) {
            _classifyPoolFailure(err, "addLiquidity");
        }
    }

    function removeLiquidity(uint256 actorSeed, uint256 liq) public counted("removeLiquidity") {
        address a = _actor(actorSeed);
        uint256 have = liquidityOf[a];
        if (have == 0) {
            _expectedRevert();
            return;
        }
        uint256 amount = bound(liq, 1, have);

        vm.prank(a);
        try liquidity.modifyLiquidity{gas: CALL_GAS}(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(amount),
                salt: _saltOf(a)
            }),
            ""
        ) {
            liquidityOf[a] = have - amount;
            _noteSuccess("removeLiquidity");
        } catch (bytes memory err) {
            _classifyPoolFailure(err, "removeLiquidity");
        }
    }

    // ---------------------------------------------------------------- actions: the clock
    /// @notice the hook's entire rule is "per block", so a campaign that never changes block is a campaign
    /// that tests one branch. Both sides of the boundary: same block, and the next one.
    function nextBlock(uint256 n) public counted("nextBlock") {
        uint256 blocks = bound(n, 1, 3);
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks * 12);
        _noteSuccess("nextBlock");
    }

    // ---------------------------------------------------------------- actions: the reads
    /// @notice a quote is an entry point. Nobody fuzzes them, and they are what other people's software
    /// trusts.
    function readQuote() public counted("readQuote") {
        try hook.quoteNextFee(key) returns (uint24 q) {
            _noteQuoteInBlock(q);
            _noteSuccess("readQuote");
            require(q <= hook.MAX_FEE(), "the hook quoted more than its own cap");
            require(q >= hook.BASE_FEE(), "the hook quoted less than its own base");
            if (q == hook.MAX_FEE()) _noteReached("quote at the cap");
            if (q == hook.BASE_FEE()) _noteReached("quote at the base");
        } catch {
            _unexpectedRevert("the quote reverted on a known pool");
        }
    }

    // ---------------------------------------------------------------- actions: the strange actors
    /// @notice tokens pushed straight at the hook. It has no delta permissions, so it can never spend them,
    /// and it must never behave as though it could.
    function donateToHook(uint256 amount, uint256 whichWord) public counted("donateToHook") {
        bool which = _bit(whichWord);
        uint256 v = bound(amount, 0, 1e18);
        HostileERC20 t = which ? token1 : token0;
        t.mint(address(hook), v);
        _noteDonation(address(hook), address(t), v);
        if (which) minted1 += v;
        else minted0 += v;
        _noteSuccess("donateToHook");
    }

    /// @notice and straight at the manager, which is a different thing: the manager's accounting is by
    /// synced reserves, and a donation it never synced is value nobody can claim.
    function donateToManager(uint256 amount, uint256 whichWord) public counted("donateToManager") {
        bool which = _bit(whichWord);
        uint256 v = bound(amount, 0, 1e18);
        HostileERC20 t = which ? token1 : token0;
        t.mint(address(manager), v);
        _noteDonation(address(manager), address(t), v);
        if (which) minted1 += v;
        else minted0 += v;
        _noteSuccess("donateToManager");
    }

    // ---------------------------------------------------------------- actions: the currency misbehaving
    // Set MID-CAMPAIGN, never only in setUp: a hostile mode that is fixed before the first action tests one
    // ordering out of millions.
    //
    // And set with a BIAS, because these switches are sticky. A `_bit` flag is on half the time and only
    // goes off when the fuzzer happens to call the same action again with the other value; the campaign
    // therefore parks itself in the broken state and stays there. Measured on this example, 64 runs x 64
    // calls, fresh corpus: 8 of 65 runs and then 17 of 65 ended with ZERO successful swaps, and the run that
    // reached the fee cap - the boundary the hook's whole promise is about - was as rare as 3 of 65. See
    // `HandlerBase._bitOneIn`, and `calmDown()` at the end of this section.
    function setFeeOnTransfer(uint256 bps, uint256 whichWord) public counted("setFeeOnTransfer") {
        bool which = _bit(whichWord);
        uint256 v = bound(bps, 0, 500);
        (which ? token1 : token0).setFeeBps(v <= 125 ? 0 : v); // a quarter of the range means "no fee"
        _noteSuccess("setFeeOnTransfer");
    }

    function setPaused(uint256 onWord, uint256 whichWord) public counted("setPaused") {
        bool on = _bitOneIn(onWord, 4);
        bool which = _bit(whichWord);
        (which ? token1 : token0).setPaused(on);
        _noteSuccess("setPaused");
    }

    function setOmitReturn(uint256 onWord, uint256 whichWord) public counted("setOmitReturn") {
        bool on = _bit(onWord);
        bool which = _bit(whichWord);
        (which ? token1 : token0).setOmitReturnValue(on);
        _noteSuccess("setOmitReturn");
    }

    function setShortDeliver(uint256 actorSeed, uint256 div, uint256 whichWord) public counted("setShortDeliver") {
        bool which = _bit(whichWord);
        (which ? token1 : token0).setShortDeliver(_actor(actorSeed), bound(div, 0, 4));
        _noteSuccess("setShortDeliver");
    }

    function setGasHog(uint256 actorSeed, uint256 onWord, uint256 whichWord) public counted("setGasHog") {
        bool on = _bitOneIn(onWord, 3);
        bool which = _bit(whichWord);
        (which ? token1 : token0).setGasHogTransfer(_actor(actorSeed), on);
        _noteSuccess("setGasHog");
    }

    function setManagerBlocked(uint256 onWord, uint256 whichWord) public counted("setManagerBlocked") {
        bool on = _bitOneIn(onWord, 4);
        bool which = _bit(whichWord);
        (which ? token1 : token0).setBlockIncoming(address(manager), on);
        _noteSuccess("setManagerBlocked");
    }

    /// @notice item 3 of the hook's threat model, the only action that makes a currency LIE about a balance
    /// rather than move the wrong amount. It existed here for a whole round without being registered in
    /// `targetSelector` below, so it never ran once - which is what an unregistered action looks like, and
    /// forge does not warn about it. Count the selector table against the handler whenever you add one.
    function setManagerUnreadable(uint256 onWord, uint256 whichWord) public counted("setManagerUnreadable") {
        bool on = _bitOneIn(onWord, 4);
        bool which = _bit(whichWord);
        (which ? token1 : token0).setBalanceRevert(address(manager), on);
        _noteSuccess("setManagerUnreadable");
    }

    /// @notice turn every sticky switch on both currencies OFF.
    ///
    /// The campaign needs a cheap way BACK from a broken configuration, not only ways into one. Without it
    /// the first paused currency or blocked manager ends the useful part of the run, and the invariants then
    /// hold over a pool nobody can trade on - a vacuous pass that looks exactly like a real one.
    function calmDown() public counted("calmDown") {
        token0.setPaused(false);
        token1.setPaused(false);
        token0.setFeeBps(0);
        token1.setFeeBps(0);
        token0.setOmitReturnValue(false);
        token1.setOmitReturnValue(false);
        token0.setBlockIncoming(address(manager), false);
        token1.setBlockIncoming(address(manager), false);
        token0.setBalanceRevert(address(manager), false);
        token1.setBalanceRevert(address(manager), false);
        for (uint256 i = 0; i < actors.length; i++) {
            token0.setShortDeliver(actors[i], 0);
            token1.setShortDeliver(actors[i], 0);
            token0.setGasHogTransfer(actors[i], false);
            token1.setGasHogTransfer(actors[i], false);
        }
        _noteSuccess("calmDown");
    }

    function fundReserve(uint256 amount, uint256 whichWord) public counted("fundReserve") {
        bool which = _bit(whichWord);
        uint256 v = bound(amount, 0, 1e18);
        (which ? token1 : token0).fundReserve(v);
        _noteMint(v);
        if (which) minted1 += v;
        else minted0 += v;
        _noteSuccess("fundReserve");
    }
}

contract CappedDynamicFeeHookInvariants is V4Harness, InvariantAsserts {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    CappedDynamicFeeHook internal hook;
    CappedFeeHandler internal handler;
    TruthReader internal truth0;
    TruthReader internal truth1;
    PoolKey internal key;

    function setUp() public {
        _setUpManager();
        _deployCurrencies();
        _deployRouters();

        (, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG,
            type(CappedDynamicFeeHook).creationCode,
            abi.encode(manager)
        );
        hook = new CappedDynamicFeeHook{salt: salt}(manager);

        key = _initPool(IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, SQRT_PRICE_1_1);
        (int24 lower, int24 upper) = _fullRange(60);

        truth0 = new TruthReader(token0);
        truth1 = new TruthReader(token1);

        handler = new CappedFeeHandler(
            manager,
            hook,
            router,
            liquidity,
            token0,
            token1,
            IBalanceReader(address(truth0)),
            IBalanceReader(address(truth1)),
            key,
            lower,
            upper
        );
        handler.seed(100_000e18, 50e18);

        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](19);
        sel[18] = CappedFeeHandler.dustAheadOfVictim.selector;
        sel[15] = CappedFeeHandler.swapBurst.selector;
        sel[16] = CappedFeeHandler.setManagerUnreadable.selector;
        sel[17] = CappedFeeHandler.calmDown.selector;
        sel[0] = CappedFeeHandler.fund.selector;
        sel[1] = CappedFeeHandler.swap.selector;
        sel[2] = CappedFeeHandler.addLiquidity.selector;
        sel[3] = CappedFeeHandler.removeLiquidity.selector;
        sel[4] = CappedFeeHandler.nextBlock.selector;
        sel[5] = CappedFeeHandler.readQuote.selector;
        sel[6] = CappedFeeHandler.donateToHook.selector;
        sel[7] = CappedFeeHandler.donateToManager.selector;
        sel[8] = CappedFeeHandler.setFeeOnTransfer.selector;
        sel[9] = CappedFeeHandler.setPaused.selector;
        sel[10] = CappedFeeHandler.setOmitReturn.selector;
        sel[11] = CappedFeeHandler.setShortDeliver.selector;
        sel[12] = CappedFeeHandler.setGasHog.selector;
        sel[13] = CappedFeeHandler.setManagerBlocked.selector;
        sel[14] = CappedFeeHandler.fundReserve.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        // Every public action of the handler is in this list. `setManagerUnreadable` was written, documented
        // as covering item 3 of the threat model, and left out of this array: it never ran, and nothing said
        // so. Count the rows of the selector table forge prints against the actions in the handler.
        assertEq(sel.length, 19, "the selector list and the handler have drifted apart");
    }

    /// @notice THE CAMPAIGN'S OWN CENSUS: one line per run into a file, added up by `scripts/census.sh`.
    ///
    /// The line forge prints - `(runs: 64, calls: 4096, reverts: 0)` - cannot say anything else here: with
    /// `fail_on_revert = true` and every call inside a try/catch, `reverts:` is 0 by construction. It is a
    /// tautology, not a gate. The census is the number to read: in how many RUNS swaps actually executed, and
    /// in how many the fee reached the cap that the hook's main invariant is about. This function executes
    /// after every run, but forge prints the logs of ONE of them, so the block on the screen at `-vv` is a
    /// sample of 1 in 64 and must not be read as the campaign. `writeCensus` records them all.
    function afterInvariant() public virtual {
        handler.writeCensus("CappedDynamicFeeHook");
        handler.printCallSummary();
        handler.printReachSummary();
        console2.log("CAMPAIGN swapsOk", handler.swapsOk());
        console2.log("CAMPAIGN quoteChecks", handler.quoteChecks());
        console2.log("CAMPAIGN capReached", handler.capReached());
        console2.log("CAMPAIGN maxFeeCharged", handler.maxFeeCharged());
    }

    // ------------------------------------------------------------------ the hook's own rules
    /// @notice THE PROMISE. Whatever the congestion, whatever the currencies did, the pool never charged
    /// more than the cap. Read from the manager's event, not from the hook.
    function invariant_the_pool_never_charged_more_than_the_cap() public view {
        assertLe(handler.maxFeeCharged(), hook.MAX_FEE(), "the pool charged more than the hook's cap");
    }

    /// @notice THE QUOTE IS NOT A LIE. Every swap in the campaign was charged exactly what the hook had just
    /// quoted for it.
    function invariant_every_quote_matched_the_execution() public view {
        assertEq(handler.quoteMismatches(), 0, "the hook quoted one fee and the pool charged another");
    }

    /// @notice THE GROWTH RULE (round r01, F1): inside one block the fee does not move. Every quote read and every swap
    /// charged in a block equals the first quote read in it - so a quote read at any point of a block binds every swap
    /// after it in that block, whoever else trades in between. Written after a discovery round found the ordering the
    /// invariant above could not see; seen red on the old rule before the hook was changed.
    function invariant_the_fee_never_moves_inside_a_block() public view {
        assertEq(handler.inBlockFeeMoves(), 0, "the fee moved inside a block: a quote read earlier in it is a lie");
        assertEq(handler.victimQuoteBroken(), 0, "a victim was charged other than the quote it read before the dust");
    }

    /// @notice the hook has no delta permissions, so it can never end an action holding value. Anything it
    /// holds was pushed at it, and it is stuck there.
    function invariant_the_hook_is_not_a_wallet() public view {
        assertHoldsOnlyDonations(
            IBalanceReader(address(truth0)),
            address(hook),
            handler.ghostDonated(address(hook), address(token0)),
            "hook currency0"
        );
        assertHoldsOnlyDonations(
            IBalanceReader(address(truth1)),
            address(hook),
            handler.ghostDonated(address(hook), address(token1)),
            "hook currency1"
        );
    }

    /// @notice the fixtures are fixtures. A router that keeps value between transactions is hiding one.
    function invariant_the_router_and_the_helper_are_empty_between_actions() public view {
        assertEq(token0.trueBalanceOf(address(router)), 0, "router kept currency0");
        assertEq(token1.trueBalanceOf(address(router)), 0, "router kept currency1");
        assertEq(token0.trueBalanceOf(address(liquidity)), 0, "helper kept currency0");
        assertEq(token1.trueBalanceOf(address(liquidity)), 0, "helper kept currency1");
    }

    /// @notice the hook's stored view of itself stays inside its own declared range.
    function invariant_the_hooks_own_state_is_within_its_bounds() public view {
        CappedDynamicFeeHook.PoolState memory s = hook.poolState(key.toId());
        assertTrue(s.known, "the hook forgot a pool it was initialised with");
        assertLe(s.blockFee, hook.MAX_FEE(), "stored quote above the cap");
        assertGe(s.blockFee, hook.BASE_FEE(), "stored quote below the base");
        assertLe(uint256(s.blockNumber), block.number, "the hook thinks it is in the future");
    }

    // ------------------------------------------------------------------ the generic ones
    function invariant_currency0_is_conserved() public view {
        assertConserved(IBalanceReader(address(truth0)), handler.holders(), handler.minted0(), "currency0");
    }

    function invariant_currency1_is_conserved() public view {
        assertConserved(IBalanceReader(address(truth1)), handler.holders(), handler.minted1(), "currency1");
    }

    /// @notice This one can now actually fail: `_unexpectedRevert` records the surprise instead of reverting
    /// on it, so the counter survives to be read here and the reason travels with it.
    function invariant_no_unexplained_reverts() public view {
        assertEq(
            handler.revertsUnexpected(),
            0,
            string.concat("the handler met a failure it did not predict: ", handler.lastUnexpected())
        );
    }

    // ------------------------------------------------------------------ non vacuity
    /// @notice Every invariant above is true of a pool nobody ever traded on. This test drives the happy
    /// path and the hostile branches by hand, asserts that they really happened, and only then runs the
    /// invariants. Without it, a campaign that spent itself bouncing off one filter would still be green.
    function test_handler_smoke() public {
        handler.fund(0, 1_000e18);
        handler.fund(1, 1_000e18);
        handler.fund(2, 1_000e18);
        handler.fundReserve(1e18, NO);
        handler.fundReserve(1e18, YES);

        handler.readQuote();
        handler.dustAheadOfVictim(1, 2, 9, 1e18);
        handler.swapBurst(1, 1e15, 12);
        assertGt(handler.capReached(), 0, "twelve swaps in one block should have reached the cap");

        handler.nextBlock(1);
        handler.readQuote();
        for (uint256 i = 0; i < 4; i++) handler.swap(2, 1e15, i + 1);

        handler.addLiquidity(0, 1e17);
        handler.removeLiquidity(0, 1e16);

        handler.donateToHook(1e17, NO);
        handler.donateToManager(1e17, YES);

        handler.setFeeOnTransfer(200, NO);
        handler.swap(1, 1e15, YES);
        handler.setFeeOnTransfer(0, NO);

        handler.setShortDeliver(1, 2, NO);
        handler.swap(1, 1e15, YES);
        handler.setShortDeliver(1, 0, NO);

        handler.setPaused(YES, YES);
        handler.swap(2, 1e15, NO);
        handler.setPaused(NO, YES);

        handler.setGasHog(2, YES, NO);
        handler.swap(2, 1e15, YES);
        handler.setGasHog(2, NO, NO);

        handler.setManagerBlocked(YES, NO);
        handler.swap(1, 1e15, YES);
        handler.setManagerBlocked(NO, NO);

        // item 3 of the threat model: a currency that LIES about a balance rather than moving the wrong
        // amount. This action was in the handler and not in `targetSelector`, so nothing had ever called it.
        handler.setManagerUnreadable(YES, NO);
        handler.swap(2, 1e15, NO);
        handler.setManagerUnreadable(NO, NO);

        handler.calmDown();
        handler.swap(0, 1e15, NO); // and the pool works again afterwards

        handler.printCallSummary();
        handler.printReachSummary();
        console2.log("manager under test:", managerModeLabel());
        console2.log("swaps ok", handler.swapsOk());
        console2.log("quote checks", handler.quoteChecks());
        console2.log("max fee charged", handler.maxFeeCharged());

        handler.assertExercised("swap", 4);
        handler.assertExercised("swapBurst", 1);
        handler.assertExercised("addLiquidity", 1);
        handler.assertExercised("removeLiquidity", 1);
        handler.assertExercised("nextBlock", 1);
        handler.assertExercised("readQuote", 2);
        handler.assertExercised("setManagerUnreadable", 2);
        handler.assertExercised("calmDown", 1);
        handler.assertExercised("dustAheadOfVictim", 1);
        handler.assertReached("victim traded after dust in its block", 1);
        assertGt(handler.victimChecks(), 0, "the F1 ordering was never checked");
        // the REACH census, not only the success census: the cap is the boundary every promise of this hook
        // is about, and an invariant that guards a boundary the suite never reaches guards nothing.
        handler.assertReached("fee at the cap", 1);
        handler.assertReached("fee at the base", 1);
        handler.assertReached("quote at the base", 1);
        assertGt(handler.quoteChecks(), 10, "the quote was never compared with an execution");
        assertGt(handler.revertsExpected(), 0, "the hostile branches were never reached");

        invariant_the_pool_never_charged_more_than_the_cap();
        invariant_every_quote_matched_the_execution();
        invariant_the_fee_never_moves_inside_a_block();
        invariant_the_hook_is_not_a_wallet();
        invariant_the_router_and_the_helper_are_empty_between_actions();
        invariant_the_hooks_own_state_is_within_its_bounds();
        invariant_currency0_is_conserved();
        invariant_currency1_is_conserved();
        invariant_no_unexplained_reverts();
    }
}
