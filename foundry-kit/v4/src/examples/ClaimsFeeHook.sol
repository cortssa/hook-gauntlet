// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title ClaimsFeeHook - A TOY. Do not copy its architecture into a product.
/// @notice The kit's worked example of a hook that keeps what it takes as ERC-6909 CLAIMS on the manager instead of
/// tokens: a fee of `FEE_BPS` of the pool's unspecified amount, returned from `afterSwap` as a positive delta and
/// squared with `manager.mint(address(this), currency.toId(), fee)` - the manager keeps the tokens (or the ETH) and owes
/// the hook a claim on them. The treasury withdraws: `burn` the claims, `take` the currency to itself, inside the
/// hook's own unlock. `DeltaFeeHook` next to it takes its fee as the token.
///
/// Why a claim changes what a test must count: after a fee the HOOK's token balance has not moved, the MANAGER's has
/// moved by the pool's delta PLUS the fee, and the hook is richer by a number that no ERC-20 `balanceOf` shows. An
/// invariant that sums ERC-20 balances sees every token where it is - so it still balances when the claim was minted
/// to the WRONG party. That is `foundry-kit/v4/README.md`'s old sentence, "an invariant that counts only ERC-20
/// balances will report a leak as conservation", and `test/examples/ClaimsFeeHook.invariants.t.sol` is where a mutant
/// that does exactly that is killed.
///
/// THE PROMISES (the SPEC, before the tests; each a named test or invariant):
///  C1  PER PARTY, per swap and per currency, counting balances (ERC-20 or ETH) AND claims: the swapper moved by the
///      delta the manager returned to the router, the hook by `pool - caller` (its booked delta), and the manager's
///      net (balance minus the claims it issued) by exactly the pool's own delta;
///  C2  THE FEE is `floor(|pool's unspecified amount| * FEE_BPS / BPS)`, in the unspecified currency, and it is held as a
///      CLAIM: in a swap the hook's token and ETH balances never move, its claims rise by exactly its booked delta;
///  C3  NOBODY ELSE gets a claim from a swap, and the hook's claims are `feesBooked - withdrawn`, per currency; the hook
///      grants no operator and no allowance on its claims, so nothing but its own swaps and withdrawals moves them.
///      Claims of OTHER parties - somebody depositing and passing on claims of its own - are none of its business
///      (the campaign has a third party doing exactly that);
///  C4  WITHDRAWAL burns exactly what it takes, only the treasury may start it, and it pays the currency - ETH or token -
///      not a claim. A treasury that cannot receive ETH cannot withdraw ETH, and nothing moves;
///  C5  `onlyManager` on every callback, `unlockCallback` included; `hookData` is never read; native pools accepted.
contract ClaimsFeeHook is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    uint256 public constant BPS = 10_000;
    uint256 public constant FEE_BPS = 30;

    IPoolManager public immutable manager;
    address public immutable treasury;

    /// @notice fees the hook returned as its delta (so the manager booked them to it), and claims burned on withdrawal
    mapping(Currency => uint256) public feesBooked;
    mapping(Currency => uint256) public withdrawn;

    error NotTheManager();
    error NotTheTreasury();
    error NotImplemented();

    event FeeClaimed(PoolId indexed id, Currency indexed currency, uint256 fee);
    event Withdrawn(Currency indexed currency, address indexed to, uint256 amount);

    modifier onlyManager() {
        if (msg.sender != address(manager)) revert NotTheManager();
        _;
    }

    constructor(IPoolManager manager_, address treasury_) {
        manager = manager_;
        treasury = treasury_;
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

    /// @notice the claims this hook holds on the manager for `currency`: its whole fee balance
    function claimsOf(Currency currency) external view returns (uint256) {
        return manager.balanceOf(address(this), currency.toId());
    }

    // ------------------------------------------------------------------ the fee
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

        uint256 id = unspecified.toId();
        // the hook's delta: the manager owes it `fee`; it squares it by minting a claim, not by taking the currency
        manager.mint(address(this), id, fee);
        feesBooked[unspecified] += fee;
        emit FeeClaimed(key.toId(), unspecified, fee);
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    // ------------------------------------------------------------------ the withdrawal
    /// @notice burn `amount` of the hook's claims on `currency` and pay that much of `currency` to `to`
    function withdraw(Currency currency, address to, uint256 amount) external {
        if (msg.sender != treasury) revert NotTheTreasury();
        manager.unlock(abi.encode(currency, to, amount));
    }

    function unlockCallback(bytes calldata data) external override onlyManager returns (bytes memory) {
        (Currency currency, address to, uint256 amount) = abi.decode(data, (Currency, address, uint256));
        uint256 id = currency.toId();
        manager.burn(address(this), id, amount);
        manager.take(currency, to, amount);
        withdrawn[currency] += amount;
        emit Withdrawn(currency, to, amount);
        return "";
    }

    // ------------------------------------------------------------------ the ones it does not declare
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
