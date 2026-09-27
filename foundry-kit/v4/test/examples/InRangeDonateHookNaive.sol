// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title InRangeDonateHookNaive - the FIRST DRAFT of `src/examples/InRangeDonateHook.sol`, kept as a test fixture
/// @notice The same fee, the same claims, the same SPEC (D1-D5 in the example's header) - and the design an owner writes
/// first: fees go into a pot, and anyone may `sweep` a pool to donate its pot to "the liquidity in range". Cheap (one
/// donation per sweep, however many swaps) and every amount is right: what was taken is what is donated, the claims are
/// the pot, nothing is created or lost. What is wrong is WHO: the donation pays whoever is in range when the sweep runs,
/// and D2 says the fee is owed to whoever was in range when it was taken. A position placed just before the sweep - by
/// the caller of the sweep, in the same transaction - takes a share it never earned; a dust position placed where nobody
/// else is (after pushing the price out of every honest range, or after the price left them) takes the whole pot.
/// It has no treasury (D3): a fee taken with nobody in range waits in the pot for whoever comes next.
///
/// Not an example to copy: the fixture the WHO invariant and the JIT-recipient actor are shown red against
/// (`test/examples/InRangeDonateHook.invariants.t.sol`, `test/examples/InRangeDonateHook.t.sol`).
contract InRangeDonateHookNaive is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 public constant BPS = 10_000;
    uint256 public constant FEE_BPS = 30;

    IPoolManager public immutable manager;

    mapping(PoolId => uint256[2]) internal _pot;
    mapping(Currency => uint256) public feesTaken;
    mapping(Currency => uint256) public donated;

    error NotTheManager();
    error NotImplemented();

    modifier onlyManager() {
        if (msg.sender != address(manager)) revert NotTheManager();
        _;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.afterSwap = true;
        p.afterSwapReturnDelta = true;
    }

    function requiredFlags() public pure returns (uint160) {
        return Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    }

    function feeOf(uint256 unspecifiedAbs) public pure returns (uint256) {
        return unspecifiedAbs * FEE_BPS / BPS;
    }

    function potOf(PoolId id) external view returns (uint256 amount0, uint256 amount1) {
        return (_pot[id][0], _pot[id][1]);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        override
        onlyManager
        returns (bytes4, int128)
    {
        bool s0 = (params.amountSpecified < 0) == params.zeroForOne;
        Currency unspecified = s0 ? key.currency1 : key.currency0;
        int128 u = s0 ? delta.amount1() : delta.amount0();
        uint256 fee = feeOf(u < 0 ? uint256(uint128(-u)) : uint256(uint128(u)));
        if (fee == 0) return (IHooks.afterSwap.selector, 0);
        manager.mint(address(this), unspecified.toId(), fee);
        feesTaken[unspecified] += fee;
        _pot[key.toId()][s0 ? 1 : 0] += fee;
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    /// @notice donate the pot to "the LPs": whoever is in range now
    function sweep(PoolKey calldata key) external {
        manager.unlock(abi.encode(key));
    }

    function unlockCallback(bytes calldata data) external override onlyManager returns (bytes memory) {
        PoolKey memory key = abi.decode(data, (PoolKey));
        PoolId id = key.toId();
        uint256 p0 = _pot[id][0];
        uint256 p1 = _pot[id][1];
        if ((p0 == 0 && p1 == 0) || manager.getLiquidity(id) == 0) return "";
        delete _pot[id];
        manager.donate(key, p0, p1, "");
        if (p0 != 0) manager.burn(address(this), key.currency0.toId(), p0);
        if (p1 != 0) manager.burn(address(this), key.currency1.toId(), p1);
        donated[key.currency0] += p0;
        donated[key.currency1] += p1;
        return "";
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        revert NotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert NotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert NotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert NotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert NotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert NotImplemented();
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert NotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert NotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert NotImplemented();
    }
}
