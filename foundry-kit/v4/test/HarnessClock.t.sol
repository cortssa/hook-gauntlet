// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
// Inside the kit: imports are relative. In your project: see scripts/setup-deps.sh's import lines.

import {V4Harness} from "../src/V4Harness.sol";

/// @notice The harness's clock (K46). forge starts a test at timestamp 1 and block 1; a hook that keys state on time then
/// reads 0 where it should have written a time, and "never set" looks like "set at the start": a hook
/// whose clock never started passes. The manager's set-up starts the clock at a realistic time, once.
contract HarnessClockTest is V4Harness {
    // the red-first copy of this file held these as literals (1_767_323_457, 24_137_911): red on the harness before K46
    uint256 internal constant T0 = V4_T0;
    uint256 internal constant B0 = V4_BLOCK0;

    function setUp() public {
        _setUpV4();
    }

    function test_setUp_starts_the_clock_at_V4_T0_and_V4_BLOCK0() public view {
        assertEq(block.timestamp, T0, "the clock did not start at V4_T0");
        assertEq(block.number, B0, "the block number did not start at V4_BLOCK0");
    }

    /// @notice not on a boundary a hook's epochs could line up with (a minute, an hour, a day, a week)
    function test_V4_T0_is_on_no_calendar_boundary() public pure {
        assertGt(T0 % 1 minutes, 0);
        assertGt(T0 % 1 hours, 0);
        assertGt(T0 % 1 days, 0);
        assertGt(T0 % 7 days, 0);
        assertGt(T0, 1_767_225_600, "before 2026-01-01"); // 2026-01-01 00:00:00 UTC
        assertLt(T0, 1_798_761_600, "after 2027-01-01");
    }

    /// @notice a suite that sets its own time keeps it: a warp after `setUp` wins
    function test_a_warp_after_setUp_wins() public {
        vm.warp(1_700_000_000);
        vm.roll(20_000_000);
        assertEq(block.timestamp, 1_700_000_000);
        assertEq(block.number, 20_000_000);
    }

    /// @notice once: a second manager set-up in the same test does not send a clock the test moved back to the start
    function test_a_second_set_up_does_not_move_the_clock() public {
        vm.warp(T0 + 7 days);
        vm.roll(B0 + 100);
        _setUpManager();
        assertEq(block.timestamp, T0 + 7 days, "the second set-up moved the clock");
        assertEq(block.number, B0 + 100, "the second set-up moved the block number");
    }
}
