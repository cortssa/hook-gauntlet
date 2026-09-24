// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SimEngine} from "../../src/sim/SimEngine.sol";
import {SimLedger} from "../../src/sim/SimLedger.sol";
import {Intent, Fill} from "../../src/sim/ISimAgent.sol";

/// @notice A ledger file the project cannot write is named at ENGINE INIT, with the fix, not at the first write of the
/// last step with forge's generic "not allowed to be accessed for write operations". A binding in a project whose
/// foundry.toml has no `fs_permissions = [{ access = "read-write", path = "./census" }]` used to run its whole scenario
/// and then fail in `_finish` (2026-09-23, a blind run): `_initEngine` now probes the path once when `GAUNTLET_SIM` is
/// set and reverts `SimLedger.LedgerNotWritable(path)`, whose documentation is the line to add.
///
/// The path is given through `_ledgerPath()`, not by setting `GAUNTLET_SIM` here: forge runs tests in parallel in one
/// process, and an environment variable set by one test is seen by every other test that inits an engine. What this
/// file does not cover is the read of the variable itself (`vm.envOr("GAUNTLET_SIM", "")`, the default `_ledgerPath`).
contract EngineLedgerProbe is SimEngine {
    string internal path_;

    function _ledgerPath() internal view override returns (string memory) {
        return path_;
    }

    function init(string memory p) external {
        path_ = p;
        _initEngine();
    }

    function _quote(Intent memory it) internal pure override returns (uint256) {
        return it.amountIn;
    }

    function _execute(Intent memory) internal pure override returns (Fill memory f) {
        return f;
    }

    function _sqrtPriceNow(uint8) internal pure override returns (uint160) {
        return 0;
    }

    function _balances(address) internal pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function _referencePriceX96() internal pure override returns (uint256) {
        return 0;
    }

    function test_a_ledger_path_outside_the_permissions_is_named_at_init() public {
        // this module's foundry.toml lets a test write under ./census only: a path outside it is what a project with no
        // fs_permissions line sees for every path
        string memory p = "not-permitted/sim.tsv";
        vm.expectRevert(abi.encodeWithSelector(SimLedger.LedgerNotWritable.selector, p));
        this.init(p);
    }

    function test_a_writable_ledger_path_passes_and_the_probe_leaves_nothing() public {
        vm.createDir("census", true);
        string memory p = "census/ledger-probe-test.tsv";
        this.init(p);
        assertTrue(address(ledger) != address(0), "the engine did not init");
        assertFalse(vm.exists(string.concat(p, ".probe")), "the probe left its file behind");
        assertFalse(vm.exists(p), "the probe created the ledger file itself");
    }

    function test_no_ledger_path_no_probe() public {
        this.init("");
        assertTrue(address(ledger) != address(0), "the engine did not init without a ledger path");
    }
}
