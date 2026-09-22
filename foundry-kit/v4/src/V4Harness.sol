// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HostileERC20} from "gauntlet-kit/HostileERC20.sol";
import {MinimalRouter} from "./MinimalRouter.sol";
import {LiquidityHelper} from "./LiquidityHelper.sol";

/// @title V4Harness
/// @notice The base a v4 hook's tests inherit from. It gives you a PoolManager, two hostile currencies, a
/// dumb router, a liquidity helper, and - the part that matters - a choice of WHICH manager.
///
/// ## The two managers, and why both
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
/// And `V4_MANAGER` takes exactly two values. Anything else - `fixtrue`, `FIXTURE`, an empty string - is a
/// revert, not a default. A mode that falls back to "source" on anything it does not recognise is the same
/// silent fallback, reached by a typo instead of a missing file.
abstract contract V4Harness is Test {
    /// @notice what the harness decided to do about the manager, before doing it.
    enum ManagerPlan {
        SOURCE,
        FIXTURE,
        SKIP_FIXTURE_MISSING
    }

    /// @notice the default place `scripts/fetch-bytecode.sh` is told to write, and the only directory
    /// `foundry.toml` grants the suite permission to read.
    string internal constant DEFAULT_FIXTURE = "fixtures/PoolManager.hex";

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
    uint256 public managerRuntimeSize;

    // ------------------------------------------------------------------ the decision, as a function
    /// @notice `V4_MANAGER` was neither "source" nor "fixture". It is not a default, it is a typo.
    error UnknownManagerMode(string mode);

    /// @notice decide what to do, given the mode and whether the fixture files are on disk. Separated from
    /// doing it so that a test can assert the decision directly, with no environment variables involved.
    /// @param mode the value of `V4_MANAGER`: exactly "source" or exactly "fixture", and nothing else
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
        bytes32 m = keccak256(bytes(mode));
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

        if (managerPlan == ManagerPlan.FIXTURE) {
            _etchManagerFromFixture(fixturePath);
        } else {
            manager = IPoolManager(address(new PoolManager(address(this))));
            managerRuntimeSize = address(manager).code.length;
        }

        _printManager();
    }

    function _etchManagerFromFixture(string memory fixturePath) private {
        string memory meta = vm.readFile(_metaPathOf(fixturePath));
        managerFixtureAddress = vm.parseJsonAddress(meta, ".address");
        managerFixtureChainId = vm.parseJsonUint(meta, ".chainId");
        managerFixtureCodeHash = vm.parseJsonBytes32(meta, ".codeHash");
        uint256 declaredSize = vm.parseJsonUint(meta, ".codeSize");

        bytes memory code = vm.parseBytes(_trim(vm.readLine(fixturePath)));
        require(code.length > 0, "V4Harness: fixture is empty");
        require(code.length == declaredSize, "V4Harness: fixture size does not match its own metadata");
        require(keccak256(code) == managerFixtureCodeHash, "V4Harness: fixture hash does not match its own metadata");

        vm.etch(managerFixtureAddress, code);
        vm.label(managerFixtureAddress, "PoolManager(etched)");
        manager = IPoolManager(managerFixtureAddress);
        managerRuntimeSize = code.length;
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
        return "compiled from source (lib/v4-core)";
    }

    function _printManager() internal view {
        console2.log("---------------------------------------------------------------");
        console2.log("V4 MANAGER:", managerModeLabel());
        console2.log("  address     ", address(manager));
        console2.log("  runtime size", managerRuntimeSize);
        if (managerPlan == ManagerPlan.FIXTURE) {
            console2.log("  fixture chain id", managerFixtureChainId);
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

    /// @notice add `liq` of liquidity over the full range, paid for by `provider`.
    function _addFullRangeLiquidity(PoolKey memory key, address provider, int256 liq) internal {
        (int24 lower, int24 upper) = _fullRange(key.tickSpacing);
        vm.prank(provider);
        liquidity.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: liq, salt: bytes32(0)}),
            ""
        );
    }
}
