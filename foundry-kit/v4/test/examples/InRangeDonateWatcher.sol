// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {MinimalRouter} from "../../src/MinimalRouter.sol";
import {LiquidityHelper} from "../../src/LiquidityHelper.sol";
import {SwapEventReader} from "../../src/SwapEventReader.sol";
import {InRangeLedger} from "../../src/InRangeLedger.sol";
import {JitRecipient, JitStep, IJitObserver} from "../../src/JitRecipient.sol";

/// @notice a third party that donates to a pool in an unlock of its own and pays for it: a donation that is NOT the
/// hook's, owed (by the manager's rule) to whoever is in range when it lands
contract ThirdPartyDonor is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function donate(PoolKey memory key, uint256 a0, uint256 a1) external payable {
        manager.unlock(abi.encode(key, a0, a1));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not the manager");
        (PoolKey memory key, uint256 a0, uint256 a1) = abi.decode(data, (PoolKey, uint256, uint256));
        manager.donate(key, a0, a1, "");
        _pay(key.currency0, a0);
        _pay(key.currency1, a1);
        return "";
    }

    function _pay(Currency c, uint256 amount) internal {
        if (amount == 0) return;
        if (c.isAddressZero()) {
            manager.settle{value: amount}();
        } else {
            manager.sync(c);
            IERC20Minimal(Currency.unwrap(c)).transfer(address(manager), amount);
            manager.settle();
        }
    }

    receive() external payable {}
}

/// @title InRangeDonateWatcher - `InRangeDonateHook`'s rule, applied to a pool as it is traded: the reference model's feed
/// @notice Every action that can earn or pay the hook's fee goes through here, so that the `InRangeLedger` is told at the
/// right MOMENT. The rule it applies is the example's SPEC D2, and nothing of the hook's code: after every swap, the fee
/// `floor(|pool's unspecified| * FEE_BPS / BPS)` - computed from the manager's own `Swap` event - is earned by the
/// positions in range at the price that swap left. A third party's donation is earned by whoever is in range when it
/// lands (the manager's rule). Positions are tracked as they are placed, and what the manager pays them on each
/// modification is noted.
///
/// It is also the `IJitObserver` of the JIT-recipient actors it owns: their pushes and washes are swaps like any other,
/// attributed after each one, before the actor's next step moves anything.
contract InRangeDonateWatcher is Test, IJitObserver {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    MinimalRouter public immutable router;
    LiquidityHelper public immutable liquidity;
    InRangeLedger public immutable ledger;
    ThirdPartyDonor public immutable donor;
    uint256 public immutable feeBps;
    PoolKey internal _key;

    /// @notice the fee each swap owed by the SPEC, and the number of swaps that owed one
    uint256[2] public feesOwed;
    uint256 public swapsWithAFee;
    uint256[2] public thirdPartyDonated;
    /// @notice payout calls an actor made while its position was in range, and those where it was ALONE in range
    uint256 public payoutsWithAJitInRange;
    uint256 public payoutsWithAJitAlone;

    constructor(
        IPoolManager manager_,
        MinimalRouter router_,
        LiquidityHelper liquidity_,
        PoolKey memory key_,
        uint256 feeBps_,
        bool closedWorld
    ) {
        manager = manager_;
        router = router_;
        liquidity = liquidity_;
        _key = key_;
        feeBps = feeBps_;
        ledger = new InRangeLedger(manager_, key_.toId(), closedWorld);
        donor = new ThirdPartyDonor(manager_);
    }

    function key() external view returns (PoolKey memory) {
        return _key;
    }

    /// @notice a JIT-recipient actor this watcher drives and observes
    function newJit() external returns (JitRecipient j) {
        j = new JitRecipient(manager, router, liquidity, address(this));
        j.setObserver(IJitObserver(address(this)));
        if (!_key.currency0.isAddressZero()) j.approveToken(Currency.unwrap(_key.currency0));
        j.approveToken(Currency.unwrap(_key.currency1));
    }

    // ------------------------------------------------------------------ the actions, attributed
    function swapAs(address swapper, SwapParams memory p, uint256 value) external returns (BalanceDelta d) {
        vm.recordLogs();
        vm.prank(swapper);
        d = router.swap{value: value}(_key, p, "");
        _accrueLastSwap(p);
    }

    /// @return i the ledger's index of the position; fees what the manager paid it in this modification
    function modifyAs(address lp, int24 lower, int24 upper, int256 delta, uint256 value)
        external
        returns (uint256 i, uint256 fees0, uint256 fees1)
    {
        i = ledger.track(lp, address(liquidity), lower, upper, liquidity.positionSalt(lp, bytes32(0)));
        vm.prank(lp);
        (, BalanceDelta fees) = liquidity.modifyLiquidity{value: value}(
            _key, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: delta, salt: bytes32(0)}), ""
        );
        fees0 = uint256(int256(fees.amount0()));
        fees1 = uint256(int256(fees.amount1()));
        ledger.noteCollected(i, fees0, fees1);
    }

    /// @notice a donation that is not the hook's: earned, by the manager's rule, by whoever is in range as it lands
    function thirdPartyDonate(uint256 a0, uint256 a1) external payable {
        ledger.accrue(a0, a1);
        thirdPartyDonated[0] += a0;
        thirdPartyDonated[1] += a1;
        donor.donate{value: msg.value}(_key, a0, a1);
    }

    function runJit(JitRecipient j, JitRecipient.Plan memory p) external returns (JitRecipient.Result memory r) {
        vm.recordLogs();
        r = j.run(p);
    }

    function jitEnter(JitRecipient j, uint128 liq, uint24 spacings) external returns (int24, int24) {
        return j.enter(_key, liq, spacings);
    }

    function jitExit(JitRecipient j) external returns (uint256, uint256) {
        return j.exit(_key);
    }

    /// @notice move anything the actors hold on to (ETH, tokens) - used to fund them from the test
    function fundJit(JitRecipient j, uint256 eth) external payable {
        (bool ok,) = address(j).call{value: eth}("");
        require(ok, "fund");
    }

    // ------------------------------------------------------------------ IJitObserver
    function onJitStep(JitStep step, SwapParams calldata lastSwap) external override {
        JitRecipient j = JitRecipient(payable(msg.sender));
        if (step == JitStep.ENTERED) {
            ledger.track(address(j), address(liquidity), j.tickLower(), j.tickUpper(), j.positionSalt());
        } else if (step == JitStep.EXITED) {
            (bool found, uint256 i) = ledger.indexOf(address(liquidity), j.tickLower(), j.tickUpper(), j.positionSalt());
            require(found, "watcher: an exit of a position it never saw placed");
            ledger.noteCollected(i, j.lastFees0(), j.lastFees1());
        } else if (step == JitStep.PAID_OUT) {
            payoutsWithAJitInRange += 1;
            if (manager.getLiquidity(_key.toId()) == j.placed()) payoutsWithAJitAlone += 1;
        } else if (
            step == JitStep.PUSHED || step == JitStep.WASHED || step == JitStep.WASHED_BACK
                || step == JitStep.PUSHED_BACK
        ) {
            _accrueLastSwap(lastSwap);
            vm.recordLogs();
        }
    }

    // ------------------------------------------------------------------ SPEC D1 + D2: the fee, earned where the swap left the price
    function _accrueLastSwap(SwapParams memory p) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool found, int128 pool0, int128 pool1) = SwapEventReader.lastSwapDelta(logs, address(manager));
        require(found, "watcher: no Swap event");
        bool s0 = (p.amountSpecified < 0) == p.zeroForOne;
        int128 u = s0 ? pool1 : pool0;
        uint256 fee = (u < 0 ? uint256(uint128(-u)) : uint256(uint128(u))) * feeBps / 10_000;
        if (fee == 0) return;
        swapsWithAFee += 1;
        feesOwed[s0 ? 1 : 0] += fee;
        if (s0) ledger.accrue(0, fee);
        else ledger.accrue(fee, 0);
    }

    receive() external payable {}
}
