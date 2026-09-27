// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";

/// @title PeripheryPlans
/// @notice What a user sends to Uniswap's periphery, encoded as the periphery reads it: the `unlockData` of
/// `PositionManager.modifyLiquidities` and of a V4Router, and the `commands` / `inputs` of the UniversalRouter. Pure
/// encoding, nothing called: the harness (`PeripheryHarness`) and the campaign's handler both use it, so the bytes a
/// test sends are the bytes the invariant campaign sends.
///
/// TWO LAYOUTS OF THE SAME SWAP, measured (K17b, 2026-09-27). The periphery at the commit `install-v4.sh` pins has a
/// `minHopPriceX36` field in `IV4Router.ExactInputSingleParams` / `ExactOutputSingleParams`; the UniversalRouter DEPLOYED
/// on mainnet (block 26 050 000) was built from an older periphery and decodes the struct without it. The same exact-in
/// swap in the pinned layout sent to the deployed router: on an ERC-20 pool it reverts (empty revert data); on a NATIVE
/// pool it goes through and the hook is handed EMPTY hookData - the deployed decoder reads the pinned layout's
/// `minHopPriceX36` (0) as the offset of `hookData`, and the word it lands on, `currency0`, is 0 on a native pool
/// (`test-periphery/fork/PeripheryAddresses.t.sol`: `test_the_deployed_universal_router_reads_the_older_swap_layout`,
/// `test_the_pinned_layout_on_a_native_pool_swaps_and_the_hook_gets_empty_hookData`). A hook's tests that encode against
/// the pinned periphery and then run against the deployed router test a revert at best, and at worst a swap whose
/// hookData is not the user's: encode for the router the hook will actually be called through.
library PeripheryPlans {
    /// @notice the UniversalRouter's command for "run these V4Router actions", and for "send what this contract holds"
    uint8 internal constant UR_V4_SWAP = 0x10;
    uint8 internal constant UR_SWEEP = 0x04;

    /// @notice the deployed UniversalRouter's `ExactInputSingleParams` (no `minHopPriceX36`): see the header
    struct DeployedExactInputSingle {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    struct DeployedExactOutputSingle {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountOut;
        uint128 amountInMaximum;
        bytes hookData;
    }

    // ------------------------------------------------------------------ PositionManager
    /// @notice MINT_POSITION paid with SETTLE_PAIR (the locker pays, through Permit2); on a native pool the ETH sent
    /// with the call pays and SWEEP returns the rest to `owner`
    function mint(
        PoolKey memory key,
        int24 lower,
        int24 upper,
        uint256 liquidity,
        address owner,
        bytes memory hookData
    ) internal pure returns (bytes memory) {
        bool native = key.currency0.isAddressZero();
        bytes memory actions = native
            ? abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP))
            : abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](native ? 3 : 2);
        params[0] = abi.encode(
            key, lower, upper, liquidity, type(uint128).max, type(uint128).max, owner, hookData
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        if (native) params[2] = abi.encode(key.currency0, owner);
        return abi.encode(actions, params);
    }

    /// @notice INCREASE_LIQUIDITY closed with CLOSE_CURRENCY on both sides (fees owed to the position can exceed what
    /// the increase costs, so a side can end as a credit: SETTLE_PAIR would revert on it), SWEEP on a native pool
    function increase(PoolKey memory key, uint256 tokenId, uint256 liquidity, address recipient, bytes memory hookData)
        internal
        pure
        returns (bytes memory)
    {
        bool native = key.currency0.isAddressZero();
        bytes memory actions = native
            ? abi.encodePacked(
                uint8(Actions.INCREASE_LIQUIDITY),
                uint8(Actions.CLOSE_CURRENCY),
                uint8(Actions.CLOSE_CURRENCY),
                uint8(Actions.SWEEP)
            )
            : abi.encodePacked(
                uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.CLOSE_CURRENCY), uint8(Actions.CLOSE_CURRENCY)
            );
        bytes[] memory params = new bytes[](native ? 4 : 3);
        params[0] = abi.encode(tokenId, liquidity, type(uint128).max, type(uint128).max, hookData);
        params[1] = abi.encode(key.currency0);
        params[2] = abi.encode(key.currency1);
        if (native) params[3] = abi.encode(key.currency0, recipient);
        return abi.encode(actions, params);
    }

    /// @notice DECREASE_LIQUIDITY, both currencies taken to `recipient`
    function decrease(PoolKey memory key, uint256 tokenId, uint256 liquidity, address recipient, bytes memory hookData)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, uint128(0), uint128(0), hookData);
        params[1] = abi.encode(key.currency0, key.currency1, recipient);
        return abi.encode(actions, params);
    }

    /// @notice BURN_POSITION (it removes whatever liquidity is left first), both currencies taken to `recipient`
    function burn(PoolKey memory key, uint256 tokenId, address recipient, bytes memory hookData)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), hookData);
        params[1] = abi.encode(key.currency0, key.currency1, recipient);
        return abi.encode(actions, params);
    }

    // ------------------------------------------------------------------ swaps
    /// @notice the three actions of one single-pool swap: the swap, SETTLE_ALL of the input (at most `maxIn`), TAKE_ALL
    /// of the output (at least `minOut`)
    function _swapActions() private pure returns (bytes memory) {
        return abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
        );
    }

    function _swapActionsOut() private pure returns (bytes memory) {
        return abi.encodePacked(
            uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
        );
    }

    /// @notice a single-pool swap for a V4Router built from the PINNED periphery (`MockV4Router` on the source
    /// manager). `limit` is the minimum out of an exact-in swap and the maximum in of an exact-out one.
    function swapPinned(
        PoolKey memory key,
        bool zeroForOne,
        bool exactIn,
        uint128 amount,
        uint128 limit,
        bytes memory hookData
    ) internal pure returns (bytes memory) {
        (Currency cin, Currency cout) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        bytes[] memory params = new bytes[](3);
        if (exactIn) {
            params[0] = abi.encode(IV4Router.ExactInputSingleParams(key, zeroForOne, amount, limit, 0, hookData));
            params[1] = abi.encode(cin, uint256(amount));
            params[2] = abi.encode(cout, uint256(limit));
            return abi.encode(_swapActions(), params);
        }
        params[0] = abi.encode(IV4Router.ExactOutputSingleParams(key, zeroForOne, amount, limit, 0, hookData));
        params[1] = abi.encode(cin, uint256(limit));
        params[2] = abi.encode(cout, uint256(amount));
        return abi.encode(_swapActionsOut(), params);
    }

    /// @notice the same swap for the DEPLOYED UniversalRouter: V4_SWAP with the actions in the deployed layout, and -
    /// when the input is ETH - a SWEEP of what the router holds of it to `sweepTo` (an exact-out swap sends more ETH
    /// than it uses)
    function swapDeployedUniversalRouter(
        PoolKey memory key,
        bool zeroForOne,
        bool exactIn,
        uint128 amount,
        uint128 limit,
        bytes memory hookData,
        address sweepTo
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        (Currency cin, Currency cout) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        bytes[] memory params = new bytes[](3);
        bytes memory actions;
        if (exactIn) {
            actions = _swapActions();
            params[0] = abi.encode(DeployedExactInputSingle(key, zeroForOne, amount, limit, hookData));
            params[1] = abi.encode(cin, uint256(amount));
            params[2] = abi.encode(cout, uint256(limit));
        } else {
            actions = _swapActionsOut();
            params[0] = abi.encode(DeployedExactOutputSingle(key, zeroForOne, amount, limit, hookData));
            params[1] = abi.encode(cin, uint256(limit));
            params[2] = abi.encode(cout, uint256(amount));
        }
        bool nativeIn = cin.isAddressZero();
        commands = nativeIn ? abi.encodePacked(UR_V4_SWAP, UR_SWEEP) : abi.encodePacked(UR_V4_SWAP);
        inputs = new bytes[](nativeIn ? 2 : 1);
        inputs[0] = abi.encode(actions, params);
        if (nativeIn) inputs[1] = abi.encode(address(0), sweepTo, uint256(0));
    }

    /// @notice the pinned layout sent to the deployed router: the measurement behind the header, kept callable
    function swapPinnedLayoutForUniversalRouter(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        bytes memory hookData
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        (Currency cin, Currency cout) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(IV4Router.ExactInputSingleParams(key, zeroForOne, amountIn, 0, 0, hookData));
        params[1] = abi.encode(cin, uint256(amountIn));
        params[2] = abi.encode(cout, uint256(0));
        commands = abi.encodePacked(UR_V4_SWAP);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(_swapActions(), params);
    }
}
