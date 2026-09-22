// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @title HookMiner
/// @notice Finds a CREATE2 salt whose resulting address carries EXACTLY the hook flags you declare.
///
/// In v4 a hook's permissions are not stored anywhere: they are the low fourteen bits of the hook's own
/// address. The manager reads them off the address before every call. So deploying a hook is a search
/// problem, and the search has two ways to go wrong.
///
/// **Equality, not containment.** A hook whose address happens to carry a flag it does not implement will be
/// called where it does not expect to be called. The naive search - "keep going until the address has at
/// least the bits I want" - accepts exactly those addresses, because every extra bit is free. This library
/// matches `flags & ALL_HOOK_MASK` for equality and refuses anything else. That is the whole difference
/// between this file and a for-loop somebody writes in a hurry.
///
/// **A salt is only valid for one deployer, one creation code and one set of constructor arguments.** The
/// CREATE2 address is `keccak256(0xff, deployer, salt, keccak256(initcode))`. Change the hook by one
/// character, change a constructor argument, deploy from a different contract, and the salt you wrote down
/// yesterday now points at an address with the wrong bits - or at an address where the hook's own
/// `validateHookPermissions` will revert, if you were lucky. Mine in `setUp`, every run. Never hard-code a
/// salt from a previous run into a test, and never into anything else.
library HookMiner {
    /// @notice the fourteen bits the manager reads. Everything above them is free.
    uint160 internal constant FLAG_MASK = Hooks.ALL_HOOK_MASK;

    /// @notice how many salts to try before giving up. One address in 2^14 carries a given exact flag set,
    /// so the expected number of tries is 16 384 and the chance of 200 000 consecutive misses is
    /// `(1 - 2^-14)^200000 = e^-12.2`, about **5 in a million**. Not "astronomically unlikely" - that was
    /// the adjective this line used to carry, and an adjective is not a number. If you ever hit it, the
    /// overwhelmingly likely explanation is a flag set that no address can carry, not bad luck.
    ///
    /// What it costs, measured on this machine (forge 1.8.1, solc 0.8.26, the example hook's 5 322-byte
    /// initcode - the `.manager` row of `forge build --sizes`, which is the build a test that imports the manager hashes): 1 239 tries used 1 752 012 gas, so roughly 1 414 gas a try, and the 16 384-try average is
    /// about 23 million gas - well inside a test's block, and under a second of wall clock.
    uint256 internal constant MAX_TRIES = 200_000;

    /// @notice no salt was found. Loudly, and with the numbers, because the alternative is a test that
    /// silently deploys at address zero and then fails somewhere unrelated.
    error NoSaltFound(uint160 wantedFlags, uint256 tried);

    /// @notice the flag bits an address carries.
    function flagsOf(address who) internal pure returns (uint160) {
        return uint160(who) & FLAG_MASK;
    }

    /// @notice does `who` carry exactly `flags`, and nothing else?
    function carriesExactly(address who, uint160 flags) internal pure returns (bool) {
        return flagsOf(who) == (flags & FLAG_MASK);
    }

    /// @notice the CREATE2 address for `deployer`, `salt` and `initcode`.
    function computeAddress(address deployer, bytes32 salt, bytes memory initcode) internal pure returns (address) {
        return computeAddressFromInitcodeHash(deployer, salt, keccak256(initcode));
    }

    /// @notice the same, for a caller that already has the initcode's hash.
    /// @dev the loop in `find` uses this: the initcode does not change between tries, so hashing it once
    /// instead of 16 384 times is the difference between the search and the search plus a hash of the whole
    /// contract per candidate. The initcode is thousands of bytes; keccak costs 6 gas per word.
    function computeAddressFromInitcodeHash(address deployer, bytes32 salt, bytes32 initcodeHash)
        internal
        pure
        returns (address)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initcodeHash)))));
    }

    /// @notice search for a salt whose CREATE2 address carries exactly `flags`.
    /// @param deployer the contract that will run the CREATE2 - in a test, usually `address(this)`
    /// @param flags the permission bits the hook declares, OR-ed together from `Hooks.*_FLAG`. Anything
    ///        outside `FLAG_MASK` is dropped without a word: the fourteen low bits are the whole of what the
    ///        manager reads, so a bit above them is not a permission and cannot be mined for.
    /// @param creationCode `type(MyHook).creationCode`
    /// @param constructorArgs `abi.encode(...)`, exactly as the constructor takes them
    /// @return hookAddress the address the hook will land at
    /// @return salt the salt to pass as `new MyHook{salt: salt}(...)`
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        // hashed ONCE, outside the loop: the initcode is the same on every try.
        bytes32 initcodeHash = keccak256(bytes.concat(creationCode, constructorArgs));
        uint160 wanted = flags & FLAG_MASK;
        for (uint256 i = 0; i < MAX_TRIES; i++) {
            salt = bytes32(i);
            hookAddress = computeAddressFromInitcodeHash(deployer, salt, initcodeHash);
            // EXACT equality. `&` here instead of `==` is the bug this library exists to not have.
            if (flagsOf(hookAddress) == wanted) return (hookAddress, salt);
        }
        revert NoSaltFound(wanted, MAX_TRIES);
    }

    /// @notice the same search, but for an address that carries `flags` PLUS at least one bit it should not.
    /// This is not for deploying anything real. It is for the test that proves your hook, or the manager,
    /// refuses an address with the wrong permissions - a guard you cannot check without a way to build the
    /// wrong thing on purpose.
    function findWithExtraFlag(
        address deployer,
        uint160 flags,
        uint160 extraFlag,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal pure returns (address hookAddress, bytes32 salt) {
        return find(deployer, (flags & FLAG_MASK) | (extraFlag & FLAG_MASK), creationCode, constructorArgs);
    }
}
