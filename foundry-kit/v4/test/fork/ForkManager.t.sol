// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {V4Harness} from "../../src/V4Harness.sol";

interface IFiatTokenProbe {
    function isBlacklisted(address) external view returns (bool);
    function blacklister() external view returns (address);
    function blacklist(address) external;
}

interface IOwnedProbe {
    function owner() external view returns (address);
    function protocolFeeController() external view returns (address);
}

/// @notice The fork itself (K16): which chain, which block, which contract, and how the test actors get real money.
/// Runs only under `V4_MANAGER=fork` with `RPC_URL` set (`FOUNDRY_PROFILE=fork`, README "The fork"); anywhere else every
/// test here is SKIPPED with the reason, never green.
contract ForkManagerTest is V4Harness {
    using PoolIdLibrary for PoolKey;

    address internal alice = address(0xA11CE);

    function setUp() public {
        _setUpV4OnFork();
    }

    /// @notice the chain and the block are the pinned ones, not whatever the endpoint calls "latest"
    function test_the_fork_is_mainnet_at_the_pinned_block() public view {
        assertEq(block.chainid, 1, "not Ethereum mainnet");
        assertEq(block.number, forkBlock, "the fork is not at the block the harness pinned");
        assertEq(forkBlock, vm.envOr("FORK_BLOCK", DEFAULT_FORK_BLOCK), "FORK_BLOCK / the constant was not honoured");
    }

    /// @notice HOW WE KNOW THIS ADDRESS IS THE v4 POOLMANAGER, from the chain and not from a name in a document:
    /// (1) it has code at the pinned block; (2) the code carries its own address as an immutable - v4's `NoDelegateCall`
    /// stores `address(this)` at construction, and a manager etched elsewhere refuses every call (the fixture path's
    /// whole reason for etching at this address); (3) it answers the v4-only error: `settle()` outside `unlock` reverts
    /// `IPoolManager.ManagerLocked()`; (4) its storage reads through v4's `extsload`; (5) it initialises a pool with this
    /// kit's key and emits v4's `Initialize` from this address; (6) the code is byte-for-byte what `fetch-bytecode.sh`
    /// fetched for the fixture path (24 009 bytes, keccak 0x785f1014...c7ce1293, README "Measured on this machine").
    function test_the_address_is_the_v4_pool_manager_and_this_is_how_we_know() public {
        bytes memory code = address(manager).code;
        assertEq(address(manager), MAINNET_POOL_MANAGER, "not the canonical address");
        assertEq(code.length, 24_009, "(1) code size");
        assertEq(keccak256(code), 0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293, "(6) code hash");
        assertTrue(_contains(code, abi.encodePacked(MAINNET_POOL_MANAGER)), "(2) no NoDelegateCall immutable of itself");

        vm.expectRevert(IPoolManager.ManagerLocked.selector);
        manager.settle();

        // (4) a raw storage read through extsload answers (slot 0 is the owner in v4's layout, Owned first)
        address owner = IOwnedProbe(address(manager)).owner();
        assertEq(address(uint160(uint256(manager.extsload(bytes32(0))))), owner, "(4) extsload does not read storage");
        console2.log("owner                ", owner);
        console2.log("protocolFeeController", IOwnedProbe(address(manager)).protocolFeeController());

        // (5) a pool of our own, on the real manager
        PoolKey memory key = _poolKey(IHooks(address(0)), 3000, 60);
        vm.expectEmit(true, true, true, false, address(manager));
        emit IPoolManager.Initialize(key.toId(), currency0, currency1, 3000, 60, IHooks(address(0)), 0, 0);
        manager.initialize(key, 79228162514264337593543950336);
    }

    /// @notice real money: USDC and WETH through forge-std's `deal` (it finds the balance slot), ETH through `vm.deal`
    function test_real_currencies_reach_the_actors() public {
        _fundReal(realUsdc(), alice, 1_000e6);
        _fundReal(realWeth(), alice, 5e18);
        _fundReal(Currency.wrap(address(0)), alice, 7e18);
        assertEq(IERC20Minimal(MAINNET_USDC).balanceOf(alice), 1_000e6);
        assertEq(IERC20Minimal(MAINNET_WETH).balanceOf(alice), 5e18);
        assertEq(alice.balance, 7e18);
        // `_fundReal` ADDS, as `_fundNative` does
        _fundReal(realUsdc(), alice, 1e6);
        assertEq(IERC20Minimal(MAINNET_USDC).balanceOf(alice), 1_001e6);
        // and approves both of the kit's routers
        assertEq(IERC20Minimal(MAINNET_USDC).allowance(alice, address(router)), type(uint256).max);
        assertEq(IERC20Minimal(MAINNET_WETH).allowance(alice, address(liquidity)), type(uint256).max);
        // `_trueBalance` reads a real token's balanceOf (a real token has no `trueBalanceOf` to ask)
        assertEq(_trueBalance(realUsdc(), alice), 1_001e6);
    }

    /// @notice WHERE `deal` FAILS ON USDC, measured - two ways, both from one fact: FiatToken v2.2 keeps the blocklist flag
    /// in the top bit of the SAME word as the balance (`balanceAndBlacklistStates`), and `balanceOf` masks it off.
    /// (1) The FIRST `deal` to a blocklisted account reverts: stdStorage's search pokes the word, sees `balanceOf` disagree
    ///     with what it wrote, and dies in its own arithmetic (panic 0x11, trace in the K16 log).
    /// (2) A `deal` to an account whose slot stdStorage already found (it caches it, per token and account, for the rest
    ///     of the test) writes the whole word: the balance lands and the account is quietly UN-blocklisted. A test that
    ///     funds, blocklists, then funds again is testing an account the token no longer blocks.
    function test_deal_on_a_blocklisted_usdc_account_reverts_or_silently_unblocklists() public {
        IFiatTokenProbe t = IFiatTokenProbe(MAINNET_USDC);
        address bob = address(0xB0B);
        vm.startPrank(t.blacklister());
        t.blacklist(alice);
        vm.stopPrank();
        vm.expectRevert(); // (1)
        this.dealExternal(MAINNET_USDC, alice, 1e6);
        assertTrue(t.isBlacklisted(alice), "(1) still blocklisted");

        deal(MAINNET_USDC, bob, 1e6); // stdStorage finds and caches bob's slot
        vm.prank(t.blacklister());
        t.blacklist(bob);
        assertTrue(t.isBlacklisted(bob));
        deal(MAINNET_USDC, bob, 2e6); // (2) the cached slot, the whole word
        assertEq(IERC20Minimal(MAINNET_USDC).balanceOf(bob), 2e6);
        assertFalse(t.isBlacklisted(bob), "deal left the flag alone: the trap is gone, and so can the guard be");
    }

    function dealExternal(address token, address to, uint256 amount) external {
        deal(token, to, amount);
    }

    /// @notice ...and what the harness does about it: `_fundReal` refuses to fund a blocklisted USDC account, loudly
    function test_fundReal_refuses_a_blocklisted_usdc_account() public {
        IFiatTokenProbe t = IFiatTokenProbe(MAINNET_USDC);
        vm.prank(t.blacklister());
        t.blacklist(alice);
        vm.expectRevert(abi.encodeWithSelector(V4Harness.DealWouldClearUsdcBlocklist.selector, alice));
        this.fundRealExternal(realUsdc(), alice, 1e6);
        assertTrue(t.isBlacklisted(alice), "still blocklisted");
    }

    /// @notice WHERE `deal` FAILS ON WETH, measured: with `adjust = true` (move totalSupply too). WETH9's totalSupply is
    /// `address(this).balance`, not a storage slot, so stdStorage has nothing to find. `_fundReal` never adjusts.
    function test_deal_with_adjust_on_weth_reverts() public {
        vm.expectRevert();
        this.dealAdjust(MAINNET_WETH, alice, 1e18);
    }

    function dealAdjust(address token, address to, uint256 amount) external {
        deal(token, to, amount, true);
    }

    function fundRealExternal(Currency c, address who, uint256 amount) external {
        _fundReal(c, who, amount);
    }

    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        for (uint256 i = 0; i + needle.length <= hay.length; i++) {
            bool all = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (hay[i + j] != needle[j]) {
                    all = false;
                    break;
                }
            }
            if (all) return true;
        }
        return false;
    }
}
