// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {V4Harness} from "../../src/V4Harness.sol";

/// @notice A block-pinned fixture, held to its word (K16). `scripts/fetch-bytecode.sh` writes the block it read the code
/// at into the fixture's metadata. This forks at THAT block and checks the claim: on the metadata's chain, at the
/// metadata's address, the code is the fixture's code, byte for byte (size and keccak). A fixture whose metadata names a
/// block where the code was different - or absent - fails here. Then it checks the same code is what the pinned fork
/// block runs: the fixture path and the fork path test the same manager.
///
/// Needs the fixture (`V4_FIXTURE`, default `fixtures/PoolManager.hex`) AND the fork; skipped with the reason otherwise.
contract FixtureBlockTest is V4Harness {
    string internal fixturePath;
    string internal meta;

    function setUp() public {
        fixturePath = vm.envOr("V4_FIXTURE", DEFAULT_FIXTURE);
        if (!vm.isFile(fixturePath) || !vm.isFile(_metaPathOf(fixturePath))) {
            vm.skip(
                true,
                string.concat(
                    "no fixture at ",
                    fixturePath,
                    ": NOTHING WAS TESTED. RPC_URL=... scripts/fetch-bytecode.sh --block <n> <manager> ",
                    fixturePath
                )
            );
            return;
        }
        _setUpV4OnFork();
        meta = vm.readFile(_metaPathOf(fixturePath));
    }

    function test_the_fixture_is_the_code_at_the_block_its_metadata_names() public {
        bytes memory code = vm.parseBytes(_trim(vm.readLine(fixturePath)));
        require(vm.keyExistsJson(meta, ".block"), "the fixture's metadata names no block: re-fetch it");
        uint256 fixtureBlock = vm.parseJsonUint(meta, ".block");
        address at = vm.parseJsonAddress(meta, ".address");
        uint256 chainId = vm.parseJsonUint(meta, ".chainId");
        bytes32 hash = vm.parseJsonBytes32(meta, ".codeHash");
        console2.log("fixture block", fixtureBlock);
        console2.log("pinned fork block", forkBlock);

        assertEq(keccak256(code), hash, "the fixture's own hash does not match its code");
        vm.rollFork(fixtureBlock);
        assertEq(block.number, fixtureBlock, "the fork did not move to the fixture's block");
        assertEq(block.chainid, chainId, "the fixture is from another chain than the fork");
        assertEq(at.code.length, code.length, "at the fixture's block, the code at its address has another size");
        assertEq(keccak256(at.code), hash, "at the fixture's block, the code at its address is not the fixture");
    }

    /// @notice the fixture path and the fork path are the same manager: the pinned block runs the fixture's code
    function test_the_pinned_fork_runs_the_fixture_code() public view {
        assertEq(address(manager), vm.parseJsonAddress(meta, ".address"), "the fixture names another address");
        assertEq(keccak256(address(manager).code), vm.parseJsonBytes32(meta, ".codeHash"), "fork code != fixture code");
    }
}
