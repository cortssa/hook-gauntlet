// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IERC6909Claims} from "v4-core/src/interfaces/external/IERC6909Claims.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {HostileERC20} from "gauntlet-kit/HostileERC20.sol";
import {HandlerBase, InvariantAsserts, IBalanceReader, YES, NO} from "gauntlet-kit/InvariantBase.sol";
import {V4Harness} from "../../src/V4Harness.sol";
import {HookMiner} from "../../src/HookMiner.sol";
import {MinimalRouter} from "../../src/MinimalRouter.sol";
import {LiquidityHelper} from "../../src/LiquidityHelper.sol";
import {SwapEventReader} from "../../src/SwapEventReader.sol";
import {HostileNativeActor} from "../../src/HostileNativeActor.sol";
import {ClaimsFeeHook} from "../../src/examples/ClaimsFeeHook.sol";

// ADAPT: a worked TOY. What carries over to a hook that holds value as ERC-6909 claims, or on a native pool: every
// party's books count THREE things - ERC-20 balances, ETH balances, and claims on the manager - and the manager's own
// books are its balance MINUS the claims it has issued. A conservation that sums balances only (or sums claims over
// everybody, where a claim and the manager's debt for it cancel) still closes when a claim goes to the wrong party: the
// leak is visible only PER PARTY.

/// @notice ETH balances: the reader the kit's `assertConserved` needs for the native currency
contract EthReader is IBalanceReader {
    function balanceOf(address who) external view returns (uint256) {
        return who.balance;
    }
}

contract TokenTruthReader is IBalanceReader {
    HostileERC20 private immutable token;

    constructor(HostileERC20 t) {
        token = t;
    }

    function balanceOf(address who) external view returns (uint256) {
        return token.trueBalanceOf(who);
    }
}

/// @notice counts the grants a claim holder made: `OperatorSet` and `Approval` events the manager emitted with `owner` as
/// the owner of the claims
library GrantScan {
    function count(Vm.Log[] memory logs, address manager, address owner) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != manager || logs[i].topics.length < 2) continue;
            bytes32 t = logs[i].topics[0];
            if (t != IERC6909Claims.OperatorSet.selector && t != IERC6909Claims.Approval.selector) continue;
            if (logs[i].topics[1] == bytes32(uint256(uint160(owner)))) n += 1;
        }
    }
}

/// @notice A third party that uses claims for its own ends, nothing to do with the hook: it deposits ETH or the token as a
/// claim in an unlock of its own, and transfers part of the claim to somebody else. A campaign that calls every claim
/// outside the hook's a leak reports this legitimate user as one (the verifier V14 measured it: "C3: somebody other than
/// the hook holds claims")
contract ThirdPartyClaims is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    /// @return minted the claim it got: what the manager CREDITED (a fee-on-transfer token delivers short)
    function depositAndSend(Currency c, uint256 amount, address to, uint256 sent) external returns (uint256 minted) {
        minted = abi.decode(manager.unlock(abi.encode(c, amount)), (uint256));
        if (sent > minted) sent = minted;
        if (sent != 0) manager.transfer(to, c.toId(), sent);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not the manager");
        (Currency c, uint256 amount) = abi.decode(data, (Currency, uint256));
        uint256 paid;
        if (c.isAddressZero()) {
            paid = manager.settle{value: amount}();
        } else {
            manager.sync(c);
            IERC20Minimal(Currency.unwrap(c)).transfer(address(manager), amount);
            paid = manager.settle();
        }
        manager.mint(address(this), c.toId(), paid);
        return abi.encode(paid);
    }

    receive() external payable {}
}

/// @notice Drives an ETH / token pool against the claims hook, and keeps every party's books - balances AND claims - per
/// swap and per withdrawal.
contract ClaimsFeeHandler is HandlerBase, InvariantAsserts {
    IPoolManager public immutable manager;
    ClaimsFeeHook public immutable hook;
    MinimalRouter public immutable router;
    LiquidityHelper public immutable liquidity;
    HostileERC20 public immutable token1;
    /// @notice a swapper whose `receive()` reverts: it may swap ETH in (exactly), never ETH out
    HostileNativeActor public immutable refuser;
    /// @notice a legitimate user of claims, unrelated to the hook
    ThirdPartyClaims public immutable thirdParty;
    address public immutable treasury;

    PoolKey internal key;
    int24 internal tickLower;
    int24 internal tickUpper;
    Currency internal constant ETH = Currency.wrap(address(0));

    uint256 private constant CALL_GAS = 4_000_000;
    uint256 private constant MAX_SWAP = 5e17;
    uint256 private constant MAX_MINT = 1_000e18;

    // ---------------------------------------------------------------- per-swap checks: every one must stay 0
    /// @notice C1 per party: the swapper moved by other than the returned delta, or the hook's claims by other than
    /// its booked delta (`pool - caller`)
    uint256 public partyBroken;
    /// @notice C1: the manager's NET (balance minus the claims of every listed holder) moved by other than -pool
    uint256 public managerNetBroken;
    /// @notice C2: the fee is not 0.30 % of the pool's unspecified amount, or the hook's BALANCE moved in a swap
    uint256 public feeWrong;
    /// @notice C3: somebody other than the hook got a claim in a swap
    uint256 public strangerClaims;
    /// @notice C3: `OperatorSet` / `Approval` events with the hook as owner, in any swap or withdrawal
    uint256 public grantsByTheHook;
    /// @notice the NAIVE books, kept so the difference is visible: balances alone (swapper + hook + manager + fee sink),
    /// ETH and token. They close even when a claim went to the wrong party
    uint256 public balanceBooksBroken;
    /// @notice C4: a withdrawal paid other than it burned, or paid in claims
    uint256 public withdrawalBroken;
    string public lastBroken;

    // ---------------------------------------------------------------- ghosts, from the manager's books
    uint256[2] public ghostFees;
    uint256[2] public ghostWithdrawn;
    /// @notice the hook's claims as the last swap or withdrawal left them: nothing else may move them
    uint256[2] public hookClaimsSeen;
    /// @notice claims the third party minted for itself, per currency (part of them sent on to actors)
    uint256[2] public thirdPartyMinted;
    uint256 public mintedEth;
    uint256 public minted1;
    uint256 public swapsOk;
    bool public calm = true;
    mapping(address => uint256) public liquidityOf;

    constructor(
        IPoolManager manager_,
        ClaimsFeeHook hook_,
        MinimalRouter router_,
        LiquidityHelper liquidity_,
        HostileERC20 t1,
        PoolKey memory key_,
        int24 lower,
        int24 upper,
        address treasury_
    ) {
        manager = manager_;
        hook = hook_;
        router = router_;
        liquidity = liquidity_;
        token1 = t1;
        key = key_;
        tickLower = lower;
        tickUpper = upper;
        treasury = treasury_;
        refuser = new HostileNativeActor(manager_);
        refuser.setMode(HostileNativeActor.Mode.REVERT);
        refuser.approve(address(t1), address(router_));
        thirdParty = new ThirdPartyClaims(manager_);
        for (uint256 i = 0; i < 5; i++) _addActor(address(uint160(0x7000 + i)));
    }

    function holders() public view returns (address[] memory out) {
        out = new address[](actors.length + 9);
        for (uint256 i = 0; i < actors.length; i++) out[i] = actors[i];
        out[actors.length] = address(manager);
        out[actors.length + 1] = address(hook);
        out[actors.length + 2] = address(router);
        out[actors.length + 3] = address(liquidity);
        out[actors.length + 4] = treasury;
        out[actors.length + 5] = address(refuser);
        out[actors.length + 6] = token1.FEE_SINK();
        out[actors.length + 7] = token1.RESERVE();
        out[actors.length + 8] = address(thirdParty);
    }

    /// @notice claims of every listed holder EXCEPT the manager (which issues them and holds none)
    function claimsOfEveryone(uint256 c) public view returns (uint256 total) {
        address[] memory h = holders();
        uint256 id = c == 0 ? 0 : uint256(uint160(address(token1)));
        for (uint256 i = 0; i < h.length; i++) {
            if (h[i] != address(manager)) total += manager.balanceOf(h[i], id);
        }
    }

    function _cur(uint256 c) internal view returns (Currency) {
        return c == 0 ? ETH : Currency.wrap(address(token1));
    }

    function _bal(uint256 c, address who) internal view returns (int256) {
        return int256(c == 0 ? who.balance : token1.trueBalanceOf(who));
    }

    function _claims(uint256 c, address who) internal view returns (int256) {
        return int256(manager.balanceOf(who, _cur(c).toId()));
    }

    function _broken(string memory why) internal {
        lastBroken = why;
    }

    // ---------------------------------------------------------------- funding
    function _fund(address a, uint256 amount) internal {
        vm.deal(a, a.balance + amount);
        token1.mint(a, amount);
        mintedEth += amount;
        minted1 += amount;
        _noteMint(amount * 2);
        vm.startPrank(a);
        token1.approve(address(router), type(uint256).max);
        token1.approve(address(liquidity), type(uint256).max);
        vm.stopPrank();
    }

    function seed(uint256 amount, int256 liq) external {
        address a = actors[0];
        _fund(a, amount);
        for (uint256 i = 1; i < actors.length; i++) _fund(actors[i], MAX_MINT); // every actor can swap from the start
        _fund(address(refuser), amount / 100);
        vm.prank(a);
        liquidity.modifyLiquidity{value: a.balance}(
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liq, salt: bytes32(uint256(1))}),
            ""
        );
        liquidityOf[a] += uint256(liq);
    }

    function fund(uint256 actorSeed, uint256 amount) public countedSetter("fund") {
        _fund(_actor(actorSeed), bound(amount, 0, MAX_MINT));
    }

    // ---------------------------------------------------------------- swaps, all four orientations, ETH on either side
    struct Snap {
        int256[2] swapper;
        int256[2] hookBal;
        int256[2] hookClaims;
        int256[2] mgr;
        int256[2] claimsAll;
        int256[2] sink;
    }

    function _snap(address a) internal view returns (Snap memory s) {
        for (uint256 c = 0; c < 2; c++) {
            s.swapper[c] = _bal(c, a);
            s.hookBal[c] = _bal(c, address(hook));
            s.hookClaims[c] = _claims(c, address(hook));
            s.mgr[c] = _bal(c, address(manager));
            s.claimsAll[c] = int256(claimsOfEveryone(c));
            s.sink[c] = _bal(c, token1.FEE_SINK()) + _bal(c, token1.RESERVE());
        }
    }

    function swap(uint256 actorSeed, uint256 amount, uint256 dirWord, uint256 exactInWord) public counted("swap") {
        address a = _actor(actorSeed);
        bool zeroForOne = _bit(dirWord);
        bool exactIn = _bit(exactInWord);
        uint256 amt = bound(amount, 1, MAX_SWAP);
        SwapParams memory p = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactIn ? -int256(amt) : int256(amt),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        // ETH in: exact-in sends exactly the input, exact-out sends what the actor has (the router refunds the rest)
        uint256 value = zeroForOne ? (exactIn ? amt : a.balance) : 0;
        if (value > a.balance) {
            _expectedRevert();
            return;
        }
        Snap memory pre = _snap(a);
        vm.recordLogs();
        vm.prank(a);
        try router.swap{gas: CALL_GAS, value: value}(key, p, "") returns (BalanceDelta d) {
            swapsOk += 1;
            _checkSwap(a, p, d, pre);
            if (zeroForOne) _noteReached("ETH in");
            else _noteReached("ETH out");
            if (!exactIn && zeroForOne) _noteReached("ETH in, exact-out: refunded");
            _noteSuccess("swap");
        } catch (bytes memory err) {
            _classify(err);
        }
    }

    function _checkSwap(address a, SwapParams memory p, BalanceDelta d, Snap memory pre) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        grantsByTheHook += GrantScan.count(logs, address(manager), address(hook));
        (bool found, int128 pool0, int128 pool1) = SwapEventReader.lastSwapDelta(logs, address(manager));
        if (!found) {
            partyBroken += 1;
            _broken("a successful swap left no Swap event");
            return;
        }
        Snap memory post = _snap(a);
        int256[2] memory pool = [int256(pool0), int256(pool1)];
        int256[2] memory caller = [int256(d.amount0()), int256(d.amount1())];
        bool s0 = (p.amountSpecified < 0) == p.zeroForOne;
        uint256 uc = s0 ? 1 : 0;

        for (uint256 c = 0; c < 2; c++) {
            int256 swapperMoved = post.swapper[c] - pre.swapper[c];
            int256 hookBalMoved = post.hookBal[c] - pre.hookBal[c];
            int256 hookClaimsMoved = post.hookClaims[c] - pre.hookClaims[c];
            int256 mgrMoved = post.mgr[c] - pre.mgr[c];
            int256 claimsMoved = post.claimsAll[c] - pre.claimsAll[c];
            int256 sinkMoved = post.sink[c] - pre.sink[c];

            // the naive books: balances only
            if (swapperMoved + hookBalMoved + mgrMoved + sinkMoved != 0) {
                balanceBooksBroken += 1;
                _broken("balances alone do not close");
            }
            // C1 per party, claims counted. The swapper's side is exact only with an honest token (a fee-on-transfer
            // delivery parks part of it at the sink); ETH is always exact
            if ((c == 0 || calm) && swapperMoved != caller[c]) {
                partyBroken += 1;
                _broken("C1: the swapper moved by other than the returned delta");
            }
            if (hookBalMoved + hookClaimsMoved != pool[c] - caller[c]) {
                partyBroken += 1;
                _broken("C1: the hook's balance + claims moved by other than its booked delta");
            }
            if (mgrMoved - claimsMoved != -pool[c]) {
                managerNetBroken += 1;
                _broken("C1: the manager's net (balance - claims issued) is not the pool's delta");
            }
            // C2: held as a claim, never as a balance
            if (hookBalMoved != 0) {
                feeWrong += 1;
                _broken("C2: the hook's balance moved in a swap");
            }
            // C3: nobody else got a claim
            if (claimsMoved != hookClaimsMoved) {
                strangerClaims += 1;
                _broken("C3: somebody other than the hook got a claim");
            }
            hookClaimsSeen[c] = uint256(post.hookClaims[c]);
        }
        uint256 unspecAbs = pool[uc] < 0 ? uint256(-pool[uc]) : uint256(pool[uc]);
        int256 fee = int256(unspecAbs * 30 / 10_000);
        if (pool[uc] - caller[uc] != fee || pool[1 - uc] - caller[1 - uc] != 0) {
            feeWrong += 1;
            _broken("C2: the booked fee is not 0.30 % of the unspecified amount, on that side only");
        }
        ghostFees[uc] += uint256(pool[uc] - caller[uc]);
        if (fee > 0) _noteReached(uc == 0 ? "fee claimed in ETH" : "fee claimed in token1");
    }

    function _classify(bytes memory err) internal {
        if (err.length >= 4) {
            bytes4 sel = bytes4(err);
            if (sel == Hooks.InvalidHookResponse.selector || sel == Hooks.HookDeltaExceedsSwapAmount.selector) {
                _unexpectedRevert("swap: the manager REJECTED what the hook returned");
                return;
            }
            if (sel == IPoolManager.CurrencyNotSettled.selector && calm) {
                _unexpectedRevert("swap: CurrencyNotSettled with every switch off - somebody's delta was left open");
                return;
            }
            if (sel == MinimalRouter.InsufficientValue.selector) {
                // an exact-out swap with ETH in, by an actor whose whole balance is less than the input: the router's
                // named refusal (an exact-in swap sends its input and cannot owe more)
                _noteReached("ETH in, exact-out: the router refused too little ETH");
                _expectedRevert();
                return;
            }
        }
        _expectedRevert();
    }

    /// @notice the swapper whose `receive()` reverts: ETH in, sending exactly the input, stands; ETH out is refused by the
    /// manager's own transfer, and the whole swap goes
    function refuserSwap(uint256 amount, uint256 ethOutWord) public counted("refuserSwap") {
        uint256 amt = bound(amount, 1, 1e17);
        bool ethOut = _bit(ethOutWord);
        SwapParams memory p = SwapParams({
            zeroForOne: !ethOut,
            amountSpecified: -int256(amt),
            sqrtPriceLimitX96: ethOut ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
        });
        uint256 value = ethOut ? 0 : amt;
        if (value > address(refuser).balance || (ethOut && token1.trueBalanceOf(address(refuser)) < amt)) {
            _expectedRevert();
            return;
        }
        Snap memory pre = _snap(address(refuser));
        vm.recordLogs();
        try refuser.swap{gas: CALL_GAS}(router, key, p, value) returns (BalanceDelta d) {
            if (ethOut && d.amount0() > 0) {
                _unexpectedRevert("a receiver that reverts was paid ETH");
                return;
            }
            swapsOk += 1;
            _checkSwap(address(refuser), p, d, pre);
            _noteReached("refusing receiver swapped ETH in");
            _noteSuccess("refuserSwap");
        } catch (bytes memory err) {
            bytes memory expected = abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(refuser),
                bytes4(0),
                abi.encodeWithSelector(HostileNativeActor.Refused.selector),
                abi.encodeWithSelector(CurrencyLibrary.NativeTransferFailed.selector)
            );
            if (ethOut && keccak256(err) == keccak256(expected)) {
                _noteReached("refusing receiver refused ETH out");
                _expectedRevert();
                return;
            }
            _classify(err);
        }
    }

    // ---------------------------------------------------------------- the treasury
    function withdraw(uint256 amount, uint256 whichWord) public counted("withdraw") {
        uint256 c = _bit(whichWord) ? 1 : 0;
        Currency cur = _cur(c);
        uint256 have = manager.balanceOf(address(hook), cur.toId());
        if (have == 0) {
            _expectedRevert();
            return;
        }
        uint256 amt = bound(amount, 1, have);
        int256 t0 = _bal(c, treasury);
        int256 m0 = _bal(c, address(manager));
        int256 tc0 = _claims(c, treasury);
        vm.recordLogs();
        vm.prank(treasury);
        try hook.withdraw{gas: CALL_GAS}(cur, treasury, amt) {
            grantsByTheHook += GrantScan.count(vm.getRecordedLogs(), address(manager), address(hook));
            hookClaimsSeen[c] = manager.balanceOf(address(hook), cur.toId());
            // with an honest token the treasury receives exactly; a fee-on-transfer token parks part at the sink
            if (
                (c == 0 || calm) && _bal(c, treasury) - t0 != int256(amt) || m0 - _bal(c, address(manager)) != int256(amt)
                    || _claims(c, treasury) != tc0 || manager.balanceOf(address(hook), cur.toId()) != have - amt
            ) {
                withdrawalBroken += 1;
                _broken("C4: a withdrawal paid other than it burned, or paid in claims");
            }
            ghostWithdrawn[c] += amt;
            _noteReached(c == 0 ? "withdrew ETH" : "withdrew token1");
            _noteSuccess("withdraw");
        } catch {
            if (calm) {
                _unexpectedRevert("withdraw: refused with every switch off");
                return;
            }
            _expectedRevert();
        }
    }

    // ---------------------------------------------------------------- liquidity, with ETH
    function addLiquidity(uint256 actorSeed, uint256 liq) public counted("addLiquidity") {
        address a = _actor(actorSeed);
        uint256 amount = bound(liq, 1e12, 1e18);
        vm.prank(a);
        try liquidity.modifyLiquidity{gas: CALL_GAS, value: a.balance}(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(amount),
                salt: bytes32(uint256(uint160(a)))
            }),
            ""
        ) {
            liquidityOf[a] += amount;
            _noteSuccess("addLiquidity");
        } catch {
            _expectedRevert();
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
                salt: bytes32(uint256(uint160(a)))
            }),
            ""
        ) {
            liquidityOf[a] = have - amount;
            _noteSuccess("removeLiquidity");
        } catch {
            _expectedRevert();
        }
    }

    // ---------------------------------------------------------------- somebody else's claims
    /// @notice the third party deposits ETH or the token as a claim of its own and sends half of it to an actor. Not a
    /// leak: the claims are backed by what it paid in, and none of them touch the hook
    function thirdPartyClaims(uint256 amount, uint256 whichWord, uint256 toSeed) public counted("thirdPartyClaims") {
        uint256 c = _bit(whichWord) ? 1 : 0;
        uint256 amt = bound(amount, 1, 1e18);
        if (c == 0) {
            vm.deal(address(thirdParty), address(thirdParty).balance + amt);
            mintedEth += amt;
        } else {
            token1.mint(address(thirdParty), amt);
            minted1 += amt;
        }
        _noteMint(amt);
        try thirdParty.depositAndSend{gas: CALL_GAS}(_cur(c), amt, _actor(toSeed), amt / 2) returns (uint256 got) {
            thirdPartyMinted[c] += got;
            _noteReached(c == 0 ? "a third party holds ETH claims" : "a third party holds token1 claims");
            _noteSuccess("thirdPartyClaims");
        } catch {
            if (calm) {
                _unexpectedRevert("thirdPartyClaims: a plain deposit into a claim was refused");
                return;
            }
            _expectedRevert();
        }
    }

    // ---------------------------------------------------------------- strange actors
    function donateEthToManager(uint256 amount) public countedSetter("donateEthToManager") {
        uint256 v = bound(amount, 0, 1e18);
        vm.deal(address(manager), address(manager).balance + v);
        mintedEth += v;
        _noteDonation(address(manager), address(0), v);
    }

    function setFeeOnTransfer(uint256 bps) public countedSetter("setFeeOnTransfer") {
        uint256 v = bound(bps, 0, 500);
        uint256 fee = v <= 250 ? 0 : v;
        if (fee != 0) calm = false;
        token1.setFeeBps(fee);
    }

    function calmDown() public countedSetter("calmDown") {
        token1.setFeeBps(0);
        calm = true;
    }

    function nextBlock(uint256 n) public countedSetter("nextBlock") {
        uint256 blocks = bound(n, 1, 3);
        vm.roll(vm.getBlockNumber() + blocks);
        vm.warp(vm.getBlockTimestamp() + blocks * 12);
    }
}

contract ClaimsFeeHookInvariants is V4Harness, InvariantAsserts {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    address internal constant TREASURY = address(0x7EA5);

    ClaimsFeeHook internal hook;
    ClaimsFeeHandler internal handler;
    /// @notice grants (`OperatorSet` / `Approval`) the hook's constructor made
    uint256 internal grantsAtDeployment;
    EthReader internal ethReader;
    TokenTruthReader internal truth1;
    PoolKey internal key;

    function setUp() public {
        _setUpManager();
        _deployCurrencies();
        _deployRouters();
        (, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG,
            type(ClaimsFeeHook).creationCode,
            abi.encode(manager, TREASURY)
        );
        vm.recordLogs();
        hook = new ClaimsFeeHook{salt: salt}(manager, TREASURY);
        grantsAtDeployment = GrantScan.count(vm.getRecordedLogs(), address(manager), address(hook));
        key = _initNativePool(IHooks(address(hook)), 3000, 60, SQRT_PRICE_1_1, currency1);
        (int24 lower, int24 upper) = _fullRange(60);
        ethReader = new EthReader();
        truth1 = new TokenTruthReader(token1);
        handler = new ClaimsFeeHandler(manager, hook, router, liquidity, token1, key, lower, upper, TREASURY);
        handler.seed(100_000e18, 50e18);

        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](11);
        sel[0] = ClaimsFeeHandler.fund.selector;
        sel[1] = ClaimsFeeHandler.swap.selector;
        sel[2] = ClaimsFeeHandler.refuserSwap.selector;
        sel[3] = ClaimsFeeHandler.withdraw.selector;
        sel[4] = ClaimsFeeHandler.addLiquidity.selector;
        sel[5] = ClaimsFeeHandler.removeLiquidity.selector;
        sel[6] = ClaimsFeeHandler.donateEthToManager.selector;
        sel[7] = ClaimsFeeHandler.setFeeOnTransfer.selector;
        sel[8] = ClaimsFeeHandler.calmDown.selector;
        sel[9] = ClaimsFeeHandler.nextBlock.selector;
        sel[10] = ClaimsFeeHandler.thirdPartyClaims.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    function afterInvariant() public virtual {
        handler.writeCensus("ClaimsFeeHook");
        handler.printCallSummary();
        handler.printReachSummary();
        console2.log("CAMPAIGN swapsOk", handler.swapsOk());
    }

    function _reason(string memory what) internal view returns (string memory) {
        return string.concat(what, " (last: ", handler.lastBroken(), ")");
    }

    // ------------------------------------------------------------------ the NAIVE ones: balances only
    /// @notice ETH conserved over every holder. Counts balances only: it holds when a claim goes to the wrong party
    function invariant_eth_is_conserved() public view {
        assertConserved(IBalanceReader(address(ethReader)), handler.holders(), handler.mintedEth(), "ETH");
    }

    function invariant_token1_is_conserved() public view {
        assertConserved(IBalanceReader(address(truth1)), handler.holders(), handler.minted1(), "token1");
    }

    /// @notice every swap's books close over BALANCES alone (swapper + hook + manager + sink). Also holds when a claim
    /// went to the wrong party: kept so that the difference between this and the next two is on the record
    function invariant_every_swap_closes_in_balances_alone() public view {
        assertEq(handler.balanceBooksBroken(), 0, _reason("balances"));
    }

    // ------------------------------------------------------------------ PER PARTY, claims counted
    /// @notice C1, C3: the swapper got its returned delta, the hook its booked delta (balance + claims), nobody else a
    /// claim - per swap and per currency
    function invariant_every_party_is_counted_with_its_claims() public view {
        assertEq(handler.partyBroken(), 0, _reason("C1"));
        assertEq(handler.strangerClaims(), 0, _reason("C3"));
    }

    /// @notice C1: the manager's net - its balance less the claims it issued to every listed holder - moved by exactly
    /// the pool's delta on every swap
    function invariant_the_managers_net_is_the_pools_delta() public view {
        assertEq(handler.managerNetBroken(), 0, _reason("C1 manager"));
    }

    /// @notice C2: the fee is exact, on the unspecified side, and held as a claim (no balance of the hook ever moved)
    function invariant_the_fee_is_exact_and_held_as_a_claim() public view {
        assertEq(handler.feeWrong(), 0, _reason("C2"));
        assertEq(address(hook).balance, 0, "the hook holds ETH");
        assertEq(token1.trueBalanceOf(address(hook)), 0, "the hook holds token1");
    }

    /// @notice C3, C4: per currency, the hook's claims are the fees the manager booked less what was withdrawn; the manager
    /// holds at least every claim it issued; withdrawals paid what they burned.
    /// SCOPE (2026-09-24): C3 is about the HOOK's claims. Until this date this invariant also asserted that nobody but the
    /// hook held a claim at all - a closed world, which called a legitimate third party depositing and passing on claims
    /// of its own a leak (the verifier V14; `test_a_third_party_moving_its_own_claims_trips_nothing`). A claim that
    /// reaches somebody else FROM A SWAP is still caught, per swap and per party (`strangerClaims`, `partyBroken`), and
    /// the router and the helper still may hold none
    function invariant_claims_are_fees_less_withdrawals_and_backed() public view {
        assertEq(handler.withdrawalBroken(), 0, _reason("C4"));
        for (uint256 c = 0; c < 2; c++) {
            Currency cur = c == 0 ? Currency.wrap(address(0)) : currency1;
            uint256 claims = manager.balanceOf(address(hook), cur.toId());
            assertEq(claims, handler.ghostFees(c) - handler.ghostWithdrawn(c), "C3: claims != fees booked - withdrawn");
            assertEq(hook.feesBooked(cur), handler.ghostFees(c), "the hook's fee ledger disagrees with the manager");
            assertEq(hook.withdrawn(cur), handler.ghostWithdrawn(c), "the hook's withdrawal ledger disagrees");
            assertGe(_trueBalance(cur, address(manager)), handler.claimsOfEveryone(c), "the manager cannot back its claims");
        }
    }

    /// @notice the router and the helper end every action holding nothing - no ETH, no token, NO CLAIM
    function invariant_the_router_and_the_helper_hold_nothing() public view {
        for (uint256 c = 0; c < 2; c++) {
            Currency cur = c == 0 ? Currency.wrap(address(0)) : currency1;
            assertEq(_trueBalance(cur, address(router)), 0, "the router kept a balance");
            assertEq(_trueBalance(cur, address(liquidity)), 0, "the helper kept a balance");
            assertEq(_claimsOf(cur, address(router)), 0, "the router holds claims");
            assertEq(_claimsOf(cur, address(liquidity)), 0, "the helper holds claims");
        }
    }

    /// @notice C3: the hook grants nobody its claims - no `OperatorSet` and no `Approval` with the hook as owner, in its
    /// constructor or in any swap or withdrawal of the campaign, and no listed holder is its operator or holds an
    /// allowance. An operator moves every claim the hook has, outside any swap; nothing in the campaign calls
    /// `transferFrom`, so without this a grant stays latent (the verifier V14's mutant W4 survived everything)
    function invariant_the_hook_grants_nobody_its_claims() public view {
        assertEq(grantsAtDeployment, 0, "C3: the hook's constructor granted an operator or an allowance");
        assertEq(handler.grantsByTheHook(), 0, "C3: the hook granted an operator or an allowance");
        address[] memory h = handler.holders();
        for (uint256 i = 0; i < h.length; i++) {
            assertFalse(manager.isOperator(address(hook), h[i]), "C3: a holder is the hook's operator");
            assertEq(manager.allowance(address(hook), h[i], 0), 0, "C3: a holder has an allowance on the hook's ETH claim");
            assertEq(
                manager.allowance(address(hook), h[i], currency1.toId()), 0, "C3: a holder has an allowance on its token1 claim"
            );
        }
    }

    /// @notice C3: the hook's claims move only inside its own swaps and withdrawals - between two actions they are what
    /// the last one left. A claim moved out by an operator (or pushed in by anybody) outside those shows here, and in the
    /// fees-less-withdrawals ledger above: two invariants, where there was one
    function invariant_the_hooks_claims_move_only_in_its_swaps_and_withdrawals() public view {
        for (uint256 c = 0; c < 2; c++) {
            Currency cur = c == 0 ? Currency.wrap(address(0)) : currency1;
            assertEq(
                manager.balanceOf(address(hook), cur.toId()),
                handler.hookClaimsSeen(c),
                "C3: the hook's claims moved outside its swaps and withdrawals"
            );
        }
    }

    function invariant_no_unexplained_reverts() public view {
        assertEq(
            handler.revertsUnexpected(),
            0,
            string.concat("the handler met a failure it did not predict: ", handler.lastUnexpected())
        );
    }

    // ------------------------------------------------------------------ non vacuity
    function test_handler_smoke() public {
        handler.fund(1, 100e18);
        handler.fund(2, 100e18);
        for (uint256 i = 0; i < 4; i++) {
            handler.swap(1, 3e17, i, (i >> 1) & 1); // all four orientations
            handler.swap(2, 1e17, i + 1, YES);
        }
        handler.refuserSwap(1e16, NO); // ETH in, exactly: stands
        handler.refuserSwap(1e16, YES); // ETH out: refused by the manager's transfer
        handler.withdraw(type(uint256).max / 3, NO); // ETH
        handler.withdraw(1e14, YES); // token1
        handler.addLiquidity(1, 1e17);
        handler.removeLiquidity(1, 1e16);
        handler.donateEthToManager(1e17);
        handler.nextBlock(1);
        handler.setFeeOnTransfer(400);
        handler.swap(1, 1e17, NO, YES);
        handler.withdraw(1e10, YES);
        handler.calmDown();
        handler.swap(0, 1e17, YES, NO);
        handler.thirdPartyClaims(3e17, NO, 2); // somebody else's ETH claims, half sent to an actor
        handler.thirdPartyClaims(2e17, YES, 3); // and token1 claims
        handler.swap(2, 1e17, YES, YES);

        handler.printCallSummary();
        handler.printReachSummary();
        handler.assertExercised("swap", 8);
        handler.assertReached("fee claimed in ETH", 2);
        handler.assertReached("fee claimed in token1", 2);
        handler.assertReached("ETH in, exact-out: refunded", 1);
        handler.assertReached("refusing receiver swapped ETH in", 1);
        handler.assertReached("refusing receiver refused ETH out", 1);
        handler.assertReached("withdrew ETH", 1);
        handler.assertReached("withdrew token1", 1);
        handler.assertReached("a third party holds ETH claims", 1);
        handler.assertReached("a third party holds token1 claims", 1);
        assertGt(handler.revertsExpected(), 0, "the hostile branches were never reached");

        invariant_eth_is_conserved();
        invariant_token1_is_conserved();
        invariant_every_swap_closes_in_balances_alone();
        invariant_every_party_is_counted_with_its_claims();
        invariant_the_managers_net_is_the_pools_delta();
        invariant_the_fee_is_exact_and_held_as_a_claim();
        invariant_claims_are_fees_less_withdrawals_and_backed();
        invariant_the_router_and_the_helper_hold_nothing();
        invariant_the_hook_grants_nobody_its_claims();
        invariant_the_hooks_claims_move_only_in_its_swaps_and_withdrawals();
        invariant_no_unexplained_reverts();
    }

    // ------------------------------------------------------------------ what the invariants see, one scenario at a time
    function _invariants() internal view returns (bytes[] memory calls, string[] memory names) {
        calls = new bytes[](11);
        names = new string[](11);
        (calls[0], names[0]) = (abi.encodeCall(this.invariant_eth_is_conserved, ()), "eth_is_conserved");
        (calls[1], names[1]) = (abi.encodeCall(this.invariant_token1_is_conserved, ()), "token1_is_conserved");
        (calls[2], names[2]) =
            (abi.encodeCall(this.invariant_every_swap_closes_in_balances_alone, ()), "every_swap_closes_in_balances_alone");
        (calls[3], names[3]) = (
            abi.encodeCall(this.invariant_every_party_is_counted_with_its_claims, ()), "every_party_is_counted_with_its_claims"
        );
        (calls[4], names[4]) =
            (abi.encodeCall(this.invariant_the_managers_net_is_the_pools_delta, ()), "the_managers_net_is_the_pools_delta");
        (calls[5], names[5]) =
            (abi.encodeCall(this.invariant_the_fee_is_exact_and_held_as_a_claim, ()), "the_fee_is_exact_and_held_as_a_claim");
        (calls[6], names[6]) = (
            abi.encodeCall(this.invariant_claims_are_fees_less_withdrawals_and_backed, ()),
            "claims_are_fees_less_withdrawals_and_backed"
        );
        (calls[7], names[7]) = (
            abi.encodeCall(this.invariant_the_router_and_the_helper_hold_nothing, ()), "the_router_and_the_helper_hold_nothing"
        );
        (calls[8], names[8]) = (abi.encodeCall(this.invariant_no_unexplained_reverts, ()), "no_unexplained_reverts");
        (calls[9], names[9]) =
            (abi.encodeCall(this.invariant_the_hook_grants_nobody_its_claims, ()), "the_hook_grants_nobody_its_claims");
        (calls[10], names[10]) = (
            abi.encodeCall(this.invariant_the_hooks_claims_move_only_in_its_swaps_and_withdrawals, ()),
            "the_hooks_claims_move_only_in_its_swaps_and_withdrawals"
        );
    }

    /// @notice runs every invariant against the state as it is, and returns how many fail (their names logged)
    function _failing(string memory label) internal returns (uint256 failed) {
        (bytes[] memory calls, string[] memory names) = _invariants();
        console2.log(label);
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok,) = address(this).call(calls[i]);
            if (!ok) {
                failed += 1;
                console2.log("  FAILS:", names[i]);
            }
        }
    }

    function _someFees() internal {
        handler.fund(1, 100e18);
        for (uint256 i = 0; i < 4; i++) {
            handler.swap(1, 3e17, i, (i >> 1) & 1);
        }
    }

    /// @notice C3 is about the HOOK's claims: a third party that deposits its own ETH and token as claims and sends them
    /// to an actor is not a leak, and no invariant may call it one. Until 2026-09-24 one did - the campaign's world was
    /// closed ("nobody but the hook holds a claim") - and this test was red on it
    function test_a_third_party_moving_its_own_claims_trips_nothing() public {
        _someFees();
        handler.thirdPartyClaims(1e17, NO, 1);
        handler.thirdPartyClaims(1e17, YES, 2);
        handler.swap(1, 3e17, YES, YES);
        assertGt(manager.balanceOf(address(uint160(0x7001)), 0), 0, "the scenario did not happen");
        assertEq(_failing("a third party's claims, moved between third parties"), 0, "an invariant called it a leak");
    }

    /// @notice the hook's claims moved OUT of it, outside any swap, by an operator it had granted: more than one invariant
    /// must see the grant once it is USED. The grant alone (the verifier V14's mutant W4: `setOperator(0xBAD, true)` in the
    /// constructor, never used, since nothing in the campaign calls `transferFrom`) moves nothing, and ONE invariant sees
    /// it - `the_hook_grants_nobody_its_claims`, by the manager's events (re-measured by the verifier V15 and by K15b: 1 of
    /// 11 red). A latent grant has no second witness: nothing moved
    function test_a_claim_moved_by_an_operator_outside_a_swap_is_caught_twice() public {
        _someFees();
        assertEq(_failing("before"), 0, "the campaign was not green to begin with");
        vm.prank(address(hook));
        manager.setOperator(address(0xBAD), true);
        vm.prank(address(0xBAD));
        manager.transferFrom(address(hook), address(0xBAD), 0, 1);
        assertGe(_failing("1 wei of the hook's ETH claim moved by an operator"), 2, "only one invariant saw it");
    }

    /// @notice the other side of "a third party's own claims trip nothing": a third party that PUSHES a claim of its own
    /// INTO the hook (`transfer` to the hook, outside any swap) trips two invariants, by design - the hook's claims are
    /// no longer its fees less its withdrawals, and they moved outside its own actions. Not a loss to anybody but the
    /// pusher; the invariants hold the hook's claims to its own books, and a donation is not in them (the verifier V15,
    /// `test_v15_third_party_pushes_its_claim_into_the_hook`: 2 of 11). The hook as a SPENDER - a third party making it
    /// its operator, or giving it an allowance - trips none (V15, `test_v15_third_party_makes_the_hook_its_operator`: 0)
    function test_a_third_partys_claim_pushed_into_the_hook_trips_two_invariants() public {
        _someFees();
        handler.thirdPartyClaims(1e17, NO, 1);
        assertEq(_failing("a third party's own claims"), 0, "the campaign was not green to begin with");
        ThirdPartyClaims tp = handler.thirdParty();
        uint256 left = manager.balanceOf(address(tp), 0);
        assertGt(left, 0, "the scenario did not happen");
        vm.prank(address(tp));
        manager.setOperator(address(hook), true);
        vm.prank(address(tp));
        manager.approve(address(hook), 0, left);
        assertEq(_failing("a third party made the hook its operator and gave it an allowance"), 0, "the hook as spender tripped one");
        vm.prank(address(tp));
        manager.transfer(address(hook), 0, left);
        assertEq(_failing("a third party pushed its ETH claim into the hook"), 2, "not the two ledger invariants");
    }
}
