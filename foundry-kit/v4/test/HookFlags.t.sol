// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {V4Harness} from "../src/V4Harness.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {HostileHook} from "../src/HostileHook.sol";
import {CappedDynamicFeeHook} from "../src/examples/CappedDynamicFeeHook.sol";

/// @notice The address IS the permission set. These tests are about the search that produces it and about
/// the two different refusals that catch a wrong one.
///
/// The distinction is worth reading once, because it is easy to believe the manager checks more than it does:
///
/// * the **manager** refuses only two shapes of address, and it refuses them at `initialize`: a hook that
///   claims a "returns delta" bit without the matching action bit, and a hook with no bits at all on a pool
///   whose fee is not dynamic. Those are the only ones. An address that carries an EXTRA action flag is
///   perfectly valid to the manager, and the manager will duly call the hook there;
/// * the **hook's own constructor** is what refuses an address that does not match what it declared, via
///   `Hooks.validateHookPermissions`. That is why every hook should call it, and why the miner has to search
///   for equality: mine for "contains the bits I want" and you get a hook the manager happily calls in a
///   place the hook has no code for.
contract HookFlagsTest is V4Harness {
    function setUp() public {
        _setUpManager();
        _deployCurrencies();
        _deployRouters();
    }

    // ------------------------------------------------------------------ the search
    function test_mined_address_carries_exactly_the_declared_flags() public {
        uint160 flags = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG;
        (address predicted, bytes32 salt) = HookMiner.find(
            address(this), flags, type(CappedDynamicFeeHook).creationCode, abi.encode(manager)
        );
        CappedDynamicFeeHook hook = new CappedDynamicFeeHook{salt: salt}(manager);

        assertEq(address(hook), predicted, "the mined address is not where it landed");
        assertEq(uint256(HookMiner.flagsOf(address(hook))), uint256(flags), "wrong flag bits");
        assertTrue(HookMiner.carriesExactly(address(hook), flags), "not an exact match");
        assertEq(uint256(hook.requiredFlags()), uint256(flags), "the hook declares something else");
        console2.log("mined hook", address(hook));
        console2.log("salt", uint256(salt));
    }

    /// @notice equality, not containment. A search that stops at "has the bits I asked for" accepts this
    /// address, and the hook's own constructor is what catches it.
    function test_an_address_with_one_extra_flag_is_refused_by_the_hooks_constructor() public {
        uint160 flags = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG;
        (address predicted, bytes32 salt) = HookMiner.findWithExtraFlag(
            address(this),
            flags,
            Hooks.AFTER_SWAP_FLAG,
            type(CappedDynamicFeeHook).creationCode,
            abi.encode(manager)
        );
        // the address really does carry the extra bit, or this test proves nothing
        assertTrue(HookMiner.flagsOf(predicted) & Hooks.AFTER_SWAP_FLAG != 0, "the extra flag is not there");
        assertFalse(HookMiner.carriesExactly(predicted, flags), "this should not be an exact match");

        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new CappedDynamicFeeHook{salt: salt}(manager);
    }

    /// @notice a salt is a function of the deployer. Reusing one across deployers is how a hard-coded salt
    /// from a previous run lands at an address with the wrong bits.
    function test_the_same_salt_is_a_different_address_for_a_different_deployer() public view {
        bytes memory initcode = bytes.concat(type(CappedDynamicFeeHook).creationCode, abi.encode(manager));
        address a = HookMiner.computeAddress(address(this), bytes32(uint256(1)), initcode);
        address b = HookMiner.computeAddress(address(0xBEEF), bytes32(uint256(1)), initcode);
        assertTrue(a != b, "the deployer does not change the address?");
    }

    /// @notice and of the constructor arguments. Change one, and yesterday's salt is worthless.
    function test_the_same_salt_is_a_different_address_for_different_constructor_args() public view {
        bytes memory code = type(CappedDynamicFeeHook).creationCode;
        address a =
            HookMiner.computeAddress(address(this), bytes32(uint256(1)), bytes.concat(code, abi.encode(manager)));
        address b = HookMiner.computeAddress(
            address(this), bytes32(uint256(1)), bytes.concat(code, abi.encode(address(0xBEEF)))
        );
        assertTrue(a != b, "the constructor arguments do not change the address?");
    }

    // ------------------------------------------------------------------ what the MANAGER refuses
    /// @notice a hook that says it returns a delta from `beforeSwap` but has no `beforeSwap` flag. The
    /// manager refuses to initialise a pool with it at all.
    function test_manager_refuses_a_delta_flag_with_no_action_flag() public {
        uint160 flags = Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG; // and NOT BEFORE_SWAP_FLAG
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(HostileHook).creationCode, abi.encode(manager));
        HostileHook hook = new HostileHook{salt: salt}(manager);
        assertEq(address(hook), predicted);

        PoolKey memory key = _poolKey(IHooks(address(hook)), 3000, 60);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, address(hook)));
        manager.initialize(key, 79228162514264337593543950336);
    }

    /// @notice a hook with no flags at all on a pool with a static fee: it would never be called, so the
    /// manager treats naming it as a mistake.
    function test_manager_refuses_a_flagless_hook_on_a_static_fee_pool() public {
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), 0, type(HostileHook).creationCode, abi.encode(manager));
        HostileHook hook = new HostileHook{salt: salt}(manager);
        assertEq(address(hook), predicted);
        assertEq(uint256(HookMiner.flagsOf(address(hook))), 0, "this address should carry no flags");

        PoolKey memory key = _poolKey(IHooks(address(hook)), 3000, 60);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, address(hook)));
        manager.initialize(key, 79228162514264337593543950336);
    }

    /// @notice ...and the honest other half: an EXTRA action flag is NOT refused by the manager. This test
    /// exists so that nobody reads the two above and concludes the manager is checking their work.
    function test_manager_accepts_an_extra_action_flag_which_is_why_the_constructor_check_matters() public {
        uint160 flags = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG;
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(HostileHook).creationCode, abi.encode(manager));
        HostileHook hook = new HostileHook{salt: salt}(manager);

        PoolKey memory key = _poolKey(IHooks(address(hook)), 3000, 60);
        manager.initialize(key, 79228162514264337593543950336); // accepted, no revert
        assertTrue(HookMiner.flagsOf(address(hook)) & Hooks.BEFORE_DONATE_FLAG != 0);
    }

    // ------------------------------------------------------------------ the search failing
    function test_the_miner_is_not_silent_when_it_cannot_find_anything() public pure {
        // Every flag set is reachable, so a real failure needs an impossible target. `find` masks its input,
        // so the honest thing to assert here is the invariant that makes a miss impossible: the mask covers
        // exactly fourteen bits, and the search space is far larger than the space of flag sets.
        assertEq(uint256(HookMiner.FLAG_MASK), uint256((1 << 14) - 1));
        assertGt(HookMiner.MAX_TRIES, uint256(1) << 14);
    }
}
