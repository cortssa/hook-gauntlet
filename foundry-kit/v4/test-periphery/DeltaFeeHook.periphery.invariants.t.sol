// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
// Inside the kit: imports are relative. In your project: see scripts/setup-deps.sh's import lines.

import {console2} from "forge-std/Test.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {MockV4Router} from "v4-periphery/test/mocks/MockV4Router.sol";
import {HostileERC20} from "gauntlet-kit/HostileERC20.sol";
import {HandlerBase, InvariantAsserts, IBalanceReader, YES, NO} from "gauntlet-kit/InvariantBase.sol";
import {SwapEventReader} from "../src/SwapEventReader.sol";
import {DeltaFeeHook} from "../src/examples/DeltaFeeHook.sol";
import {PeripheryHarness, IUniversalRouter, IERC721Owner} from "./PeripheryHarness.sol";
import {PeripheryPlans} from "./PeripheryPlans.sol";

/// @notice balances with every switch of the token ignored
contract PeripheryTruthReader is IBalanceReader {
    HostileERC20 private immutable token;

    constructor(HostileERC20 t) {
        token = t;
    }

    function balanceOf(address who) external view returns (uint256) {
        return token.trueBalanceOf(who);
    }
}

/// @notice DeltaFeeHook's per-party books, with EVERY action going through Uniswap's periphery (K17b): positions are
/// minted, increased, decreased and burned through `PositionManager.modifyLiquidities` (paid through Permit2), swaps -
/// exact-in and exact-out, both directions - go through the V4Router (`MockV4Router` on the source manager, the deployed
/// UniversalRouter on the fork). Each action's books are read from true balances of five parties - the user, the hook,
/// the manager, the router, the PositionManager - and the pool's own delta off the `Swap` event; the hook's delta is
/// derived (`pool - user`, the router being square), never asked of the hook.
///
/// No hostile switch is turned here: the hostile tokens' behaviours are the everyday suite's
/// (`test/examples/DeltaFeeHook.invariants.t.sol`). Every precondition an action needs (a balance, a position) is checked
/// before the call, and the pool keeps a seed position no action touches, far larger than any swap, so no revert is
/// predicted: every revert is unexplained, and `invariant_no_unexplained_reverts` goes red on the first.
///
/// "Through the periphery" is CHECKED, not only built (K17c, from the verifier V17b: with the swaps sent through the
/// kit's `MinimalRouter` every other invariant here stayed green). Each of the five actions runs under
/// `throughThePeriphery`, which records every call the action made (`vm.startStateDiffRecording`) and holds it to one
/// rule: the manager was entered - `swap`, `modifyLiquidity`, `donate`, `initialize` - only by the periphery contract the
/// action is for (a swap: ONE `swap` from the router; a liquidity change: ONE `modifyLiquidity` from the PositionManager),
/// and the hook's callbacks carried that contract as `sender`, a swap's as many as the hook's flags declare. Whatever
/// path the body takes, the recording sees where it reached the manager from.
contract DeltaFeePeripheryHandler is HandlerBase, InvariantAsserts {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable manager;
    DeltaFeeHook public immutable hook;
    IPositionManager public immutable posm;
    address public immutable swapRouter;
    IAllowanceTransfer public immutable permit2;
    /// @notice true: the router is the deployed UniversalRouter (fork), paid through Permit2; false: `MockV4Router`
    bool public immutable deployedRouter;
    HostileERC20 public immutable token0;
    HostileERC20 public immutable token1;

    PoolKey internal key;
    int24 internal fullLower;
    int24 internal fullUpper;

    uint256 private constant MAX_SWAP = 5e17;
    uint256 private constant MIN_LIQ = 1e12;
    uint256 private constant MAX_LIQ = 1e20;
    uint256 private constant MAX_MINT = 1e22;

    // ---------------------------------------------------------------- the per-action checks: every one must stay 0
    /// @notice per currency, user + hook + manager + router + PositionManager moved by other than 0, or (swap) the
    /// manager moved by other than the pool's own delta
    uint256 public booksBroken;
    /// @notice the hook's balance moved by other than its booked delta (`pool - user`)
    uint256 public hookNotBooked;
    /// @notice the router or the PositionManager ended an action with more or less than it began with
    uint256 public peripheryNotSquare;
    /// @notice the user paid (exact-in) or received (exact-out) other than exactly what it specified
    uint256 public specifiedWrong;
    /// @notice the fee was not exactly 0.30 % of the pool's unspecified amount, on the unspecified side (P2)
    uint256 public feeWrong;
    /// @notice the hook took on the specified side, or paid a rebate above the nominal (P3)
    uint256 public rebateWrong;
    /// @notice the hook moved in a liquidity action (it has no liquidity callbacks), or the manager's position for a
    /// token is not the liquidity the handler put there
    uint256 public positionWrong;
    /// @notice an action that reached the manager other than through the periphery contract it is for, or not the
    /// number of times it should, or whose hook callbacks were not given that contract as `sender` (K17c)
    uint256 public notThroughPeriphery;
    uint256 public lastBrokenAt;
    string public lastBroken;

    uint256 public swapsOk;
    uint256 public exactOutOk;
    uint256 public rebatesSeen;
    uint256 public minted0;
    uint256 public minted1;

    /// @notice the ghost counters of "through the periphery" (K17c): the manager entries the successful actions had to
    /// make (one per swap and per liquidity change; none for a burn of an empty position), and those seen made by the
    /// right periphery contract; the hook's swap callbacks in successful swaps, and those given `sender` = the router.
    /// Equal pairs, or an action went round the periphery.
    uint256 public entriesExpected;
    uint256 public entriesFromPeriphery;
    uint256 public hookSwapCallbacks;
    uint256 public hookSwapCallbacksFromRouter;
    /// @notice the swap callbacks the hook's address declares (beforeSwap, afterSwap): what one swap must show
    uint256 public immutable swapCallbacksDeclared;
    /// @dev the manager entries the running action must have made, set by its body where it succeeds
    uint256 private _entriesThisAction;

    /// @notice the positions each actor owns (token ids), and the liquidity the handler put in each
    mapping(address => uint256[]) internal _tokens;
    mapping(uint256 => uint256) public liquidityOf;
    uint256 public seedTokenId;

    constructor(
        IPoolManager manager_,
        DeltaFeeHook hook_,
        IPositionManager posm_,
        address swapRouter_,
        IAllowanceTransfer permit2_,
        bool deployedRouter_,
        HostileERC20 t0,
        HostileERC20 t1,
        PoolKey memory key_,
        int24 lower,
        int24 upper
    ) {
        manager = manager_;
        hook = hook_;
        posm = posm_;
        swapRouter = swapRouter_;
        permit2 = permit2_;
        deployedRouter = deployedRouter_;
        token0 = t0;
        token1 = t1;
        key = key_;
        fullLower = lower;
        fullUpper = upper;
        swapCallbacksDeclared = (Hooks.hasPermission(IHooks(address(hook_)), Hooks.BEFORE_SWAP_FLAG) ? 1 : 0)
            + (Hooks.hasPermission(IHooks(address(hook_)), Hooks.AFTER_SWAP_FLAG) ? 1 : 0);
        for (uint256 i = 0; i < 5; i++) _addActor(address(uint160(0x7000 + i)));
    }

    function holders() public view returns (address[] memory out) {
        out = new address[](actors.length + 7);
        for (uint256 i = 0; i < actors.length; i++) out[i] = actors[i];
        out[actors.length] = address(manager);
        out[actors.length + 1] = address(hook);
        out[actors.length + 2] = swapRouter;
        out[actors.length + 3] = address(posm);
        out[actors.length + 4] = address(permit2);
        out[actors.length + 5] = token0.FEE_SINK();
        out[actors.length + 6] = token0.RESERVE();
    }

    function tokensOf(address a) external view returns (uint256[] memory) {
        return _tokens[a];
    }

    // ---------------------------------------------------------------- funding
    function _mintAndApprove(address a, uint256 amount) internal {
        token0.mint(a, amount);
        token1.mint(a, amount);
        minted0 += amount;
        minted1 += amount;
        _noteMint(amount * 2);
        HostileERC20[2] memory t = [token0, token1];
        vm.startPrank(a);
        for (uint256 i = 0; i < 2; i++) {
            t[i].approve(address(permit2), type(uint256).max);
            permit2.approve(address(t[i]), address(posm), type(uint160).max, type(uint48).max);
            if (deployedRouter) permit2.approve(address(t[i]), swapRouter, type(uint160).max, type(uint48).max);
            else t[i].approve(swapRouter, type(uint256).max);
        }
        vm.stopPrank();
    }

    /// @notice the pool's seed: actor 0's full-range position, which no action touches
    function seed(int256 liq) external {
        address a = actors[0];
        for (uint256 i = 0; i < actors.length; i++) _mintAndApprove(actors[i], MAX_MINT);
        seedTokenId = posm.nextTokenId();
        vm.prank(a);
        posm.modifyLiquidities(
            PeripheryPlans.mint(key, fullLower, fullUpper, uint256(liq), a, ""), block.timestamp + 60
        );
        liquidityOf[seedTokenId] = uint256(liq);
    }

    function fund(uint256 actorSeed, uint256 amount) public countedSetter("fund") {
        _mintAndApprove(_actor(actorSeed), bound(amount, 0, MAX_MINT));
    }

    function nextBlock(uint256 n) public countedSetter("nextBlock") {
        vm.roll(block.number + bound(n, 1, 3));
        vm.warp(block.timestamp + 12);
    }

    // ---------------------------------------------------------------- books
    function _snap(address user) internal view returns (int256[10] memory s) {
        HostileERC20[2] memory t = [token0, token1];
        for (uint256 i = 0; i < 2; i++) {
            s[i] = int256(t[i].trueBalanceOf(user));
            s[2 + i] = int256(t[i].trueBalanceOf(address(hook)));
            s[4 + i] = int256(t[i].trueBalanceOf(address(manager)));
            s[6 + i] = int256(t[i].trueBalanceOf(swapRouter));
            s[8 + i] = int256(t[i].trueBalanceOf(address(posm)));
        }
    }

    function _diff(int256[10] memory pre, int256[10] memory post) internal pure returns (int256[10] memory d) {
        for (uint256 i = 0; i < 10; i++) d[i] = post[i] - pre[i];
    }

    function _broken(string memory why) internal {
        lastBroken = why;
        lastBrokenAt = block.number;
        console2.log("BROKEN:", why);
    }

    /// @notice the five-party books of one action: conserved per currency, the periphery square
    function _checkConserved(int256[10] memory d, string memory what) internal {
        for (uint256 i = 0; i < 2; i++) {
            if (d[i] + d[2 + i] + d[4 + i] + d[6 + i] + d[8 + i] != 0) {
                booksBroken++;
                _broken(string.concat(what, ": not conserved in currency", vm.toString(i)));
            }
            if (d[6 + i] != 0 || d[8 + i] != 0) {
                peripheryNotSquare++;
                _broken(string.concat(what, ": the router or the PositionManager is not square in currency", vm.toString(i)));
            }
        }
    }

    // ---------------------------------------------------------------- through the periphery, checked (K17c)
    /// @notice every call the action makes is recorded, and held to "the manager was entered only through the periphery
    /// contract this action is for" once it returns - whatever path its body took, an early return included
    modifier throughThePeriphery(bool isSwap, string memory what) {
        _entriesThisAction = 0;
        vm.startStateDiffRecording();
        _;
        _checkThroughPeriphery(vm.stopAndReturnStateDiff(), isSwap, _entriesThisAction, what);
    }

    function _isManagerEntry(bytes4 sel) internal pure returns (bool) {
        return sel == IPoolManager.swap.selector || sel == IPoolManager.modifyLiquidity.selector
            || sel == IPoolManager.donate.selector || sel == IPoolManager.initialize.selector;
    }

    function _isHookCallback(bytes4 sel) internal pure returns (bool) {
        return sel == IHooks.beforeInitialize.selector || sel == IHooks.afterInitialize.selector
            || sel == IHooks.beforeAddLiquidity.selector || sel == IHooks.afterAddLiquidity.selector
            || sel == IHooks.beforeRemoveLiquidity.selector || sel == IHooks.afterRemoveLiquidity.selector
            || sel == IHooks.beforeSwap.selector || sel == IHooks.afterSwap.selector
            || sel == IHooks.beforeDonate.selector || sel == IHooks.afterDonate.selector;
    }

    /// @notice a callback's first argument, `sender`, off the calldata the manager sent
    function _senderOf(bytes memory data) internal pure returns (address s) {
        assembly {
            s := and(mload(add(data, 36)), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    /// @notice the recorded calls of one action (reverted ones skipped: they did not happen) against the rule. `entries`
    /// is what the body said a success needs: 1 for a swap or a liquidity change, 0 for an action that did nothing
    function _checkThroughPeriphery(Vm.AccountAccess[] memory acc, bool isSwap, uint256 entries, string memory what)
        internal
    {
        address from = isSwap ? swapRouter : address(posm);
        bytes4 want = isSwap ? IPoolManager.swap.selector : IPoolManager.modifyLiquidity.selector;
        uint256 good;
        uint256 other;
        uint256 cb;
        uint256 cbFromRouter;
        for (uint256 i = 0; i < acc.length; i++) {
            Vm.AccountAccess memory x = acc[i];
            if (x.reverted || x.kind != VmSafe.AccountAccessKind.Call || x.data.length < 36) continue;
            bytes4 sel = bytes4(x.data);
            if (x.account == address(manager) && _isManagerEntry(sel)) {
                if (sel == want && x.accessor == from) good++;
                else other++;
            } else if (x.account == address(hook) && _isHookCallback(sel)) {
                bool swapCallback = sel == IHooks.beforeSwap.selector || sel == IHooks.afterSwap.selector;
                bool rightSender = x.accessor == address(manager) && _senderOf(x.data) == from;
                if (isSwap && swapCallback) {
                    cb++;
                    if (rightSender) cbFromRouter++;
                } else if (isSwap || swapCallback || !rightSender) {
                    other++;
                }
            }
        }
        entriesExpected += entries;
        entriesFromPeriphery += good;
        if (isSwap) {
            hookSwapCallbacks += cb;
            hookSwapCallbacksFromRouter += cbFromRouter;
        }
        if (good != entries || other != 0 || cbFromRouter != cb || (isSwap && cb != entries * swapCallbacksDeclared)) {
            notThroughPeriphery++;
            _broken(
                string.concat(
                    what,
                    ": not through the ",
                    isSwap ? "router" : "PositionManager",
                    " - manager entries from it ",
                    vm.toString(good),
                    " of ",
                    vm.toString(entries),
                    ", from elsewhere ",
                    vm.toString(other),
                    isSwap
                        ? string.concat("; hook swap callbacks from it ", vm.toString(cbFromRouter), " of ", vm.toString(cb))
                        : ""
                )
            );
        }
    }

    // ---------------------------------------------------------------- liquidity, through the PositionManager
    function _hasFor(address a, uint256 liq) internal view returns (bool) {
        // full range at a price near 1 costs about `liq` of each; twice that is a safe floor
        return token0.trueBalanceOf(a) >= 2 * liq && token1.trueBalanceOf(a) >= 2 * liq;
    }

    /// @param entries the `modifyLiquidity` calls the plan makes in the manager (1; 0 for a burn of an empty position)
    function _posm(address a, bytes memory plan, string memory what, uint256 entries)
        internal
        returns (bool ok, int256[10] memory d)
    {
        int256[10] memory pre = _snap(a);
        vm.prank(a);
        try posm.modifyLiquidities(plan, block.timestamp + 60) {
            ok = true;
        } catch (bytes memory err) {
            _unexpectedRevert(string.concat(what, " through the PositionManager: ", vm.toString(err)));
            return (false, d);
        }
        _entriesThisAction = entries;
        d = _diff(pre, _snap(a));
        _checkConserved(d, what);
        if (d[2] != 0 || d[3] != 0) {
            positionWrong++;
            _broken(string.concat(what, ": the hook moved in a liquidity action"));
        }
    }

    function _checkPosition(uint256 id, string memory what) internal {
        (uint128 liq,,) = manager.getPositionInfo(key.toId(), address(posm), fullLower, fullUpper, bytes32(id));
        if (liq != liquidityOf[id]) {
            positionWrong++;
            _broken(string.concat(what, ": the manager's position is not the handler's liquidity"));
        }
    }

    function mint(uint256 actorSeed, uint256 liq) public counted("mint") throughThePeriphery(false, "mint") {
        address a = _actor(actorSeed);
        liq = bound(liq, MIN_LIQ, MAX_LIQ);
        if (!_hasFor(a, liq)) return;
        uint256 id = posm.nextTokenId();
        (bool ok, int256[10] memory d) =
            _posm(a, PeripheryPlans.mint(key, fullLower, fullUpper, liq, a, ""), "mint", 1);
        if (!ok) return;
        _tokens[a].push(id);
        liquidityOf[id] = liq;
        _checkPosition(id, "mint");
        if (IERC721Owner(address(posm)).ownerOf(id) != a) {
            positionWrong++;
            _broken("mint: the token is not the minter's");
        }
        if (d[0] < 0 && d[1] < 0) _noteReached("position minted, both currencies paid");
        _noteSuccess("mint");
    }

    function _pick(address a, uint256 idxWord) internal view returns (bool found, uint256 idx, uint256 id) {
        uint256 n = _tokens[a].length;
        if (n == 0) return (false, 0, 0);
        idx = idxWord % n;
        return (true, idx, _tokens[a][idx]);
    }

    function increase(uint256 actorSeed, uint256 idxWord, uint256 liq)
        public
        counted("increase")
        throughThePeriphery(false, "increase")
    {
        address a = _actor(actorSeed);
        (bool found,, uint256 id) = _pick(a, idxWord);
        if (!found) return;
        liq = bound(liq, MIN_LIQ, MAX_LIQ);
        if (!_hasFor(a, liq)) return;
        (bool ok,) = _posm(a, PeripheryPlans.increase(key, id, liq, a, ""), "increase", 1);
        if (!ok) return;
        liquidityOf[id] += liq;
        _checkPosition(id, "increase");
        _noteSuccess("increase");
    }

    function decrease(uint256 actorSeed, uint256 idxWord, uint256 liq)
        public
        counted("decrease")
        throughThePeriphery(false, "decrease")
    {
        address a = _actor(actorSeed);
        (bool found,, uint256 id) = _pick(a, idxWord);
        if (!found || liquidityOf[id] < 2) return;
        liq = bound(liq, 1, liquidityOf[id] - 1);
        (bool ok, int256[10] memory d) = _posm(a, PeripheryPlans.decrease(key, id, liq, a, ""), "decrease", 1);
        if (!ok) return;
        liquidityOf[id] -= liq;
        _checkPosition(id, "decrease");
        if (d[0] > 0 || d[1] > 0) _noteReached("liquidity decreased, currency out");
        _noteSuccess("decrease");
    }

    function burn(uint256 actorSeed, uint256 idxWord) public counted("burn") throughThePeriphery(false, "burn") {
        address a = _actor(actorSeed);
        (bool found, uint256 idx, uint256 id) = _pick(a, idxWord);
        if (!found) return;
        // BURN_POSITION removes what is left first: one `modifyLiquidity` if anything is, none if the position is empty
        (bool ok,) = _posm(a, PeripheryPlans.burn(key, id, a, ""), "burn", liquidityOf[id] > 0 ? 1 : 0);
        if (!ok) return;
        liquidityOf[id] = 0;
        _checkPosition(id, "burn");
        uint256[] storage ts = _tokens[a];
        ts[idx] = ts[ts.length - 1];
        ts.pop();
        try IERC721Owner(address(posm)).ownerOf(id) returns (address) {
            positionWrong++;
            _broken("burn: the token still has an owner");
        } catch {}
        _noteReached("position burned");
        _noteSuccess("burn");
    }

    // ---------------------------------------------------------------- swaps, through the router
    function swap(uint256 actorSeed, uint256 amount, uint256 dirWord, uint256 exactInWord)
        public
        counted("swap")
        throughThePeriphery(true, "swap")
    {
        address a = _actor(actorSeed);
        bool zeroForOne = _bit(dirWord);
        bool exactIn = _bit(exactInWord);
        amount = bound(amount, 1e6, MAX_SWAP);
        HostileERC20 input = zeroForOne ? token0 : token1;
        if (input.trueBalanceOf(a) < 3 * amount) return;
        uint128 limit = exactIn ? 0 : uint128(2 * amount);

        int256[10] memory pre = _snap(a);
        vm.recordLogs();
        if (!_routerSwap(a, zeroForOne, exactIn, uint128(amount), limit)) return;
        _entriesThisAction = 1;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        int256[10] memory d = _diff(pre, _snap(a));
        (bool found, int128 p0, int128 p1) = SwapEventReader.lastSwapDelta(logs, address(manager));
        if (!found) {
            _unexpectedRevert("swap: the router returned and the manager emitted no Swap");
            return;
        }
        _checkSwap(d, [int256(p0), int256(p1)], zeroForOne, exactIn, amount);
        swapsOk++;
        if (!exactIn) {
            exactOutOk++;
            _noteReached("exact-out swap through the router");
        } else {
            _noteReached("exact-in swap through the router");
        }
        _noteSuccess("swap");
    }

    function _routerSwap(address a, bool zeroForOne, bool exactIn, uint128 amount, uint128 limit)
        internal
        returns (bool)
    {
        if (deployedRouter) {
            (bytes memory commands, bytes[] memory inputs) =
                PeripheryPlans.swapDeployedUniversalRouter(key, zeroForOne, exactIn, amount, limit, "", a);
            vm.prank(a);
            try IUniversalRouter(swapRouter).execute(commands, inputs, block.timestamp + 60) {
                return true;
            } catch (bytes memory err) {
                _unexpectedRevert(string.concat("swap through the UniversalRouter: ", vm.toString(err)));
                return false;
            }
        }
        bytes memory plan = PeripheryPlans.swapPinned(key, zeroForOne, exactIn, amount, limit, "");
        vm.prank(a);
        try MockV4Router(payable(swapRouter)).executeActions(plan) {
            return true;
        } catch (bytes memory err) {
            _unexpectedRevert(string.concat("swap through the V4Router: ", vm.toString(err)));
            return false;
        }
    }

    function _checkSwap(int256[10] memory d, int256[2] memory pool, bool zeroForOne, bool exactIn, uint256 amount)
        internal
    {
        _checkConserved(d, "swap");
        for (uint256 i = 0; i < 2; i++) {
            if (d[4 + i] != -pool[i]) {
                booksBroken++;
                _broken(string.concat("swap: the manager did not keep the pool's delta in currency", vm.toString(i)));
            }
            if (d[2 + i] != pool[i] - d[i]) {
                hookNotBooked++;
                _broken(string.concat("swap: the hook's balance is not its booked delta in currency", vm.toString(i)));
            }
        }
        uint256 s = exactIn == zeroForOne ? 0 : 1; // the specified currency's index
        int256 userSpecified = d[s];
        if (userSpecified != (exactIn ? -int256(amount) : int256(amount))) {
            specifiedWrong++;
            _broken("swap: the user did not pay / receive exactly what it specified");
        }
        int256 hookSpec = d[2 + s];
        int256 hookUnspec = d[2 + (1 - s)];
        uint256 poolUnspec = pool[1 - s] < 0 ? uint256(-pool[1 - s]) : uint256(pool[1 - s]);
        if (hookUnspec != int256(hook.feeOf(poolUnspec))) {
            feeWrong++;
            _broken("swap: the fee is not 0.30 % of the pool's unspecified amount");
        }
        if (hookUnspec > 0) _noteReached("fee taken");
        if (hookSpec > 0 || uint256(-hookSpec) > hook.nominalRebateOf(amount)) {
            rebateWrong++;
            _broken("swap: a take on the specified side, or a rebate above the nominal");
        }
        if (hookSpec < 0) {
            rebatesSeen++;
            _noteReached("rebate paid");
        }
    }
}

/// @notice the campaign. Runs under `FOUNDRY_PROFILE=periphery` (source manager, pinned periphery) and
/// `periphery-fork` (the deployed periphery). `scripts/census.sh` with the same profile reads what it did.
contract DeltaFeeHookPeripheryInvariants is PeripheryHarness, InvariantAsserts {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    DeltaFeeHook internal hook;
    DeltaFeePeripheryHandler internal handler;
    PeripheryTruthReader internal truth0;
    PeripheryTruthReader internal truth1;
    PoolKey internal key;

    function setUp() public {
        _setUpV4();
        _deployPeriphery();
        hook = DeltaFeeHook(
            _deployHook(
                type(DeltaFeeHook).creationCode,
                abi.encode(manager),
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                    | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            )
        );
        key = _poolKey(IHooks(address(hook)), 3000, 60);
        _initPoolThroughPosm(key, SQRT_PRICE_1_1);
        (int24 lower, int24 upper) = _fullRange(60);
        truth0 = new PeripheryTruthReader(token0);
        truth1 = new PeripheryTruthReader(token1);
        handler = new DeltaFeePeripheryHandler(
            manager, hook, posm, swapRouter, permit2, peripheryIsDeployed, token0, token1, key, lower, upper
        );
        handler.seed(1e22);

        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](7);
        sel[0] = DeltaFeePeripheryHandler.fund.selector;
        sel[1] = DeltaFeePeripheryHandler.mint.selector;
        sel[2] = DeltaFeePeripheryHandler.increase.selector;
        sel[3] = DeltaFeePeripheryHandler.decrease.selector;
        sel[4] = DeltaFeePeripheryHandler.burn.selector;
        sel[5] = DeltaFeePeripheryHandler.swap.selector;
        sel[6] = DeltaFeePeripheryHandler.nextBlock.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        // one caller for the fuzzer's calls (the handler pranks its own actors): on the fork every new caller address is
        // an account forge fetches from the endpoint - measured, 969 `eth_getAccountInfo` for one fork battery without it
        targetSender(address(0xF022));
    }

    function afterInvariant() public {
        handler.writeCensus("DeltaFeeHook/periphery");
        handler.printCallSummary();
        handler.printReachSummary();
        console2.log("CAMPAIGN swapsOk", handler.swapsOk());
        console2.log("CAMPAIGN exactOutOk", handler.exactOutOk());
        console2.log("CAMPAIGN rebatesSeen", handler.rebatesSeen());
    }

    function _reason(string memory what) internal view returns (string memory) {
        return string.concat(what, " (last: ", handler.lastBroken(), ")");
    }

    function invariant_every_action_is_conserved_over_the_five_parties() public view {
        assertEq(handler.booksBroken(), 0, _reason("books"));
    }

    function invariant_the_hook_gets_exactly_its_booked_delta() public view {
        assertEq(handler.hookNotBooked(), 0, _reason("hook booked"));
    }

    function invariant_the_router_and_the_position_manager_end_every_action_square() public view {
        assertEq(handler.peripheryNotSquare(), 0, _reason("periphery square"));
    }

    function invariant_the_user_pays_or_receives_exactly_what_it_specified() public view {
        assertEq(handler.specifiedWrong(), 0, _reason("specified"));
    }

    function invariant_the_fee_is_exact_and_on_the_unspecified_side() public view {
        assertEq(handler.feeWrong(), 0, _reason("P2"));
    }

    function invariant_the_rebate_is_bounded() public view {
        assertEq(handler.rebateWrong(), 0, _reason("P3"));
    }

    function invariant_positions_are_what_the_handler_put_there() public view {
        assertEq(handler.positionWrong(), 0, _reason("positions"));
    }

    function invariant_currency0_is_conserved() public view {
        assertEq(sumBalances(truth0, handler.holders()), handler.minted0(), "currency0: created != held");
    }

    function invariant_currency1_is_conserved() public view {
        assertEq(sumBalances(truth1, handler.holders()), handler.minted1(), "currency1: created != held");
    }

    function invariant_no_unexplained_reverts() public view {
        assertEq(handler.revertsUnexpected(), 0, handler.lastUnexpected());
    }

    /// @notice every swap and every liquidity change reached the manager through the periphery, counted per action
    /// (K17c): one `swap` from the router per swap, one `modifyLiquidity` from the PositionManager per liquidity change,
    /// nothing else entering the manager, and every one of the hook's swap callbacks given `sender` = the router
    function invariant_every_action_reached_the_manager_through_the_periphery() public view {
        assertEq(handler.notThroughPeriphery(), 0, _reason("through the periphery"));
        assertEq(handler.entriesFromPeriphery(), handler.entriesExpected(), "manager entries from the periphery != actions");
        assertEq(handler.hookSwapCallbacksFromRouter(), handler.hookSwapCallbacks(), "hook swap callbacks not from the router");
        assertEq(
            handler.hookSwapCallbacks(),
            handler.swapsOk() * handler.swapCallbacksDeclared(),
            "hook swap callbacks != swaps x the callbacks the hook declares"
        );
    }

    function _allInvariants() internal view {
        invariant_every_action_is_conserved_over_the_five_parties();
        invariant_the_hook_gets_exactly_its_booked_delta();
        invariant_the_router_and_the_position_manager_end_every_action_square();
        invariant_the_user_pays_or_receives_exactly_what_it_specified();
        invariant_the_fee_is_exact_and_on_the_unspecified_side();
        invariant_the_rebate_is_bounded();
        invariant_positions_are_what_the_handler_put_there();
        invariant_currency0_is_conserved();
        invariant_currency1_is_conserved();
        invariant_no_unexplained_reverts();
        invariant_every_action_reached_the_manager_through_the_periphery();
    }

    /// @notice non-vacuity: every action succeeds, every boundary the invariants are about is reached, by hand
    function test_handler_smoke() public {
        for (uint256 i = 0; i < 4; i++) {
            handler.swap(1, 5e17, i, YES); // fill both reserves first: a fresh hook has nothing to rebate
        }
        handler.nextBlock(1);
        handler.swap(2, 1e17, YES, NO); // exact-out 0->1
        handler.swap(2, 1e17, NO, NO); // exact-out 1->0
        handler.swap(3, 2e17, YES, YES);
        handler.mint(1, 1e18);
        handler.mint(2, 5e17);
        handler.increase(1, 0, 1e17);
        handler.swap(4, 3e17, NO, YES);
        handler.decrease(1, 0, 3e17);
        handler.burn(2, 0);
        handler.fund(3, 1e18);
        handler.nextBlock(2);
        handler.swap(1, 1e17, YES, NO);

        handler.assertExercised("swap", 8);
        handler.assertExercised("mint", 2);
        handler.assertExercised("increase", 1);
        handler.assertExercised("decrease", 1);
        handler.assertExercised("burn", 1);
        handler.assertReached("fee taken", 8);
        handler.assertReached("rebate paid", 1);
        handler.assertReached("exact-out swap through the router", 3);
        handler.assertReached("position burned", 1);
        handler.assertReached("position minted, both currencies paid", 2);
        handler.assertReached("liquidity decreased, currency out", 1);
        // the through-the-periphery counters are not vacuous: 9 swaps and 5 liquidity changes, each seen entering the
        // manager from its periphery contract, and 2 hook callbacks per swap, each from the router
        assertEq(handler.swapCallbacksDeclared(), 2, "DeltaFeeHook declares beforeSwap and afterSwap");
        assertEq(handler.entriesExpected(), 14, "manager entries the actions had to make");
        assertEq(handler.hookSwapCallbacks(), 18, "hook swap callbacks");
        _allInvariants();
    }
}
