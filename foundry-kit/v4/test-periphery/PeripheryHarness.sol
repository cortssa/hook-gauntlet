// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
// Inside the kit: imports are relative. In your project: see scripts/setup-deps.sh's import lines.

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IImmutableState} from "v4-periphery/src/interfaces/IImmutableState.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {MockV4Router} from "v4-periphery/test/mocks/MockV4Router.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {V4Harness} from "../src/V4Harness.sol";
import {SwapEventReader} from "../src/SwapEventReader.sol";
import {PeripheryPlans} from "./PeripheryPlans.sol";

/// @notice the one entry point of the UniversalRouter the kit uses
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IERC721Owner {
    function ownerOf(uint256 id) external view returns (address);
}

/// @title PeripheryHarness
/// @notice `V4Harness` plus Uniswap's REAL periphery in front of the manager (K17b): the hook is reached the way users
/// reach it - liquidity through `PositionManager.modifyLiquidities`, swaps through a V4Router - instead of through the
/// kit's `MinimalRouter` / `LiquidityHelper`. Needs `V4_WITH_PERIPHERY=1 scripts/install-v4.sh` and runs under
/// `FOUNDRY_PROFILE=periphery` (source) or `periphery-fork` (the fork): `foundry-kit/v4/README.md`, "The periphery".
///
/// ## Which periphery
///
/// **Source / fixture manager** (`_deployPeriphery`): everything from the commits `install-v4.sh` pins.
///  * `PositionManager` - Uniswap's own, deployed from its artifact (`vm.deployCode`: a test that imports it next to
///    `PoolManager` asks forge for two incompatible compiler restrictions in one unit) with its real constructor: this
///    manager, Permit2, the unsubscribe gas limit the mainnet deployment was built with (150 000, read from it on the
///    fork), no token descriptor (`tokenURI` is not a hook's concern and is not covered), and a WETH (solmate's).
///  * `Permit2` - its own repository's test deployer (`permit2/test/utils/DeployPermit2.sol`): Permit2 is pinned at
///    solc 0.8.17 and this project compiles 0.8.26, so it cannot be built here; the deployer etches its runtime code at
///    the canonical address. That code is mainnet's except for the two words of its cached chain id (31 337) and domain
///    separator - and that cached domain is not the canonical address's, so on this chain `DOMAIN_SEPARATOR()` answers
///    a domain no one would compute (measured: `test-periphery/fork/PeripheryAddresses.t.sol`). The kit uses on-chain
///    allowances only; a signature path tested here must sign against what `DOMAIN_SEPARATOR()` answers.
///  * the swap router - the periphery's own test router, `MockV4Router`, not a V4Router of ours: `V4Router` is abstract
///    (the UniversalRouter, which completes it, is another repository the kit does not install), and `MockV4Router` is
///    Uniswap's completion of it at the pinned commit. Everything a hook can see - `sender`, `hookData`, the order of
///    swap and settlement, the deltas the router settles - is `V4Router`'s. What it does NOT share with the deployed
///    router is how the input is paid: `transferFrom` from the user (approve the router), where the UniversalRouter
///    pulls through Permit2.
///
/// **Fork** (`V4_MANAGER=fork`): the periphery DEPLOYED on mainnet, as it is at the pinned block - `PositionManager`
/// and the `UniversalRouter` at their mainnet addresses, Permit2 at its canonical one - nothing deployed, nothing etched.
/// `test-periphery/fork/PeripheryAddresses.t.sol` checks on the chain that each is what its name says. Neither is the
/// pinned build. The router decodes an older swap layout (`PeripheryPlans`: measured). The position manager's runtime is
/// larger than the pinned build's (23 877 B against 20 006) and dispatches the same 39 external functions, no more
/// (measured off its code); what source it was built from is NOT measured. So on the fork the same test runs against the
/// code users actually call.
///
/// ## What a hook sees through it (the rule, measured in `test-periphery/PeripherySender.t.sol`)
///
/// `sender` in every callback is the contract that called the manager: the `PositionManager` for initialise (through
/// `initializePool`) and every liquidity change, the router for every swap - never the user. A position's owner in the
/// manager is the `PositionManager`, its `salt` is the token id. `hookData` arrives byte for byte as the user wrote it:
/// it is the user's input, not the router's. The user is visible only as `IMsgSender(sender).msgSender()`, which the
/// periphery's contracts answer truthfully and any other contract answers however it likes.
abstract contract PeripheryHarness is V4Harness {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for *;

    /// @notice mainnet's v4 PositionManager and UniversalRouter, and Permit2 (the same address on every chain). How each
    /// was checked on the chain, not taken from a page: `test-periphery/fork/PeripheryAddresses.t.sol`.
    address internal constant MAINNET_POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address internal constant MAINNET_UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address internal constant PERMIT2_ADDRESS = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /// @notice the mainnet PositionManager's constructor argument, read from it at the pinned block
    uint256 internal constant MAINNET_UNSUBSCRIBE_GAS_LIMIT = 150_000;

    IPositionManager public posm;
    /// @notice `MockV4Router` (source, fixture) or the deployed UniversalRouter (fork)
    address public swapRouter;
    IAllowanceTransfer public permit2;
    address public posmWeth;
    /// @notice true on the fork: the periphery is the chain's, and the router is the UniversalRouter
    bool public peripheryIsDeployed;

    /// @notice `_deployPeriphery` before the manager exists (`_setUpV4` first)
    error PeripheryBeforeManager();
    /// @notice no code at a periphery address at the fork's block
    error PeripheryNotOnChain(address what, uint256 blockNumber);
    /// @notice a deployed periphery contract that answers another manager
    error PeripheryOfAnotherManager(address what, address itsManager);
    /// @notice `initializePool` found the pool initialised already (it returns `type(int24).max` instead of reverting)
    error PoolAlreadyInitialised();

    // ------------------------------------------------------------------ the periphery
    /// @notice call after `_setUpV4()` (or `_setUpV4OnFork()`): the manager must exist. Deploys the pinned periphery in
    /// front of a source or fixture manager; takes the deployed one on the fork.
    function _deployPeriphery() internal {
        if (address(manager) == address(0)) revert PeripheryBeforeManager();
        if (managerPlan == ManagerPlan.FORK) {
            _takeDeployedPeriphery();
        } else {
            permit2 = IAllowanceTransfer(new DeployPermit2().deployPermit2());
            posmWeth = address(new WETH());
            posm = IPositionManager(
                vm.deployCode(
                    "PositionManager.sol:PositionManager",
                    abi.encode(manager, permit2, MAINNET_UNSUBSCRIBE_GAS_LIMIT, address(0), posmWeth)
                )
            );
            swapRouter = address(new MockV4Router(manager));
        }
        vm.label(address(posm), peripheryIsDeployed ? "PositionManager(mainnet)" : "PositionManager");
        vm.label(swapRouter, peripheryIsDeployed ? "UniversalRouter(mainnet)" : "MockV4Router");
        vm.label(address(permit2), "Permit2");
    }

    function _takeDeployedPeriphery() private {
        address[3] memory at = [MAINNET_POSITION_MANAGER, MAINNET_UNIVERSAL_ROUTER, PERMIT2_ADDRESS];
        for (uint256 i = 0; i < 3; i++) {
            if (at[i].code.length == 0) revert PeripheryNotOnChain(at[i], block.number);
        }
        for (uint256 i = 0; i < 2; i++) {
            address m = address(IImmutableState(at[i]).poolManager());
            if (m != address(manager)) revert PeripheryOfAnotherManager(at[i], m);
        }
        posm = IPositionManager(MAINNET_POSITION_MANAGER);
        swapRouter = MAINNET_UNIVERSAL_ROUTER;
        permit2 = IAllowanceTransfer(PERMIT2_ADDRESS);
        posmWeth = MAINNET_WETH;
        peripheryIsDeployed = true;
    }

    /// @notice let the periphery pull `c` from `who`: the PositionManager through Permit2 (ERC-20 -> Permit2 -> spender,
    /// an on-chain allowance, no signature), the router through Permit2 on the fork (the UniversalRouter pays that way)
    /// and by a plain approval on source (`MockV4Router` pays with `transferFrom`). Nothing for ETH.
    function _approvePeriphery(address who, Currency c) internal {
        if (c.isAddressZero()) return;
        address t = Currency.unwrap(c);
        vm.startPrank(who);
        IERC20Minimal(t).approve(address(permit2), type(uint256).max);
        permit2.approve(t, address(posm), type(uint160).max, type(uint48).max);
        if (peripheryIsDeployed) permit2.approve(t, swapRouter, type(uint160).max, type(uint48).max);
        else IERC20Minimal(t).approve(swapRouter, type(uint256).max);
        vm.stopPrank();
    }

    /// @notice initialise a pool the way users do it, through the PositionManager (`sender` of the initialise callbacks
    /// is then the PositionManager)
    function _initPoolThroughPosm(PoolKey memory key, uint160 sqrtPriceX96) internal {
        if (posm.initializePool(key, sqrtPriceX96) == type(int24).max) revert PoolAlreadyInitialised();
    }

    // ------------------------------------------------------------------ liquidity, through the PositionManager
    function _posmCall(address who, bytes memory unlockData, uint256 value) internal {
        vm.prank(who);
        posm.modifyLiquidities{value: value}(unlockData, block.timestamp + 60);
    }

    /// @notice the ETH a liquidity call sends on a native pool: all `who` has (the PositionManager sweeps the rest back)
    function _posmValue(PoolKey memory key, address who) internal view returns (uint256) {
        return key.currency0.isAddressZero() ? who.balance : 0;
    }

    function _posmMint(address who, PoolKey memory key, int24 lower, int24 upper, uint256 liq, bytes memory hookData)
        internal
        returns (uint256 tokenId)
    {
        tokenId = posm.nextTokenId();
        _posmCall(who, PeripheryPlans.mint(key, lower, upper, liq, who, hookData), _posmValue(key, who));
    }

    function _posmIncrease(address who, PoolKey memory key, uint256 tokenId, uint256 liq, bytes memory hookData) internal {
        _posmCall(who, PeripheryPlans.increase(key, tokenId, liq, who, hookData), _posmValue(key, who));
    }

    function _posmDecrease(address who, PoolKey memory key, uint256 tokenId, uint256 liq, bytes memory hookData) internal {
        _posmCall(who, PeripheryPlans.decrease(key, tokenId, liq, who, hookData), 0);
    }

    function _posmBurn(address who, PoolKey memory key, uint256 tokenId, bytes memory hookData) internal {
        _posmCall(who, PeripheryPlans.burn(key, tokenId, who, hookData), 0);
    }

    /// @notice the liquidity the MANAGER holds for a PositionManager token: the position is the PositionManager's, and
    /// its salt is the token id
    function _managerLiquidityOf(PoolKey memory key, uint256 tokenId, int24 lower, int24 upper)
        internal
        view
        returns (uint128 liq)
    {
        (liq,,) = manager.getPositionInfo(key.toId(), address(posm), lower, upper, bytes32(tokenId));
    }

    // ------------------------------------------------------------------ swaps, through the router
    /// @notice one single-pool swap. `limit` is the minimum out (exact-in) or the maximum in (exact-out).
    struct RouterSwap {
        bool zeroForOne;
        bool exactIn;
        uint128 amount;
        uint128 limit;
        bytes hookData;
    }

    /// @notice swap through the router as `who`. With ETH as the input it sends `amount` (exact-in) or `limit`
    /// (exact-out); the router sends back what it did not use (`MockV4Router.executeActionsAndSweepExcessETH`, or the
    /// UniversalRouter's SWEEP).
    function _routerSwap(address who, PoolKey memory key, RouterSwap memory s) internal {
        bool nativeIn = s.zeroForOne && key.currency0.isAddressZero();
        uint256 value = nativeIn ? (s.exactIn ? s.amount : s.limit) : 0;
        if (peripheryIsDeployed) {
            (bytes memory commands, bytes[] memory inputs) = PeripheryPlans.swapDeployedUniversalRouter(
                key, s.zeroForOne, s.exactIn, s.amount, s.limit, s.hookData, who
            );
            vm.prank(who);
            IUniversalRouter(swapRouter).execute{value: value}(commands, inputs, block.timestamp + 60);
        } else {
            bytes memory plan = PeripheryPlans.swapPinned(key, s.zeroForOne, s.exactIn, s.amount, s.limit, s.hookData);
            vm.prank(who);
            MockV4Router(payable(swapRouter)).executeActionsAndSweepExcessETH{value: value}(plan);
        }
    }

    // ------------------------------------------------------------------ every party's books, through the periphery
    /// @notice what one periphery call did to everyone, per currency, each from its own balance (`_trueBalance`): the
    /// user, the hook (its tokens and its ERC-6909 claims), the manager, the router and the PositionManager. For a swap
    /// also the pool's own delta off the manager's `Swap` event (caller-signed). Signed from each party's side.
    /// Conservation is `user + hook + manager + router + posm == 0` per currency; the router and the PositionManager
    /// end every call as they began (0); with the router square, the user's change IS what the manager settled with the
    /// router, so the hook's booked delta is `pool - user`.
    struct PeripheryBooks {
        int256 user0;
        int256 user1;
        int256 hook0;
        int256 hook1;
        int256 hookClaims0;
        int256 hookClaims1;
        int256 manager0;
        int256 manager1;
        int256 router0;
        int256 router1;
        int256 posm0;
        int256 posm1;
        int256 pool0;
        int256 pool1;
        bool swapSeen;
    }

    /// @notice one callback the hook received: its selector, the `sender` argument, the `hookData` argument (empty for
    /// the initialise callbacks, which have none), and the liquidity `salt` (liquidity callbacks only)
    struct HookCall {
        bytes4 selector;
        address sender;
        bytes hookData;
        bytes32 salt;
    }

    function _snapPeriphery(PoolKey memory key, address who) internal view returns (int256[12] memory s) {
        address hook = address(key.hooks);
        Currency[2] memory c = [key.currency0, key.currency1];
        for (uint256 i = 0; i < 2; i++) {
            s[i] = int256(_trueBalance(c[i], who));
            s[2 + i] = int256(_trueBalance(c[i], hook));
            s[4 + i] = int256(_claimsOf(c[i], hook));
            s[6 + i] = int256(_trueBalance(c[i], address(manager)));
            s[8 + i] = int256(_trueBalance(c[i], swapRouter));
            s[10 + i] = int256(_trueBalance(c[i], address(posm)));
        }
    }

    function _fillBooks(int256[12] memory pre, int256[12] memory post) internal pure returns (PeripheryBooks memory b) {
        b.user0 = post[0] - pre[0];
        b.user1 = post[1] - pre[1];
        b.hook0 = post[2] - pre[2];
        b.hook1 = post[3] - pre[3];
        b.hookClaims0 = post[4] - pre[4];
        b.hookClaims1 = post[5] - pre[5];
        b.manager0 = post[6] - pre[6];
        b.manager1 = post[7] - pre[7];
        b.router0 = post[8] - pre[8];
        b.router1 = post[9] - pre[9];
        b.posm0 = post[10] - pre[10];
        b.posm1 = post[11] - pre[11];
    }

    /// @notice `_routerSwap` with every party's books and every callback the hook received
    function _routerSwapWithBooks(address who, PoolKey memory key, RouterSwap memory s)
        internal
        returns (PeripheryBooks memory b, HookCall[] memory calls)
    {
        int256[12] memory pre = _snapPeriphery(key, who);
        vm.recordLogs();
        vm.startStateDiffRecording();
        _routerSwap(who, key, s);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        b = _fillBooks(pre, _snapPeriphery(key, who));
        (bool found, int128 p0, int128 p1) = SwapEventReader.lastSwapDelta(logs, address(manager));
        require(found, "PeripheryHarness: no Swap event, the swap did not happen");
        b.pool0 = p0;
        b.pool1 = p1;
        b.swapSeen = true;
        calls = _hookCallsIn(acc, address(key.hooks));
    }

    /// @notice one PositionManager call (`unlockData` from `PeripheryPlans`) with every party's books and the hook's
    /// callbacks
    function _posmWithBooks(address who, PoolKey memory key, bytes memory unlockData, uint256 value)
        internal
        returns (PeripheryBooks memory b, HookCall[] memory calls)
    {
        int256[12] memory pre = _snapPeriphery(key, who);
        vm.startStateDiffRecording();
        _posmCall(who, unlockData, value);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        b = _fillBooks(pre, _snapPeriphery(key, who));
        calls = _hookCallsIn(acc, address(key.hooks));
    }

    /// @notice every call into `hook` in a recorded state diff, decoded. Read off the CALLDATA the manager sent, so it is
    /// what the hook was given, whatever the hook does with it (the example hooks ignore `sender` and `hookData`).
    function _hookCallsIn(Vm.AccountAccess[] memory acc, address hook) internal pure returns (HookCall[] memory calls) {
        uint256 n;
        for (uint256 i = 0; i < acc.length; i++) {
            if (_isHookCallback(acc[i], hook)) n++;
        }
        calls = new HookCall[](n);
        n = 0;
        for (uint256 i = 0; i < acc.length; i++) {
            if (_isHookCallback(acc[i], hook)) calls[n++] = _decodeHookCall(acc[i].data);
        }
    }

    function _isHookCallback(Vm.AccountAccess memory a, address hook) private pure returns (bool) {
        if (a.account != hook || a.kind != VmSafe.AccountAccessKind.Call || a.data.length < 4) return false;
        bytes4 sel = bytes4(a.data);
        return sel == IHooks.beforeInitialize.selector || sel == IHooks.afterInitialize.selector
            || sel == IHooks.beforeAddLiquidity.selector || sel == IHooks.afterAddLiquidity.selector
            || sel == IHooks.beforeRemoveLiquidity.selector || sel == IHooks.afterRemoveLiquidity.selector
            || sel == IHooks.beforeSwap.selector || sel == IHooks.afterSwap.selector
            || sel == IHooks.beforeDonate.selector || sel == IHooks.afterDonate.selector;
    }

    function _decodeHookCall(bytes memory data) private pure returns (HookCall memory c) {
        c.selector = bytes4(data);
        bytes memory args = new bytes(data.length - 4);
        for (uint256 i = 0; i < args.length; i++) args[i] = data[i + 4];
        bytes4 s = c.selector;
        if (s == IHooks.beforeInitialize.selector) {
            (c.sender,,) = abi.decode(args, (address, PoolKey, uint160));
        } else if (s == IHooks.afterInitialize.selector) {
            (c.sender,,,) = abi.decode(args, (address, PoolKey, uint160, int24));
        } else if (s == IHooks.beforeSwap.selector) {
            (c.sender,,, c.hookData) = abi.decode(args, (address, PoolKey, SwapParams, bytes));
        } else if (s == IHooks.afterSwap.selector) {
            (c.sender,,,, c.hookData) = abi.decode(args, (address, PoolKey, SwapParams, int256, bytes));
        } else if (s == IHooks.beforeAddLiquidity.selector || s == IHooks.beforeRemoveLiquidity.selector) {
            ModifyLiquidityParams memory p;
            (c.sender,, p, c.hookData) = abi.decode(args, (address, PoolKey, ModifyLiquidityParams, bytes));
            c.salt = p.salt;
        } else if (s == IHooks.afterAddLiquidity.selector || s == IHooks.afterRemoveLiquidity.selector) {
            ModifyLiquidityParams memory p;
            (c.sender,, p,,, c.hookData) =
                abi.decode(args, (address, PoolKey, ModifyLiquidityParams, int256, int256, bytes));
            c.salt = p.salt;
        } else {
            (c.sender,,,, c.hookData) = abi.decode(args, (address, PoolKey, uint256, uint256, bytes));
        }
    }

    /// @notice every callback in `calls` came from `sender` with exactly `hookData` (the initialise callbacks carry no
    /// hookData and are held to `sender` only). Returns how many there were, for the caller to hold to a number.
    function _assertHookCalls(HookCall[] memory calls, address sender, bytes memory hookData, string memory label)
        internal
        pure
        returns (uint256)
    {
        for (uint256 i = 0; i < calls.length; i++) {
            assertEq(calls[i].sender, sender, string.concat(label, ": the hook's `sender` is not the periphery contract"));
            if (calls[i].selector == IHooks.beforeInitialize.selector || calls[i].selector == IHooks.afterInitialize.selector) {
                continue;
            }
            assertEq(calls[i].hookData, hookData, string.concat(label, ": hookData did not arrive byte for byte"));
        }
        return calls.length;
    }

    /// @notice conservation over the five parties, and the router and the PositionManager square, per currency
    function _assertPeripheryConserved(PeripheryBooks memory b, string memory label) internal pure {
        assertEq(b.user0 + b.hook0 + b.manager0 + b.router0 + b.posm0, 0, string.concat(label, ": currency0 not conserved"));
        assertEq(b.user1 + b.hook1 + b.manager1 + b.router1 + b.posm1, 0, string.concat(label, ": currency1 not conserved"));
        assertEq(b.router0, 0, string.concat(label, ": the router kept or lost currency0"));
        assertEq(b.router1, 0, string.concat(label, ": the router kept or lost currency1"));
        assertEq(b.posm0, 0, string.concat(label, ": the PositionManager kept or lost currency0"));
        assertEq(b.posm1, 0, string.concat(label, ": the PositionManager kept or lost currency1"));
    }
}
