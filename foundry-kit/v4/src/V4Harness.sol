// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {HostileERC20} from "gauntlet-kit/HostileERC20.sol";
import {MinimalRouter} from "./MinimalRouter.sol";
import {LiquidityHelper} from "./LiquidityHelper.sol";
import {SwapEventReader} from "./SwapEventReader.sol";
import {HookMiner} from "./HookMiner.sol";

/// @notice the one question the harness asks USDC (FiatToken v2.2) before funding an account
interface IUsdcBlocklist {
    function isBlacklisted(address account) external view returns (bool);
}

/// @title V4Harness
/// @notice The base a v4 hook's tests inherit from. It gives you a PoolManager, two hostile currencies, a
/// dumb router, a liquidity helper, and - the part that matters - a choice of WHICH manager.
///
/// ## The managers, and why more than one
///
/// **From source** (`V4_MANAGER=source`, the default). `new PoolManager(...)` out of `lib/v4-core`, at the
/// commit `scripts/install-v4.sh` pins. Fast, hermetic, debuggable, and it tests the manager you READ. It is
/// not necessarily the manager that exists on the chain you are aiming at: v4-core moves, chains were
/// deployed at different commits, and the compiler settings are ours, not theirs.
///
/// **Real bytecode** (`V4_MANAGER=fixture`). The runtime code of the manager that is actually deployed,
/// fetched with `scripts/fetch-bytecode.sh` and `vm.etch`-ed at the address it lives at. Etching at THAT
/// address and not another one is not cosmetic: `NoDelegateCall` bakes its own address into the code as an
/// immutable, so a manager etched somewhere else refuses every call that goes through it.
///
/// The suite says which one ran, on every run, in one line. If you cannot see that line in the output of a
/// result somebody hands you, you do not know what was tested.
///
/// ## When the fixture is missing
///
/// It SKIPS, loudly. It does not fall back to the source manager. A silent fallback is the worst outcome
/// available here, because the run is green, the log says nothing, and everyone believes the suite was run
/// against the real manager when it was not. `managerPlanFor()` is a plain function so that this decision
/// can itself be tested - see `test/ManagerSelection.t.sol`.
///
/// **A fork** (`V4_MANAGER=fork`, K16). Ethereum mainnet at a PINNED block (`DEFAULT_FORK_BLOCK`, overridable with
/// `FORK_BLOCK` - a block number in plain decimal, anything else a revert: `forkBlockFrom`), through the endpoint in `RPC_URL`, reached by the alias `mainnet` in `foundry.toml` - so that a trace
/// shows `createSelectFork("mainnet", ...)` and never the endpoint. The manager is the deployed one at its canonical
/// address, with its code AND its storage (owner, protocol-fee controller, every pool and every balance it holds), and
/// the real currencies are there to use: USDC, WETH, ETH (`_fundReal`). The harness's hostile tokens are still deployed,
/// so every suite that runs on `source` runs on the fork unchanged. Without `RPC_URL` it SKIPS, like the fixture.
///
/// And `V4_MANAGER` takes exactly three values. Anything else - `fixtrue`, `FIXTURE`, an empty string - is a
/// revert, not a default. A mode that falls back to "source" on anything it does not recognise is the same
/// silent fallback, reached by a typo instead of a missing file.
///
/// ## Two things it does to every hook suite (K46)
///
/// **The clock starts at a realistic time.** forge starts a test at timestamp 1 and block 1. A hook that keys state
/// on time (a start, epochs, windows) then reads 0 where it should have written a time, and a test cannot tell "never
/// set" from "set at the start": a hook whose clock never started passed a suite that way. So the manager's set-up
/// warps to `V4_T0` and rolls to `V4_BLOCK0`, once, before any hook exists. A warp after `setUp` wins. The fork keeps the
/// chain's own clock at its pinned block.
///
/// **The address's permission bits are held against the callbacks the hook implements.** `_deployHook` calls each of
/// the ten callbacks as the manager and fails, naming the callback, when one that does something has no bit on the
/// address: the manager never calls it, so its code is dead in production and alive only in a unit test that calls it
/// by hand. A bit set for a callback that reverts on the probe is a log line, not a failure. `_skipPermissionCheck` is
/// the escape for a suite that deploys a mis-flagged hook on purpose (`HostileHook` answers every callback), and for a
/// project's suites while that finding is open and recorded (doctrine/EVIDENCE.md section 2).
abstract contract V4Harness is Test {
    /// @notice what the harness decided to do about the manager, before doing it. (Appended to, never reordered: the
    /// numbers of the first three are what older logs and tests say.)
    enum ManagerPlan {
        SOURCE,
        FIXTURE,
        SKIP_FIXTURE_MISSING,
        FORK,
        SKIP_FORK_NO_RPC
    }

    /// @notice the default place `scripts/fetch-bytecode.sh` is told to write, and the only directory
    /// `foundry.toml` grants the suite permission to read.
    string internal constant DEFAULT_FIXTURE = "fixtures/PoolManager.hex";

    // ------------------------------------------------------------------ the fork (K16)
    /// @notice THE PIN. Every fork run reads the chain as it was at this block, so two runs a month apart read the same
    /// state, and forge's fork cache (`~/.foundry/cache/rpc/mainnet/<block>`) answers the second one from disk. Moving it
    /// is a decision: re-measure the README's fork numbers (`test/ManagerSelection.t.sol` holds it to this value).
    uint256 public constant DEFAULT_FORK_BLOCK = 26_050_000;
    /// @notice the `rpc_endpoints` alias in `foundry.toml`, which reads `RPC_URL`. The harness never reads the endpoint
    /// itself: a cheatcode's return value is printed in a trace, and the endpoint usually carries a key.
    string internal constant FORK_RPC_ALIAS = "mainnet";
    uint256 internal constant FORK_CHAIN_ID = 1;
    /// @notice Ethereum mainnet's v4 PoolManager. How the address was checked on the chain, not taken from a page:
    /// `test/fork/ForkManager.t.sol`, `test_the_address_is_the_v4_pool_manager_and_this_is_how_we_know`.
    address internal constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    /// @notice Circle's USDC (FiatToken proxy, 6 decimals; blocklist and pause) and WETH9, on mainnet
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    IPoolManager public manager;
    MinimalRouter public router;
    LiquidityHelper public liquidity;

    HostileERC20 public token0;
    HostileERC20 public token1;
    Currency public currency0;
    Currency public currency1;

    ManagerPlan public managerPlan;
    /// @notice set only on the fixture path; the address the code was etched at, its chain, and its hash.
    address public managerFixtureAddress;
    uint256 public managerFixtureChainId;
    bytes32 public managerFixtureCodeHash;
    /// @notice the block the fixture's code was read at (`fetch-bytecode.sh` records it; K16)
    uint256 public managerFixtureBlock;
    uint256 public managerRuntimeSize;
    /// @notice set only on the fork path: the block the fork is pinned at, and the keccak of the manager's code there
    uint256 public forkBlock;
    bytes32 public managerForkCodeHash;

    /// @notice ERC-20s of the real world (USDC, WETH on the fork) that the harness funded: their balance is `balanceOf`,
    /// since they have no `trueBalanceOf` to ask (see `_trueBalance`)
    mapping(address => bool) internal _plainErc20;

    // ------------------------------------------------------------------ the decision, as a function
    /// @notice `V4_MANAGER` was not "source", "fixture" or "fork". It is not a default, it is a typo.
    error UnknownManagerMode(string mode);
    /// @notice the fork answered with another chain: the addresses this harness knows are mainnet's
    error ForkNotMainnet(uint256 chainId);
    /// @notice no code at the manager's address at the fork's block: a `FORK_BLOCK` before the manager was deployed
    error ForkManagerHasNoCode(uint256 blockNumber);
    /// @notice an environment variable that must hold a block number in plain decimal (`FORK_BLOCK`) holds something
    /// else: a word, nothing, a sign, a space in front, a dot, an exponent, hex, a leading zero. Never read as the pin.
    error EnvNotADecimalBlockNumber(string variable, string value);
    /// @notice the fixture's metadata names no block. `fetch-bytecode.sh` has recorded one since K16: re-fetch.
    error FixtureNotBlockPinned(string metaPath);
    /// @notice USDC keeps the blocklist bit in the balance's own word: `deal` to a blocklisted account either reverts
    /// inside stdStorage's search or, if the slot was found earlier in the test, overwrites the word and un-blocklists
    /// the account (both measured, `test/fork/ForkManager.t.sol`). Fund first, blocklist after, and fund no more.
    error DealWouldClearUsdcBlocklist(address who);

    /// @notice decide what to do, given the mode and whether the fixture files are on disk. Separated from
    /// doing it so that a test can assert the decision directly, with no environment variables involved.
    /// @param mode the value of `V4_MANAGER`: exactly "source", "fixture" or "fork" (K16), and nothing else
    /// @param fixturePath the `.hex` path; its `.json` sibling must exist too, because the address the code
    ///        must be etched at lives in the json, and code without an address is not a manager
    /// @dev not `view`: `vm.isFile` is not a view cheatcode.
    ///
    /// TWO WORDS ONLY, and this used to be one word. The old line was
    /// `if (mode != "fixture") return SOURCE;`, which turns `V4_MANAGER=fixtrue` into a full green run
    /// against the source manager - the exact silent fallback the skip below exists to prevent, reached by
    /// one transposed letter instead of a missing file. The header of this file promises "it does not fall
    /// back to the source manager"; with a typo, it did. Found by an independent audit, which typed
    /// `fixtrue` and watched the suite report "compiled from source, 5 passed".
    function managerPlanFor(string memory mode, string memory fixturePath) public returns (ManagerPlan) {
        // whether RPC_URL EXISTS, never what it holds (a cheatcode's return value is printed in a trace)
        return managerPlanFor(mode, fixturePath, vm.envExists("RPC_URL"));
    }

    /// @notice the same decision with the endpoint's presence as an argument, so a test can ask it both ways (K16).
    /// `fork` without an endpoint is a SKIP, exactly as `fixture` without its files: never "source", never a fork of
    /// some endpoint the harness picked for you. The endpoint changes nothing for the other two modes.
    function managerPlanFor(string memory mode, string memory fixturePath, bool rpcSet) public returns (ManagerPlan) {
        bytes32 m = keccak256(bytes(mode));
        if (m == keccak256("fork")) return rpcSet ? ManagerPlan.FORK : ManagerPlan.SKIP_FORK_NO_RPC;
        if (m != keccak256("fixture")) {
            if (m != keccak256("source")) revert UnknownManagerMode(mode);
            return ManagerPlan.SOURCE;
        }
        if (!vm.isFile(fixturePath)) return ManagerPlan.SKIP_FIXTURE_MISSING;
        if (!vm.isFile(_metaPathOf(fixturePath))) return ManagerPlan.SKIP_FIXTURE_MISSING;
        return ManagerPlan.FIXTURE;
    }

    function _metaPathOf(string memory fixturePath) internal pure returns (string memory) {
        bytes memory b = bytes(fixturePath);
        if (b.length > 4) {
            bytes memory tail = new bytes(4);
            for (uint256 i = 0; i < 4; i++) tail[i] = b[b.length - 4 + i];
            if (keccak256(tail) == keccak256(".hex")) {
                bytes memory stem = new bytes(b.length - 4);
                for (uint256 i = 0; i < b.length - 4; i++) stem[i] = b[i];
                return string.concat(string(stem), ".json");
            }
        }
        return string.concat(fixturePath, ".json");
    }

    // ------------------------------------------------------------------ setting the manager up
    /// @notice call this first from your `setUp`.
    function _setUpManager() internal {
        string memory mode = vm.envOr("V4_MANAGER", string("source"));
        string memory fixturePath = vm.envOr("V4_FIXTURE", DEFAULT_FIXTURE);
        managerPlan = managerPlanFor(mode, fixturePath);

        if (managerPlan == ManagerPlan.SKIP_FIXTURE_MISSING) {
            // The reason goes in the skip itself, not only in a console2.log: forge does not print a
            // skipped setUp's logs at any verbosity, so a banner would be invisible and this would be a
            // silent skip - one line away from the silent pass it exists to prevent. With a reason, the
            // summary line reads
            //   [SKIP: V4_MANAGER=fixture but fixtures/PoolManager.hex is missing ...]
            // which is the thing somebody scrolling past has to see.
            string memory why = string.concat(
                "V4_MANAGER=fixture but ",
                fixturePath,
                " (and ",
                _metaPathOf(fixturePath),
                ") is missing. NOTHING WAS TESTED. Fetch it: RPC_URL=... scripts/fetch-bytecode.sh <manager address> ",
                fixturePath
            );
            console2.log("V4 MANAGER: NOTHING RAN.", why);
            vm.skip(true, why);
            return;
        }

        if (managerPlan == ManagerPlan.SKIP_FORK_NO_RPC) {
            // the same rule as the missing fixture: the reason travels in the skip, and nothing falls back to source
            vm.skip(
                true,
                "V4_MANAGER=fork but RPC_URL is not set. NOTHING WAS TESTED. Export RPC_URL (a read-only mainnet endpoint, archive if FORK_BLOCK is old) in your own shell; never in a file of the repository"
            );
            return;
        }

        if (managerPlan == ManagerPlan.FORK) {
            _forkManager();
        } else if (managerPlan == ManagerPlan.FIXTURE) {
            _etchManagerFromFixture(fixturePath);
        } else {
            manager = IPoolManager(address(new PoolManager(address(this))));
            managerRuntimeSize = address(manager).code.length;
        }

        _startClock();
        _printManager();
    }

    // ------------------------------------------------------------------ the clock (K46)
    /// @notice where every suite's clock starts: 2026-01-02 03:10:57 UTC. Not a round number on purpose: a start on a
    /// day's or a week's boundary would line a hook's epochs up with the calendar and hide an off-by-one at the edge.
    /// A test that means "the start" reads this, or `block.timestamp` in its own `setUp`.
    uint256 public constant V4_T0 = 1_767_323_457;
    /// @notice the block height every suite starts at: about Ethereum mainnet's at `V4_T0`, not a round number either
    uint256 public constant V4_BLOCK0 = 24_137_911;
    bool private _clockStarted;

    /// @notice warp to `V4_T0` and roll to `V4_BLOCK0`, once per test contract's set-up, before any hook is deployed (it
    /// runs inside `_setUpManager`). Why: under forge's timestamp 1 a hook's recorded start read 0 whether its
    /// clock had started or not, and a hook whose clock never started passed. A second call
    /// does nothing, so a suite that warped after the first is not sent back. On the fork it does nothing at all: the
    /// fork's clock is the chain's, at the pinned block, and a warp there would put the manager's own pools in the future.
    function _startClock() internal {
        if (_clockStarted) return;
        _clockStarted = true;
        if (managerPlan == ManagerPlan.FORK) return;
        vm.warp(V4_T0);
        vm.roll(V4_BLOCK0);
    }

    function _etchManagerFromFixture(string memory fixturePath) private {
        string memory meta = vm.readFile(_metaPathOf(fixturePath));
        managerFixtureAddress = vm.parseJsonAddress(meta, ".address");
        managerFixtureChainId = vm.parseJsonUint(meta, ".chainId");
        managerFixtureCodeHash = vm.parseJsonBytes32(meta, ".codeHash");
        uint256 declaredSize = vm.parseJsonUint(meta, ".codeSize");
        // K16: a fixture is the code AT A BLOCK. Without the block nobody can check the fixture against the chain
        // (`test/fork/FixtureBlock.t.sol` does), so a fixture that names none is refused, not guessed at.
        if (!vm.keyExistsJson(meta, ".block")) revert FixtureNotBlockPinned(_metaPathOf(fixturePath));
        managerFixtureBlock = vm.parseJsonUint(meta, ".block");

        bytes memory code = vm.parseBytes(_trim(vm.readLine(fixturePath)));
        require(code.length > 0, "V4Harness: fixture is empty");
        require(code.length == declaredSize, "V4Harness: fixture size does not match its own metadata");
        require(keccak256(code) == managerFixtureCodeHash, "V4Harness: fixture hash does not match its own metadata");

        vm.etch(managerFixtureAddress, code);
        vm.label(managerFixtureAddress, "PoolManager(etched)");
        manager = IPoolManager(managerFixtureAddress);
        managerRuntimeSize = code.length;
    }

    /// @notice fork mainnet at the pinned block and take the deployed manager as it is there: code AND storage.
    /// Nothing is etched and nothing is deployed in its place; if the block is before the manager existed, or the endpoint
    /// is another chain, it reverts saying which - a fork of the wrong thing is not a fork run.
    function _forkManager() private {
        // NOT `vm.envOr("FORK_BLOCK", DEFAULT_FORK_BLOCK)`: forge 1.8.1's envOr hands back the default whenever it cannot
        // parse the value, so "abc", "", "-1" and "26050000.0" ran green on the pin, and it reads "1e7" as 10 000 000
        // (V16, 2026-09-26). The variable is read as text and held to `forkBlockFrom`.
        bool set = vm.envExists("FORK_BLOCK");
        forkBlock = forkBlockFrom(set, set ? vm.envString("FORK_BLOCK") : "");
        vm.createSelectFork(FORK_RPC_ALIAS, forkBlock);
        _takeForkedManager();
    }

    /// @notice the block a fork run reads: the pin when `FORK_BLOCK` is not set; when it is, its value, which must be a
    /// block number in plain decimal - digits only, no sign, no space in front, no dot, no exponent, no `0x`, no leading
    /// zero ("0" itself is a number) - or this reverts naming the variable. Separated so that a test can hold it to that
    /// without an environment. One thing it cannot see: forge 1.8.1 strips trailing whitespace and surrounding quotes
    /// from an environment value before any cheatcode returns it (measured, K16b), so `FORK_BLOCK="26050000 "` arrives as
    /// "26050000" - the number that was written, not a fallback.
    function forkBlockFrom(bool isSet, string memory value) public pure returns (uint256 n) {
        if (!isSet) return DEFAULT_FORK_BLOCK;
        bytes memory b = bytes(value);
        // 77 digits never overflow a uint256; nothing that long is a block number either
        if (b.length == 0 || b.length > 77 || (b.length > 1 && b[0] == "0")) {
            revert EnvNotADecimalBlockNumber("FORK_BLOCK", value);
        }
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c < 0x30 || c > 0x39) revert EnvNotADecimalBlockNumber("FORK_BLOCK", value);
            n = n * 10 + (c - 0x30);
        }
    }

    /// @notice what the fork IS, checked before its manager is taken: mainnet (else `ForkNotMainnet`), with code at the
    /// manager's address (else `ForkManagerHasNoCode`). Internal and apart from `_forkManager` so that
    /// `test/fork/ForkManager.t.sol` can hold it to both refusals on the live fork (`vm.chainId`, `vm.rollFork`): a fork
    /// of another chain needs another endpoint, and forge's `FOUNDRY_CHAIN_ID=5` does the same for a whole run.
    function _takeForkedManager() internal {
        if (block.chainid != FORK_CHAIN_ID) revert ForkNotMainnet(block.chainid);
        if (MAINNET_POOL_MANAGER.code.length == 0) revert ForkManagerHasNoCode(block.number);
        manager = IPoolManager(MAINNET_POOL_MANAGER);
        managerRuntimeSize = MAINNET_POOL_MANAGER.code.length;
        managerForkCodeHash = keccak256(MAINNET_POOL_MANAGER.code);
        vm.label(MAINNET_POOL_MANAGER, "PoolManager(mainnet fork)");
        vm.label(MAINNET_USDC, "USDC");
        vm.label(MAINNET_WETH, "WETH");
    }

    /// @dev `cast code` writes one line, but a file that has been through a Windows editor has a `\r` on the
    /// end of it and `vm.parseBytes` will not say why it is unhappy.
    function _trim(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 end = b.length;
        while (end > 0) {
            bytes1 c = b[end - 1];
            if (c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d) end--;
            else break;
        }
        bytes memory out = new bytes(end);
        for (uint256 i = 0; i < end; i++) out[i] = b[i];
        return string(out);
    }

    /// @notice one line saying which manager is under test. Report it.
    function managerModeLabel() public view returns (string memory) {
        if (managerPlan == ManagerPlan.SKIP_FIXTURE_MISSING) return "skipped (fixture missing)";
        if (managerPlan == ManagerPlan.FIXTURE) return "real bytecode (etched fixture)";
        if (managerPlan == ManagerPlan.FORK) return "mainnet fork (the deployed manager, its storage, at a pinned block)";
        if (managerPlan == ManagerPlan.SKIP_FORK_NO_RPC) return "skipped (fork asked for, RPC_URL not set)";
        return "compiled from source (lib/v4-core)";
    }

    function _printManager() internal view {
        console2.log("---------------------------------------------------------------");
        console2.log("V4 MANAGER:", managerModeLabel());
        console2.log("  address     ", address(manager));
        console2.log("  runtime size", managerRuntimeSize);
        console2.log("  timestamp   ", block.timestamp);
        console2.log("  block number", block.number);
        if (managerPlan == ManagerPlan.FORK) {
            // the block and the chain, never the endpoint
            console2.log("  fork block  ", forkBlock);
            console2.log("  chain id    ", block.chainid);
            console2.log("  code hash   ", vm.toString(managerForkCodeHash));
        }
        if (managerPlan == ManagerPlan.FIXTURE) {
            console2.log("  fixture chain id", managerFixtureChainId);
            console2.log("  fixture block   ", managerFixtureBlock);
            console2.log("  code hash   ", vm.toString(managerFixtureCodeHash));
            console2.log("  NOTE: block.chainid here is", block.chainid);
            console2.log("  If your hook reads block.chainid, set vm.chainId() to the fixture's chain yourself.");
        }
        console2.log("---------------------------------------------------------------");
    }

    // ------------------------------------------------------------------ currencies
    /// @notice two hostile ERC-20s, sorted, as v4 requires. They behave honestly until a test flips a switch.
    function _deployCurrencies() internal {
        HostileERC20 a = new HostileERC20("Hostile A", "HOSA", 18);
        HostileERC20 b = new HostileERC20("Hostile B", "HOSB", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));
        vm.label(address(token0), "token0");
        vm.label(address(token1), "token1");
    }

    /// @notice the routers. Deployed after the manager, because they hold it as an immutable.
    function _deployRouters() internal {
        router = new MinimalRouter(manager);
        liquidity = new LiquidityHelper(manager);
        vm.label(address(router), "MinimalRouter");
        vm.label(address(liquidity), "LiquidityHelper");
    }

    /// @notice the world before any hook, in the one order that works: the manager, the two currencies, the routers.
    /// The order is not taste. The routers hold the manager as an immutable, so they come after it. And every contract
    /// here is created by THIS contract, at an address its nonce picks: the currencies' addresses decide which one is
    /// `token0`, so moving a deployment moves the prices and the books of every test that reads them.
    function _setUpV4() internal {
        _setUpManager();
        _deployCurrencies();
        _deployRouters();
    }

    // ------------------------------------------------------------------ fork-only suites and real currencies (K16)
    /// @notice `_setUpV4` for a suite that means nothing off the fork (real USDC, the deployed manager's storage). Under
    /// any other `V4_MANAGER` it SKIPS with the reason; under `fork` without `RPC_URL`, `_setUpManager` skips. Never green.
    function _setUpV4OnFork() internal {
        string memory mode = vm.envOr("V4_MANAGER", string("source"));
        if (keccak256(bytes(mode)) != keccak256("fork")) {
            vm.skip(
                true,
                string.concat(
                    "a fork-only suite under V4_MANAGER=",
                    mode,
                    ": NOTHING WAS TESTED. Run it as FOUNDRY_PROFILE=fork V4_MANAGER=fork with RPC_URL exported"
                )
            );
            return;
        }
        _setUpV4();
    }

    function realUsdc() internal pure returns (Currency) {
        return Currency.wrap(MAINNET_USDC);
    }

    function realWeth() internal pure returns (Currency) {
        return Currency.wrap(MAINNET_WETH);
    }

    /// @notice give `who` `amount` MORE of a real currency and approve the kit's router and liquidity helper: ETH through
    /// `vm.deal`, an ERC-20 through forge-std's `deal` (it finds the balance slot; totalSupply is left alone, because on
    /// WETH9 it is not a slot and `deal(..., true)` reverts). USDC's blocklist bit shares the balance's word, and `deal`
    /// to a blocklisted account either reverts or quietly un-blocklists it: such an account is refused here, by name.
    function _fundReal(Currency c, address who, uint256 amount) internal {
        if (c.isAddressZero()) {
            _fundNative(who, amount);
            return;
        }
        address token = Currency.unwrap(c);
        if (token == MAINNET_USDC && IUsdcBlocklist(token).isBlacklisted(who)) revert DealWouldClearUsdcBlocklist(who);
        _plainErc20[token] = true;
        deal(token, who, IERC20Minimal(token).balanceOf(who) + amount);
        vm.startPrank(who);
        IERC20Minimal(token).approve(address(router), type(uint256).max);
        IERC20Minimal(token).approve(address(liquidity), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice a pool of two currencies in either order: sorted here, as v4 requires (ETH, the zero address, first)
    function _initRealPool(IHooks hook, uint24 fee, int24 tickSpacing, uint160 sqrtPriceX96, Currency a, Currency b)
        internal
        returns (PoolKey memory key)
    {
        (Currency c0, Currency c1) = Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
        key = PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: hook});
        manager.initialize(key, sqrtPriceX96);
    }

    // ------------------------------------------------------------------ the hook, at a mined address (K22)
    /// @notice `_deployHook` ran before `_deployRouters`. The manager the hook's constructor arguments name may not
    /// exist yet (an `abi.encode(manager)` evaluated then encodes address zero, and the miner mines for that), and the
    /// hook's CREATE2 bumps this contract's nonce, which moves every contract the setup creates after it. Call
    /// `_setUpV4()` (or the three steps it runs) first.
    error HookBeforeRouters();
    /// @notice the CREATE2 produced no contract and said nothing: the mined address is taken already (the same hook,
    /// same arguments, deployed twice from here), or the constructor ran out of gas.
    error HookNotDeployed(address mined);
    /// @notice the CREATE2 landed somewhere other than where the miner said. It cannot happen while this contract is
    /// the deployer; it is checked so that it is never assumed.
    error HookLandedElsewhere(address mined, address landed);

    /// @notice put a hook at an address whose low fourteen bits are exactly `flags`: mine a salt for THIS contract,
    /// `creationCode` and `constructorArgs` (`HookMiner.find`), CREATE2 it, check it landed where it was mined. The
    /// same contract, at the same address, from the same deployer, with the same nonce afterwards, as the two lines it
    /// replaces - `(, bytes32 salt) = HookMiner.find(address(this), flags, type(H).creationCode, abi.encode(args));`
    /// then `new H{salt: salt}(args)` (`test/HookFlags.t.sol` compares the two). A constructor that reverts - a hook's
    /// own `validateHookPermissions` among them - reverts this with the constructor's own revert data, as `new` does.
    /// A test ABOUT the mining (`test/HookFlags.t.sol`) keeps `HookMiner.find` and `new` by hand: it asserts on the
    /// salt and the predicted address, which this does not hand back.
    /// Then it holds the address's bits against the callbacks the hook implements (`_checkHookPermissions`, K46) and
    /// reverts `V4Harness: <callback> implemented but its permission bit is not set on <address> - the manager never
    /// calls it. This is a finding, not a fix (doctrine/NEXT.md row 6b): ...` when one that does something has no bit -
    /// unless the suite set `_skipPermissionCheck`. The refusal ends naming the act, in its order: the finding's test
    /// under `pending/<id>.t.sol` - its own `setUp` sets `_skipPermissionCheck = true`, then a test function of its own
    /// calls `_checkHookPermissions(address(hook))` directly, with no `vm.expectRevert`, so this line fails that test -
    /// its red record
    /// (`scripts/pending-red.sh`), the count in `STATE.md`; then the flag and a header line naming the finding in the
    /// suites that deploy the hook; then the battery, which checks them against that record - current while `src/` and
    /// the finding's own file are as recorded (doctrine/EVIDENCE.md section 2: the everyday suite too).
    /// @param creationCode `type(MyHook).creationCode`
    /// @param constructorArgs `abi.encode(...)`, exactly as the constructor takes them - usually `abi.encode(manager)`,
    ///        which is why this refuses to run before the routers (`HookBeforeRouters`)
    /// @param flags the permission bits the hook declares, OR-ed from `Hooks.*_FLAG`
    /// @return hook the deployed hook; cast it: `MyHook(_deployHook(...))` (payable: a hook with
    ///         `receive` casts too)
    function _deployHook(bytes memory creationCode, bytes memory constructorArgs, uint160 flags)
        internal
        returns (address payable hook)
    {
        if (address(router) == address(0) || address(liquidity) == address(0)) revert HookBeforeRouters();
        (address mined, bytes32 salt) = HookMiner.find(address(this), flags, creationCode, constructorArgs);
        bytes memory initcode = bytes.concat(creationCode, constructorArgs);
        assembly ("memory-safe") {
            hook := create2(0, add(initcode, 0x20), mload(initcode), salt)
            if and(iszero(hook), gt(returndatasize(), 0)) {
                let p := mload(0x40)
                returndatacopy(p, 0, returndatasize())
                revert(p, returndatasize())
            }
        }
        if (hook == address(0)) revert HookNotDeployed(mined);
        if (hook != mined) revert HookLandedElsewhere(mined, hook);
        if (!_skipPermissionCheck) _checkHookPermissions(hook);
    }

    // ------------------------------------------------------------------ the bits against the callbacks (K46)
    /// @notice set it to true in a suite that deploys a hook mis-flagged ON PURPOSE (`HostileHook`, which answers all ten
    /// callbacks, at an address carrying one; a mutant that drops a bit): `_deployHook` then skips the check. Set it
    /// around that one deployment and back, so the suite's other hooks are still checked. In a project, while a
    /// permission-bits finding is open AND recorded (its pending test red on this check's own line), a suite may set it
    /// in `setUp` with a header line `// _skipPermissionCheck: <id> open`: the hook then runs as the manager drives it,
    /// the callback never called (doctrine/EVIDENCE.md section 2; `scripts/battery.sh` refuses it under `test/` otherwise).
    bool internal _skipPermissionCheck;

    /// @notice what each callback did when the harness called it as the manager, one bit per callback, at the position
    /// of its `Hooks.*_FLAG` (so `p.answered & Hooks.AFTER_INITIALIZE_FLAG != 0` reads as it says).
    /// @param answered returned normally
    /// @param ownError reverted with data of its own (a guard, or the probe's pool is one the hook does not know): it
    ///        has code there
    /// @param notImplemented reverted as not implemented: `NotImplemented()` or `HookNotImplemented()` (the examples',
    ///        v4-periphery's and OpenZeppelin's `BaseHook`'s), the same data as a selector no hook has, or no data at all
    ///        (no such function, a bare `revert()`)
    /// @param blind the hook answers a selector no hook has (a fallback): nothing here can be told apart, and no bit
    ///        is checked
    struct HookProbe {
        uint160 answered;
        uint160 ownError;
        uint160 notImplemented;
        bool blind;
    }

    /// @notice the gas one probe may use. A write under STATICCALL burns all of it, so it is kept low; a callback that
    /// needs more than 5 M gas on an ordinary call is a finding of its own, not something to wait for
    uint256 private constant PROBE_GAS = 5_000_000;

    /// @notice fail, naming the callback, when the hook at `hook` implements a callback its address has no bit for; log a
    /// warning when a bit is set for a callback that reverts on the probe. `_deployHook` calls it; a suite that deploys a
    /// hook by hand (`deployCodeTo`, `new` at a mined salt) can call it itself.
    ///
    /// How a callback is judged implemented: it is called as the manager, with the harness's two currencies, fee 3000,
    /// spacing 60, the full range, 1e18, a zeroForOne exact-in swap, zero deltas and empty `hookData`, first under
    /// STATICCALL (nothing it does can stay: no write, no event, nothing recorded by `vm.recordLogs`). A callback that
    /// returns, or reverts with data of its own, has code there. One that reverts with no data under STATICCALL either
    /// has no such function or tried to write - so, for a callback whose bit is NOT set, it is called once more for real
    /// inside a state snapshot that is reverted straight after. A callback that writes (an `afterInitialize`
    /// recording when the pool started) answers that second call. What it cannot see: a callback reached only through a fallback
    /// (`blind`, logged), a guard that reverts with no data on the probe's arguments (counted not implemented), and an
    /// unused callback that returns its selector and does nothing (counted implemented: make it revert, as the examples
    /// do, or declare the bit).
    function _checkHookPermissions(address hook) internal {
        HookProbe memory p = _probeHookCallbacks(hook);
        string memory where = vm.toString(hook);
        if (p.blind) {
            console2.log(
                string.concat(
                    "V4Harness: the hook at ",
                    where,
                    " answers a selector no hook has (a fallback): its permission bits were NOT checked against its callbacks"
                )
            );
            return;
        }
        string memory missing;
        uint256 n;
        for (uint256 i = 0; i < 10; i++) {
            uint160 f = _callbackFlag(i);
            bool bit = Hooks.hasPermission(IHooks(hook), f);
            if (!bit && (p.answered | p.ownError) & f != 0) {
                missing = n == 0 ? _callbackName(i) : string.concat(missing, ", ", _callbackName(i));
                n++;
            } else if (bit && p.notImplemented & f != 0) {
                console2.log(
                    string.concat(
                        "V4Harness: WARNING ",
                        _callbackName(i),
                        " has its permission bit set on ",
                        where,
                        " but reverts on call as not implemented: every pool of this hook reverts there"
                    )
                );
            } else if (bit && p.ownError & f != 0) {
                console2.log(
                    string.concat(
                        "V4Harness: note - ",
                        _callbackName(i),
                        " (bit set) reverted on the harness's probe with an error of its own; the probe's pool is not one",
                        " the hook set up, so this is usually a guard. Check it is not a callback that always reverts"
                    )
                );
            }
        }
        if (n == 0) return;
        revert(
            string.concat(
                "V4Harness: ",
                missing,
                n == 1 ? " implemented but its permission bit is not set on " : " implemented but their permission bits are not set on ",
                where,
                " - the manager never calls it. This is a finding, not a fix (doctrine/NEXT.md row 6b). In this order: write its test as",
                " pending/<id>.t.sol - its own setUp sets _skipPermissionCheck = true, then a test function of its own calls",
                " _checkHookPermissions(address(hook)) directly (V4Harness: function _checkHookPermissions(address hook) internal), with",
                " no vm.expectRevert, so this revert fails that test - record that red with scripts/pending-red.sh <proj> pending/<id>.t.sol, count it",
                " in STATE.md; then put _skipPermissionCheck = true and a header line // _skipPermissionCheck: <id> open in the suites",
                " that deploy the hook; then the battery, which holds them to that red record, current while src/ and pending/<id>.t.sol are as recorded (doctrine/EVIDENCE.md section 2)."
            )
        );
    }

    /// @notice call each of the ten callbacks as the manager and say what it did (`HookProbe`). Nothing it does stays:
    /// the calls are STATICCALLs, or real calls inside a state snapshot reverted straight after.
    function _probeHookCallbacks(address hook) internal returns (HookProbe memory p) {
        // a selector no hook has: what the hook does with it is what "no such function" looks like here
        vm.prank(address(manager));
        (bool controlOk, bytes memory control) =
            hook.staticcall{gas: PROBE_GAS}(abi.encodeWithSignature("v4HarnessNoSuchCallback()"));
        if (controlOk) {
            p.blind = true;
            return p;
        }
        for (uint256 i = 0; i < 10; i++) {
            uint160 f = _callbackFlag(i);
            bytes memory data = _probeCalldata(i, hook);
            vm.prank(address(manager));
            (bool ok, bytes memory ret) = hook.staticcall{gas: PROBE_GAS}(data);
            if (!ok && ret.length == 0) {
                if (!Hooks.hasPermission(IHooks(hook), f)) {
                    // no data: no such function, a bare revert, or a write under STATICCALL. Call it for real, and undo it.
                    uint256 snap = vm.snapshotState();
                    vm.prank(address(manager));
                    (ok, ret) = hook.call{gas: PROBE_GAS}(data);
                    vm.revertToStateAndDelete(snap);
                } else if (_codeHasSelector(hook.code, bytes4(data))) {
                    // its bit is set and the function is there: most likely a write under STATICCALL. Not run for real
                    // (its events would reach a `vm.recordLogs` the suite started), and nothing to warn about.
                    continue;
                }
            }
            if (ok) p.answered |= f;
            else if (_isNotImplementedRevert(ret, control)) p.notImplemented |= f;
            else p.ownError |= f;
        }
    }

    /// @notice whether a revert's data says "not implemented". Override it in a suite whose hook marks its unused
    /// callbacks with an error of another name.
    function _isNotImplementedRevert(bytes memory ret, bytes memory control) internal pure virtual returns (bool) {
        if (ret.length == 0) return true;
        if (keccak256(ret) == keccak256(control)) return true;
        if (ret.length != 4) return false;
        bytes4 sel = bytes4(ret);
        return sel == bytes4(keccak256("NotImplemented()")) || sel == bytes4(keccak256("HookNotImplemented()"));
    }

    /// @notice whether `code` pushes `sel` the way solc's dispatcher does: PUSH4 and the four bytes, or PUSH3 and three
    /// when the selector's first byte is zero
    function _codeHasSelector(bytes memory code, bytes4 sel) internal pure returns (bool found) {
        uint256 s = uint32(sel);
        uint256 want = s >> 24 == 0 ? (0x62 << 24) | s : (0x63 << 32) | s;
        uint256 shift = s >> 24 == 0 ? 224 : 216;
        assembly ("memory-safe") {
            let start := add(code, 0x20)
            let len := mload(code)
            for { let i := 0 } lt(add(i, 5), add(len, 1)) { i := add(i, 1) } {
                if eq(shr(shift, mload(add(start, i))), want) {
                    found := 1
                    break
                }
            }
        }
    }

    /// @notice the ten callbacks, in the order of their bits (13 down to 4)
    function _callbackFlag(uint256 i) internal pure returns (uint160) {
        if (i == 0) return Hooks.BEFORE_INITIALIZE_FLAG;
        if (i == 1) return Hooks.AFTER_INITIALIZE_FLAG;
        if (i == 2) return Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
        if (i == 3) return Hooks.AFTER_ADD_LIQUIDITY_FLAG;
        if (i == 4) return Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        if (i == 5) return Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
        if (i == 6) return Hooks.BEFORE_SWAP_FLAG;
        if (i == 7) return Hooks.AFTER_SWAP_FLAG;
        if (i == 8) return Hooks.BEFORE_DONATE_FLAG;
        return Hooks.AFTER_DONATE_FLAG;
    }

    function _callbackName(uint256 i) internal pure returns (string memory) {
        if (i == 0) return "beforeInitialize";
        if (i == 1) return "afterInitialize";
        if (i == 2) return "beforeAddLiquidity";
        if (i == 3) return "afterAddLiquidity";
        if (i == 4) return "beforeRemoveLiquidity";
        if (i == 5) return "afterRemoveLiquidity";
        if (i == 6) return "beforeSwap";
        if (i == 7) return "afterSwap";
        if (i == 8) return "beforeDonate";
        return "afterDonate";
    }

    /// @notice callback `i` with the arguments of an ordinary call on a pool of the harness's currencies
    function _probeCalldata(uint256 i, address hook) internal view returns (bytes memory) {
        PoolKey memory key = _poolKey(IHooks(hook), 3000, 60);
        address sender = address(router);
        if (i == 0) return abi.encodeCall(IHooks.beforeInitialize, (sender, key, uint160(1) << 96));
        if (i == 1) return abi.encodeCall(IHooks.afterInitialize, (sender, key, uint160(1) << 96, int24(0)));
        if (i < 6) {
            (int24 lower, int24 upper) = _fullRange(60);
            int256 liq = i < 4 ? int256(1e18) : -1e18;
            ModifyLiquidityParams memory lp =
                ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: liq, salt: bytes32(0)});
            if (i == 2) return abi.encodeCall(IHooks.beforeAddLiquidity, (sender, key, lp, ""));
            if (i == 4) return abi.encodeCall(IHooks.beforeRemoveLiquidity, (sender, key, lp, ""));
            BalanceDelta zero = BalanceDelta.wrap(0);
            if (i == 3) return abi.encodeCall(IHooks.afterAddLiquidity, (sender, key, lp, zero, zero, ""));
            return abi.encodeCall(IHooks.afterRemoveLiquidity, (sender, key, lp, zero, zero, ""));
        }
        if (i < 8) {
            SwapParams memory sp =
                SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
            if (i == 6) return abi.encodeCall(IHooks.beforeSwap, (sender, key, sp, ""));
            return abi.encodeCall(IHooks.afterSwap, (sender, key, sp, BalanceDelta.wrap(0), ""));
        }
        if (i == 8) return abi.encodeCall(IHooks.beforeDonate, (sender, key, 1e18, 1e18, ""));
        return abi.encodeCall(IHooks.afterDonate, (sender, key, 1e18, 1e18, ""));
    }

    // ------------------------------------------------------------------ pools
    function _poolKey(IHooks hook, uint24 fee, int24 tickSpacing) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hook
        });
    }

    /// @notice initialise a pool at the given price. Returns the key, which is the pool's identity.
    function _initPool(IHooks hook, uint24 fee, int24 tickSpacing, uint160 sqrtPriceX96)
        internal
        returns (PoolKey memory key)
    {
        key = _poolKey(hook, fee, tickSpacing);
        manager.initialize(key, sqrtPriceX96);
    }

    /// @notice the widest position the tick spacing allows. Computed, never hard-coded: the usable range
    /// depends on the spacing, and a test that hard-codes ticks for spacing 60 silently tests a narrow band
    /// when somebody changes the spacing to 1.
    function _fullRange(int24 tickSpacing) internal pure returns (int24 lower, int24 upper) {
        lower = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        upper = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
    }

    /// @notice mint both currencies to `who` and approve the router and the liquidity helper.
    function _fundAndApprove(address who, uint256 amount) internal {
        token0.mint(who, amount);
        token1.mint(who, amount);
        vm.startPrank(who);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token0.approve(address(liquidity), type(uint256).max);
        token1.approve(address(liquidity), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ native currency and claims (K14)
    /// @notice what `who` holds of `c`, whatever `c` is: ETH for the zero address, the TRUE balance of a harness token
    /// (`HostileERC20.trueBalanceOf`, which no switch of the token can falsify) otherwise. Every currency the harness
    /// hands out is one of the two; a project that brings its own ERC-20 overrides this. A real token the harness funded
    /// on the fork (`_fundReal`: USDC, WETH) has no `trueBalanceOf`, and its `balanceOf` is the balance.
    function _trueBalance(Currency c, address who) internal view virtual returns (uint256) {
        if (c.isAddressZero()) return who.balance;
        if (_plainErc20[Currency.unwrap(c)]) return IERC20Minimal(Currency.unwrap(c)).balanceOf(who);
        return HostileERC20(Currency.unwrap(c)).trueBalanceOf(who);
    }

    /// @notice the ERC-6909 claims `who` holds on the manager for `c`: value the manager OWES `who`, in `c`, which no
    /// token balance shows. A hook that keeps its fees as claims holds them here and nowhere else.
    function _claimsOf(Currency c, address who) internal view returns (uint256) {
        return manager.balanceOf(who, c.toId());
    }

    /// @notice give `who` `amount` more ETH (`vm.deal` SETS a balance; this adds to it)
    function _fundNative(address who, uint256 amount) internal {
        vm.deal(who, who.balance + amount);
    }

    /// @notice a pool with ETH as `currency0` and `other` (an ERC-20) as `currency1`: the zero address always sorts first
    function _nativePoolKey(IHooks hook, uint24 fee, int24 tickSpacing, Currency other)
        internal
        pure
        returns (PoolKey memory)
    {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: other,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hook
        });
    }

    function _initNativePool(IHooks hook, uint24 fee, int24 tickSpacing, uint160 sqrtPriceX96, Currency other)
        internal
        returns (PoolKey memory key)
    {
        key = _nativePoolKey(hook, fee, tickSpacing, other);
        manager.initialize(key, sqrtPriceX96);
    }

    // ------------------------------------------------------------------ one swap, with every party's books (K13, K14)
    /// @notice what one swap did to everyone, per currency, each from its OWN source - so that a test can hold a hook
    /// that returns deltas to `swapper + hook + manager == 0` and see WHERE a unit went. Signed from each party's side:
    /// negative = it paid, positive = it received.
    /// @param caller0/1 the delta the manager returned to the router: the swapper's side, the hook's delta INCLUDED
    /// @param pool0/1 the pool's own delta, off the manager's `Swap` event (caller-signed; emitted before `afterSwap`)
    /// @param swapper0/1, hook0/1, manager0/1 true balance changes (`_trueBalance`: ETH for a native currency, and a
    ///        hostile token cannot lie to them). The swapper's ETH is net of the router's refund: what it sent less what
    ///        came back
    /// @param hookClaims0/1 the change in the hook's ERC-6909 claims on the manager. A claim is value the manager owes,
    ///        held as tokens the manager keeps: with claims minted in a swap the manager's balance moves by the pool's
    ///        delta PLUS those claims (`manager - hookClaims == -pool`), and conservation counts them as the hook's
    /// @param valueSent the ETH the swapper sent with the call
    /// The hook's own delta, as the manager booked it, is `pool - caller`. A hook that settles its own delta inside
    /// its callbacks - the only way a POSITIVE hook delta can be cleared: `take`, `mint` and `clear` all act on
    /// `msg.sender` - shows it as `hook + hookClaims == pool - caller`: in its balance if it took, in its claims if it
    /// minted.
    struct SwapBooks {
        int256 caller0;
        int256 caller1;
        int256 pool0;
        int256 pool1;
        int256 swapper0;
        int256 swapper1;
        int256 hook0;
        int256 hook1;
        int256 manager0;
        int256 manager1;
        int256 hookClaims0;
        int256 hookClaims1;
        uint256 valueSent;
    }

    /// @notice `_swapWithBooks` finds the manager's `Swap` event with `vm.recordLogs()` / `vm.getRecordedLogs()`, and those
    /// CONSUME the recorder: a test that called `vm.recordLogs()` before it loses what it recorded before the swap AND the
    /// swap's own events - the hook's among them. (K15b, from the verifier V15: a grant the hook made inside `afterSwap`
    /// went unseen by a unit test that recorded around four swaps, its mutant 11/11 green.) Set `_keepSwapLogs` and every
    /// `_swapWithBooks` appends every log of its swap here; `_takeKeptSwapLogs()` hands them over and empties the list.
    bool internal _keepSwapLogs;
    Vm.Log[] internal _keptSwapLogs;

    function _takeKeptSwapLogs() internal returns (Vm.Log[] memory logs) {
        logs = new Vm.Log[](_keptSwapLogs.length);
        for (uint256 i = 0; i < logs.length; i++) {
            logs[i] = _keptSwapLogs[i];
        }
        delete _keptSwapLogs;
    }

    /// @notice swap through `router` as `swapper` and return every party's books (see `SwapBooks`). Reverts if the
    /// manager emitted no `Swap` (the swap did not happen). With ETH as the INPUT (a native `currency0`, zeroForOne) it
    /// sends `|amountSpecified|` on an exact-in swap and the swapper's whole ETH balance on an exact-out one (the input
    /// is not known in advance; the router refunds the rest): the overload with `value` chooses.
    function _swapWithBooks(address swapper, PoolKey memory key, SwapParams memory params)
        internal
        returns (SwapBooks memory b)
    {
        uint256 value;
        if (key.currency0.isAddressZero() && params.zeroForOne) {
            value = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : swapper.balance;
        }
        return _swapWithBooks(swapper, key, params, value);
    }

    function _swapWithBooks(address swapper, PoolKey memory key, SwapParams memory params, uint256 value)
        internal
        returns (SwapBooks memory b)
    {
        int256[8] memory pre = _booksSnapshot(key, swapper);
        vm.recordLogs();
        vm.prank(swapper);
        BalanceDelta d = router.swap{value: value}(key, params, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (_keepSwapLogs) {
            for (uint256 i = 0; i < logs.length; i++) {
                _keptSwapLogs.push(logs[i]);
            }
        }
        (bool found, int128 p0, int128 p1) = SwapEventReader.lastSwapDelta(logs, address(manager));
        require(found, "V4Harness: no Swap event, the swap did not happen");
        b.caller0 = d.amount0();
        b.caller1 = d.amount1();
        b.pool0 = p0;
        b.pool1 = p1;
        int256[8] memory post = _booksSnapshot(key, swapper);
        b.swapper0 = post[0] - pre[0];
        b.swapper1 = post[1] - pre[1];
        b.hook0 = post[2] - pre[2];
        b.hook1 = post[3] - pre[3];
        b.manager0 = post[4] - pre[4];
        b.manager1 = post[5] - pre[5];
        b.hookClaims0 = post[6] - pre[6];
        b.hookClaims1 = post[7] - pre[7];
        b.valueSent = value;
    }

    /// @dev every balance `SwapBooks` differences, in its order: swapper, hook, manager (0 then 1), the hook's claims.
    /// A function of its own since K16: inline, the IR build of `_swapWithBooks` ran out of stack once `_trueBalance`
    /// learned to read a real token.
    function _booksSnapshot(PoolKey memory key, address swapper) internal view returns (int256[8] memory s) {
        address hook = address(key.hooks);
        s[0] = int256(_trueBalance(key.currency0, swapper));
        s[1] = int256(_trueBalance(key.currency1, swapper));
        s[2] = int256(_trueBalance(key.currency0, hook));
        s[3] = int256(_trueBalance(key.currency1, hook));
        s[4] = int256(_trueBalance(key.currency0, address(manager)));
        s[5] = int256(_trueBalance(key.currency1, address(manager)));
        s[6] = int256(_claimsOf(key.currency0, hook));
        s[7] = int256(_claimsOf(key.currency1, hook));
    }

    /// @notice add `liq` of liquidity over the full range, paid for by `provider`.
    /// On a pool with ETH as `currency0` the provider sends its whole ETH balance and the helper refunds what the
    /// manager did not charge.
    function _addFullRangeLiquidity(PoolKey memory key, address provider, int256 liq) internal {
        (int24 lower, int24 upper) = _fullRange(key.tickSpacing);
        uint256 value = key.currency0.isAddressZero() && liq > 0 ? provider.balance : 0;
        vm.prank(provider);
        liquidity.modifyLiquidity{value: value}(
            key,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: liq, salt: bytes32(0)}),
            ""
        );
    }
}
