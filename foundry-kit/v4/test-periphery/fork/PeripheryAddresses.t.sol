// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
// Inside the kit: imports are relative. In your project: see scripts/setup-deps.sh's import lines.

import {console2} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {PeripheryPools} from "../PeripheryPools.sol";
import {PeripheryPlans} from "../PeripheryPlans.sol";
import {IUniversalRouter} from "../PeripheryHarness.sol";
import {PeripheryProbeHook} from "../PeripheryProbeHook.sol";

interface IPositionManagerFacts {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
    function WETH9() external view returns (address);
    function unsubscribeGasLimit() external view returns (uint256);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function nextTokenId() external view returns (uint256);
}

interface IPermit2Facts {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @notice The periphery the fork uses is the periphery it says it is, checked on the chain at the pinned block, the
/// way `test/fork/ForkManager.t.sol` checks the manager (K17b). Fork only: skipped with the reason anywhere else, and
/// outside the `periphery` profile's default run (`no_match_path`), inside `periphery-fork`'s.
contract PeripheryAddressesForkTest is PeripheryPools {
    function setUp() public {
        _setUpPeripheryWorldOnFork();
    }

    /// @notice the PositionManager at 0xbD21…ee9e: code at the block (23 877 bytes); it answers the v4 manager, the
    /// canonical Permit2 and WETH9; its ERC-721 is "Uniswap v4 Positions NFT" / "UNI-V4-POSM"; its unsubscribe gas limit
    /// is 150 000 (the constructor argument the source deployment copies); and it has minted: the next token id is far
    /// above 1 (415 911 at block 26 050 000)
    function test_the_position_manager_is_the_v4_position_manager_and_this_is_how_we_know() public view {
        IPositionManagerFacts p = IPositionManagerFacts(MAINNET_POSITION_MANAGER);
        assertEq(MAINNET_POSITION_MANAGER.code.length, 23_877, "its code size at the pinned block");
        assertEq(p.poolManager(), MAINNET_POOL_MANAGER, "its manager");
        assertEq(p.permit2(), PERMIT2_ADDRESS, "its Permit2");
        assertEq(p.WETH9(), MAINNET_WETH, "its WETH9");
        assertEq(p.name(), "Uniswap v4 Positions NFT");
        assertEq(p.symbol(), "UNI-V4-POSM");
        assertEq(p.unsubscribeGasLimit(), MAINNET_UNSUBSCRIBE_GAS_LIMIT, "the constructor argument the source copy uses");
        assertEq(p.nextTokenId(), 415_911, "positions minted by the pinned block");
    }

    /// @notice the UniversalRouter at 0x66a9…A8Af: code at the block (19 499 bytes), it answers the v4 manager, and it
    /// swaps on a pool of ours when asked in the deployed layout (below)
    function test_the_universal_router_answers_the_v4_manager() public view {
        assertEq(MAINNET_UNIVERSAL_ROUTER.code.length, 19_499, "its code size at the pinned block");
        assertEq(address(IPositionManagerFacts(MAINNET_UNIVERSAL_ROUTER).poolManager()), MAINNET_POOL_MANAGER);
    }

    /// @notice Permit2 at its canonical address: its EIP-712 domain is "Permit2" on chain 1 at that address
    function test_permit2_is_permit2() public view {
        assertEq(IPermit2Facts(PERMIT2_ADDRESS).DOMAIN_SEPARATOR(), _permit2Domain(block.chainid));
        assertEq(PERMIT2_ADDRESS.code.length, 9_152, "its code size");
    }

    /// @notice what the source harness etches (Permit2's own test deployer) against what is on mainnet: the same 9 152
    /// bytes except two words - the immutables Permit2's EIP-712 base caches at construction: the chain id (the
    /// deployer's code was built on chain 31 337, mainnet's on 1) and the domain separator (mainnet's is the canonical
    /// address's on chain 1; the deployer's is not the canonical address's on 31 337). The logic is byte for byte mainnet's.
    function test_the_source_harness_permit2_is_mainnets_but_for_its_cached_chain_id_and_domain() public {
        bytes memory real = PERMIT2_ADDRESS.code;
        vm.etch(PERMIT2_ADDRESS, "");
        new DeployPermit2().deployPermit2();
        bytes memory etched = PERMIT2_ADDRESS.code;
        vm.etch(PERMIT2_ADDRESS, real);
        assertEq(etched.length, real.length, "the same size");
        // the two words, where the measurement found the only differing bytes
        uint256 chainIdAt = 6945;
        uint256 domainAt = 6983;
        for (uint256 i = 0; i < real.length; i++) {
            bool inWords = (i >= chainIdAt && i < chainIdAt + 32) || (i >= domainAt && i < domainAt + 32);
            if (!inWords) assertEq(real[i], etched[i], string.concat("a byte differs outside the two words: ", vm.toString(i)));
        }
        assertEq(_word(real, chainIdAt), 1, "mainnet's cached chain id");
        assertEq(_word(etched, chainIdAt), 31_337, "the deployer's cached chain id");
        assertEq(bytes32(_word(real, domainAt)), _permit2Domain(1), "mainnet's cached domain separator");
        // the deployer's cached domain separator is NOT the canonical address's on 31 337 (it was cached where the code
        // was first built): on the source harness's chain, which is 31 337, Permit2 answers THAT one. Nothing here signs
        // a permit (the kit uses on-chain allowances); a test of a signature path on the source harness must sign against
        // what `DOMAIN_SEPARATOR()` answers, never against a domain it computes.
        bytes32 etchedDomain = bytes32(_word(etched, domainAt));
        assertTrue(etchedDomain != _permit2Domain(31_337), "the deployer's cached domain is the canonical one after all");
        vm.etch(PERMIT2_ADDRESS, etched);
        vm.chainId(31_337);
        assertEq(IPermit2Facts(PERMIT2_ADDRESS).DOMAIN_SEPARATOR(), etchedDomain, "on 31 337 it answers its cached domain");
        vm.chainId(1);
        vm.etch(PERMIT2_ADDRESS, real);
    }

    function _word(bytes memory b, uint256 at) internal pure returns (uint256 w) {
        for (uint256 i = 0; i < 32; i++) w = (w << 8) | uint8(b[at + i]);
    }

    function _permit2Domain(uint256 chainId) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)"),
                keccak256("Permit2"),
                chainId,
                PERMIT2_ADDRESS
            )
        );
    }

    /// @notice the deployed UniversalRouter decodes the OLDER single-swap layout (no `minHopPriceX36`): the same exact-in
    /// swap in the layout of the pinned periphery reverts, in the deployed layout it pays exactly what it specified and
    /// hookData reaches the hook's pool (here a pool with no hook, so the swap itself is the evidence)
    function test_the_deployed_universal_router_reads_the_older_swap_layout() public {
        // fee 4321: USDC / WETH at 0.30 % with no hook and spacing 60 already exists on mainnet at the pinned block
        // (initialising it again is refused), and a fresh pool is what every other test here uses
        PoolKey memory k = _erc20Key(IHooks(address(0)), 4321);
        _openPool(k);
        uint128 amt = _amt(k.currency0);

        (bytes memory commands, bytes[] memory inputs) =
            PeripheryPlans.swapPinnedLayoutForUniversalRouter(k, true, amt, HOOK_DATA);
        vm.prank(trader);
        (bool ok,) = MAINNET_UNIVERSAL_ROUTER.call(
            abi.encodeCall(IUniversalRouter.execute, (commands, inputs, block.timestamp + 60))
        );
        assertFalse(ok, "the pinned layout went through the deployed router");

        (PeripheryBooks memory b,) = _routerSwapWithBooks(trader, k, _swapOf(k, true, true, HOOK_DATA));
        assertEq(b.user0, -int256(uint256(amt)), "the deployed layout: paid exactly what it specified");
        assertGt(b.user1, 0, "and received the output");
        _assertPeripheryConserved(b, "the deployed layout");
    }

    /// @notice the same mistake on a NATIVE pool does not revert: the deployed router reads the pinned layout's
    /// `minHopPriceX36` word (0) as the offset of `hookData`, finds the struct's first word there - `currency0`, which is
    /// the zero address on a native pool - reads it as a length of 0, and swaps with EMPTY hookData. The swap stands and
    /// the hook is handed other bytes than the user wrote. (On an ERC-20 pool `currency0` is an address, read as a length
    /// far past the calldata, and the decoder reverts: the test above.)
    function test_the_pinned_layout_on_a_native_pool_swaps_and_the_hook_gets_empty_hookData() public {
        PeripheryProbeHook probe = PeripheryProbeHook(
            _deployHook(type(PeripheryProbeHook).creationCode, abi.encode(manager), _probeFlags())
        );
        PoolKey memory k = _nativeKey(IHooks(address(probe)), 3000);
        _openPool(k);
        probe.clear();
        uint128 amt = _amt(k.currency0);
        (bytes memory commands, bytes[] memory inputs) =
            PeripheryPlans.swapPinnedLayoutForUniversalRouter(k, true, amt, HOOK_DATA);
        uint256 before = trader.balance;
        vm.prank(trader);
        IUniversalRouter(MAINNET_UNIVERSAL_ROUTER).execute{value: amt}(commands, inputs, block.timestamp + 60);
        assertEq(before - trader.balance, amt, "the swap went through: the trader paid its ETH");
        assertEq(probe.seenCount(), 2, "beforeSwap and afterSwap ran");
        assertEq(probe.seenAt(0).hookData, "", "the hook was handed empty hookData, not the user's");
        assertEq(probe.seenAt(1).hookData, "", "in both callbacks");
    }


    /// @notice the PositionManager built from the pinned periphery is NOT the deployed one: other code, other size
    /// (the harness says so; the fork suites run the deployed one)
    function test_the_pinned_position_manager_is_not_the_deployed_one() public {
        address ours = vm.deployCode(
            "PositionManager.sol:PositionManager",
            abi.encode(manager, PERMIT2_ADDRESS, MAINNET_UNSUBSCRIBE_GAS_LIMIT, address(0), MAINNET_WETH)
        );
        console2.log("pinned PositionManager runtime size", ours.code.length);
        assertTrue(ours.code.length != MAINNET_POSITION_MANAGER.code.length, "the same size as the deployed one");
    }
}
