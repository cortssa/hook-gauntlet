// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BacktestBase, BacktestFixture, RealSwap} from "../../src/BacktestBase.sol";
import {CappedDynamicFeeHook} from "../../src/examples/CappedDynamicFeeHook.sol";
import {DeltaFeeHook} from "../../src/examples/DeltaFeeHook.sol";
import {InRangeDonateHook} from "../../src/examples/InRangeDonateHook.sol";

/// @notice The kit's own backtest (K19): the three example hooks that take fees, replayed through 200 blocks of the chain's
/// ETH / USDC 0.05 % v4 pool (no hook, spacing 10) ending at the harness's pinned block 26 050 000 - the state at the end of
/// block 26 049 800, the swaps of blocks 26 049 801 .. 26 050 000. The fixture is committed (public event data, pinned to
/// its blocks): `.gauntlet/backtests/21c67e77-26049800-26050000.tsv` and its `.json`. A sandbox report, not a proof: what
/// this replay substitutes is in `BacktestBase` and `doctrine/SIMULATE.md`, "Backtests". Run it through
/// `scripts/backtest.sh foundry-kit/v4 --pool 0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27 --from
/// 26049800 --to 26050000`, which writes the report; the fork battery runs it as a test.
abstract contract KitBacktest is BacktestBase {
    /// @notice the kit's committed window - the only one whose fidelity was measured: the chain's ETH / USDC 0.05 % pool,
    /// the state at the end of block 26 049 800, the swaps of blocks 26 049 801 .. 26 050 000
    bytes32 internal constant KIT_POOL = 0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27;
    uint256 internal constant KIT_FROM = 26049800;
    uint256 internal constant KIT_TO = 26050000;
    /// @notice how far the control may drift from the real prices on THAT window (measured: 1)
    uint256 internal constant KIT_CONTROL_MAX_DEV_PPM = 10;

    function _defaultFixture() internal pure override returns (string memory) {
        return ".gauntlet/backtests/21c67e77-26049800-26050000.tsv";
    }

    /// @notice the replay's fidelity on the COMMITTED window only, held: with no hook, every post-swap price within 10 ppm
    /// of the real pool's (measured: 1 at most; the window's real liquidity does change inside 7 swaps - a tick, JIT of
    /// 0.124 % - and the single-position substitution hides it at that cost), and every swap replayed. A replay that
    /// swapped the wrong way, the wrong amount or the wrong kind (exact-out) fails here. On any other window (the one in the
    /// sidecar of `BACKTEST_FIXTURE`, read by `setUp`) nothing is asserted - the bound was measured on one window, and a
    /// window that crosses ticks where the real liquidity changes drifts by more (measured, K19b: 131 ppm over the 500
    /// blocks before it) - and the report's "control's fidelity" line says so.
    function _checkControl(Totals memory t) internal view override {
        if (window.poolId != KIT_POOL || window.from != KIT_FROM || window.to != KIT_TO) {
            _fidelity(
                string.concat(
                    "NOT asserted: this window (",
                    vm.toString(window.from),
                    " .. ",
                    vm.toString(window.to),
                    ") is not the kit's committed one (pool 0x21c67e77, 26049800 .. 26050000), where the ",
                    vm.toString(KIT_CONTROL_MAX_DEV_PPM),
                    " ppm bound was measured; the control drifted ",
                    vm.toString(t.maxAbsDevPpm),
                    " ppm here, the replay's own, and nothing holds it"
                )
            );
            return;
        }
        assertEq(t.replayed, t.swaps, "control: a swap of the committed window was not replayed");
        assertLe(t.maxAbsDevPpm, KIT_CONTROL_MAX_DEV_PPM, "control: the replay drifted from the real prices on the committed window");
        _fidelity(
            string.concat(
                "asserted: every swap replayed and every post-swap price within ",
                vm.toString(KIT_CONTROL_MAX_DEV_PPM),
                " ppm of the real pool's (the kit's committed window; ",
                vm.toString(t.maxAbsDevPpm),
                " here)"
            )
        );
    }
}

contract CappedDynamicFeeHookBacktest is KitBacktest {
    CappedDynamicFeeHook internal hook;

    function _backtestName() internal pure override returns (string memory) {
        return "CappedDynamicFeeHook";
    }

    function _deployBacktestHook() internal override returns (address) {
        hook = CappedDynamicFeeHook(
            _deployHook(
                type(CappedDynamicFeeHook).creationCode, abi.encode(manager), Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
            )
        );
        return address(hook);
    }

    /// @notice the hook refuses a pool with a static fee (its defence f): the key carries the dynamic-fee flag, and the
    /// hook sets the fee - a substitution the report names (the real pool's LP fee is 500)
    function _backtestFee(uint24) internal pure override returns (uint24) {
        return LPFeeLibrary.DYNAMIC_FEE_FLAG;
    }

    function _hookNotes(PoolKey memory key, address) internal view override {
        _note(string.concat("fee quoted for the next block: ", vm.toString(uint256(hook.quoteNextFee(key)))));
    }

    /// @notice the replay's measurement held to the hook's own rule, recomputed from the fixture: every swap of a block pays
    /// `BASE_FEE + STEP x` the swaps the pool saw in the block just before it (capped), so the fees the manager applied range
    /// exactly over what the real blocks say - and the hook takes and returns nothing. (The new pool's protocol fee is 0 on
    /// this fork, the runs line says so; the swap fee is then the LP fee.) A replay that did not roll the block, or rolled
    /// it wrong, fails here.
    function _checkBacktest(Totals memory t) internal view override {
        uint256 lo = type(uint256).max;
        uint256 hi = 0;
        for (uint256 i = 0; i < realSwaps.length; i++) {
            uint256 prev = 0;
            for (uint256 j = 0; j < i; j++) {
                if (realSwaps[j].blockNumber + 1 == realSwaps[i].blockNumber) prev++;
            }
            uint256 fee = hook.feeForCongestion(uint32(prev));
            if (fee < lo) lo = fee;
            if (fee > hi) hi = fee;
        }
        assertEq(uint256(t.feeMin), lo, "the lowest fee applied is not the lowest the real blocks call for");
        assertEq(uint256(t.feeMax), hi, "the highest fee applied is not the highest the real blocks call for");
        assertEq(t.took0 + t.took1 + t.returned0 + t.returned1 + t.donated0 + t.donated1, 0, "a fee hook with no delta moved value");
    }
}

contract DeltaFeeHookBacktest is KitBacktest {
    DeltaFeeHook internal hook;

    function _backtestName() internal pure override returns (string memory) {
        return "DeltaFeeHook";
    }

    function _deployBacktestHook() internal override returns (address) {
        hook = DeltaFeeHook(
            _deployHook(
                type(DeltaFeeHook).creationCode,
                abi.encode(manager),
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                    | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            )
        );
        return address(hook);
    }

    function _hookNotes(PoolKey memory key, address) internal view override {
        Currency[2] memory cs = [key.currency0, key.currency1];
        for (uint256 j = 0; j < 2; j++) {
            _note(
                string.concat(
                    "currency",
                    vm.toString(j),
                    ": feesBooked ",
                    vm.toString(hook.feesBooked(cs[j])),
                    ", rebatesPaid ",
                    vm.toString(hook.rebatesPaid(cs[j])),
                    ", reserveOf ",
                    vm.toString(hook.reserveOf(cs[j])),
                    ", held ",
                    vm.toString(_trueBalance(cs[j], address(hook)))
                )
            );
            // its P4 over the real window: rebates never exceed fees, and the ledger is backed
            assertLe(hook.rebatesPaid(cs[j]), hook.feesBooked(cs[j]), "P4: rebates > fees over the window");
            assertLe(hook.reserveOf(cs[j]), _trueBalance(cs[j], address(hook)), "P4: the ledger is not backed");
        }
    }

    /// @notice the replay's measurement - read off the manager's Swap event and the router's delta - against the hook's own
    /// ledger: what it took is what it booked, what it returned is what it paid in rebates, per currency
    function _checkBacktest(Totals memory t) internal view override {
        assertEq(t.took0, hook.feesBooked(window.key.currency0), "took0 != feesBooked");
        assertEq(t.took1, hook.feesBooked(window.key.currency1), "took1 != feesBooked");
        assertEq(t.returned0, hook.rebatesPaid(window.key.currency0), "returned0 != rebatesPaid");
        assertEq(t.returned1, hook.rebatesPaid(window.key.currency1), "returned1 != rebatesPaid");
        assertGt(t.took0 + t.took1, 0, "the fee hook took nothing over a window of real swaps");
    }
}

contract InRangeDonateHookBacktest is KitBacktest {
    using PoolIdLibrary for PoolKey;

    InRangeDonateHook internal hook;
    address internal treasury = address(0x7EA5);

    function _backtestName() internal pure override returns (string memory) {
        return "InRangeDonateHook";
    }

    function _deployBacktestHook() internal override returns (address) {
        hook = InRangeDonateHook(
            _deployHook(
                type(InRangeDonateHook).creationCode,
                abi.encode(manager, treasury),
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                    | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            )
        );
        return address(hook);
    }

    function _hookNotes(PoolKey memory key, address) internal view override {
        (uint256 pot0, uint256 pot1) = hook.potOf(key.toId());
        uint256[2] memory pot = [pot0, pot1];
        Currency[2] memory cs = [key.currency0, key.currency1];
        for (uint256 j = 0; j < 2; j++) {
            _note(
                string.concat(
                    "currency",
                    vm.toString(j),
                    ": feesTaken ",
                    vm.toString(hook.feesTaken(cs[j])),
                    ", donated ",
                    vm.toString(hook.donated(cs[j])),
                    ", pot left ",
                    vm.toString(pot[j]),
                    ", unowned ",
                    vm.toString(hook.unownedTotal(cs[j]))
                )
            );
            // D1 over the real window: every fee taken is donated, still in the pot, or unowned
            assertEq(
                hook.feesTaken(cs[j]), hook.donated(cs[j]) + pot[j] + hook.unownedTotal(cs[j]), "D1: a fee is unaccounted for"
            );
        }
    }

    /// @notice the replay's measurement against the hook's own ledger: what it took is its fees, what the manager's Donate
    /// events paid out is what it says it donated, per currency
    function _checkBacktest(Totals memory t) internal view override {
        assertEq(t.took0, hook.feesTaken(window.key.currency0), "took0 != feesTaken");
        assertEq(t.took1, hook.feesTaken(window.key.currency1), "took1 != feesTaken");
        assertEq(t.donated0, hook.donated(window.key.currency0), "donated0 != donated");
        assertEq(t.donated1, hook.donated(window.key.currency1), "donated1 != donated");
        assertEq(t.returned0 + t.returned1, 0, "a hook that only takes returned something");
        assertGt(t.donated0 + t.donated1, 0, "nothing was paid out over a window of real swaps");
    }
}

/// @notice The fixture's format, without a fork (it needs no endpoint): what `BacktestFixture` refuses, by name, and the
/// committed fixture read back - its sidecar's hash, its count, its key hashing to the chain's ETH / USDC 0.05 % pool id.
contract BacktestFixtureFormatTest is Test {
    string internal constant GOOD =
        "26049804\t1790282963\t198\t474\t0x23617e59a5925b2a4bf75d73ff6711cd0b29de85\t29154854076950637\t-78448606\t4108496466221074272367801\t171357403690873183\t-197351\t625";

    function parse(string memory line) external pure returns (RealSwap memory) {
        return BacktestFixture.parseLine(line, 3);
    }

    function readBoth(string memory path) external returns (uint256 n, bytes32 id) {
        BacktestFixture.Window memory w = BacktestFixture.readWindow(path);
        RealSwap[] memory s = BacktestFixture.readSwaps(path, w);
        return (s.length, w.poolId);
    }

    function test_a_line_is_read_column_by_column() public view {
        RealSwap memory s = this.parse(GOOD);
        assertEq(s.blockNumber, 26049804);
        assertEq(s.timestamp, 1790282963);
        assertEq(s.txIndex, 198);
        assertEq(s.logIndex, 474);
        assertEq(s.sender, 0x23617e59A5925b2A4Bf75d73ff6711cD0b29De85);
        assertEq(s.amount0, 29154854076950637);
        assertEq(s.amount1, -78448606);
        assertEq(uint256(s.sqrtPriceX96), 4108496466221074272367801);
        assertEq(uint256(s.liquidity), 171357403690873183);
        assertEq(int256(s.tick), -197351);
        assertEq(uint256(s.fee), 625);
    }

    function test_a_line_that_is_not_the_format_is_refused_never_read_as_zero() public view {
        string[6] memory bad = [
            // ten columns: the fee missing
            "26049804\t1790282963\t198\t474\t0x23617e59a5925b2a4bf75d73ff6711cd0b29de85\t29154854076950637\t-78448606\t4108496466221074272367801\t171357403690873183\t-197351",
            // an empty amount
            "26049804\t1790282963\t198\t474\t0x23617e59a5925b2a4bf75d73ff6711cd0b29de85\t\t-78448606\t4108496466221074272367801\t171357403690873183\t-197351\t625",
            // hex where a decimal goes
            "26049804\t1790282963\t198\t474\t0x23617e59a5925b2a4bf75d73ff6711cd0b29de85\t0x10\t-78448606\t4108496466221074272367801\t171357403690873183\t-197351\t625",
            // a word
            "26049804\tnone\t198\t474\t0x23617e59a5925b2a4bf75d73ff6711cd0b29de85\t29154854076950637\t-78448606\t4108496466221074272367801\t171357403690873183\t-197351\t625",
            // a short address
            "26049804\t1790282963\t198\t474\t0x23617e59\t29154854076950637\t-78448606\t4108496466221074272367801\t171357403690873183\t-197351\t625",
            // a tick out of range
            "26049804\t1790282963\t198\t474\t0x23617e59a5925b2a4bf75d73ff6711cd0b29de85\t29154854076950637\t-78448606\t4108496466221074272367801\t171357403690873183\t-900000\t625"
        ];
        for (uint256 i = 0; i < bad.length; i++) {
            try this.parse(bad[i]) returns (RealSwap memory) {
                revert(string.concat("a bad line was read: case ", vm.toString(i)));
            } catch (bytes memory err) {
                assertEq(bytes4(err), BacktestFixture.FixtureFormat.selector, string.concat("case ", vm.toString(i)));
            }
        }
    }

    function test_the_committed_fixture_reads_and_names_the_chains_eth_usdc_pool() public {
        (uint256 n, bytes32 id) = this.readBoth(".gauntlet/backtests/21c67e77-26049800-26050000.tsv");
        assertGt(n, 0, "no swap in the committed fixture");
        assertEq(id, 0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27);
        // the key the sidecar names IS that pool's: ETH, USDC, 0.05 %, spacing 10, no hook
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
        assertEq(keccak256(abi.encode(k)), id);
    }
}
