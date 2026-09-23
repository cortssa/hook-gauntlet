// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title CappedDynamicFeeHook - A TOY. Do not copy its architecture into a product.
/// @notice A deliberately small hook that exists ONLY to show the v4 harness working. It is not a product
/// and it has no planted bugs.
///
/// What it does: the pool's LP fee rises with congestion, one block late. Every swap in a block pays the same
/// fee: `BASE_FEE`, plus `STEP` for each swap the pool saw in the PREVIOUS block, capped at `MAX_FEE`. A block
/// after a quiet one (or after an idle stretch) pays the base. It takes no delta, holds no tokens and has no owner.
///
/// Why one block late (round r01, 2026-09-23, finding F1, medium): the first version charged the n-th swap of a
/// block `BASE_FEE + n * STEP`. Then a victim who read the quote could be charged ten times it by anyone who
/// placed nine 1-wei swaps ahead of it in the same block - "charged == quoted" held only when the read and the
/// swap were atomic. The fix is at the cause: nothing placed inside a block can move what that block charges,
/// because that fee was fixed by the block before it. The congestion signal can still be inflated - for the NEXT
/// block, in the open, readable by anyone before they trade. `SPEC.md` next to this file has the story.
///
/// ADAPT: this is a WORKED TOY, not a template to fill in. What carries over to your hook is the shape - the
/// threat model written before the tests, the permissions declared once and checked in the constructor, the
/// quote exposed as a view so the suite can compare what the hook SAID with what the pool DID. The rules
/// themselves come from your hook: derive them with `doctrine/INVARIANTS.md` and `doctrine/FUZZ-ACTIONS.md`.
///
/// THE THREAT MODEL, written down BEFORE the tests.
///
/// In scope, the hook must survive:
///  1. a swapper who chooses the `hookData`: empty, enormous, or crafted. Nothing here reads it, and that is
///     a decision, not an oversight - see defence (a);
///  2. a swapper who swaps many times in one block, including through a contract, to push the fee up or to
///     roll it over: `swapsInBlock` must not wrap, the fee must not exceed the cap, and no swap placed inside
///     a block may change the fee of that block (a quote read in a block binds every swap after it in that block);
///  3. a currency that lies, charges a fee on transfer, delivers short or burns gas. The hook never moves a
///     token, so the failure must land on the router or the manager's settlement, never on a wrong fee;
///  4. a pool it has never seen. A hook serves many pools; one that assumes it was initialised is a hook
///     that quotes from another pool's state;
///  5. anyone calling its hook entry points directly, rather than through the manager;
///  6. a pool with a static fee trying to use it, where `updateDynamicLPFee` would revert somewhere less
///     obvious later.
///
/// Out of scope, declared and not defended:
///  7. the pool operator choosing a hostile `tickSpacing` or an absurd initial price. The fee is unaffected,
///     the arithmetic below does not touch ticks, and a pool's own parameters are its owner's business.
///  8. the protocol fee. If governance sets one, the total fee the swapper pays is more than the fee this
///     hook quoted. The harness runs with the protocol fee at zero and the tests say so.
///
/// The defences, one per line of the model:
///  * (a) `hookData` is never read or decoded: input that is never parsed cannot be parsed wrongly (1);
///  * (b) the fee is computed by one pure function with a hard cap, in `uint24`, and the counter saturates
///        rather than wrapping; the fee of a block is fixed from the previous block's count at its first swap
///        and stored, so swaps inside the block only count towards the NEXT one (2);
///  * (c) the hook has no delta permissions at all, so the manager will not let it move value (3);
///  * (d) a pool is recorded in `afterInitialize`, and `beforeSwap` refuses a pool it does not know (4);
///  * (e) `onlyManager` on every entry point (5);
///  * (f) `afterInitialize` refuses a pool whose fee is not the dynamic-fee flag (6).
contract CappedDynamicFeeHook is IHooks {
    using LPFeeLibrary for uint24;

    /// @notice the fee the first swap in a block pays, in hundredths of a bip (500 = 0.05%).
    uint24 public constant BASE_FEE = 500;
    /// @notice added per extra swap in the same block.
    uint24 public constant STEP = 500;
    /// @notice the cap. The whole point of the hook: it can never charge more than this.
    uint24 public constant MAX_FEE = 5_000;

    IPoolManager public immutable manager;

    /// @param blockNumber the block the two fields after it belong to (the last block this pool saw a swap in, or
    ///        the block it was initialised in)
    /// @param swapsInBlock the swaps seen in that block; they set the fee of the block AFTER it
    /// @param blockFee the fee every swap in `blockNumber` paid. Once the chain has moved on it is history, not the
    ///        next fee: read `quoteNextFee` for that (r01, F6)
    struct PoolState {
        bool known;
        uint64 blockNumber;
        uint32 swapsInBlock;
        uint24 blockFee;
    }

    mapping(PoolId => PoolState) internal _pools;

    error NotTheManager();
    error NotADynamicFeePool();
    error NotMyPool();
    error UnknownPool();
    error NotImplemented();

    /// @param swapCountAfter swaps seen in this block INCLUDING this one: they set the NEXT block's fee. `fee` is this
    /// block's, fixed by the previous block's count, and the same in every FeeQuoted of one block and pool.
    event FeeQuoted(PoolId indexed id, uint32 swapCountAfter, uint24 fee);

    modifier onlyManager() {
        if (msg.sender != address(manager)) revert NotTheManager();
        _;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
        // The address IS the permission set. Checking it here, in the constructor, is what turns a mined
        // address that carries one bit too many into a deployment that fails now instead of a hook that gets
        // called somewhere it has no code for. `HookMiner.find` mines for equality precisely so that this
        // check passes; if you replace the miner with one that mines for "contains", this line is what goes
        // red, and that is the point of it.
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @notice the permissions this hook declares. One place, read by the constructor and by the tests.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice the same permissions as the address bits to mine for.
    function requiredFlags() public pure returns (uint160) {
        return Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG;
    }

    // ------------------------------------------------------------------ the rule, as a pure function
    /// @notice what every swap of a block pays when the previous block saw `swapsInPreviousBlock` swaps. Pure, so
    /// the tests, the invariants and the hook itself all agree on one definition instead of three.
    function feeForCongestion(uint32 swapsInPreviousBlock) public pure returns (uint24) {
        uint256 raw = uint256(BASE_FEE) + uint256(STEP) * uint256(swapsInPreviousBlock);
        return raw >= MAX_FEE ? MAX_FEE : uint24(raw);
    }

    /// @notice the fee of the current block: stored once the block has seen a swap, else derived from the block
    /// before it. The stored state counts only if it is THIS block (an identity, not an ordering: a stored block
    /// ahead of the current one is stale too), and its count only if it is the block right before this one.
    function _feeOfThisBlock(PoolState storage s) internal view returns (uint24) {
        if (s.blockNumber == uint64(block.number)) return s.blockFee;
        return feeForCongestion(uint256(s.blockNumber) + 1 == block.number ? s.swapsInBlock : 0);
    }

    /// @notice THE QUOTE: what a swap on this pool is charged if it executes in THIS block - and, since the fee of a
    /// block cannot move once the block has begun, what every swap after it in this block is charged too. A view is
    /// an entry point like any other, and it is the one other people's software will trust. The suite compares it
    /// against what the pool actually charged. Off-chain: evaluate it at the block you expect to land in (a call
    /// against the latest block answers for THAT block, which may be the previous one).
    function quoteNextFee(PoolKey calldata key) external view returns (uint24) {
        PoolState storage s = _pools[key.toId()];
        if (!s.known) revert UnknownPool();
        return _feeOfThisBlock(s);
    }

    function poolState(PoolId id) external view returns (PoolState memory) {
        return _pools[id];
    }

    // ------------------------------------------------------------------ the two hooks it declares
    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        override
        onlyManager
        returns (bytes4)
    {
        if (address(key.hooks) != address(this)) revert NotMyPool();
        if (!key.fee.isDynamicFee()) revert NotADynamicFeePool();
        PoolState storage s = _pools[key.toId()];
        s.known = true;
        s.blockNumber = uint64(block.number);
        s.swapsInBlock = 0;
        s.blockFee = BASE_FEE;
        manager.updateDynamicLPFee(key, BASE_FEE);
        return IHooks.afterInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        override
        onlyManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        PoolState storage s = _pools[id];
        if (!s.known) revert UnknownPool();

        // the fee is read BEFORE the state moves to this block: it is fixed by the previous block's count, and the
        // swaps of this block (this one included) only count towards the next
        uint24 fee = _feeOfThisBlock(s);
        if (s.blockNumber != uint64(block.number)) {
            s.blockNumber = uint64(block.number);
            s.swapsInBlock = 0;
            s.blockFee = fee;
        }

        // saturating, not wrapping: once the fee is capped the counter has nothing left to say, and a
        // uint32 that wraps would drop the next block's fee back to the base.
        if (s.swapsInBlock != type(uint32).max) s.swapsInBlock += 1;
        emit FeeQuoted(id, s.swapsInBlock, fee);

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // ------------------------------------------------------------------ the twelve it does not
    // A hook is only called where its address says it may be. These revert rather than returning a selector,
    // so that a wrong address - a mined salt that carried a bit too many, a deployer that changed - shows up
    // as a failed call in the test that did it, instead of as silence.
    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
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

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        override
        returns (bytes4, int128)
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
