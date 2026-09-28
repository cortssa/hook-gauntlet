// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {V4Harness} from "./V4Harness.sol";

/// @notice one `Swap` event of the real pool, as `scripts/backtest.sh` wrote it into the fixture (one line of the .tsv)
struct RealSwap {
    uint256 blockNumber;
    uint256 timestamp;
    uint256 txIndex;
    uint256 logIndex;
    address sender;
    int256 amount0;
    int256 amount1;
    uint160 sqrtPriceX96;
    uint128 liquidity;
    int24 tick;
    uint24 fee;
}

/// @title BacktestFixture
/// @notice Reads the two files `scripts/backtest.sh` writes (K19): `<id8>-<from>-<to>.tsv`, the real pool's `Swap` events
/// of blocks `from+1 .. to`, one per line, in chain order; and its `.json` sidecar - the pool's key, the window, the number
/// of lines and the SHA-256 of the .tsv. Everything that does not match is refused by name, never read as a zero: a line
/// with a missing column, a column that is not a number, a count or a hash the sidecar does not name.
library BacktestFixture {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string internal constant HEADER = "# hook-gauntlet backtest fixture 1";
    string internal constant COLUMNS =
        "block\ttimestamp\ttxIndex\tlogIndex\tsender\tamount0\tamount1\tsqrtPriceX96\tliquidity\ttick\tfee";

    /// @notice line `line` (1 = the first line of the file) is not what the format says: `why`
    error FixtureFormat(uint256 line, string why);
    /// @notice the .tsv and its sidecar disagree (`what`): a fixture edited, truncated or paired with another's sidecar
    error FixtureDoesNotMatchItsSidecar(string what);
    /// @notice the key in the sidecar does not hash to the pool id it names
    error NotThePoolsKey(bytes32 poolId, bytes32 keyHash);

    struct Window {
        bytes32 poolId;
        PoolKey key;
        uint256 from;
        uint256 to;
        uint256 swaps;
    }

    function _startsWith(string memory s, string memory prefix) private pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(prefix);
        if (a.length < b.length) return false;
        for (uint256 i = 0; i < b.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    function _isDecimal(string memory s, bool signed) private pure returns (bool) {
        bytes memory b = bytes(s);
        uint256 i = 0;
        if (signed && b.length > 0 && b[0] == "-") i = 1;
        if (b.length == i) return false;
        for (; i < b.length; i++) {
            if (b[i] < "0" || b[i] > "9") return false;
        }
        return true;
    }

    function _uint(string memory s, uint256 line, string memory column) private pure returns (uint256) {
        if (!_isDecimal(s, false)) revert FixtureFormat(line, string.concat(column, " is not a decimal number: '", s, "'"));
        return vm.parseUint(s);
    }

    function _int(string memory s, uint256 line, string memory column) private pure returns (int256) {
        if (!_isDecimal(s, true)) revert FixtureFormat(line, string.concat(column, " is not a decimal number: '", s, "'"));
        return vm.parseInt(s);
    }

    /// @notice one data line of the .tsv: eleven tab-separated columns, in the order of `COLUMNS`
    function parseLine(string memory text, uint256 line) internal pure returns (RealSwap memory s) {
        string[] memory f = vm.split(text, "\t");
        if (f.length != 11) revert FixtureFormat(line, string.concat("11 columns expected, found ", vm.toString(f.length)));
        s.blockNumber = _uint(f[0], line, "block");
        s.timestamp = _uint(f[1], line, "timestamp");
        s.txIndex = _uint(f[2], line, "txIndex");
        s.logIndex = _uint(f[3], line, "logIndex");
        bytes memory a = bytes(f[4]);
        if (a.length != 42 || a[0] != "0" || a[1] != "x") revert FixtureFormat(line, "sender is not an 0x address");
        s.sender = vm.parseAddress(f[4]);
        s.amount0 = _int(f[5], line, "amount0");
        s.amount1 = _int(f[6], line, "amount1");
        uint256 p = _uint(f[7], line, "sqrtPriceX96");
        if (p > type(uint160).max) revert FixtureFormat(line, "sqrtPriceX96 does not fit 160 bits");
        s.sqrtPriceX96 = uint160(p);
        uint256 l = _uint(f[8], line, "liquidity");
        if (l > type(uint128).max) revert FixtureFormat(line, "liquidity does not fit 128 bits");
        s.liquidity = uint128(l);
        int256 t = _int(f[9], line, "tick");
        if (t < TickMath.MIN_TICK || t > TickMath.MAX_TICK) revert FixtureFormat(line, "tick out of range");
        s.tick = int24(t);
        uint256 fee = _uint(f[10], line, "fee");
        if (fee > 1_000_000) revert FixtureFormat(line, "fee above 100 %");
        s.fee = uint24(fee);
    }

    /// @notice the sidecar of `tsvPath` (same stem, `.json`), checked against the .tsv's bytes and the key against the id
    function readWindow(string memory tsvPath) internal returns (Window memory w) {
        string memory jsonPath = _sidecarOf(tsvPath);
        if (!vm.isFile(jsonPath)) revert FixtureDoesNotMatchItsSidecar(string.concat("no sidecar at ", jsonPath));
        string memory j = vm.readFile(jsonPath);
        if (vm.parseJsonUint(j, ".format") != 1) revert FixtureDoesNotMatchItsSidecar("sidecar format is not 1");
        if (vm.parseJsonUint(j, ".chainId") != 1) revert FixtureDoesNotMatchItsSidecar("sidecar chainId is not 1 (mainnet)");
        bytes32 declared = vm.parseJsonBytes32(j, ".tsvSha256");
        if (sha256(vm.readFileBinary(tsvPath)) != declared) {
            revert FixtureDoesNotMatchItsSidecar("the .tsv's SHA-256 is not the one its sidecar names");
        }
        w.poolId = vm.parseJsonBytes32(j, ".poolId");
        w.key = PoolKey({
            currency0: Currency.wrap(vm.parseJsonAddress(j, ".currency0")),
            currency1: Currency.wrap(vm.parseJsonAddress(j, ".currency1")),
            fee: uint24(vm.parseJsonUint(j, ".fee")),
            tickSpacing: int24(vm.parseJsonInt(j, ".tickSpacing")),
            hooks: IHooks(vm.parseJsonAddress(j, ".hooks"))
        });
        bytes32 h = keccak256(abi.encode(w.key));
        if (h != w.poolId) revert NotThePoolsKey(w.poolId, h);
        w.from = vm.parseJsonUint(j, ".from");
        w.to = vm.parseJsonUint(j, ".to");
        w.swaps = vm.parseJsonUint(j, ".swaps");
        if (w.to <= w.from) revert FixtureDoesNotMatchItsSidecar("to is not after from");
    }

    /// @notice every data line of the .tsv, checked: the two header lines, eleven columns each, blocks inside the window and
    /// in chain order, and as many lines as the sidecar says
    function readSwaps(string memory tsvPath, Window memory w) internal view returns (RealSwap[] memory out) {
        string[] memory lines = vm.split(vm.readFile(tsvPath), "\n");
        if (lines.length < 2 || !_startsWith(lines[0], HEADER)) revert FixtureFormat(1, "not a hook-gauntlet backtest fixture 1");
        if (keccak256(bytes(lines[1])) != keccak256(bytes(COLUMNS))) revert FixtureFormat(2, "the column line is not the format's");
        uint256 n = 0;
        for (uint256 i = 2; i < lines.length; i++) {
            if (bytes(lines[i]).length > 0) n++;
        }
        if (n != w.swaps) {
            revert FixtureDoesNotMatchItsSidecar(
                string.concat("the .tsv has ", vm.toString(n), " swaps, the sidecar says ", vm.toString(w.swaps))
            );
        }
        out = new RealSwap[](n);
        uint256 k = 0;
        for (uint256 i = 2; i < lines.length; i++) {
            if (bytes(lines[i]).length == 0) continue;
            RealSwap memory s = parseLine(lines[i], i + 1);
            if (s.blockNumber <= w.from || s.blockNumber > w.to) revert FixtureFormat(i + 1, "block outside the window");
            if (k > 0) {
                RealSwap memory q = out[k - 1];
                bool after_ = s.blockNumber > q.blockNumber
                    || (s.blockNumber == q.blockNumber
                        && (s.txIndex > q.txIndex || (s.txIndex == q.txIndex && s.logIndex > q.logIndex)));
                if (!after_) revert FixtureFormat(i + 1, "not in chain order (block, txIndex, logIndex)");
            }
            out[k++] = s;
        }
    }

    function _sidecarOf(string memory tsvPath) internal pure returns (string memory) {
        bytes memory b = bytes(tsvPath);
        if (b.length > 4 && b[b.length - 4] == "." && b[b.length - 3] == "t" && b[b.length - 2] == "s" && b[b.length - 1] == "v") {
            bytes memory stem = new bytes(b.length - 4);
            for (uint256 i = 0; i < stem.length; i++) stem[i] = b[i];
            return string.concat(string(stem), ".json");
        }
        return string.concat(tsvPath, ".json");
    }
}

/// @title BacktestBase
/// @notice "What would THIS hook have done in this window of real swaps on this pool?" (K19). A sandbox report for the
/// dossier (section 6, the sandbox row; section 9, what it cannot say), NOT a proof: `doctrine/SIMULATE.md`, "Backtests".
///
/// What it does, on a mainnet fork at block `from` of a fixture `scripts/backtest.sh` wrote:
///  1. reads the REAL pool's price and in-range liquidity at the end of block `from` (StateLibrary);
///  2. deploys your hook (`_deployBacktestHook`), initialises a NEW pool with the real pool's currencies, fee and tick
///     spacing and your hook (a hook is part of a pool's key: it cannot be attached to the pool that exists), at that price,
///     and gives it ONE full-range position of exactly that liquidity;
///  3. drives every real swap of blocks `from+1 .. to` through the kit's router, in chain order, with `vm.roll` / `vm.warp`
///     to the swap's block and timestamp: EXACT-IN, of the amount the real swapper paid in, in the real direction, with no
///     price limit. A swap that reverts is recorded (the revert's selector), not fatal;
///  4. records per swap what the hook took (its delta, positive), returned (negative), paid out (`Donate` events on its
///     pool), the swap fee the manager applied, the gas of the router call, the post-swap price against the real pool's,
///     and whether the books closed (swapper + hook + manager == 0 in each currency, the swapper moved by what the router
///     was told);
///  5. does it all again, in a test of its own, on a CONTROL pool with no hook (same currencies and fee, tick spacing
///     doubled: the real pool's own key is taken), so that the report can say how much of a deviation is the replay's and
///     how much is the hook's. The base asserts only that no swap was lost, that the books closed and that the control
///     refused nothing; `_checkBacktest` and `_checkControl` are where a hook's own ledger and a window's fidelity are held.
/// Everything is printed as `BT|...` lines that `scripts/backtest.sh` turns into `.gauntlet/reports/07-backtest.txt`.
///
/// The substitutions, named (they are what this report is NOT): the LP set (one full-range position of the active
/// liquidity at `from`, where the real pool had many ranges, and whatever they added or removed in the window is absent);
/// the routers and the swap type (every swap exact-in, no limit, through `MinimalRouter`, one trader); the ORDER is the
/// chain's but the reactions are not - the real swaps were placed against the real pool's price, and a hook that moves
/// the price moves it under swaps that were never placed against it (arbitrage, MEV, the hook's own effect on later
/// swaps); the protocol fee is whatever the controller gives a new pool on the fork.
///
/// To use it on your hook: a contract `<YourHook>Backtest is BacktestBase` that overrides `_deployBacktestHook` (and
/// `_backtestFee` for a dynamic-fee hook), then `scripts/backtest.sh <proj> --pool <id> --from <b> --to <b> --hook
/// <YourHook>` (foundry-kit/v4/README.md, "Backtests").
abstract contract BacktestBase is V4Harness {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    BacktestFixture.Window internal window;
    RealSwap[] internal realSwaps;
    string internal fixturePath;

    address internal backtestLp = address(0xB7B7);
    address internal backtestTrader = address(0xB7A0);

    /// @notice per swap, what the replay saw
    struct Row {
        uint256 i;
        uint256 blockNumber;
        bool zeroForOne;
        uint256 amountIn;
        uint8 status; // 0 replayed, 1 refused (reverted), 2 unreplayable (the event names no input and no output)
        bytes4 reason;
        uint256 gas;
        int256 hook0;
        int256 hook1;
        uint256 donated0;
        uint256 donated1;
        uint24 swapFee;
        int256 devPpm;
        int256 outDevPpm;
        bool booksClosed;
    }

    struct Totals {
        uint256 swaps;
        uint256 replayed;
        uint256 refused;
        uint256 unreplayable;
        uint256 took0;
        uint256 took1;
        uint256 returned0;
        uint256 returned1;
        uint256 donated0;
        uint256 donated1;
        uint24 feeMin;
        uint24 feeMax;
        uint256 gasSum;
        uint256 gasMax;
        uint256 booksOpen;
        uint256 maxAbsDevPpm;
        uint256 lpFees0;
        uint256 lpFees1;
    }

    /// @notice the real pool is not initialised, or has nothing in range, at `from`
    error RealPoolEmptyAtFrom(bytes32 poolId, uint256 blockNumber);

    // ------------------------------------------------------------------ what a hook's backtest provides
    /// @notice deploy the hook under test on the fork (`_deployHook(type(H).creationCode, abi.encode(manager, ...), flags)`)
    function _deployBacktestHook() internal virtual returns (address hook);

    /// @notice its name in the report
    function _backtestName() internal view virtual returns (string memory);

    /// @notice the fee in the hook pool's key: the real pool's, unless the hook needs another (a dynamic-fee hook returns
    /// `LPFeeLibrary.DYNAMIC_FEE_FLAG` - a substitution the report names)
    function _backtestFee(uint24 realFee) internal view virtual returns (uint24) {
        return realFee;
    }

    /// @notice the fixture read when `BACKTEST_FIXTURE` is not set ("" = none: the suite skips, saying how to fetch one)
    function _defaultFixture() internal view virtual returns (string memory) {
        return "";
    }

    /// @notice extra `BT|note|...` lines from the hook's own ledger, after its replay (optional)
    function _hookNotes(PoolKey memory, address) internal virtual {}

    /// @notice assertions of your own over the totals (optional; the base asserts only that the replay is complete and
    /// that the books closed)
    function _checkBacktest(Totals memory) internal virtual {}

    /// @notice assertions of your own over the CONTROL's totals (optional): for a window you know, how far a replay with no
    /// hook may drift from the real prices - the replay's own fidelity, held
    function _checkControl(Totals memory) internal virtual {}

    // ------------------------------------------------------------------ set up: the fixture, then a fork AT `from`
    function setUp() public virtual {
        string memory mode = vm.envOr("V4_MANAGER", string("source"));
        if (keccak256(bytes(mode)) != keccak256("fork")) {
            vm.skip(
                true,
                string.concat(
                    "a backtest under V4_MANAGER=", mode, ": NOTHING WAS REPLAYED. It runs on a fork: FOUNDRY_PROFILE=fork V4_MANAGER=fork with RPC_URL exported"
                )
            );
            return;
        }
        fixturePath = vm.envOr("BACKTEST_FIXTURE", _defaultFixture());
        if (bytes(fixturePath).length == 0 || !vm.isFile(fixturePath)) {
            vm.skip(
                true,
                string.concat(
                    "no backtest fixture at '",
                    fixturePath,
                    "': NOTHING WAS REPLAYED. Fetch it: scripts/backtest.sh <proj> --pool <id> --from <block> --to <block> (needs RPC_URL)"
                )
            );
            return;
        }
        if (!vm.envExists("RPC_URL")) {
            vm.skip(
                true,
                "a backtest forks at its window's first block and RPC_URL is not set: NOTHING WAS REPLAYED. Export RPC_URL (an archive endpoint) in your own shell"
            );
            return;
        }
        window = BacktestFixture.readWindow(fixturePath);
        RealSwap[] memory s = BacktestFixture.readSwaps(fixturePath, window);
        for (uint256 i = 0; i < s.length; i++) {
            realSwaps.push(s[i]);
        }
        // the fork is at the window's first block, not at the harness's pin (FORK_BLOCK is not read here)
        vm.createSelectFork(FORK_RPC_ALIAS, window.from);
        managerPlan = ManagerPlan.FORK;
        forkBlock = window.from;
        _takeForkedManager();
        _printManager();
        _deployCurrencies();
        _deployRouters();
    }

    // ------------------------------------------------------------------ the replay: the hook, then a control, each its own test
    // (its own transaction: which storage is warm - and so the gas - does not depend on what the other run touched)
    /// @notice the window through a pool with the hook
    function test_backtest_replay_the_window_through_the_hook() public {
        (uint160 sqrtP, uint128 liq) = _seed();
        Totals memory t = _replay(_backtestName(), _deployBacktestHook(), _backtestFee(window.key.fee), window.key.tickSpacing, sqrtP, liq);
        // the replay is complete and its books closed: the only things the base asserts about a hook
        assertEq(t.replayed + t.refused + t.unreplayable, realSwaps.length, "a swap of the window was lost");
        assertEq(t.booksOpen, 0, "a replayed swap left the books open (swapper + hook + manager != 0)");
        _checkBacktest(t);
    }

    /// @notice the same window through a pool with NO hook: what the replay itself does to the numbers
    function test_backtest_replay_the_window_through_a_control_pool_with_no_hook() public {
        (uint160 sqrtP, uint128 liq) = _seed();
        Totals memory t =
            _replay(string.concat("control(", _backtestName(), ")"), address(0), window.key.fee, window.key.tickSpacing * 2, sqrtP, liq);
        assertEq(t.replayed + t.refused + t.unreplayable, realSwaps.length, "control: a swap of the window was lost");
        assertEq(t.booksOpen, 0, "control: a replayed swap left the books open");
        assertEq(t.refused, 0, "control: a swap reverted on a pool with no hook - the replay itself is broken");
        _checkControl(t);
    }

    /// @dev the real pool at `from` (logged), and the two actors funded
    function _seed() internal returns (uint160 sqrtP, uint128 liq) {
        PoolId realId = PoolId.wrap(window.poolId);
        int24 tick;
        uint24 protocolFee;
        uint24 lpFee;
        (sqrtP, tick, protocolFee, lpFee) = manager.getSlot0(realId);
        liq = manager.getLiquidity(realId);
        if (sqrtP == 0 || liq == 0) revert RealPoolEmptyAtFrom(window.poolId, window.from);
        console2.log(
            string.concat(
                "BT|window|",
                vm.toString(window.poolId),
                "|",
                vm.toString(window.from),
                "|",
                vm.toString(window.to),
                "|",
                vm.toString(realSwaps.length),
                "|",
                fixturePath
            )
        );
        console2.log(
            string.concat(
                "BT|seed|",
                vm.toString(uint256(sqrtP)),
                "|",
                vm.toString(int256(tick)),
                "|",
                vm.toString(uint256(liq)),
                "|",
                vm.toString(uint256(lpFee)),
                "|",
                vm.toString(uint256(protocolFee))
            )
        );
        _fundBoth(backtestLp);
        _fundBoth(backtestTrader);
    }

    function _fundBoth(address who) internal {
        Currency[2] memory cs = [window.key.currency0, window.key.currency1];
        for (uint256 j = 0; j < 2; j++) {
            // enough for any pool: 2^100 of the smallest unit (1.27e30); ETH by vm.deal, an ERC-20 by `deal`
            _fundReal(cs[j], who, 2 ** 100);
        }
    }

    function _replay(string memory name, address hook, uint24 fee, int24 spacing, uint160 sqrtP, uint128 liq)
        internal
        returns (Totals memory t)
    {
        PoolKey memory key = PoolKey({
            currency0: window.key.currency0,
            currency1: window.key.currency1,
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(hook)
        });
        // a control key the chain already has (a hookless pool of these currencies at this fee and spacing) is taken: the
        // next spacing up, said in the `BT|run` line
        while (hook == address(0)) {
            (uint160 taken,,,) = manager.getSlot0(key.toId());
            if (taken == 0) break;
            key.tickSpacing++;
        }
        spacing = key.tickSpacing;
        manager.initialize(key, sqrtP);
        _addFullRangeLiquidity(key, backtestLp, int256(uint256(liq)));
        (,, uint24 pf,) = manager.getSlot0(key.toId());
        console2.log(
            string.concat(
                "BT|run|",
                name,
                "|",
                vm.toString(hook),
                "|",
                vm.toString(uint256(fee)),
                "|",
                vm.toString(int256(spacing)),
                "|",
                vm.toString(uint256(pf)),
                "|",
                vm.toString(uint256(manager.getLiquidity(key.toId())))
            )
        );
        t.swaps = realSwaps.length;
        t.feeMin = type(uint24).max;
        for (uint256 i = 0; i < realSwaps.length; i++) {
            Row memory r = _replayOne(key, i);
            _add(t, r);
            _logRow(name, r);
        }
        if (t.replayed == 0) t.feeMin = 0;
        // what the one position earned as LP fees over the window: it is all the liquidity there is, from a growth of 0
        (uint256 g0, uint256 g1) = manager.getFeeGrowthGlobals(key.toId());
        t.lpFees0 = FullMath.mulDiv(g0, liq, 1 << 128);
        t.lpFees1 = FullMath.mulDiv(g1, liq, 1 << 128);
        _logTotals(name, t);
        if (hook != address(0)) _hookNotes(key, hook);
    }

    function _replayOne(PoolKey memory key, uint256 i) internal returns (Row memory r) {
        RealSwap memory s = realSwaps[i];
        r.i = i;
        r.blockNumber = s.blockNumber;
        vm.roll(s.blockNumber);
        vm.warp(s.timestamp);
        int256 specified;
        if (s.amount0 < 0 && s.amount1 > 0) {
            r.zeroForOne = true;
            specified = s.amount0;
        } else if (s.amount1 < 0 && s.amount0 > 0) {
            specified = s.amount1;
        } else {
            r.status = 2;
            return r;
        }
        r.amountIn = uint256(-specified);
        SwapParams memory p = SwapParams({
            zeroForOne: r.zeroForOne,
            amountSpecified: specified,
            sqrtPriceLimitX96: r.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        uint256 value = r.zeroForOne && key.currency0.isAddressZero() ? r.amountIn : 0;
        int256[8] memory pre = _booksSnapshot(key, backtestTrader);
        vm.recordLogs();
        uint256 g0 = gasleft();
        vm.prank(backtestTrader);
        try router.swap{value: value}(key, p, "") returns (BalanceDelta d) {
            r.gas = g0 - gasleft();
            _readSwap(r, key, vm.getRecordedLogs(), d, s);
            r.booksClosed = _booksClose(pre, _booksSnapshot(key, backtestTrader), d);
        } catch (bytes memory err) {
            r.gas = g0 - gasleft();
            vm.getRecordedLogs();
            r.status = 1;
            if (err.length >= 4) r.reason = bytes4(err);
        }
    }

    function _readSwap(Row memory r, PoolKey memory key, Vm.Log[] memory logs, BalanceDelta d, RealSwap memory s)
        internal
        pure
    {
        bytes32 id = PoolId.unwrap(key.toId());
        int128 pool0;
        int128 pool1;
        uint160 sqrtAfter;
        for (uint256 k = 0; k < logs.length; k++) {
            Vm.Log memory l = logs[k];
            if (l.topics.length < 2 || l.topics[1] != id) continue;
            if (l.topics[0] == IPoolManager.Swap.selector) {
                (pool0, pool1, sqrtAfter,,, r.swapFee) = abi.decode(l.data, (int128, int128, uint160, uint128, int24, uint24));
            } else if (l.topics[0] == IPoolManager.Donate.selector) {
                (uint256 a0, uint256 a1) = abi.decode(l.data, (uint256, uint256));
                r.donated0 += a0;
                r.donated1 += a1;
            }
        }
        r.hook0 = int256(pool0) - int256(d.amount0());
        r.hook1 = int256(pool1) - int256(d.amount1());
        r.devPpm = _priceDevPpm(sqrtAfter, s.sqrtPriceX96);
        int256 realOut = r.zeroForOne ? s.amount1 : s.amount0;
        int256 gotOut = r.zeroForOne ? int256(d.amount1()) : int256(d.amount0());
        r.outDevPpm = realOut == 0 ? int256(0) : (gotOut - realOut) * 1e6 / realOut;
    }

    /// @notice (replay price / real price - 1) in parts per million, from the two sqrt prices
    function _priceDevPpm(uint160 replay, uint160 real_) internal pure returns (int256) {
        if (replay == 0 || real_ == 0) return type(int256).max;
        uint256 r = FullMath.mulDiv(uint256(replay), 1e12, uint256(real_)); // sqrt ratio x 1e12
        uint256 pr = FullMath.mulDiv(r, r, 1e12); // price ratio x 1e12
        return (int256(pr) - 1e12) / 1e6;
    }

    function _booksClose(int256[8] memory pre, int256[8] memory post, BalanceDelta d) internal pure returns (bool) {
        int256 s0 = post[0] - pre[0];
        int256 s1 = post[1] - pre[1];
        bool conserved0 = s0 + (post[2] - pre[2]) + (post[4] - pre[4]) == 0;
        bool conserved1 = s1 + (post[3] - pre[3]) + (post[5] - pre[5]) == 0;
        return conserved0 && conserved1 && s0 == int256(d.amount0()) && s1 == int256(d.amount1());
    }

    function _add(Totals memory t, Row memory r) internal pure {
        if (r.status == 1) {
            t.refused++;
            return;
        }
        if (r.status == 2) {
            t.unreplayable++;
            return;
        }
        t.replayed++;
        if (r.hook0 > 0) t.took0 += uint256(r.hook0);
        else t.returned0 += uint256(-r.hook0);
        if (r.hook1 > 0) t.took1 += uint256(r.hook1);
        else t.returned1 += uint256(-r.hook1);
        t.donated0 += r.donated0;
        t.donated1 += r.donated1;
        if (r.swapFee < t.feeMin) t.feeMin = r.swapFee;
        if (r.swapFee > t.feeMax) t.feeMax = r.swapFee;
        t.gasSum += r.gas;
        if (r.gas > t.gasMax) t.gasMax = r.gas;
        if (!r.booksClosed) t.booksOpen++;
        uint256 a = r.devPpm < 0 ? uint256(-r.devPpm) : uint256(r.devPpm);
        if (a > t.maxAbsDevPpm) t.maxAbsDevPpm = a;
    }

    function _logRow(string memory name, Row memory r) internal pure {
        string memory head = string.concat(
            "BT|swap|",
            name,
            "|",
            vm.toString(r.i),
            "|",
            vm.toString(r.blockNumber),
            "|",
            r.zeroForOne ? "0to1" : "1to0",
            "|",
            vm.toString(r.amountIn),
            "|",
            r.status == 0 ? "replayed" : (r.status == 1 ? "refused" : "unreplayable"),
            "|",
            r.status == 1 ? vm.toString(abi.encodePacked(r.reason)) : "-"
        );
        string memory mid = string.concat(
            "|",
            vm.toString(r.gas),
            "|",
            vm.toString(r.hook0),
            "|",
            vm.toString(r.hook1),
            "|",
            vm.toString(r.donated0),
            "|",
            vm.toString(r.donated1),
            "|",
            vm.toString(uint256(r.swapFee))
        );
        string memory tail = string.concat(
            "|", vm.toString(r.devPpm), "|", vm.toString(r.outDevPpm), "|", r.booksClosed ? "closed" : (r.status == 0 ? "OPEN" : "-")
        );
        console2.log(string.concat(head, mid, tail));
    }

    function _logTotals(string memory name, Totals memory t) internal pure {
        string memory a = string.concat(
            "BT|total|",
            name,
            "|",
            vm.toString(t.swaps),
            "|",
            vm.toString(t.replayed),
            "|",
            vm.toString(t.refused),
            "|",
            vm.toString(t.unreplayable),
            "|",
            vm.toString(t.took0),
            "|",
            vm.toString(t.took1),
            "|",
            vm.toString(t.returned0),
            "|",
            vm.toString(t.returned1)
        );
        string memory b = string.concat(
            "|",
            vm.toString(t.donated0),
            "|",
            vm.toString(t.donated1),
            "|",
            vm.toString(t.lpFees0),
            "|",
            vm.toString(t.lpFees1),
            "|",
            vm.toString(uint256(t.feeMin)),
            "|",
            vm.toString(uint256(t.feeMax)),
            "|",
            vm.toString(t.replayed == 0 ? 0 : t.gasSum / t.replayed),
            "|",
            vm.toString(t.gasMax),
            "|",
            vm.toString(t.booksOpen),
            "|",
            vm.toString(t.maxAbsDevPpm)
        );
        console2.log(string.concat(a, b));
    }

    /// @notice one `BT|note|<name>|<text>` line, for `_hookNotes`
    function _note(string memory text) internal view {
        console2.log(string.concat("BT|note|", _backtestName(), "|", text));
    }
}
