// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC6909Claims} from "v4-core/src/interfaces/external/IERC6909Claims.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {V4Harness} from "../../src/V4Harness.sol";
import {HookMiner} from "../../src/HookMiner.sol";
import {ClaimsFeeHook} from "../../src/examples/ClaimsFeeHook.sol";

/// @notice a treasury that is a contract and cannot receive ETH
contract RefusingTreasury {
    function pull(ClaimsFeeHook hook, Currency c, uint256 amount) external {
        hook.withdraw(c, address(this), amount);
    }

    receive() external payable {
        revert("no ETH here");
    }
}

/// @notice Unit tests for the claims example (C1-C5 in its header) on an ETH / token pool. The point of every swap test
/// is the pair of lines that say the same thing two ways: conservation over BALANCES alone (swapper + hook + manager)
/// closes to zero while the hook got nothing it could `balanceOf` - its fee is invisible to it - and conservation PER
/// PARTY, counting claims, says where the fee is.
contract ClaimsFeeHookTest is V4Harness {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    ClaimsFeeHook internal hook;
    PoolKey internal key;
    Currency internal eth = Currency.wrap(address(0));
    address internal provider = address(0xA11CE);
    address internal trader = address(0xB0B);
    address internal treasury = address(0x7EA5);

    function setUp() public {
        _setUpV4();
        hook = ClaimsFeeHook(
            _deployHook(
                type(ClaimsFeeHook).creationCode,
                abi.encode(manager, treasury),
                Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            )
        );
        vm.label(address(hook), "ClaimsFeeHook");
        _fundAndApprove(provider, 1_000_000e18);
        _fundAndApprove(trader, 1_000_000e18);
        _fundNative(provider, 1_000e18);
        _fundNative(trader, 1_000e18);
        key = _initNativePool(IHooks(address(hook)), 3000, 60, SQRT_PRICE_1_1, currency1);
        _addFullRangeLiquidity(key, provider, 100e18);
    }

    function _p(bool exactIn, bool zeroForOne, uint256 amount) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactIn ? -int256(amount) : int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function test_the_address_carries_exactly_the_declared_flags() public view {
        assertTrue(HookMiner.carriesExactly(address(hook), hook.requiredFlags()));
    }

    function test_only_the_manager_and_the_treasury() public {
        SwapParams memory p = _p(true, true, 1e18);
        BalanceDelta d;
        vm.expectRevert(ClaimsFeeHook.NotTheManager.selector);
        hook.afterSwap(address(this), key, p, d, "");
        vm.expectRevert(ClaimsFeeHook.NotTheManager.selector);
        hook.unlockCallback(abi.encode(eth, address(this), uint256(1)));
        vm.expectRevert(ClaimsFeeHook.NotTheTreasury.selector);
        hook.withdraw(eth, address(this), 1);
    }

    // ------------------------------------------------------------------ C1, C2 in all four orientations
    function _orientation(bool exactIn, bool zeroForOne, string memory label) internal {
        SwapParams memory p = _p(exactIn, zeroForOne, 1e18);
        bool s0 = exactIn == zeroForOne;
        SwapBooks memory b = _swapWithBooks(trader, key, p);
        int256[2] memory booked = [b.pool0 - b.caller0, b.pool1 - b.caller1];
        int256 poolUnspec = s0 ? b.pool1 : b.pool0;
        uint256 fee = uint256(poolUnspec < 0 ? -poolUnspec : poolUnspec) * 30 / 10_000;
        console2.log(label);
        console2.log("  swapper ETH, token1      :", vm.toString(b.swapper0), vm.toString(b.swapper1));
        console2.log("  hook balances ETH, token1:", vm.toString(b.hook0), vm.toString(b.hook1));
        console2.log("  hook CLAIMS ETH, token1  :", vm.toString(b.hookClaims0), vm.toString(b.hookClaims1));
        console2.log("  manager ETH, token1      :", vm.toString(b.manager0), vm.toString(b.manager1));

        // BALANCES ALONE close to zero - and the hook's fee is not in them
        assertEq(b.swapper0 + b.hook0 + b.manager0, 0, string.concat(label, ": ETH balances"));
        assertEq(b.swapper1 + b.hook1 + b.manager1, 0, string.concat(label, ": token1 balances"));
        assertEq(b.hook0, 0, string.concat(label, ": the hook's ETH balance moved (C2: the fee is a claim)"));
        assertEq(b.hook1, 0, string.concat(label, ": the hook's token1 balance moved (C2)"));
        // PER PARTY, claims counted (C1): the hook got its booked delta as claims, the manager's NET kept the pool's delta
        assertEq(b.swapper0, b.caller0, string.concat(label, ": swapper ETH"));
        assertEq(b.swapper1, b.caller1, string.concat(label, ": swapper token1"));
        assertEq(b.hookClaims0, booked[0], string.concat(label, ": the hook's ETH claims are not its booked delta"));
        assertEq(b.hookClaims1, booked[1], string.concat(label, ": the hook's token1 claims are not its booked delta"));
        assertEq(b.manager0 - b.hookClaims0, -b.pool0, string.concat(label, ": the manager's net ETH"));
        assertEq(b.manager1 - b.hookClaims1, -b.pool1, string.concat(label, ": the manager's net token1"));
        // C2: the fee, exact, in the unspecified currency
        assertEq(s0 ? b.hookClaims1 : b.hookClaims0, int256(fee), string.concat(label, ": fee"));
        assertEq(s0 ? b.hookClaims0 : b.hookClaims1, 0, string.concat(label, ": a claim in the specified currency"));
        assertGt(fee, 0);
        // C3: nobody else holds a claim
        assertEq(_claimsOf(eth, address(router)) + _claimsOf(currency1, address(router)), 0, "the router got claims");
        assertEq(_claimsOf(eth, trader) + _claimsOf(currency1, trader), 0, "the swapper got claims");
    }

    function test_exact_in_eth_in_the_fee_is_a_token1_claim() public {
        _orientation(true, true, "exact-in  ETH in");
    }

    function test_exact_in_eth_out_the_fee_is_an_eth_claim() public {
        _orientation(true, false, "exact-in  ETH out");
    }

    function test_exact_out_eth_in_the_fee_is_an_eth_claim() public {
        _orientation(false, true, "exact-out ETH in");
    }

    function test_exact_out_eth_out_the_fee_is_a_token1_claim() public {
        _orientation(false, false, "exact-out ETH out");
    }

    // ------------------------------------------------------------------ two pools sharing a currency (K15)
    /// @notice a LIMIT of the design, stated: the manager keeps claims per (owner, currency), so the ETH fees of every pool
    /// on this hook are ONE claim, and `feesBooked` is per currency too. Nothing is paid back out per pool (no rebate),
    /// so nothing can be drained across pools - but nothing on chain says which pool a claim came from except the
    /// hook's `FeeClaimed(poolId, ...)` events. Two ETH pools (ETH / token1, ETH / token0): the hook's ETH claim is the sum
    /// of the two pools' ETH fees, and the events, read per pool, add up to it exactly.
    function test_two_pools_fees_in_one_currency_are_one_claim_and_only_the_events_split_it() public {
        PoolKey memory b = _initNativePool(IHooks(address(hook)), 3000, 60, SQRT_PRICE_1_1, currency0);
        _addFullRangeLiquidity(b, provider, 100e18);
        uint256[2] memory perPool;
        uint256[2] memory booked;
        PoolKey[2] memory k = [key, b];
        uint256[2] memory amount = [uint256(1e18), 2e18];
        for (uint256 j = 0; j < 2; j++) {
            uint256 before = hook.claimsOf(eth);
            vm.recordLogs();
            vm.prank(trader);
            router.swap(k[j], _p(true, false, amount[j]), ""); // the non-ETH currency in: the fee is in ETH
            booked[j] = hook.claimsOf(eth) - before;
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 i = 0; i < logs.length; i++) {
                if (logs[i].emitter != address(hook) || logs[i].topics[0] != ClaimsFeeHook.FeeClaimed.selector) continue;
                if (logs[i].topics[2] != bytes32(uint256(uint160(Currency.unwrap(eth))))) continue;
                uint256 fee = abi.decode(logs[i].data, (uint256));
                if (logs[i].topics[1] == PoolId.unwrap(key.toId())) perPool[0] += fee;
                else if (logs[i].topics[1] == PoolId.unwrap(b.toId())) perPool[1] += fee;
            }
        }
        assertEq(perPool[0], booked[0], "pool A's events are not its ETH fee");
        assertEq(perPool[1], booked[1], "pool B's events are not its ETH fee");
        assertGt(perPool[0], 0);
        assertGt(perPool[1], perPool[0], "test setup: the two pools' fees are not told apart by size");
        assertEq(hook.claimsOf(eth), perPool[0] + perPool[1], "the hook's one ETH claim is not the two pools' fees");
        assertEq(hook.feesBooked(eth), perPool[0] + perPool[1]);
    }

    // ------------------------------------------------------------------ C3: nobody else may move the hook's claims
    /// @notice `OperatorSet` and `Approval` events the manager emitted with `owner` as the owner of the claims
    function _grantsBy(address owner, Vm.Log[] memory logs) internal view returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(manager) || logs[i].topics.length < 2) continue;
            bytes32 t = logs[i].topics[0];
            if (t != IERC6909Claims.OperatorSet.selector && t != IERC6909Claims.Approval.selector) continue;
            if (logs[i].topics[1] == bytes32(uint256(uint160(owner)))) n += 1;
        }
    }

    /// @notice C3: the hook grants nobody its claims. Its constructor, a swap in every orientation and a withdrawal of
    /// each currency emit no `OperatorSet` and no `Approval` with the hook as owner, and no party of the test is its
    /// operator or holds an allowance on either claim. An operator can move every claim the hook holds with
    /// `transferFrom`, outside any swap; the verifier V14's mutant W4 (`setOperator(0xBAD, true)` in the constructor)
    /// passed the whole suite before this test, because nothing in it ever calls `transferFrom`. The swaps' events are
    /// read through `_keepSwapLogs`, not a recording around them: `_swapWithBooks` consumes the recorder, and until K15b
    /// this test saw none of what the hook emitted inside a swap (the verifier V15's mutant VC1, `approve(0xBEEF, id, 1)`
    /// after every fee mint, 11/11 green here; now red). The four `Swap` events are counted, so the test cannot go blind
    /// that way again unnoticed.
    function test_the_hook_grants_nobody_an_operator_or_an_allowance() public {
        address t2 = address(0x7EA6);
        vm.recordLogs(); // the search inside `_deployHook` is pure: nothing is recorded but the constructor's events
        ClaimsFeeHook fresh = ClaimsFeeHook(
            _deployHook(
                type(ClaimsFeeHook).creationCode,
                abi.encode(manager, t2),
                Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            )
        );
        uint256 grants = _grantsBy(address(fresh), vm.getRecordedLogs());

        _keepSwapLogs = true;
        for (uint256 i = 0; i < 4; i++) {
            _swapWithBooks(trader, key, _p(i < 2, i % 2 == 0, 1e18));
        }
        _keepSwapLogs = false;
        Vm.Log[] memory swapLogs = _takeKeptSwapLogs();
        uint256 swaps;
        for (uint256 i = 0; i < swapLogs.length; i++) {
            if (swapLogs[i].emitter == address(manager) && swapLogs[i].topics[0] == IPoolManager.Swap.selector) swaps += 1;
        }
        assertEq(swaps, 4, "test setup: the swaps' own events were not read");
        grants += _grantsBy(address(hook), swapLogs);

        vm.recordLogs();
        vm.startPrank(treasury);
        hook.withdraw(eth, treasury, hook.claimsOf(eth) / 2);
        hook.withdraw(currency1, treasury, hook.claimsOf(currency1) / 2);
        vm.stopPrank();
        grants += _grantsBy(address(hook), vm.getRecordedLogs());
        assertEq(grants, 0, "the hook granted an operator or an allowance on its claims");

        address[8] memory parties =
            [address(router), address(liquidity), treasury, trader, provider, address(this), address(manager), t2];
        uint256[2] memory ids = [eth.toId(), currency1.toId()];
        for (uint256 i = 0; i < parties.length; i++) {
            assertFalse(manager.isOperator(address(hook), parties[i]), "a party is the hook's operator");
            assertFalse(manager.isOperator(address(fresh), parties[i]), "a party is the fresh hook's operator");
            for (uint256 j = 0; j < 2; j++) {
                assertEq(manager.allowance(address(hook), parties[i], ids[j]), 0, "a party holds an allowance");
            }
        }
    }

    // ------------------------------------------------------------------ C3, C4: the withdrawal
    function _earn() internal {
        for (uint256 i = 0; i < 3; i++) {
            _swapWithBooks(trader, key, _p(true, true, 1e18));
            _swapWithBooks(trader, key, _p(true, false, 1e18));
        }
    }

    function test_withdrawal_burns_exactly_what_it_pays_in_eth_and_in_the_token() public {
        _earn();
        for (uint256 j = 0; j < 2; j++) {
            Currency c = j == 0 ? eth : currency1;
            uint256 claims = hook.claimsOf(c);
            assertGt(claims, 0, "nothing earned: the test proves nothing");
            assertEq(claims, hook.feesBooked(c), "claims != fees booked");
            uint256 half = claims / 2;
            uint256 t0 = _trueBalance(c, treasury);
            uint256 m0 = _trueBalance(c, address(manager));
            vm.prank(treasury);
            hook.withdraw(c, treasury, half);
            assertEq(_trueBalance(c, treasury) - t0, half, "the treasury did not get the currency");
            assertEq(m0 - _trueBalance(c, address(manager)), half, "the manager did not pay it");
            assertEq(hook.claimsOf(c), claims - half, "claims not burned by what was paid");
            assertEq(hook.claimsOf(c), hook.feesBooked(c) - hook.withdrawn(c), "C3: claims != fees - withdrawn");
            assertEq(_claimsOf(c, treasury), 0, "the treasury was paid in claims");
        }
    }

    function test_withdrawing_more_than_the_claims_is_refused() public {
        _earn();
        uint256 claims = hook.claimsOf(eth);
        vm.prank(treasury);
        vm.expectRevert();
        hook.withdraw(eth, treasury, claims + 1);
    }

    /// @notice C4: a treasury that cannot receive ETH cannot withdraw ETH - v4's own wrapped error, nothing moves - and
    /// can still withdraw the token
    function test_a_treasury_that_refuses_eth_cannot_withdraw_it_and_nothing_moves() public {
        RefusingTreasury t = new RefusingTreasury();
        ClaimsFeeHook h = ClaimsFeeHook(
            _deployHook(
                type(ClaimsFeeHook).creationCode,
                abi.encode(manager, address(t)),
                Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            )
        );
        PoolKey memory k = _initNativePool(IHooks(address(h)), 500, 10, SQRT_PRICE_1_1, currency1);
        _addFullRangeLiquidity(k, provider, 100e18);
        for (uint256 i = 0; i < 2; i++) {
            _swapWithBooks(trader, k, _p(true, true, 1e18));
            _swapWithBooks(trader, k, _p(true, false, 1e18));
        }
        uint256 claims = h.claimsOf(eth);
        uint256 m0 = address(manager).balance;
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(t),
                bytes4(0),
                abi.encodeWithSignature("Error(string)", "no ETH here"),
                abi.encodeWithSelector(CurrencyLibrary.NativeTransferFailed.selector)
            )
        );
        t.pull(h, eth, claims);
        assertEq(h.claimsOf(eth), claims, "claims burned for a withdrawal that did not happen");
        assertEq(address(manager).balance, m0);
        t.pull(h, currency1, h.claimsOf(currency1));
        assertEq(h.claimsOf(currency1), 0);
    }
}
