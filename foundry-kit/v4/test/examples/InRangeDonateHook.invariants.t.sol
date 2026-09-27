// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {HostileERC20} from "gauntlet-kit/HostileERC20.sol";
import {HandlerBase} from "gauntlet-kit/InvariantBase.sol";
import {V4Harness} from "../../src/V4Harness.sol";
import {MinimalRouter} from "../../src/MinimalRouter.sol";
import {LiquidityHelper} from "../../src/LiquidityHelper.sol";
import {InRangeLedger} from "../../src/InRangeLedger.sol";
import {JitRecipient} from "../../src/JitRecipient.sol";
import {InRangeDonateHook} from "../../src/examples/InRangeDonateHook.sol";
import {InRangeDonateHookNaive} from "./InRangeDonateHookNaive.sol";
import {InRangeDonateWatcher} from "./InRangeDonateWatcher.sol";

// ADAPT: a worked TOY. What carries over to any hook that pays "whoever is in range" - a donation, a sweep, a reward
// streamed to the active tick - or pays traders by volume: (1) the JIT-recipient actor (`src/JitRecipient.sol`) as three
// kinds of action - around the payout in one transaction, after moving the price, and as the trader too - plus one that
// SITS in range across other actions; (2) a reference model fed at the moment the SPEC says a payout is EARNED
// (`src/InRangeLedger.sol`; here `InRangeDonateWatcher` feeds it after every swap); (3) the invariant on WHO was paid,
// per party, next to the ones on HOW MUCH. On this hook's first draft every amount invariant below is green and the
// WHO one is red: `test_on_the_naive_hook_only_the_who_invariant_goes_red`.

/// @notice what the campaign needs of either version of the hook
interface IDonatingHook {
    function sweep(PoolKey calldata key) external;
    function potOf(PoolId id) external view returns (uint256, uint256);
    function feesTaken(Currency c) external view returns (uint256);
    function donated(Currency c) external view returns (uint256);
}

/// @notice Drives one pool (LP fee 0, spacing 60, price 1) under `InRangeDonateHook` or its naive first draft. Honest LPs
/// on three ranges ([-1200, 1200], [0, 2400], [-3000, -600]); every swap stops inside [-4200, 4200], so the price can
/// reach ticks where NOBODY is in range. Three JIT-recipient actors: `jit` (one-transaction runs: around a payout, or
/// after a push), `washer` (the trader variant) and `sitter` (enters and stays in range across other actions).
contract InRangeDonateHandler is HandlerBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    IDonatingHook public immutable hook;
    bool public immutable defended;
    InRangeDonateWatcher public immutable watcher;
    InRangeLedger public immutable ledger;
    HostileERC20 public immutable token0;
    HostileERC20 public immutable token1;
    address public immutable treasury;
    JitRecipient public immutable jit;
    JitRecipient public immutable washer;
    JitRecipient public immutable sitter;

    PoolKey internal key;
    int24 internal constant EDGE = 4200;
    address[3] internal lps = [address(0x7100), address(0x7101), address(0x7102)];
    int24[3] internal lowers = [int24(-1200), int24(0), int24(-3000)];
    int24[3] internal uppers = [int24(1200), int24(2400), int24(-600)];
    address[2] internal traders = [address(0x7200), address(0x7201)];

    /// @notice per swap: the hook's fee ledger moved by other than the SPEC's fee
    uint256 public feeWrong;
    string public lastBroken;
    uint256 public swapsOk;

    constructor(
        IPoolManager manager_,
        IDonatingHook hook_,
        bool defended_,
        MinimalRouter router_,
        LiquidityHelper liquidity_,
        HostileERC20 t0,
        HostileERC20 t1,
        PoolKey memory key_,
        address treasury_
    ) {
        manager = manager_;
        hook = hook_;
        defended = defended_;
        token0 = t0;
        token1 = t1;
        key = key_;
        treasury = treasury_;
        watcher = new InRangeDonateWatcher(manager_, router_, liquidity_, key_, 30, true);
        ledger = watcher.ledger();
        jit = watcher.newJit();
        washer = watcher.newJit();
        sitter = watcher.newJit();
        JitRecipient[3] memory js = [jit, washer, sitter];
        for (uint256 i = 0; i < 3; i++) {
            t0.mint(address(js[i]), 1e32);
            t1.mint(address(js[i]), 1e32);
        }
        t0.mint(address(watcher.donor()), 1e30);
        t1.mint(address(watcher.donor()), 1e30);
        for (uint256 i = 0; i < 3; i++) _fund(lps[i], address(router_), address(liquidity_));
        for (uint256 i = 0; i < 2; i++) _fund(traders[i], address(router_), address(liquidity_));
    }

    function _fund(address who, address router_, address liquidity_) internal {
        token0.mint(who, 1e32);
        token1.mint(who, 1e32);
        vm.startPrank(who);
        token0.approve(router_, type(uint256).max);
        token1.approve(router_, type(uint256).max);
        token0.approve(liquidity_, type(uint256).max);
        token1.approve(liquidity_, type(uint256).max);
        vm.stopPrank();
    }

    /// @notice the honest LPs' first positions
    function seed() external {
        for (uint256 i = 0; i < 3; i++) watcher.modifyAs(lps[i], lowers[i], uppers[i], int256(1e20 >> i), 0);
    }

    function parties() public view returns (address[6] memory p) {
        p = [lps[0], lps[1], lps[2], address(jit), address(washer), address(sitter)];
    }

    function poolKey() external view returns (PoolKey memory) {
        return key;
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(key.toId());
    }

    function _pot() internal view returns (uint256 p0, uint256 p1) {
        return hook.potOf(key.toId());
    }

    function _broken(string memory why) internal {
        feeWrong += 1;
        lastBroken = why;
    }

    // ------------------------------------------------------------------ actions
    function swap(uint256 actorSeed, uint256 amount, uint256 dirWord, uint256 exactInWord) public counted("swap") {
        bool zeroForOne = _bit(dirWord);
        int24 t = _tick();
        if (zeroForOne ? t <= -EDGE : t >= EDGE) return; // at the edge of the campaign's price range: nothing to do
        bool exactIn = _bit(exactInWord);
        amount = bound(amount, 1e9, 3e19);
        SwapParams memory p = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactIn ? -int256(amount) : int256(amount),
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(zeroForOne ? -EDGE : EDGE)
        });
        (uint256 pot0, uint256 pot1) = _pot();
        uint256[2] memory takenBefore = [hook.feesTaken(key.currency0), hook.feesTaken(key.currency1)];
        uint256[2] memory owedBefore = [watcher.feesOwed(0), watcher.feesOwed(1)];
        try watcher.swapAs(traders[actorSeed % 2], p, 0) {
            swapsOk += 1;
            _noteSuccess("swap");
            for (uint256 c = 0; c < 2; c++) {
                uint256 taken = hook.feesTaken(c == 0 ? key.currency0 : key.currency1) - takenBefore[c];
                if (taken != watcher.feesOwed(c) - owedBefore[c]) _broken("D1: the fee is not the SPEC's");
                if (taken != 0 && manager.getLiquidity(key.toId()) == 0) _noteReached("a fee taken with nobody in range");
            }
            if (defended && pot0 + pot1 != 0) _noteReached("the pot paid before a swap");
        } catch (bytes memory err) {
            _unexpectedRevert(_why("swap", err));
        }
    }

    function addLiquidity(uint256 lpSeed, uint256 amount) public counted("addLiquidity") {
        uint256 i = lpSeed % 3;
        (uint256 pot0, uint256 pot1) = _pot();
        int256 liq = int256(bound(amount, 1e15, 1e20));
        try watcher.modifyAs(lps[i], lowers[i], uppers[i], liq, 0) {
            _noteSuccess("addLiquidity");
            if (defended && pot0 + pot1 != 0) _noteReached("the pot paid before liquidity arrived");
        } catch (bytes memory err) {
            _unexpectedRevert(_why("addLiquidity", err));
        }
    }

    function removeLiquidity(uint256 lpSeed, uint256 amount) public counted("removeLiquidity") {
        uint256 i = lpSeed % 3;
        (uint128 has,,) = manager.getPositionInfo(
            key.toId(), address(watcher.liquidity()), lowers[i], uppers[i], watcher.liquidity().positionSalt(lps[i], bytes32(0))
        );
        if (has == 0) return;
        (uint256 pot0, uint256 pot1) = _pot();
        int256 liq = int256(bound(amount, 1, has));
        try watcher.modifyAs(lps[i], lowers[i], uppers[i], -liq, 0) {
            _noteSuccess("removeLiquidity");
            if (defended && pot0 + pot1 != 0) _noteReached("the pot paid before liquidity left");
        } catch (bytes memory err) {
            _unexpectedRevert(_why("removeLiquidity", err));
        }
    }

    function sweep() public counted("sweep") {
        try hook.sweep(key) {
            _noteSuccess("sweep");
        } catch (bytes memory err) {
            _unexpectedRevert(_why("sweep", err));
        }
    }

    function _plan(JitRecipient.Plan memory p, uint256 liqWord, uint256 spacingsWord) internal view {
        p.key = key;
        // dust when the word is a multiple of 4 (one run in four), weight otherwise
        p.liquidity = liqWord % 4 == 0 ? 1 : uint128(bound(liqWord >> 8, 1e15, 1e21));
        p.spacings = uint24(bound(spacingsWord, 1, 4));
        p.payoutTarget = address(hook);
        p.payoutCall = abi.encodeCall(IDonatingHook.sweep, (key));
    }

    /// @notice the actor places a position around the price, the payout is called, the position leaves: ONE transaction
    function jitAroundPayout(uint256 liqWord, uint256 spacingsWord) public counted("jitAroundPayout") {
        JitRecipient.Plan memory p;
        _plan(p, liqWord, spacingsWord);
        _runJit(jit, p, "jitAroundPayout");
    }

    /// @notice FR13's variant: first move the price (often to where nobody is in range), then the same, then (maybe) back
    function jitAfterPush(uint256 targetWord, uint256 liqWord, uint256 backWord) public counted("jitAfterPush") {
        JitRecipient.Plan memory p;
        _plan(p, liqWord, 1);
        int24 target = int24(int256(bound(targetWord, 0, uint256(int256(2 * EDGE - 120))))) - EDGE + 60;
        p.pushToSqrtPrice = TickMath.getSqrtPriceAtTick(target);
        p.pushBack = _bit(backWord);
        _runJit(jit, p, "jitAfterPush");
    }

    /// @notice the trader variant: in range with weight, it trades there (and back), then the payout, then out
    function washJit(uint256 amountWord, uint256 liqWord, uint256 backWord) public counted("washJit") {
        JitRecipient.Plan memory p;
        _plan(p, liqWord, 3); // one spacing each side of the price: a wash that moves it a little stays in range
        p.liquidity = uint128(bound(liqWord, 1e18, 1e22));
        uint256 size = bound(amountWord >> 1, 1e15, 1e19);
        p.washAmount = _bit(amountWord) ? int256(size) : -int256(size);
        p.washBack = _bit(backWord);
        int24 t = _tick();
        if (p.washAmount > 0 ? t <= -EDGE : t >= EDGE) return; // at the edge of the campaign's price range
        p.washLimitSqrtPrice = TickMath.getSqrtPriceAtTick(p.washAmount > 0 ? -EDGE : EDGE);
        _runJit(washer, p, "washJit");
    }

    function _runJit(JitRecipient j, JitRecipient.Plan memory p, string memory action) internal {
        uint256 alone = watcher.payoutsWithAJitAlone();
        try watcher.runJit(j, p) returns (JitRecipient.Result memory r) {
            _noteSuccess(action);
            _noteReached("a JIT position was in range at a payout");
            if (watcher.payoutsWithAJitAlone() > alone) _noteReached("a JIT position was ALONE in range at a payout");
            if (r.fees0 + r.fees1 != 0) _noteReached("a JIT position was paid something");
        } catch (bytes memory err) {
            _unexpectedRevert(_why(action, err));
        }
    }

    /// @notice the sitter enters and STAYS: other actions run while it is in range; it leaves later (`sitterExit`)
    function sitterEnter(uint256 liqWord, uint256 spacingsWord) public counted("sitterEnter") {
        if (sitter.placed() != 0) return;
        uint128 liq = uint128(bound(liqWord, 1, 1e21));
        try watcher.jitEnter(sitter, liq, uint24(bound(spacingsWord, 1, 4))) {
            _noteSuccess("sitterEnter");
        } catch (bytes memory err) {
            _unexpectedRevert(_why("sitterEnter", err));
        }
    }

    function sitterExit() public counted("sitterExit") {
        if (sitter.placed() == 0) return;
        try watcher.jitExit(sitter) returns (uint256 f0, uint256 f1) {
            _noteSuccess("sitterExit");
            if (f0 + f1 != 0) _noteReached("a sitter was paid for what it sat through");
        } catch (bytes memory err) {
            _unexpectedRevert(_why("sitterExit", err));
        }
    }

    /// @notice somebody else donates to the pool (class 20's other half: a donation the hook did not make)
    function thirdPartyDonate(uint256 a0, uint256 a1) public counted("thirdPartyDonate") {
        if (manager.getLiquidity(key.toId()) == 0) return; // the manager refuses a donation to nobody
        a0 = bound(a0, 0, 1e17);
        a1 = bound(a1, 0, 1e17);
        try watcher.thirdPartyDonate(a0, a1) {
            _noteSuccess("thirdPartyDonate");
        } catch (bytes memory err) {
            _unexpectedRevert(_why("thirdPartyDonate", err));
        }
    }

    function withdrawUnowned(uint256 amount, uint256 whichWord) public counted("withdrawUnowned") {
        if (!defended) return;
        Currency c = _bit(whichWord) ? key.currency1 : key.currency0;
        uint256 u = InRangeDonateHook(address(hook)).unowned(c);
        if (u == 0) return;
        vm.prank(treasury);
        try InRangeDonateHook(address(hook)).withdrawUnowned(c, treasury, bound(amount, 1, u)) {
            _noteSuccess("withdrawUnowned");
        } catch (bytes memory err) {
            _unexpectedRevert(_why("withdrawUnowned", err));
        }
    }

    function _why(string memory action, bytes memory err) internal pure returns (string memory) {
        return string.concat(action, ": ", err.length >= 4 ? vm.toString(abi.encodePacked(bytes4(err))) : "empty revert");
    }
}

/// @notice The campaign: the invariants on WHO was paid (per party, by the reference model) next to those on HOW MUCH.
contract InRangeDonateHookInvariants is V4Harness {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    address internal constant TREASURY = address(0x7EA5);

    InRangeDonateHook internal hook;
    InRangeDonateHookNaive internal naive;
    InRangeDonateHandler internal handler;

    function setUp() public {
        _setUpV4();
        hook = InRangeDonateHook(
            _deployHook(
                type(InRangeDonateHook).creationCode,
                abi.encode(manager, TREASURY),
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                    | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            )
        );
        naive = InRangeDonateHookNaive(
            _deployHook(
                type(InRangeDonateHookNaive).creationCode,
                abi.encode(manager),
                Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            )
        );
        handler = _handlerFor(_campaignOnTheDefendedHook());

        targetContract(address(handler));
        // one caller: nothing in the handler depends on it, and on a fork every new caller is an account the fork fetches
        targetSender(address(0x7300));
        bytes4[] memory sel = new bytes4[](12);
        sel[0] = InRangeDonateHandler.swap.selector;
        sel[1] = InRangeDonateHandler.addLiquidity.selector;
        sel[2] = InRangeDonateHandler.removeLiquidity.selector;
        sel[3] = InRangeDonateHandler.sweep.selector;
        sel[4] = InRangeDonateHandler.jitAroundPayout.selector;
        sel[5] = InRangeDonateHandler.jitAfterPush.selector;
        sel[6] = InRangeDonateHandler.washJit.selector;
        sel[7] = InRangeDonateHandler.sitterEnter.selector;
        sel[8] = InRangeDonateHandler.sitterExit.selector;
        sel[9] = InRangeDonateHandler.thirdPartyDonate.selector;
        sel[10] = InRangeDonateHandler.withdrawUnowned.selector;
        sel[11] = InRangeDonateHandler.swap.selector; // swaps twice as often: they are what earns a fee
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    /// @notice which hook the CAMPAIGN runs on. A copy of this suite that answers false runs it on the first draft: the
    /// fuzzer then finds the WHO invariant red on its own (measured, `foundry-kit/v4/README.md`, "Paying whoever is in
    /// range"); not in the battery, which must be green
    function _campaignOnTheDefendedHook() internal pure virtual returns (bool) {
        return true;
    }

    /// @notice a pool of its own under the defended hook or the naive one, its LPs seeded, and a handler for it
    function _handlerFor(bool defended) internal returns (InRangeDonateHandler h) {
        address hk = defended ? address(hook) : address(naive);
        PoolKey memory k = _initPool(IHooks(hk), 0, 60, SQRT_PRICE_1_1);
        h = new InRangeDonateHandler(
            manager, IDonatingHook(hk), defended, router, liquidity, token0, token1, k, TREASURY
        );
        h.seed();
    }

    function afterInvariant() public virtual {
        handler.writeCensus("InRangeDonateHook");
        handler.printCallSummary();
        handler.printReachSummary();
        console2.log("CAMPAIGN swapsOk", handler.swapsOk());
    }

    function _key() internal view returns (PoolKey memory) {
        return handler.poolKey();
    }

    // ------------------------------------------------------------------ WHO was paid
    /// @notice D2, the invariant this example exists for: no party - honest LP or JIT-recipient actor - has received more
    /// of the hook's payouts (and of third parties' donations) than it was in range for, by the reference model, plus
    /// `InRangeLedger.TOLERANCE` (1 wei). Every amount invariant below can be green while this one is red
    function invariant_nobody_is_paid_for_fees_taken_before_it_was_in_range() public view {
        InRangeLedger l = handler.ledger();
        address[6] memory ps = handler.parties();
        for (uint256 i = 0; i < ps.length; i++) {
            (uint256 x0, uint256 x1) = l.excess(ps[i]);
            if (x0 + x1 != 0) {
                (uint256 r0, uint256 r1) = l.received(ps[i]);
                (uint256 e0, uint256 e1) = l.entitled(ps[i]);
                console2.log("WHO: party", ps[i]);
                console2.log("  received", r0, r1);
                console2.log("  entitled", e0, e1);
            }
            assertEq(x0 + x1, 0, "WHO: a party was paid for fees taken while it was not in range");
        }
    }

    /// @notice D2 the other way (defended only): once the pot not yet paid is counted, every party holds what it was in
    /// range for, to within rounding (`InRangeLedger.shortfall`). Nobody's share went elsewhere
    function invariant_every_party_is_paid_for_the_fees_taken_while_it_was_in_range() public view {
        if (!handler.defended()) return;
        InRangeLedger l = handler.ledger();
        (uint256 p0, uint256 p1) = hook.potOf(_key().toId());
        address[6] memory ps = handler.parties();
        for (uint256 i = 0; i < ps.length; i++) {
            (uint256 y0, uint256 y1) = l.shortfall(ps[i], p0, p1);
            assertEq(y0 + y1, 0, "WHO: a party was paid less than it was in range for");
        }
    }

    /// @notice D3 (defended only): what the treasury may take is EXACTLY what was taken with nobody in range
    function invariant_fees_taken_with_nobody_in_range_are_the_treasurys() public view {
        if (!handler.defended()) return;
        (uint256 u0, uint256 u1) = handler.ledger().unownedEntitled();
        PoolKey memory k = _key();
        assertEq(hook.unownedTotal(k.currency0), u0, "D3: the treasury's currency0 is not the fees nobody was owed");
        assertEq(hook.unownedTotal(k.currency1), u1, "D3: the treasury's currency1 is not the fees nobody was owed");
    }

    // ------------------------------------------------------------------ HOW MUCH
    /// @notice D1: every swap's fee is the SPEC's, and the hook's fee ledger is the model's
    function invariant_every_fee_is_the_specs() public view {
        assertEq(handler.feeWrong(), 0, string.concat("D1: ", handler.lastBroken()));
        PoolKey memory k = _key();
        IDonatingHook h = handler.hook();
        assertEq(h.feesTaken(k.currency0), handler.watcher().feesOwed(0), "D1: currency0 fees");
        assertEq(h.feesTaken(k.currency1), handler.watcher().feesOwed(1), "D1: currency1 fees");
    }

    /// @notice every fee taken is donated, waiting in the pot, or (defended) unowned; the hook's claims are exactly the
    /// pot and the unowned not yet withdrawn; it holds no token
    function invariant_every_fee_is_donated_pending_or_unowned_and_backed_by_claims() public view {
        PoolKey memory k = _key();
        IDonatingHook h = handler.hook();
        (uint256 p0, uint256 p1) = h.potOf(k.toId());
        uint256[2] memory pot = [p0, p1];
        Currency[2] memory cs = [k.currency0, k.currency1];
        for (uint256 c = 0; c < 2; c++) {
            uint256 unownedTotal = handler.defended() ? hook.unownedTotal(cs[c]) : 0;
            uint256 unownedNow = handler.defended() ? hook.unowned(cs[c]) : 0;
            assertEq(h.feesTaken(cs[c]), h.donated(cs[c]) + pot[c] + unownedTotal, "a fee is neither paid nor pending");
            assertEq(manager.balanceOf(address(h), cs[c].toId()), pot[c] + unownedNow, "the claims are not the pot");
            assertEq(_trueBalance(cs[c], address(h)), 0, "the hook holds a token");
        }
    }

    /// @notice what LEFT the hook for the pool's liquidity, by the manager's books and not the hook's - the claims the
    /// SPEC's fees minted (each swap's fee from the manager's own `Swap` event, as D1 checks), less the claims the hook
    /// still holds, less what the treasury took out of the manager - plus third parties' donations, is what the tracked
    /// positions received. EXACTLY, in units of 2^-128 wei (`InRangeLedger.receivedX128`), up to the one remainder no
    /// position is ever paid: `d * 2^128 mod L` per donation (`InRangeLedger.unreceivableBoundX128`, derived; far below
    /// one wei in this campaign). The hook's own `donated` counter is not read: a wei that leaves the hook for anyone but
    /// the positions in range or the treasury, with the counter saying it was donated, is red here (V18's VM3, K18b's
    /// VM4). NOT the treasury: its whole balance is subtracted, so a skim of 1-2 wei per donation TO the treasury stays
    /// green here (V18b's T1/T2); the unit suite's per-party books catch it, the campaign does not
    function invariant_what_was_donated_was_received() public view {
        InRangeLedger l = handler.ledger();
        assertTrue(l.closedWorld(), "the exact total needs every position of the pool tracked");
        PoolKey memory k = _key();
        address h = address(handler.hook());
        InRangeDonateWatcher w = handler.watcher();
        (uint256 got0, uint256 got1) = l.receivedX128();
        uint256[2] memory got = [got0, got1];
        Currency[2] memory cs = [k.currency0, k.currency1];
        uint256 bound = l.unreceivableBoundX128();
        for (uint256 c = 0; c < 2; c++) {
            uint256 minted = w.feesOwed(c);
            uint256 held = manager.balanceOf(h, cs[c].toId());
            uint256 treasury = _trueBalance(cs[c], TREASURY);
            assertGe(minted, held + treasury, "the hook holds, or its treasury took, more than the fees minted");
            uint256 givenX128 = (minted - held - treasury + w.thirdPartyDonated(c)) << 128;
            assertLe(got[c], givenX128, "the positions received more than was given to them");
            assertLe(givenX128 - got[c], bound, "part of what left the hook was never received by a position in range");
        }
    }

    /// @notice the reference model's idea of the liquidity in range is the manager's, at every accrual
    function invariant_the_model_agrees_with_the_manager() public view {
        assertEq(handler.ledger().disagreements(), 0, handler.ledger().lastDisagreement());
    }

    function invariant_no_unexplained_reverts() public view {
        assertEq(
            handler.revertsUnexpected(),
            0,
            string.concat("the handler met a failure it did not predict: ", handler.lastUnexpected())
        );
    }

    // ------------------------------------------------------------------ non vacuity
    function _walk(InRangeDonateHandler h) internal {
        for (uint256 i = 0; i < 4; i++) {
            h.swap(i, 2e18, i, 3); // exact-in, up then down
            h.swap(i + 1, 1e18, i + 1, 2); // exact-out, down then up
        }
        h.sweep();
        h.jitAroundPayout((uint256(1e20) << 8) | 1, 1); // weight
        h.jitAroundPayout(0, 1); // dust (a word that is a multiple of 4)
        h.swap(0, 3e19, 0, 3); // up and out of every honest range, to the campaign's edge: a fee with nobody in range
        h.jitAfterPush(0, 0, 1); // push down to tick -4140 (nobody), dust alone, sweep, out, back up
        h.jitAfterPush(4140, (uint256(1e20) << 8) | 1, 0); // push to tick 0 with weight, and stay there
        h.washJit(3e17, 1e21, 1); // sells currency1 and buys it back
        h.washJit((uint256(2e17) << 1) | 1, 5e20, 0); // sells currency0
        h.sitterEnter(1e20, 2);
        h.swap(1, 1e17, 1, 3);
        h.sitterExit(); // its exit pays the pot first: its share of the swap it sat through
        h.swap(2, 1e17, 0, 3);
        h.addLiquidity(0, 1e18);
        h.swap(3, 1e17, 1, 3);
        h.removeLiquidity(1, 1e18);
        h.thirdPartyDonate(1e15, 2e15);
        h.withdrawUnowned(type(uint256).max, 0);
        h.withdrawUnowned(1, 1);
        h.sweep();
    }

    function test_handler_smoke() public {
        _walk(handler);
        handler.printCallSummary();
        handler.printReachSummary();
        handler.assertExercised("swap", 10);
        handler.assertExercised("jitAroundPayout", 2);
        handler.assertExercised("jitAfterPush", 2);
        handler.assertExercised("washJit", 2);
        handler.assertExercised("sitterEnter", 1);
        handler.assertExercised("sitterExit", 1);
        handler.assertExercised("addLiquidity", 1);
        handler.assertExercised("removeLiquidity", 1);
        handler.assertExercised("thirdPartyDonate", 1);
        handler.assertExercised("withdrawUnowned", 1);
        handler.assertReached("a fee taken with nobody in range", 1);
        handler.assertReached("the pot paid before a swap", 1);
        handler.assertReached("the pot paid before liquidity arrived", 1);
        handler.assertReached("the pot paid before liquidity left", 1);
        handler.assertReached("a JIT position was in range at a payout", 4);
        handler.assertReached("a JIT position was ALONE in range at a payout", 1);
        handler.assertReached("a JIT position was paid something", 1); // the washer: its own fees, R1
        handler.assertReached("a sitter was paid for what it sat through", 1);
        assertEq(_failing("the defended hook after the walk"), 0, "an invariant failed on the defended hook");
    }

    // ------------------------------------------------------------------ what the invariants see, one scenario at a time
    function _invariants() internal view returns (bytes[] memory calls, string[] memory names) {
        calls = new bytes[](8);
        names = new string[](8);
        (calls[0], names[0]) = (abi.encodeCall(this.invariant_nobody_is_paid_for_fees_taken_before_it_was_in_range, ()), "WHO");
        (calls[1], names[1]) =
            (abi.encodeCall(this.invariant_every_party_is_paid_for_the_fees_taken_while_it_was_in_range, ()), "WHO, lower");
        (calls[2], names[2]) =
            (abi.encodeCall(this.invariant_fees_taken_with_nobody_in_range_are_the_treasurys, ()), "D3 treasury");
        (calls[3], names[3]) = (abi.encodeCall(this.invariant_every_fee_is_the_specs, ()), "D1 fee");
        (calls[4], names[4]) = (
            abi.encodeCall(this.invariant_every_fee_is_donated_pending_or_unowned_and_backed_by_claims, ()),
            "fees donated, pending or unowned"
        );
        (calls[5], names[5]) = (abi.encodeCall(this.invariant_what_was_donated_was_received, ()), "donated = received");
        (calls[6], names[6]) = (abi.encodeCall(this.invariant_the_model_agrees_with_the_manager, ()), "model");
        (calls[7], names[7]) = (abi.encodeCall(this.invariant_no_unexplained_reverts, ()), "no unexplained reverts");
    }

    /// @notice runs every invariant against the state as it is; returns a bit per failing one (bit i = `_invariants()[i]`)
    function _failing(string memory label) internal returns (uint256 failed) {
        (bytes[] memory calls, string[] memory names) = _invariants();
        console2.log(label);
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok,) = address(this).call(calls[i]);
            if (!ok) {
                failed |= 1 << i;
                console2.log("  FAILS:", names[i]);
            }
        }
    }

    function _trading(InRangeDonateHandler h) internal {
        for (uint256 i = 0; i < 4; i++) {
            h.swap(i, 2e18, i, 3);
        }
    }

    /// @notice the three JIT scenarios on the FIRST DRAFT: each turns the WHO invariant red - and only it: every amount
    /// invariant (fee exact, fees donated or pending, claims = pot, donated = received, the model agrees, no unexplained
    /// revert) stays green. That is `HOOK-ATTACKS.md` class 20 in one test: a payout's amounts can all be right while it
    /// goes to the wrong parties
    function test_on_the_naive_hook_only_the_who_invariant_goes_red() public {
        uint256 snap = vm.snapshotState();
        for (uint256 s = 0; s < 3; s++) {
            handler = _handlerFor(false);
            _trading(handler);
            assertEq(_failing("naive, honest trading only"), 0, "red before any JIT");
            string memory what;
            if (s == 0) {
                handler.jitAroundPayout((uint256(1e20) << 8) | 1, 1);
                what = "naive: a JIT position around the sweep";
            } else if (s == 1) {
                handler.jitAfterPush(8000, 0, 1);
                what = "naive: dust after a push to where nobody is";
            } else {
                handler.washJit(1e18, 1e21, 1);
                what = "naive: wash + JIT";
            }
            assertEq(_failing(what), 1, "not exactly the WHO invariant");
            vm.revertToState(snap);
        }
    }

    /// @notice the same three on the defended hook: nothing fails
    function test_on_the_defended_hook_the_same_three_trip_nothing() public {
        _trading(handler);
        handler.jitAroundPayout((uint256(1e20) << 8) | 1, 1);
        handler.jitAfterPush(8000, 0, 1);
        handler.washJit(1e18, 1e21, 1);
        assertEq(_failing("defended: the three JIT scenarios"), 0, "an invariant failed");
    }
}
