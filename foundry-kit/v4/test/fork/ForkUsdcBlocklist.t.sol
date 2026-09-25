// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {DeltaFeeHook} from "../../src/examples/DeltaFeeHook.sol";
import {ClaimsFeeHook} from "../../src/examples/ClaimsFeeHook.sol";
import {ForkPoolsBase} from "./ForkExamples.t.sol";

interface IFiatToken {
    function blacklister() external view returns (address);
    function pauser() external view returns (address);
    function blacklist(address) external;
    function unBlacklist(address) external;
    function isBlacklisted(address) external view returns (bool);
    function pause() external;
    function unpause() external;
}

/// @notice USDC's own switches, on a v4 pool with an example hook (K16): the blocklist and the pause, which no token the
/// kit deploys has. Who is blocklisted decides who is stuck: the swapper, the LP, the hook, the manager. Measured on the
/// mainnet fork (FiatToken v2.2 behind the USDC proxy at the pinned block), on a fresh USDC / WETH pool.
///
/// The one that matters for a hook author: a hook that RECEIVES the currency (DeltaFeeHook takes its fee as tokens and
/// pays rebates out of them) turns its own blocklisting into a freeze of its whole pool - once it holds USDC, every swap
/// touches USDC on the hook's side, one way or the other. A hook that keeps its fee as ERC-6909 claims (ClaimsFeeHook)
/// is never a party to a USDC transfer during a swap, and its pool keeps trading.
contract ForkUsdcBlocklistTest is ForkPoolsBase {
    DeltaFeeHook internal dHook;
    ClaimsFeeHook internal cHook;
    PoolKey internal dKey; // USDC / WETH through DeltaFeeHook
    PoolKey internal cKey; // USDC / WETH through ClaimsFeeHook
    IFiatToken internal fiat = IFiatToken(MAINNET_USDC);
    address internal treasury = address(0x7EA5);
    address internal lp2 = address(0x1B2);

    bytes internal constant BLOCKED = "Blacklistable: account is blacklisted";
    bytes internal constant PAUSED = "Pausable: paused";

    function setUp() public {
        _setUpV4OnFork();
        dHook = DeltaFeeHook(
            _deployHook(
                type(DeltaFeeHook).creationCode,
                abi.encode(manager),
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                    | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            )
        );
        cHook = ClaimsFeeHook(
            _deployHook(
                type(ClaimsFeeHook).creationCode,
                abi.encode(manager, treasury),
                Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            )
        );
        _fundActors();
        _fundReal(realUsdc(), lp2, 1_000_000e6);
        _fundReal(realWeth(), lp2, 1_000e18);
        dKey = _initUsdcWeth(IHooks(address(dHook)), 3000);
        cKey = _initUsdcWeth(IHooks(address(cHook)), 3000);
    }

    // ------------------------------------------------------------------ helpers
    function _block(address who) internal {
        vm.prank(fiat.blacklister());
        fiat.blacklist(who);
        assertTrue(fiat.isBlacklisted(who));
    }

    function _unblock(address who) internal {
        vm.prank(fiat.blacklister());
        fiat.unBlacklist(who);
    }

    /// @notice swap as `who`; (true, "") or (false, the revert data)
    function _try(address who, PoolKey memory k, SwapParams memory p) internal returns (bool ok, bytes memory reason) {
        vm.prank(who);
        try router.swap(k, p, "") {
            ok = true;
        } catch (bytes memory r) {
            reason = r;
        }
    }

    /// @notice the token's own words somewhere in the revert data: raw from a `transferFrom`, or wrapped once or twice
    /// in v4's `WrappedError` (the manager's `take`, then the hook call around it)
    function _says(bytes memory reason, bytes memory words) internal pure returns (bool) {
        if (words.length > reason.length) return false;
        for (uint256 i = 0; i + words.length <= reason.length; i++) {
            bool all = true;
            for (uint256 j = 0; j < words.length; j++) {
                if (reason[i + j] != words[j]) {
                    all = false;
                    break;
                }
            }
            if (all) return true;
        }
        return false;
    }

    function _fillDeltaReserves() internal {
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(trader);
            router.swap(dKey, _pk(dKey, true, true, 10), "");
            vm.prank(trader);
            router.swap(dKey, _pk(dKey, true, false, 10), "");
        }
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _lp2Position(PoolKey memory k, int256 liq) internal {
        (int24 lower, int24 upper) = _fullRange(k.tickSpacing);
        vm.prank(lp2);
        liquidity.modifyLiquidity(
            k, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: liq, salt: bytes32(0)}), ""
        );
    }

    // ------------------------------------------------------------------ the swapper
    /// @notice a blocklisted swapper can neither pay in USDC nor be paid in it: both directions revert, in the token's
    /// own words, and the pool is untouched for everybody else
    function test_a_blocklisted_swapper_can_neither_pay_nor_be_paid_in_usdc() public {
        _block(trader);
        (bool ok, bytes memory r) = _try(trader, dKey, _pk(dKey, true, true, 1)); // USDC in
        assertFalse(ok, "a blocklisted account paid in USDC");
        assertTrue(_says(r, BLOCKED), "not the token's refusal");
        (ok, r) = _try(trader, dKey, _pk(dKey, true, false, 1)); // WETH in, USDC out
        assertFalse(ok, "a blocklisted account was paid in USDC");
        assertTrue(_says(r, BLOCKED), "not the token's refusal");
        (ok,) = _try(provider, dKey, _pk(dKey, true, false, 1));
        assertTrue(ok, "somebody else's swap should not care");
    }

    // ------------------------------------------------------------------ the LP
    /// @notice a blocklisted LP's USDC is stuck in the pool (the kit's helper pays the LP itself; v4 would let a router
    /// pay a different recipient, or mint claims instead) until the blocklister lets go, and then it all comes out
    function test_a_blocklisted_lp_is_stuck_until_unblocked() public {
        _lp2Position(dKey, 1e15);
        _block(lp2);
        (int24 lower, int24 upper) = _fullRange(dKey.tickSpacing);
        vm.prank(lp2);
        vm.expectRevert(); // the manager's take of USDC to lp2, wrapped (ERC20TransferFailed)
        liquidity.modifyLiquidity(
            dKey, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: -1e15, salt: bytes32(0)}), ""
        );
        _unblock(lp2);
        uint256 before = _trueBalance(realUsdc(), lp2);
        _lp2Position(dKey, -1e15);
        assertGt(_trueBalance(realUsdc(), lp2), before, "nothing came out after the unblock");
    }

    // ------------------------------------------------------------------ the hook
    /// @notice THE ONE. DeltaFeeHook blocklisted, holding USDC fees from earlier swaps: every orientation now touches USDC
    /// on the hook's side - the fee is `take`n TO the hook when USDC is unspecified, the rebate is paid FROM the hook
    /// when USDC is specified - so every swap on its pool reverts. Nobody but the hook is blocklisted.
    /// Seen red first (K16) with the expectation that ignores the token - "the hook's blocklisting is the hook's
    /// problem, swaps go through" - `assertTrue(ok)`: FAIL on the first orientation.
    function test_a_blocklisted_delta_hook_freezes_its_own_pool() public {
        _fillDeltaReserves();
        uint256 reserve = dHook.reserveOf(realUsdc());
        assertGt(reserve, 0, "test setup: the hook holds no USDC, and this proves only half");
        _block(address(dHook));
        for (uint256 i = 0; i < 4; i++) {
            (bool ok, bytes memory r) = _try(trader, dKey, _pk(dKey, i < 2, i % 2 == 0, 1));
            assertFalse(ok, "a swap went through a pool whose hook the token refuses");
            assertTrue(_says(r, BLOCKED), "reverted, but not in the token's words");
        }
        assertEq(dHook.reserveOf(realUsdc()), reserve, "the frozen hook's ledger moved");
        _unblock(address(dHook));
        (bool ok2,) = _try(trader, dKey, _pk(dKey, true, true, 1));
        assertTrue(ok2, "the pool did not come back when the hook was unblocked");
    }

    /// @notice the same hook blocklisted BEFORE it ever held USDC: only the swaps whose fee is USDC die (the fee is taken
    /// to the hook); a swap that specifies USDC owes no rebate out of an empty USDC reserve and goes through
    function test_a_blocklisted_delta_hook_with_no_usdc_yet_fails_only_where_the_fee_is_usdc() public {
        _block(address(dHook));
        (bool ok, bytes memory r) = _try(trader, dKey, _pk(dKey, true, false, 1)); // WETH in: USDC unspecified, fee USDC
        assertFalse(ok, "the fee in USDC was taken to a blocklisted hook");
        assertTrue(_says(r, BLOCKED));
        (ok,) = _try(trader, dKey, _pk(dKey, true, true, 1)); // USDC in: fee in WETH, no USDC rebate to pay
        assertTrue(ok, "a swap that never moves USDC to or from the hook was refused");
    }

    /// @notice the contrast: ClaimsFeeHook keeps its fee as ERC-6909 claims, so no swap moves USDC to or from it, and a
    /// blocklisted ClaimsFeeHook's pool keeps trading. Its withdrawal still works: the manager pays the TREASURY, and the
    /// hook is not a party to that transfer (FiatToken checks the caller, the sender and the recipient - the manager
    /// twice and the treasury).
    function test_a_blocklisted_claims_hook_keeps_its_pool_trading_and_still_withdraws() public {
        _block(address(cHook));
        for (uint256 i = 0; i < 4; i++) {
            (bool ok,) = _try(trader, cKey, _pk(cKey, i < 2, i % 2 == 0, 1));
            assertTrue(ok, "a claims hook's blocklisting stopped a swap");
        }
        uint256 claims = cHook.claimsOf(realUsdc());
        assertGt(claims, 0, "no USDC fee earned");
        uint256 t0 = _trueBalance(realUsdc(), treasury);
        vm.prank(treasury);
        cHook.withdraw(realUsdc(), treasury, claims);
        assertEq(_trueBalance(realUsdc(), treasury) - t0, claims, "the treasury was not paid");
        // ...and a blocklisted TREASURY cannot take USDC to itself, but the hook lets it name another recipient
        _block(treasury);
        _swapWithBooks(trader, cKey, _pk(cKey, true, false, 1));
        uint256 more = cHook.claimsOf(realUsdc());
        vm.prank(treasury);
        vm.expectRevert();
        cHook.withdraw(realUsdc(), treasury, more);
        vm.prank(treasury);
        cHook.withdraw(realUsdc(), address(0xCAFE), more);
        assertEq(_trueBalance(realUsdc(), address(0xCAFE)), more, "the other recipient was not paid");
    }

    // ------------------------------------------------------------------ the manager, and the pause
    /// @notice the manager itself blocklisted (it holds every v4 pool's USDC in one balance): every USDC pool, with any
    /// hook or none, stops - swaps both ways, and liquidity out
    function test_a_blocklisted_manager_freezes_every_usdc_pool() public {
        _lp2Position(cKey, 1e15);
        _block(address(manager));
        (bool ok, bytes memory r) = _try(trader, cKey, _pk(cKey, true, true, 1));
        assertFalse(ok);
        assertTrue(_says(r, BLOCKED));
        (ok, r) = _try(trader, cKey, _pk(cKey, true, false, 1));
        assertFalse(ok);
        assertTrue(_says(r, BLOCKED));
        (int24 lower, int24 upper) = _fullRange(cKey.tickSpacing);
        vm.prank(lp2);
        vm.expectRevert();
        liquidity.modifyLiquidity(
            cKey, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: -1e15, salt: bytes32(0)}), ""
        );
    }

    /// @notice USDC paused: nothing that moves USDC moves, on any pool, whoever you are - and nothing is lost: after the
    /// unpause the same swap goes through and the LP takes its position out
    function test_a_paused_usdc_freezes_the_pool_and_the_unpause_restores_it() public {
        _lp2Position(dKey, 1e15);
        vm.prank(fiat.pauser());
        fiat.pause();
        for (uint256 i = 0; i < 2; i++) {
            (bool ok, bytes memory r) = _try(trader, dKey, _pk(dKey, true, i == 0, 1));
            assertFalse(ok, "a swap moved USDC while it was paused");
            assertTrue(_says(r, PAUSED), "reverted, but not in the token's words");
        }
        (int24 lower, int24 upper) = _fullRange(dKey.tickSpacing);
        vm.prank(lp2);
        vm.expectRevert();
        liquidity.modifyLiquidity(
            dKey, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: -1e15, salt: bytes32(0)}), ""
        );
        vm.prank(fiat.pauser());
        fiat.unpause();
        (bool ok2,) = _try(trader, dKey, _pk(dKey, true, true, 1));
        assertTrue(ok2, "the pool did not come back after the unpause");
        uint256 before = _trueBalance(realUsdc(), lp2);
        _lp2Position(dKey, -1e15);
        assertGt(_trueBalance(realUsdc(), lp2), before, "the LP's USDC did not come out after the unpause");
    }
}
