// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
// Inside the kit: imports are relative. In your project: see scripts/setup-deps.sh's import lines.

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {V4Harness} from "../src/V4Harness.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {HostileHook} from "../src/HostileHook.sol";

/// @notice ten callbacks that revert `NotImplemented()`, as the examples' unused ones do; a fixture overrides the ones
/// it implements. Its constructor does not validate its own permissions: these fixtures are mined to addresses that do
/// not match what they implement, on purpose.
abstract contract ProbeFixture is IHooks {
    IPoolManager public immutable manager;

    error NotImplemented();
    error NotManager();

    constructor(IPoolManager m) {
        manager = m;
    }

    modifier onlyManager() {
        if (msg.sender != address(manager)) revert NotManager();
        _;
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external virtual returns (bytes4) {
        revert NotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external virtual returns (bytes4) {
        revert NotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        virtual
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
    ) external virtual returns (bytes4, BalanceDelta) {
        revert NotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        virtual
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
    ) external virtual returns (bytes4, BalanceDelta) {
        revert NotImplemented();
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        virtual
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert NotImplemented();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        virtual
        returns (bytes4, int128)
    {
        revert NotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert NotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert NotImplemented();
    }
}

/// @notice a defect class the check exists for: `afterInitialize` records when the pool started, and only
/// `beforeInitialize` is declared - the manager never calls it, `initializedAt` stays 0. `beforeInitialize` is a view guard
/// behind `onlyManager`: it answers only if the probe really comes from the manager, under STATICCALL.
contract UndeclaredAfterInitializeHook is ProbeFixture {
    using PoolIdLibrary for PoolKey;

    mapping(PoolId => uint256) public initializedAt;

    constructor(IPoolManager m) ProbeFixture(m) {}

    function beforeInitialize(address, PoolKey calldata, uint160) external view override onlyManager returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        override
        onlyManager
        returns (bytes4)
    {
        initializedAt[key.toId()] = block.timestamp;
        return IHooks.afterInitialize.selector;
    }
}

/// @notice implements `beforeSwap`, which writes and emits; `afterDonate` is left `NotImplemented()`
contract WritingSwapHook is ProbeFixture {
    uint256 public swaps;

    event Swapped(uint256 n);

    constructor(IPoolManager m) ProbeFixture(m) {}

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        override
        onlyManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        swaps++;
        emit Swapped(swaps);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}

/// @notice no callbacks at all: not even the functions
contract NoCallbacksHook {
    uint256 public x;
}

/// @notice a fallback that answers anything: the probe cannot tell an implemented callback from an absent one
contract FallbackHook {
    fallback() external {}
}

/// @notice `_deployHook` holds the address's permission bits against the callbacks the hook implements (K46): a callback
/// that does something and has no bit fails the deployment by name, a bit for a callback that reverts is a log line.
contract HookPermissionsTest is V4Harness {
    string internal constant ONE = " implemented but its permission bit is not set on ";
    string internal constant MANY = " implemented but their permission bits are not set on ";
    /// @notice how the refusal ends (v0.4.1; v0.4.2: the finding's own test - a direct call, no expectRevert - and the
    /// flag's rule): the act, named
    string internal constant ACT =
        " - the manager never calls it. This is a finding, not a fix (doctrine/NEXT.md row 6b). In this order: write its test as"
        " pending/<id>.t.sol - its own setUp sets _skipPermissionCheck = true, then a test function of its own calls"
        " _checkHookPermissions(address(hook)) directly (V4Harness: function _checkHookPermissions(address hook) internal), with"
        " no vm.expectRevert, so this revert fails that test - record that red with scripts/pending-red.sh <proj> pending/<id>.t.sol, count it"
        " in STATE.md; then put _skipPermissionCheck = true and a header line // _skipPermissionCheck: <id> open in the suites"
        " that deploy the hook; then the battery, which holds them to that red record, current while src/ and pending/<id>.t.sol are as recorded (doctrine/EVIDENCE.md section 2).";

    function setUp() public {
        _setUpV4();
    }

    function deployHook(bytes memory creationCode, bytes memory args, uint160 flags) external returns (address) {
        return _deployHook(creationCode, args, flags);
    }

    function _predicted(bytes memory creationCode, uint160 flags) internal view returns (address a) {
        (a,) = HookMiner.find(address(this), flags, creationCode, abi.encode(manager));
    }

    function _startsWith(string memory s, string memory prefix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(prefix);
        if (a.length < b.length) return false;
        for (uint256 i = 0; i < b.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    function _assertRefused(bytes memory creationCode, uint160 flags, string memory expected) internal {
        try this.deployHook(creationCode, abi.encode(manager), flags) returns (address hook) {
            assertTrue(false, string.concat("deployed at ", vm.toString(hook), " with no word; expected: ", expected));
        } catch Error(string memory reason) {
            assertTrue(_startsWith(reason, expected), string.concat("refused, but with: ", reason));
        }
    }

    // ------------------------------------------------------------------ the failures, by name
    function test_an_implemented_callback_without_its_bit_fails_naming_it() public {
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG;
        bytes memory code = type(UndeclaredAfterInitializeHook).creationCode;
        _assertRefused(
            code, flags, string.concat("V4Harness: afterInitialize", ONE, vm.toString(_predicted(code, flags)))
        );
    }

    /// @notice the refusal names the act, whole (v0.4.1: a run read this refusal and bypassed it, and nothing was
    /// recorded): a finding, not a fix - the pending test, its red record, the count, and the only place for the flag
    function test_the_refusal_names_the_act_a_pending_test_its_red_record_and_the_count() public {
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG;
        bytes memory code = type(UndeclaredAfterInitializeHook).creationCode;
        string memory expected = string.concat("V4Harness: afterInitialize", ONE, vm.toString(_predicted(code, flags)), ACT);
        try this.deployHook(code, abi.encode(manager), flags) returns (address hook) {
            assertTrue(false, string.concat("deployed at ", vm.toString(hook), " with no word; expected: ", expected));
        } catch Error(string memory reason) {
            assertEq(reason, expected);
        }
    }

    /// @notice `HostileHook` answers all ten callbacks: at an address carrying one bit, nine are named
    function test_the_hostile_hook_at_one_bit_is_refused_naming_the_nine_others() public {
        uint160 flags = Hooks.BEFORE_SWAP_FLAG;
        bytes memory code = type(HostileHook).creationCode;
        _assertRefused(
            code,
            flags,
            string.concat(
                "V4Harness: beforeInitialize, afterInitialize, beforeAddLiquidity, afterAddLiquidity, beforeRemoveLiquidity,",
                " afterRemoveLiquidity, afterSwap, beforeDonate, afterDonate",
                MANY,
                vm.toString(_predicted(code, flags))
            )
        );
    }

    // ------------------------------------------------------------------ what passes
    function test_the_same_hook_with_both_bits_deploys() public {
        address hook = this.deployHook(
            type(UndeclaredAfterInitializeHook).creationCode,
            abi.encode(manager),
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG
        );
        assertGt(hook.code.length, 0);
    }

    /// @notice a bit set for a callback that reverts `NotImplemented()` is a warning, not a failure
    function test_a_bit_for_a_callback_that_is_not_implemented_deploys() public {
        address hook = this.deployHook(
            type(WritingSwapHook).creationCode, abi.encode(manager), Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_DONATE_FLAG
        );
        assertGt(hook.code.length, 0);
    }

    /// @notice a bit for a function the contract does not have at all: a warning too
    function test_a_bit_for_a_function_that_does_not_exist_deploys() public {
        address hook = this.deployHook(type(NoCallbacksHook).creationCode, abi.encode(manager), Hooks.AFTER_DONATE_FLAG);
        assertGt(hook.code.length, 0);
    }

    /// @notice a fallback that answers anything cannot be checked: logged, not failed
    function test_a_hook_that_answers_anything_is_not_checked() public {
        address hook = this.deployHook(type(FallbackHook).creationCode, abi.encode(manager), Hooks.BEFORE_SWAP_FLAG);
        assertGt(hook.code.length, 0);
    }

    // ------------------------------------------------------------------ the escape
    /// @notice a suite that deploys a mis-flagged hook on purpose sets `_skipPermissionCheck` around that deployment
    function test_skipPermissionCheck_lets_a_mis_flagged_hook_through_and_only_while_set() public {
        _skipPermissionCheck = true;
        address hostile = this.deployHook(type(HostileHook).creationCode, abi.encode(manager), Hooks.BEFORE_SWAP_FLAG);
        _skipPermissionCheck = false;
        assertTrue(HookMiner.carriesExactly(hostile, Hooks.BEFORE_SWAP_FLAG), "not at a mined address");
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG;
        bytes memory code = type(UndeclaredAfterInitializeHook).creationCode;
        _assertRefused(code, flags, string.concat("V4Harness: afterInitialize", ONE, vm.toString(_predicted(code, flags))));
    }

    // ------------------------------------------------------------------ what the probe saw, and that it left nothing
    function _deployUnchecked(bytes memory creationCode, uint160 flags) internal returns (address hook) {
        _skipPermissionCheck = true;
        hook = _deployHook(creationCode, abi.encode(manager), flags);
        _skipPermissionCheck = false;
    }

    /// @notice a view guard behind `onlyManager` answers the STATICCALL (so the probe really comes from the manager),
    /// a callback that writes answers the real call made after an empty STATICCALL revert, the eight others are not
    /// implemented - and the write did not stay
    function test_the_probe_tells_a_guard_a_write_and_not_implemented_apart_and_leaves_no_state() public {
        address hook = _deployUnchecked(type(UndeclaredAfterInitializeHook).creationCode, Hooks.BEFORE_INITIALIZE_FLAG);
        HookProbe memory p = _probeHookCallbacks(hook);
        assertFalse(p.blind);
        assertEq(p.answered, Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG, "answered");
        assertEq(p.ownError, 0, "own error");
        uint160 allTen = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.AFTER_DONATE_FLAG;
        assertEq(p.notImplemented, allTen & ~(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG), "not implemented");
        PoolKey memory key = _poolKey(IHooks(hook), 3000, 60);
        assertEq(UndeclaredAfterInitializeHook(hook).initializedAt(PoolIdLibrary.toId(key)), 0, "the probe's write stayed");
    }

    /// @notice a callback whose bit is set and that writes and emits is not run for real: nothing reaches a log
    /// recording the suite started, and its state does not move
    function test_a_writing_callback_with_its_bit_is_not_run_for_real() public {
        address hook = _deployUnchecked(type(WritingSwapHook).creationCode, Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_DONATE_FLAG);
        vm.recordLogs();
        HookProbe memory p = _probeHookCallbacks(hook);
        assertEq(vm.getRecordedLogs().length, 0, "the probe emitted into the suite's recording");
        assertEq(WritingSwapHook(hook).swaps(), 0, "the probe's write stayed");
        assertEq((p.answered | p.ownError | p.notImplemented) & Hooks.BEFORE_SWAP_FLAG, 0, "beforeSwap was classified");
        assertTrue(p.notImplemented & Hooks.AFTER_DONATE_FLAG != 0, "afterDonate reverts NotImplemented()");
    }

    /// @notice a bit set for a function the contract does not have: not implemented, by the code's own dispatcher
    function test_a_bit_for_a_missing_function_is_not_implemented() public {
        address hook = _deployUnchecked(type(NoCallbacksHook).creationCode, Hooks.AFTER_DONATE_FLAG);
        HookProbe memory p = _probeHookCallbacks(hook);
        assertTrue(p.notImplemented & Hooks.AFTER_DONATE_FLAG != 0, "afterDonate");
        assertEq(p.answered | p.ownError, 0, "something answered");
    }

    function test_a_fallback_makes_the_probe_blind() public {
        address hook = _deployUnchecked(type(FallbackHook).creationCode, Hooks.BEFORE_SWAP_FLAG);
        assertTrue(_probeHookCallbacks(hook).blind);
    }

    /// @notice the selector search finds what solc's dispatcher pushes, and not what is absent
    function test_codeHasSelector_on_a_hook() public {
        address hook = _deployUnchecked(type(WritingSwapHook).creationCode, Hooks.BEFORE_SWAP_FLAG);
        assertTrue(_codeHasSelector(hook.code, IHooks.beforeSwap.selector), "beforeSwap");
        assertTrue(_codeHasSelector(hook.code, IHooks.afterDonate.selector), "afterDonate (it reverts, but it is there)");
        assertFalse(_codeHasSelector(hook.code, bytes4(keccak256("v4HarnessNoSuchCallback()"))), "an absent selector");
    }
}
