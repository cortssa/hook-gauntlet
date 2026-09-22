// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {HostileERC20, IHostileTokenCallback} from "../src/HostileERC20.sol";

/// @notice a second caller, so the "lies to one caller" switch can be shown to tell the truth to everyone else.
contract Reader {
    function read(HostileERC20 token, address who) external view returns (uint256) {
        return token.balanceOf(who);
    }
}

/// @notice records the token's callbacks, and can re-enter the token from inside one.
contract CallbackSpy is IHostileTokenCallback {
    HostileERC20 public token;
    uint256 public sends;
    uint256 public receives;
    uint256 public balanceSeenOnSend;
    uint256 public balanceSeenOnReceive;
    address public reenterTo;
    uint256 public reenterAmount;
    uint256 public reentries;

    function setToken(HostileERC20 t) external {
        token = t;
    }

    function armReentry(address to, uint256 amount) external {
        reenterTo = to;
        reenterAmount = amount;
    }

    function tokensToSend(address from, address, uint256) external override {
        sends += 1;
        balanceSeenOnSend = token.trueBalanceOf(from);
        if (reenterTo != address(0)) {
            reentries += 1;
            address to = reenterTo;
            reenterTo = address(0); // one shot, so the test bounds the recursion
            token.transfer(to, reenterAmount);
        }
    }

    function tokensReceived(address, address to, uint256) external override {
        receives += 1;
        balanceSeenOnReceive = token.trueBalanceOf(to);
    }
}

/// @notice a caller that has work of its own to do after the token returns. It is how the frame-eating switch
/// is observed: the token says true, and the victim then cannot afford its own next step.
contract Victim {
    HostileERC20 public immutable token;
    uint256 public finished;

    constructor(HostileERC20 t) {
        token = t;
    }

    function pull(address from, address to, uint256 value) external {
        token.transferFrom(from, to, value);
        bytes32 h;
        for (uint256 i = 0; i < 200; i++) h = keccak256(abi.encode(h, i)); // about 40 000 gas of own work
        if (uint256(h) == 1) return;
        finished += 1;
    }
}

/// @dev one test per switch: each proves the switch does exactly what its natspec claims, and nothing else.
contract HostileERC20Test is Test {
    HostileERC20 t;
    Reader reader;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA401);

    uint256 constant E = 1e18;

    function setUp() public {
        t = new HostileERC20("Hostile", "HOSS", 18);
        reader = new Reader();
        t.mint(alice, 100 * E);
        t.mint(bob, 100 * E);
        vm.prank(alice);
        t.approve(address(this), type(uint256).max);
        vm.prank(bob);
        t.approve(address(this), type(uint256).max);
    }

    // ================================================================== baseline
    /// the mock is a plain, correct ERC-20 with every switch off.
    function test_baseline_is_an_honest_erc20() public {
        t.transferFrom(alice, bob, 10 * E);
        assertEq(t.balanceOf(alice), 90 * E, "sender debited");
        assertEq(t.balanceOf(bob), 110 * E, "recipient credited");
        assertEq(t.trueBalanceOf(alice), t.balanceOf(alice), "view matches the truth");
        assertEq(t.totalSupply(), 200 * E, "supply untouched");
    }

    // ================================================================== read side
    function test_switch_balanceRevert() public {
        t.setBalanceRevert(alice, true);
        vm.expectRevert(abi.encodeWithSelector(HostileERC20.BalanceUnreadable.selector, alice));
        t.balanceOf(alice);
        assertEq(t.balanceOf(bob), 100 * E, "only the flagged wallet is unreadable");
        assertEq(t.trueBalanceOf(alice), 100 * E, "the referee still sees the truth");
    }

    function test_switch_balanceMax() public {
        t.setBalanceMax(alice, true);
        assertEq(t.balanceOf(alice), type(uint256).max, "answers infinity");
        assertEq(t.trueBalanceOf(alice), 100 * E, "while holding a finite amount");
    }

    function test_switch_balanceGasBurn() public {
        uint256 g0 = gasleft();
        uint256 cheap = t.balanceOf(alice);
        uint256 usedCheap = g0 - gasleft();

        t.setBalanceGasBurn(alice, 400);
        uint256 g1 = gasleft();
        uint256 dear = t.balanceOf(alice);
        uint256 usedDear = g1 - gasleft();

        assertEq(dear, cheap, "the answer is still the truth");
        assertGt(usedDear, usedCheap + 20_000, "the read got much more expensive");
        console2.log("balanceOf gas, plain", usedCheap);
        console2.log("balanceOf gas, burning 400 rounds", usedDear);
    }

    function test_switch_balanceRevertWhenRich() public {
        t.setBalanceRevertWhenRich(alice, true);

        // a capped read is under the threshold: the token answers honestly
        (bool ok, bytes memory data) =
            address(t).staticcall{gas: 60_000}(abi.encodeWithSelector(HostileERC20.balanceOf.selector, alice));
        assertTrue(ok, "the capped probe succeeds");
        assertEq(abi.decode(data, (uint256)), 100 * E, "and tells the truth");

        // the same read in a full frame reverts
        vm.expectRevert(abi.encodeWithSelector(HostileERC20.BalanceUnreadable.selector, alice));
        t.balanceOf(alice);
    }

    function test_switch_balanceUnderstateWhenRich() public {
        t.setBalanceUnderstateWhenRich(alice, 4);

        (bool ok, bytes memory data) =
            address(t).staticcall{gas: 60_000}(abi.encodeWithSelector(HostileERC20.balanceOf.selector, alice));
        assertTrue(ok, "capped probe succeeds");
        assertEq(abi.decode(data, (uint256)), 100 * E, "capped probe sees the truth");

        assertEq(t.balanceOf(alice), 25 * E, "the uncapped read sees a quarter of it");
    }

    function test_switch_balanceLieToCaller() public {
        t.setBalanceLieToCaller(alice, address(reader), 777);
        assertEq(reader.read(t, alice), 777, "the chosen caller is lied to");
        assertEq(t.balanceOf(alice), 100 * E, "everyone else gets the truth");

        t.setBalanceLieToCaller(alice, address(0), 0);
        assertEq(reader.read(t, alice), 100 * E, "switch off");
    }

    function test_switch_balanceRevertAfterMove() public {
        t.setBalanceRevertAfterMove(alice, true);
        assertEq(t.balanceOf(alice), 100 * E, "readable before the move");

        t.transferFrom(alice, bob, 1 * E);

        vm.expectRevert(abi.encodeWithSelector(HostileERC20.BalanceUnreadable.selector, alice));
        t.balanceOf(alice);
        assertEq(t.balanceOf(bob), 101 * E, "the recipient stays readable");
    }

    function test_switch_viewOverstateAfterMove() public {
        t.setViewOverstateAfterMove(alice, 3 * E);
        assertEq(t.balanceOf(alice), 100 * E, "inert until the wallet moves");

        t.transferFrom(alice, bob, 10 * E);

        assertEq(t.trueBalanceOf(alice), 90 * E, "really lost ten");
        assertEq(t.balanceOf(alice), 93 * E, "but the view shows a drop of seven");
    }

    function test_switch_viewUnderstateAfterMove() public {
        t.setViewUnderstateAfterMove(alice, 3 * E);
        assertEq(t.balanceOf(alice), 100 * E, "inert until the wallet moves");

        t.transferFrom(alice, bob, 10 * E);

        assertEq(t.trueBalanceOf(alice), 90 * E, "really lost ten");
        assertEq(t.balanceOf(alice), 87 * E, "but the view shows a drop of thirteen");
    }

    // ================================================================== write side
    function test_switch_trueNoMove() public {
        t.setTrueNoMove(alice, true);
        bool ok = t.transferFrom(alice, bob, 10 * E);
        assertTrue(ok, "it returns true");
        assertEq(t.trueBalanceOf(alice), 100 * E, "and moved nothing");
        assertEq(t.trueBalanceOf(bob), 100 * E, "the recipient got nothing");
        assertEq(t.allowance(alice, address(this)), type(uint256).max, "infinite allowance is not spent here");
    }

    /// The switch is tested by its CONSEQUENCE, not by a gas measurement: under Foundry the difference in
    /// `gasleft()` around a call in the test frame does not track what the callee spent, so a test written
    /// that way measures nothing. Here a victim calls the token and then tries to finish its own work.
    function test_switch_gasHogTransfer() public {
        Victim v = new Victim(t);
        vm.prank(alice);
        t.approve(address(v), type(uint256).max);

        (bool honest,) =
            address(v).call{gas: 400_000}(abi.encodeWithSelector(Victim.pull.selector, alice, bob, 10 * E));
        assertTrue(honest, "with the switch off the caller finishes its work");
        assertEq(v.finished(), 1, "and says so");
        assertEq(t.trueBalanceOf(bob), 110 * E, "and the tokens moved");

        t.setGasHogTransfer(alice, true);
        (bool hogged,) =
            address(v).call{gas: 400_000}(abi.encodeWithSelector(Victim.pull.selector, alice, bob, 10 * E));
        assertFalse(hogged, "with the switch on the caller dies after the token hands control back");
        assertEq(v.finished(), 1, "the second pull never completed");
        assertEq(t.trueBalanceOf(bob), 110 * E, "and nothing moved");
    }

    /// the token itself still reports success: the caller is told everything is fine, and is then killed by
    /// the cost of its own next step.
    function test_switch_gasHogTransfer_returns_true_when_the_caller_needs_nothing_more() public {
        t.setGasHogTransfer(alice, true);
        (bool ok, bytes memory data) = address(t).call{gas: 400_000}(
            abi.encodeWithSelector(HostileERC20.transferFrom.selector, alice, bob, 10 * E)
        );
        assertTrue(ok, "it returns");
        assertTrue(abi.decode(data, (bool)), "and it returns true");
        assertEq(t.trueBalanceOf(bob), 100 * E, "while moving nothing");
        assertEq(t.allowance(alice, address(this)), type(uint256).max, "infinite allowance is untouched");
    }

    function test_switch_feeBps() public {
        t.setFeeBps(250); // 2.5 percent
        t.transferFrom(alice, bob, 100 * E);

        assertEq(t.trueBalanceOf(alice), 0, "the sender loses exactly what it sent");
        assertEq(t.trueBalanceOf(bob), 100 * E + 975 * E / 10, "the recipient receives less");
        assertEq(t.trueBalanceOf(t.FEE_SINK()), 25 * E / 10, "the fee is parked, not destroyed");
        assertEq(t.totalSupply(), 200 * E, "supply untouched");
    }

    function test_switch_shortDeliver() public {
        t.setShortDeliver(alice, 4);
        vm.prank(alice);
        t.approve(address(this), 40 * E);

        t.transferFrom(alice, bob, 40 * E);

        assertEq(t.trueBalanceOf(bob), 110 * E, "a quarter arrived");
        assertEq(t.trueBalanceOf(alice), 90 * E, "and the sender only lost a quarter");
        assertEq(t.allowance(alice, address(this)), 0, "but the whole allowance was spent");
    }

    function test_switch_bonusTo() public {
        t.fundReserve(50 * E);
        t.setBonusTo(bob, 2 * E);

        t.transferFrom(alice, bob, 10 * E);

        assertEq(t.trueBalanceOf(alice), 90 * E, "the sender lost ten");
        assertEq(t.trueBalanceOf(bob), 112 * E, "the recipient gained twelve");
        assertEq(t.trueBalanceOf(t.RESERVE()), 48 * E, "the difference came out of the reserve");
    }

    function test_switch_bonusTo_stops_at_an_empty_reserve() public {
        t.setBonusTo(bob, 2 * E); // reserve never funded
        t.transferFrom(alice, bob, 10 * E);
        assertEq(t.trueBalanceOf(bob), 110 * E, "no bonus, and no revert");
    }

    function test_switch_rebateFrom() public {
        t.fundReserve(50 * E);
        t.setRebateFrom(alice, 4 * E);

        t.transferFrom(alice, bob, 10 * E);

        assertEq(t.trueBalanceOf(alice), 94 * E, "the sender only really lost six");
        assertEq(t.trueBalanceOf(bob), 110 * E, "while the recipient gained ten");
        assertEq(t.trueBalanceOf(t.RESERVE()), 46 * E, "the rebate came out of the reserve");
    }

    function test_switch_extraBurnFrom() public {
        t.setExtraBurnFrom(alice, 1 * E);

        t.transferFrom(alice, bob, 10 * E);

        assertEq(t.trueBalanceOf(alice), 89 * E, "the sender lost eleven");
        assertEq(t.trueBalanceOf(bob), 110 * E, "the recipient gained ten");
        assertEq(t.trueBalanceOf(t.FEE_SINK()), 1 * E, "the extra is parked");
    }

    function test_switch_blockIncoming() public {
        t.setBlockIncoming(bob, true);
        vm.expectRevert(abi.encodeWithSelector(HostileERC20.RecipientBlocked.selector, bob));
        t.transferFrom(alice, bob, 1 * E);

        t.transferFrom(alice, carol, 1 * E);
        assertEq(t.trueBalanceOf(carol), 1 * E, "other recipients are fine");
    }

    function test_switch_paused() public {
        t.setPaused(true);
        vm.expectRevert(HostileERC20.TransfersPaused.selector);
        t.transferFrom(alice, bob, 1 * E);

        t.setPaused(false);
        t.transferFrom(alice, bob, 1 * E);
        assertEq(t.trueBalanceOf(bob), 101 * E, "and it thaws");
    }

    function test_switch_omitReturnValue() public {
        t.setOmitReturnValue(true);

        (bool ok, bytes memory data) =
            address(t).call(abi.encodeWithSelector(HostileERC20.transferFrom.selector, alice, bob, 10 * E));
        assertTrue(ok, "the call succeeds");
        assertEq(data.length, 0, "with no return data at all");
        assertEq(t.trueBalanceOf(bob), 110 * E, "and it really moved the tokens");

        // A typed call cannot decode a bool that is not there, so it reverts even though the transfer
        // worked. Asserted as a RAW call rather than with a bare `vm.expectRevert()`: the failure has no
        // selector and no message at all - it is the ABI decoder's own `revert(0, 0)` - and "it reverted
        // with nothing" is the claim. A bare expectation would also have accepted an insufficient
        // allowance, a paused token, or a typo in the signature above.
        (bool typedOk, bytes memory typedRet) =
            address(this).call(abi.encodeCall(this.typedTransferFrom, (alice, bob, 1 * E)));
        assertFalse(typedOk, "the typed call must fail on the missing return value");
        assertEq(typedRet.length, 0, "and it fails with NO revert data: that is a decoder failure");
    }

    /// @dev the typed call has to live one frame down, so the decoder's revert is the call that reverts.
    function typedTransferFrom(address from, address to, uint256 value) external {
        t.transferFrom(from, to, value);
    }

    // ================================================================== callbacks
    function test_switch_sendCallback_runs_before_the_move() public {
        CallbackSpy spy = new CallbackSpy();
        spy.setToken(t);
        t.setSendCallback(alice, address(spy), 1);

        t.transferFrom(alice, bob, 10 * E);

        assertEq(spy.sends(), 1, "the sender hook fired once");
        assertEq(spy.balanceSeenOnSend(), 100 * E, "and it ran before the balances moved");
        assertEq(t.trueBalanceOf(alice), 90 * E, "the move still happened");
    }

    function test_switch_sendCallback_is_a_reentrancy_window() public {
        CallbackSpy spy = new CallbackSpy();
        spy.setToken(t);
        t.mint(address(spy), 5 * E);
        t.setSendCallback(alice, address(spy), 1);
        spy.armReentry(carol, 5 * E);

        t.transferFrom(alice, bob, 10 * E);

        assertEq(spy.reentries(), 1, "the hook moved tokens of its own mid transfer");
        assertEq(t.trueBalanceOf(carol), 5 * E, "and they arrived");
        assertEq(t.trueBalanceOf(bob), 110 * E, "the outer transfer completed too");
    }

    function test_switch_receiveCallback_runs_after_the_move() public {
        CallbackSpy spy = new CallbackSpy();
        spy.setToken(t);
        t.setReceiveCallback(bob, address(spy), 1);

        t.transferFrom(alice, bob, 10 * E);

        assertEq(spy.receives(), 1, "the recipient hook fired once");
        assertEq(spy.balanceSeenOnReceive(), 110 * E, "and it ran after the balances moved");
    }

    function test_callbacks_are_bounded_by_their_fire_count() public {
        CallbackSpy spy = new CallbackSpy();
        spy.setToken(t);
        t.setSendCallback(alice, address(spy), 2);

        t.transferFrom(alice, bob, 1 * E);
        t.transferFrom(alice, bob, 1 * E);
        t.transferFrom(alice, bob, 1 * E);

        assertEq(spy.sends(), 2, "it fires exactly as many times as it was armed for");
    }

    // ================================================================== housekeeping
    function test_switches_are_per_wallet_and_can_be_turned_off() public {
        t.setTrueNoMove(alice, true);
        t.transferFrom(alice, bob, 10 * E);
        assertEq(t.trueBalanceOf(bob), 100 * E, "alice moved nothing");

        t.transferFrom(bob, carol, 10 * E);
        assertEq(t.trueBalanceOf(carol), 10 * E, "bob is unaffected");

        t.setTrueNoMove(alice, false);
        t.transferFrom(alice, bob, 10 * E);
        assertEq(t.trueBalanceOf(bob), 100 * E, "alice moves again");
    }

    function test_nothing_is_ever_destroyed() public {
        t.fundReserve(20 * E);
        t.setFeeBps(100);
        t.setExtraBurnFrom(alice, 1 * E);
        t.setBonusTo(bob, 1 * E);
        t.setRebateFrom(alice, 1 * E);

        t.transferFrom(alice, bob, 10 * E);

        uint256 total = t.trueBalanceOf(alice) + t.trueBalanceOf(bob) + t.trueBalanceOf(carol)
            + t.trueBalanceOf(t.FEE_SINK()) + t.trueBalanceOf(t.RESERVE());
        assertEq(total, t.totalSupply(), "the books close over every address the mock can touch");
    }

    function test_gas_threshold_is_configurable() public {
        t.setGasThreshold(1); // everything is a rich frame now
        t.setBalanceRevertWhenRich(alice, true);
        (bool ok,) =
            address(t).staticcall{gas: 60_000}(abi.encodeWithSelector(HostileERC20.balanceOf.selector, alice));
        assertFalse(ok, "even the capped probe is above the threshold");
        assertEq(t.gasThreshold(), 1, "the setter really wrote it: with the assignment deleted it is still 0");
    }

    // ================================================================== the plumbing nothing asserted
    // Every test below exists because `forge test --mutate src/HostileERC20.sol` found the line unguarded.
    // They are dull, and that is the point: the switchboard's own bookkeeping had no assertions at all, so a
    // mutation could delete a constructor assignment, break the allowance arithmetic, or remove the guard on
    // `setFeeBps` and every one of the thirty switch tests above still passed.

    /// @dev kills `decimals = d` -> deleted. Nothing had ever read it.
    function test_the_constructor_records_what_it_was_given() public {
        HostileERC20 six = new HostileERC20("Six", "SIX", 6);
        assertEq(six.decimals(), 6, "decimals");
        assertEq(six.name(), "Six");
        assertEq(six.symbol(), "SIX");
        assertEq(t.decimals(), 18, "and the one the rest of this file uses");
    }

    /// @dev kills `require(bps <= 10_000, ...)` -> `require(true, ...)`, and the two mutations that move the
    /// boundary (`< 10_000`, `!= 10_000`). A fee over 100 per cent would make the mock destroy tokens, which
    /// is the one thing its accounting promises never to do - and the guard had no test.
    function test_the_fee_cannot_be_set_above_one_hundred_per_cent() public {
        t.setFeeBps(10_000); // exactly 100 % is allowed: the boundary itself
        assertEq(t.feeBps(), 10_000);

        vm.expectRevert(bytes("HostileERC20: fee over 100 percent"));
        t.setFeeBps(10_001);
        assertEq(t.feeBps(), 10_000, "and the refused value did not land");
    }

    /// @dev kills `a - value` -> `a % value`, `a << value`, `a >> value`, `a ^ value`. Every test in this
    /// file approves `type(uint256).max`, which takes the branch that does NOT touch the allowance, so the
    /// arithmetic on the other branch had never once run. An infinite approval is the convenient thing to
    /// write in a fixture and it is the one value that tests nothing.
    function test_a_finite_allowance_is_spent_by_exactly_what_was_moved() public {
        vm.prank(carol);
        t.approve(address(this), 100);
        t.mint(carol, 100);

        t.transferFrom(carol, bob, 30);
        // 100 - 30 = 70. The mutants: 100 % 30 = 10, 100 >> 30 = 0, 100 ^ 30 = 126, 100 << 30 is enormous.
        assertEq(t.allowance(carol, address(this)), 70, "the allowance must fall by the amount, exactly");

        t.transferFrom(carol, bob, 70);
        assertEq(t.allowance(carol, address(this)), 0, "and reach zero when it is spent out");

        vm.expectRevert(abi.encodeWithSelector(HostileERC20.InsufficientAllowance.selector, carol, address(this)));
        t.transferFrom(carol, bob, 1);
    }

    /// @dev the other branch, stated so the pair is complete: an infinite approval is not spent at all.
    function test_an_infinite_allowance_is_not_spent() public {
        t.transferFrom(alice, bob, 10 * E);
        assertEq(t.allowance(alice, address(this)), type(uint256).max, "max means max, not max minus ten");
    }

    /// @dev kills `msg.sender == lie.caller` -> `msg.sender <= lie.caller`. AN ADDRESS IS AN IDENTITY, NOT
    /// AN ORDERING - the same family as the two survivors the hook example found, and the same reason this
    /// one lived: every reader the suite owned happened to sort on one side of the named caller. The test
    /// asserts that the two probes really are on opposite sides before it uses them.
    function test_the_caller_lie_is_told_to_one_address_and_not_to_everyone_below_it() public {
        Reader above = new Reader();
        Reader below = new Reader();
        // deploy until we hold one on each side of `above`, rather than assuming the nonce ordering
        while (uint160(address(below)) >= uint160(address(above))) below = new Reader();
        assertLt(uint160(address(below)), uint160(address(above)), "the probes are on opposite sides");

        t.setBalanceLieToCaller(alice, address(above), 7);
        assertEq(above.read(t, alice), 7, "the named caller is lied to");
        assertEq(below.read(t, alice), 100 * E, "and a caller sorted BELOW it is told the truth");
        assertEq(t.balanceOf(alice), 100 * E, "as is everybody else");
    }

    /// @dev kills `b > missing` -> `b != missing` in `balanceOf`'s understate branch, which computes
    /// `b - missing` when the balance is SMALLER than the lie and answers with an arithmetic panic instead
    /// of the zero the switch promises. The natspec says the view reads `balance - missing`; a mock that
    /// panics where it promised a number is a mock that fails the suite for its own reasons.
    function test_understating_more_than_the_wallet_holds_reads_zero_and_does_not_panic() public {
        t.setViewUnderstateAfterMove(alice, 1_000 * E); // ten times what alice has
        t.transferFrom(alice, bob, 1 * E); // arms the "after a move" switches
        assertEq(t.balanceOf(alice), 0, "it floors at zero");
        assertEq(t.trueBalanceOf(alice), 99 * E, "and the truth is untouched");
    }

    /// @dev kills the five bitwise mutations of `debit + extra` in the balance check (`&`, `|`, `^`, `<<`,
    /// `>>`). Four of them agree with the sum whenever `extra` is zero, which it is in every other test in
    /// this file, and the fifth needs the case that must NOT revert. So: one wallet one wei short of what
    /// the move will cost it, and one with exactly enough.
    ///
    /// The numbers are chosen so the mutants disagree: 100 + 28 = 128, while `100 | 28` is 124, `100 ^ 28`
    /// is 120, `100 & 28` is 4 and `100 >> 28` is 0.
    function test_the_balance_check_covers_the_delivery_and_the_extra_burn_together() public {
        address thin = address(0x7411);
        t.mint(thin, 127); // one short of 100 + 28
        t.setExtraBurnFrom(thin, 28);
        vm.prank(thin);
        t.approve(address(this), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(HostileERC20.InsufficientBalance.selector, thin));
        t.transferFrom(thin, bob, 100);

        t.mint(thin, 1); // now exactly 128
        t.transferFrom(thin, bob, 100); // must not revert
        assertEq(t.trueBalanceOf(thin), 0, "the sender pays the delivery AND the burn");
        assertEq(t.trueBalanceOf(t.FEE_SINK()), 28, "and the burn is parked, not destroyed");
    }

    /// @dev kills `cb.firesLeft -= 1` -> `cb.firesLeft >>= 1`, which agrees with the decrement at 1 and at
    /// 2 and stops agreeing at 3. `test_callbacks_are_bounded_by_their_fire_count` arms two fires, which is
    /// the largest count where a halving and a decrement are the same thing.
    function test_the_fire_count_is_decremented_and_not_halved() public {
        CallbackSpy spy = new CallbackSpy();
        spy.setToken(t);
        t.setSendCallback(alice, address(spy), 3);

        for (uint256 i = 0; i < 4; i++) t.transferFrom(alice, bob, 1 * E);
        assertEq(spy.sends(), 3, "three fires means three, not `3 -> 1 -> 0` in two moves");
    }

    /// @dev kills `cb.target == address(0)` -> `cb.target < address(0)`, which is never true. A callback armed
    /// with NO target and fires to spare must be skipped: the mutant calls the zero address instead, Solidity's
    /// code-size check reverts, and the transfer dies. `MUTANTS.md` listed this for a while as "a two-line test
    /// that is not written" - a sentence that costs more to keep than the test.
    function test_a_callback_with_no_target_is_skipped_and_not_called() public {
        t.setSendCallback(alice, address(0), 3);

        t.transferFrom(alice, bob, 1 * E);

        assertEq(t.trueBalanceOf(bob), 101 * E, "the move did not happen");
        (, uint256 firesLeft) = t.sendCallback(alice);
        assertEq(firesLeft, 3, "a skipped callback must not spend a fire");
    }
}
