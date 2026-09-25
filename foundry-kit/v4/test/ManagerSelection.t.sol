// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {V4Harness} from "../src/V4Harness.sol";

/// @notice Tests of the harness's own decision: which manager, and what to do when the fixture is not there.
///
/// These call `managerPlanFor` with explicit arguments instead of reading the environment, so that they mean
/// the same thing whether or not the person running them has `V4_MANAGER` set.
contract ManagerSelectionTest is V4Harness {
    function setUp() public {
        // deliberately NOT _setUpManager(): this contract is about the decision, not about the manager.
    }

    function test_source_is_the_mode_you_get_when_you_ask_for_it_by_name() public {
        assertEq(uint256(managerPlanFor("source", DEFAULT_FIXTURE)), uint256(ManagerPlan.SOURCE));
    }

    /// @notice THE OTHER HALF OF THE GUARD, and the one this file used to assert the opposite of. It read
    /// `managerPlanFor("anything else", ...) == SOURCE` and called that the documented behaviour, so
    /// `V4_MANAGER=fixtrue` ran the whole suite against a source build and printed "compiled from source,
    /// 5 passed" - the silent fallback the skip exists to prevent, reached by one transposed letter.
    ///
    /// An unrecognised mode is a typo, not a default. Two words, and everything else is loud.
    function test_a_typo_in_the_mode_reverts_instead_of_quietly_meaning_source() public {
        vm.expectRevert(abi.encodeWithSelector(V4Harness.UnknownManagerMode.selector, "fixtrue"));
        this.planFor("fixtrue", DEFAULT_FIXTURE);

        vm.expectRevert(abi.encodeWithSelector(V4Harness.UnknownManagerMode.selector, "FIXTURE"));
        this.planFor("FIXTURE", DEFAULT_FIXTURE); // the case matters too

        vm.expectRevert(abi.encodeWithSelector(V4Harness.UnknownManagerMode.selector, ""));
        this.planFor("", DEFAULT_FIXTURE); // V4_MANAGER= is not "unset", it is empty

        vm.expectRevert(abi.encodeWithSelector(V4Harness.UnknownManagerMode.selector, "anything else"));
        this.planFor("anything else", DEFAULT_FIXTURE);
    }

    /// @dev one frame down, so `expectRevert` sees the call and not this contract's own.
    function planFor(string memory mode, string memory fixturePath) external returns (ManagerPlan) {
        return managerPlanFor(mode, fixturePath);
    }

    /// @notice THE GUARD. `V4_MANAGER=fixture` with no fixture on disk must NOT quietly become "source".
    ///
    /// This is the one test in the file that is worth its weight. The failure it prevents is not a crash, it
    /// is a green run: somebody asks for the real manager, the file is not there, the suite runs against the
    /// source build and reports success, and everyone downstream believes the real bytecode was tested.
    function test_missing_fixture_is_a_skip_and_never_a_silent_fallback_to_source() public {
        uint256 plan = uint256(managerPlanFor("fixture", "fixtures/there-is-no-such-file.hex"));
        assertEq(plan, uint256(ManagerPlan.SKIP_FIXTURE_MISSING), "a missing fixture must skip");
        assertTrue(plan != uint256(ManagerPlan.SOURCE), "a missing fixture must never fall back to source");
    }

    /// @notice half an installation is not an installation. The hex without its json has no address, and
    /// code etched at the wrong address is a different contract.
    function test_hex_without_its_metadata_is_also_a_skip() public {
        // fixtures/README.md is committed and has no fixtures/README.json next to it, so it is a real file
        // on disk standing in for a half-fetched fixture. No writing required.
        assertTrue(vm.isFile("fixtures/README.md"), "the fixtures README should be committed");
        assertEq(
            uint256(managerPlanFor("fixture", "fixtures/README.md")),
            uint256(ManagerPlan.SKIP_FIXTURE_MISSING),
            "a fixture with no metadata must skip"
        );
    }

    function test_metadata_path_is_the_hex_path_with_json_on_it() public pure {
        assertEq(_metaPathOf("fixtures/PoolManager.hex"), "fixtures/PoolManager.json");
        assertEq(_metaPathOf("fixtures/a.hex"), "fixtures/a.json");
        // anything that is not a .hex keeps its name and gains .json, rather than losing four characters
        assertEq(_metaPathOf("fixtures/README.md"), "fixtures/README.md.json");
        assertEq(_metaPathOf("x"), "x.json");
    }

    function test_trim_removes_the_line_endings_a_windows_editor_leaves() public pure {
        assertEq(_trim("0x1234\r"), "0x1234");
        assertEq(_trim("0x1234\n"), "0x1234");
        assertEq(_trim("0x1234  \r\n"), "0x1234");
        assertEq(_trim("0x1234"), "0x1234");
        assertEq(_trim(""), "");
    }

    function test_the_label_says_which_manager_ran() public {
        managerPlan = ManagerPlan.SOURCE;
        assertEq(managerModeLabel(), "compiled from source (lib/v4-core)");
        managerPlan = ManagerPlan.FIXTURE;
        assertEq(managerModeLabel(), "real bytecode (etched fixture)");
        managerPlan = ManagerPlan.SKIP_FIXTURE_MISSING;
        assertEq(managerModeLabel(), "skipped (fixture missing)");
        managerPlan = ManagerPlan.FORK;
        assertEq(managerModeLabel(), "mainnet fork (the deployed manager, its storage, at a pinned block)");
        managerPlan = ManagerPlan.SKIP_FORK_NO_RPC;
        assertEq(managerModeLabel(), "skipped (fork asked for, RPC_URL not set)");
    }

    // ------------------------------------------------------------------ the third mode (K16)
    /// @notice `fork` is the third word, and asking for it with an endpoint is the fork.
    function test_fork_with_an_endpoint_is_the_fork() public {
        assertEq(uint256(managerPlanFor("fork", DEFAULT_FIXTURE, true)), uint256(ManagerPlan.FORK));
    }

    /// @notice THE FORK'S GUARD, the same one the fixture has. `V4_MANAGER=fork` with no `RPC_URL` must skip; it must
    /// never become a green run against the source build, and never a fork of some default endpoint either.
    function test_fork_without_an_endpoint_is_a_skip_and_never_a_silent_fallback_to_source() public {
        uint256 plan = uint256(managerPlanFor("fork", DEFAULT_FIXTURE, false));
        assertEq(plan, uint256(ManagerPlan.SKIP_FORK_NO_RPC), "no endpoint must skip");
        assertTrue(plan != uint256(ManagerPlan.SOURCE), "no endpoint must never fall back to source");
    }

    /// @notice the endpoint decides nothing for the other two modes: `source` never forks because RPC_URL happens to be
    /// exported, and `fixture` still needs its files
    function test_an_endpoint_in_the_environment_changes_neither_source_nor_fixture() public {
        assertEq(uint256(managerPlanFor("source", DEFAULT_FIXTURE, true)), uint256(ManagerPlan.SOURCE));
        assertEq(
            uint256(managerPlanFor("fixture", "fixtures/there-is-no-such-file.hex", true)),
            uint256(ManagerPlan.SKIP_FIXTURE_MISSING)
        );
    }

    /// @notice three words now, and still nothing else
    function test_a_typo_of_fork_reverts_too() public {
        vm.expectRevert(abi.encodeWithSelector(V4Harness.UnknownManagerMode.selector, "FORK"));
        this.planFor3("FORK", DEFAULT_FIXTURE, true);
        vm.expectRevert(abi.encodeWithSelector(V4Harness.UnknownManagerMode.selector, "forked"));
        this.planFor3("forked", DEFAULT_FIXTURE, true);
    }

    function planFor3(string memory mode, string memory fixturePath, bool rpcSet) external returns (ManagerPlan) {
        return managerPlanFor(mode, fixturePath, rpcSet);
    }

    /// @notice the block is a constant, so that two runs a week apart read the same chain. A test, because a pin that
    /// somebody sets to 0 ("latest") in passing turns every number in the README into a number nobody can reproduce.
    function test_the_fork_block_is_pinned_and_not_latest() public pure {
        assertGt(DEFAULT_FORK_BLOCK, 21_688_329, "before the mainnet PoolManager existed (its deployment block)");
        assertEq(DEFAULT_FORK_BLOCK, 26_050_000, "the pin moved: move the README's fork numbers with it");
    }
}

/// @notice The harness actually wired up, whichever manager the environment asked for. Under the default it
/// builds one from source; under `V4_MANAGER=fixture` it etches the fetched one, or skips loudly.
contract ManagerIsUsableTest is V4Harness {
    function setUp() public {
        _setUpV4();
    }

    function test_the_manager_under_test_is_a_real_contract_and_says_which_one_it_is() public view {
        assertTrue(address(manager) != address(0), "no manager");
        assertGt(address(manager).code.length, 20_000, "that is not a PoolManager");
        assertEq(address(manager).code.length, managerRuntimeSize, "the recorded size is not the real one");
        console2.log("this run tested:", managerModeLabel());
        if (managerPlan == ManagerPlan.FIXTURE) {
            assertEq(address(manager), managerFixtureAddress, "etched somewhere other than its own address");
            assertEq(keccak256(address(manager).code), managerFixtureCodeHash, "etched code is not the fetched code");
            assertGt(managerFixtureChainId, 0, "a fixture with no chain id is a fixture from nowhere");
        }
    }
}
