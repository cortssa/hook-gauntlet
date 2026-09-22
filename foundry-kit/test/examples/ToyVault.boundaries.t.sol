// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HostileERC20} from "../../src/HostileERC20.sol";
import {ToyVault} from "../../src/examples/ToyVault.sol";

// Every test in this file exists because `forge test --mutate src/examples/ToyVault.sol` produced a mutant
// that the invariant suite did not kill. The invariants were not wrong; they were BLIND to the edges, because
// a stateful campaign that wraps every call in try/catch cannot tell "reverted for the declared reason" from
// "reverted for another one", and never tries the exact boundary on purpose.
//
// The generalisable lesson, and the reason this file is worth reading before you write your own: a free tool
// found, in thirty seconds, a set of holes in an example whose author had written a threat model first and
// believed it was covered. Run the mutation pass on YOUR hook before you pay for a round, and then read the
// survivor list one by one. Some survivors are equivalent mutants and are argued away in
// `src/examples/MUTANTS.md`; the rest are the tests below.
//
// Each test names the mutation it kills, so that a reader who deletes a test can see what goes with it.

/// @notice A token that lets a test choose the SHAPE of its return data, which is the one thing
/// `HostileERC20` cannot express: its switches are about value, and these are about bytes on the wire.
/// `ToyVault._selfBalance` demands at least 32 bytes back from `balanceOf`, and `ToyVault._call` accepts a
/// transfer that returns nothing while refusing one that returns `false`. Both promises need a token that can
/// return nothing, return too much, or revert with no data at all.
///
/// It is deliberately naive about allowances: it is a shape generator, not a second hostile token.
contract ReturnDataToken {
    enum Read {
        WORD, // a normal 32-byte answer
        EMPTY, // returns successfully with NO data
        WIDE, // returns 64 bytes: a correct answer with something appended
        REVERT_NO_DATA // reverts with an empty reason

    }

    enum Write {
        TRUE, // a normal 32-byte `true`
        FALSE, // a normal 32-byte `false`, AFTER moving the tokens
        NOTHING // moves the tokens and returns no data at all

    }

    mapping(address => uint256) public bal;
    Read public readShape;
    Write public writeShape;

    /// @notice once anything has moved, `balanceOf` answers `b - shrinkAfterMove`. The point is a SECOND read
    /// that is smaller than the first, which is the only way to reach `post < pre` inside a deposit.
    uint256 public shrinkAfterMove;
    bool public moved;

    function mint(address to, uint256 v) external {
        bal[to] += v;
    }

    function setReadShape(Read s) external {
        readShape = s;
    }

    function setWriteShape(Write s) external {
        writeShape = s;
    }

    function setShrinkAfterMove(uint256 v) external {
        shrinkAfterMove = v;
    }

    function balanceOf(address who) external view returns (uint256) {
        uint256 b = bal[who];
        if (moved && shrinkAfterMove > 0) b = b > shrinkAfterMove ? b - shrinkAfterMove : 0;
        Read s = readShape;
        if (s == Read.REVERT_NO_DATA) {
            assembly {
                revert(0, 0)
            }
        }
        if (s == Read.EMPTY) {
            assembly {
                return(0, 0)
            }
        }
        if (s == Read.WIDE) {
            assembly {
                mstore(0x00, b)
                mstore(0x20, b)
                return(0x00, 0x40)
            }
        }
        return b;
    }

    function transferFrom(address from, address to, uint256 v) external returns (bool) {
        _move(from, to, v);
        _answer();
        return true;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        _move(msg.sender, to, v);
        _answer();
        return true;
    }

    function _move(address from, address to, uint256 v) private {
        require(bal[from] >= v, "ReturnDataToken: balance");
        bal[from] -= v;
        bal[to] += v;
        moved = true;
    }

    /// @dev the tokens have already moved by the time this runs, on purpose: a token that lies about the
    /// outcome AFTER doing the work is the interesting one.
    function _answer() private view {
        Write s = writeShape;
        if (s == Write.FALSE) {
            assembly {
                mstore(0x00, 0)
                return(0x00, 0x20)
            }
        }
        if (s == Write.NOTHING) {
            assembly {
                return(0, 0)
            }
        }
    }
}

contract ToyVaultBoundariesTest is Test {
    HostileERC20 internal token;
    ToyVault internal vault;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        token = new HostileERC20("Hostile", "HOSS", 18);
        vault = new ToyVault(address(token));
        token.mint(alice, 100e18);
        token.mint(bob, 100e18);
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);
    }

    function _deposit(address who, uint256 amount) internal returns (uint256) {
        vm.prank(who);
        return vault.deposit(amount);
    }

    // ================================================================ deposit: what counts as a delivery
    /// @dev kills `post <= pre` -> `post < pre`. With that mutation a deposit that delivered NOTHING is not
    /// refused: it credits zero and succeeds, so a caller is told its deposit worked.
    function test_a_deposit_that_delivers_nothing_is_refused_not_credited_as_zero() public {
        token.setTrueNoMove(alice, true); // returns true, moves nothing
        vm.prank(alice);
        vm.expectRevert(ToyVault.NothingDelivered.selector);
        vault.deposit(5e18);

        assertEq(vault.credit(alice), 0, "nothing arrived, so there is nothing to credit");
        assertEq(vault.totalCredit(), 0);
    }

    /// @dev kills `post <= pre` -> `post == pre`. If the vault's own balance READS smaller after the transfer
    /// than before it - threat-model case 8, the token lying about the vault - the mutation lets
    /// `post - pre` underflow, so the vault answers with an arithmetic panic instead of its own error. The
    /// vault does not defend case 8 and does not claim to; what it does promise is that it never credits, and
    /// that it fails with a reason it named.
    function test_a_vault_balance_that_reads_smaller_after_the_transfer_is_refused_with_the_declared_error()
        public
    {
        ReturnDataToken t = new ReturnDataToken();
        ToyVault v = new ToyVault(address(t));
        t.mint(alice, 10e18);
        t.mint(address(v), 100e18);
        t.setShrinkAfterMove(50e18); // the second read is 50e18 below the first

        vm.prank(alice);
        vm.expectRevert(ToyVault.NothingDelivered.selector);
        v.deposit(10e18);

        assertEq(v.credit(alice), 0);
    }

    // ================================================================ withdraw: the credit boundary
    /// @dev kills `have < amount` -> `have <= amount`. Withdrawing EXACTLY the whole credit is the one amount
    /// the campaign never proposes, and it is the amount every user eventually asks for.
    function test_withdrawing_exactly_the_whole_credit_is_allowed() public {
        uint256 credited = _deposit(alice, 7e18);
        assertEq(credited, 7e18);

        uint256 before = token.trueBalanceOf(alice);
        vm.prank(alice);
        vault.withdraw(credited);

        assertEq(vault.credit(alice), 0, "the credit was not cleared");
        assertEq(vault.totalCredit(), 0, "the total did not follow");
        assertEq(token.trueBalanceOf(alice) - before, credited, "the tokens did not come back");
    }

    /// @dev kills `have < amount` -> `have != amount`, which refuses every PARTIAL withdrawal.
    ///
    /// Worth reading twice, because it is the second blind spot in the same line. Not one test in this file
    /// took part of a credit: they all took the whole thing, because "the whole credit" was the boundary the
    /// FIRST mutation pass pointed at, and the tests were written to that. Closing one blind spot is how you
    /// acquire the next one, and the only thing that finds it is running the pass again afterwards.
    ///
    /// The campaign cannot see it either, and for the reason this file was created: the mutant reverts with
    /// `InsufficientCredit`, the handler classifies that as a predicted failure and moves on.
    function test_withdrawing_part_of_the_credit_is_allowed() public {
        _deposit(alice, 5e18);

        vm.prank(alice);
        vault.withdraw(2e18);
        assertEq(vault.credit(alice), 3e18, "the rest of the credit must survive the partial withdrawal");
        assertEq(vault.totalCredit(), 3e18, "and the total must follow it down by the same amount");

        vm.prank(alice); // and the remainder afterwards, in one go
        vault.withdraw(3e18);
        assertEq(vault.credit(alice), 0);
    }

    /// @dev kills `have < amount` -> `have == amount`. With that mutation asking for more than you have does
    /// not meet the guard at all: it falls through to `have - amount` and answers with an arithmetic panic,
    /// which is a different contract from one that says `InsufficientCredit`.
    function test_withdrawing_more_than_the_credit_is_refused_with_the_declared_error() public {
        _deposit(alice, 3e18);
        vm.prank(alice);
        vm.expectRevert(ToyVault.InsufficientCredit.selector);
        vault.withdraw(3e18 + 1);

        vm.prank(bob); // and a wallet with no credit at all
        vm.expectRevert(ToyVault.InsufficientCredit.selector);
        vault.withdraw(1);
    }

    // ================================================================ withdraw: the outflow check
    // The check is `spent != amount`, in BOTH directions, and it used to be `spent > amount`. That missing
    // lower bound was found by an independent audit and not by any tool in this repository: the mutation
    // pass changes operators, it does not invent the branch that is not there, and the invariant campaign
    // had no action that pointed the "returns true and moves nothing" switch at the VAULT. The four tests
    // below are the ones that would have caught it.

    /// @dev THE AUDIT'S FINDING, as a test. A token that returns true and moves nothing on the way OUT: the
    /// caller's credit used to be cleared, the tokens stayed in the vault, and `totalCredit` went to zero -
    /// so the vault owed nobody anything and the tokens were unclaimable by anyone.
    /// Kills `spent != amount` -> `spent > amount` (the old code), `-> spent >= amount`, and any mutation
    /// that drops the lower bound.
    function test_a_payout_that_moves_nothing_is_refused_and_the_credit_survives() public {
        _deposit(alice, 10e18);
        token.setTrueNoMove(address(vault), true);

        uint256 aliceBefore = token.trueBalanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ToyVault.PaidOtherThanAsked.selector, 10e18, 0));
        vault.withdraw(10e18);

        assertEq(vault.credit(alice), 10e18, "the credit must survive a payout that never happened");
        assertEq(vault.totalCredit(), 10e18, "and so must the total");
        assertEq(token.trueBalanceOf(alice), aliceBefore, "alice received nothing, correctly");
        assertEq(token.trueBalanceOf(address(vault)), 10e18, "and the vault still holds what it owes");
    }

    /// @dev the quieter half of the same finding: the token delivers HALF. Under the old bound the caller
    /// lost the claim on the other half. Kills the same mutations as above, and is the one a reviewer is
    /// likelier to write off as "a fee-on-transfer token, that is fine".
    function test_a_payout_that_delivers_half_is_refused_and_the_credit_survives() public {
        _deposit(alice, 10e18);
        uint256 aliceBefore = token.trueBalanceOf(alice);
        token.setShortDeliver(address(vault), 2);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ToyVault.PaidOtherThanAsked.selector, 10e18, 5e18));
        vault.withdraw(10e18);

        assertEq(vault.credit(alice), 10e18, "half a delivery is not a delivery");
        assertEq(token.trueBalanceOf(alice), aliceBefore, "and alice kept nothing she was not given");
    }

    /// @dev LINE 10 OF THE MODEL, OUT OF SCOPE, PINNED DOWN. This test asserts a LOSS, on purpose: the token delivers
    /// a sixth and burns the other five sixths from the vault, so the vault's balance falls by exactly the amount,
    /// the exact-outflow check is satisfied, the credit is cleared, and alice holds a sixth of her money. A contract
    /// that measures only its own balance cannot see this, and the threat model says so instead of claiming a
    /// defence it does not have. If a later version of the vault DOES defend it (by measuring the recipient), this
    /// test goes red - and that is the moment to move line 10 back into scope, not to delete the test.
    function test_outOfScope_short_delivery_hidden_by_a_sender_side_burn() public {
        _deposit(alice, 6e18);
        uint256 aliceBefore = token.trueBalanceOf(alice);
        token.setShortDeliver(address(vault), 6);
        token.setExtraBurnFrom(address(vault), 5e18);

        vm.prank(alice);
        vault.withdraw(6e18); // goes through

        assertEq(token.trueBalanceOf(address(vault)), 0, "the payout cost the vault exactly the amount");
        assertEq(vault.credit(alice), 0, "the credit was cleared in full");
        assertEq(token.trueBalanceOf(alice) - aliceBefore, 1e18, "and alice received a sixth: exact outflow is not delivery");
    }

    /// @dev a token that pays the SENDER a rebate leaves the vault richer than it should be. The vault
    /// refuses it, and that refusal is a DECISION with a cost, written down at the top of `ToyVault.sol`:
    /// from where the vault stands, "the token gave some of it back" and "the token never delivered it" are
    /// the same measurement, and one of the two loses the caller's money.
    /// Kills `spent != amount` -> `spent > amount` and `-> spent >= amount`.
    function test_a_payout_that_costs_the_vault_less_than_the_amount_is_refused_too() public {
        _deposit(alice, 1e18);
        token.fundReserve(5e18);
        token.setRebateFrom(address(vault), 25e16); // 0.25e18 of the 1e18 comes straight back

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ToyVault.PaidOtherThanAsked.selector, 1e18, 75e16));
        vault.withdraw(1e18);
        assertEq(vault.credit(alice), 1e18, "a refused payout leaves the credit alone");
    }

    /// @dev the extreme of the same shape: the rebate is bigger than the payout, so the vault ends RICHER
    /// and `pre > post` is false. Kills `pre > post` -> `pre != post` (which underflows here instead of
    /// yielding zero) and `-> pre >= post`'s siblings that change the value of `spent` on this input.
    function test_a_payout_that_leaves_the_vault_richer_is_refused_without_underflowing() public {
        _deposit(alice, 1e18);
        token.fundReserve(5e18);
        token.setRebateFrom(address(vault), 2e18); // more comes back than goes out

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ToyVault.PaidOtherThanAsked.selector, 1e18, 0));
        vault.withdraw(1e18);
        assertEq(vault.credit(alice), 1e18);
    }

    /// @dev the honest payout, which is the input every mutation of `!=` has to keep working. A token that
    /// takes exactly what it was told to take, and delivers it. Kills `spent != amount` -> `spent == amount`
    /// (and `< `, `<=`), all of which refuse every correct withdrawal there is.
    function test_a_payout_that_costs_exactly_the_amount_is_allowed() public {
        _deposit(alice, 4e18);
        uint256 vaultBefore = token.trueBalanceOf(address(vault));
        uint256 aliceBefore = token.trueBalanceOf(alice);

        vm.prank(alice);
        vault.withdraw(4e18); // must not revert

        assertEq(vaultBefore - token.trueBalanceOf(address(vault)), 4e18, "the vault spent exactly the amount");
        assertEq(token.trueBalanceOf(alice) - aliceBefore, 4e18, "and alice got exactly the amount");
        assertEq(vault.credit(alice), 0);
    }

    /// @dev kills `pre > post` -> `pre == post`, `pre - post` -> `pre % post` and `pre - post` ->
    /// `pre << post`, all three at once, because all three make `spent` collapse to something small or to
    /// zero. The numbers are chosen so that the vault ends with LESS THAN HALF of what it started with:
    /// `pre % post` only differs from `pre - post` once `pre >= 2 * post`, and a campaign that moves small
    /// amounts never gets there.
    function test_a_payout_that_costs_the_vault_far_more_than_the_amount_is_refused() public {
        _deposit(alice, 1e18);
        token.mint(address(vault), 9e18); // a donation: the vault now holds 10e18 and owes 1e18
        assertEq(token.trueBalanceOf(address(vault)), 10e18);

        token.setExtraBurnFrom(address(vault), 8e18); // leaving costs 8e18 on top of the 1e18 paid out

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ToyVault.PaidOtherThanAsked.selector, 1e18, 9e18));
        vault.withdraw(1e18);
    }

    /// @dev the frame-eating token on the way OUT (case 5 of the model, outbound). Whatever it costs the
    /// caller, the credit must survive - and the test is written as a raw capped call rather than an
    /// `expectRevert` because the SHAPE of the failure depends on the budget: with room left after the
    /// token returns, the vault gets to its second read and answers `PaidOtherThanAsked(amount, 0)`; with a
    /// tighter frame it dies with no revert data at all. A handler's catch branch has to classify both.
    function test_a_payout_whose_token_eats_the_frame_leaves_the_credit_alone() public {
        _deposit(alice, 1e18);
        uint256 aliceBefore = token.trueBalanceOf(alice);
        token.setGasHogTransfer(address(vault), true);

        vm.prank(alice);
        (bool ok,) = address(vault).call{gas: 600_000}(abi.encodeWithSignature("withdraw(uint256)", 1e18));
        assertFalse(ok, "a payout through a frame-eating token must not succeed");
        assertEq(vault.credit(alice), 1e18, "the credit survives");
        assertEq(vault.totalCredit(), 1e18, "and so does the total");
        assertEq(token.trueBalanceOf(alice), aliceBefore, "alice was paid nothing, correctly");
    }

    // ================================================================ the return data of `balanceOf`
    /// @dev kills `!ok || data.length < 32` -> `!ok != data.length < 32`. When the read reverts with NO data
    /// both halves are true, and the exclusive-or of two truths is false: the vault stops refusing and hands
    /// the empty buffer to `abi.decode`, which fails with no reason of its own. The kit's own hostile token
    /// cannot reach this case - its `BalanceUnreadable(address)` is 36 bytes of revert data, not zero - which
    /// is exactly why the mutant survived a campaign that flips that switch all day.
    function test_a_balance_read_that_reverts_with_no_data_is_refused_with_the_declared_error() public {
        ReturnDataToken t = new ReturnDataToken();
        ToyVault v = new ToyVault(address(t));
        t.mint(alice, 10e18);
        t.setReadShape(ReturnDataToken.Read.REVERT_NO_DATA);

        vm.prank(alice);
        vm.expectRevert(ToyVault.TransferFailed.selector);
        v.deposit(1e18);
    }

    /// @dev kills `data.length < 32` -> `data.length > 32`. A read that succeeds and returns NOTHING is the
    /// silent version of the same attack, and the mutation accepts it.
    function test_a_balance_read_that_succeeds_with_no_data_is_refused_with_the_declared_error() public {
        ReturnDataToken t = new ReturnDataToken();
        ToyVault v = new ToyVault(address(t));
        t.mint(alice, 10e18);
        t.setReadShape(ReturnDataToken.Read.EMPTY);

        vm.prank(alice);
        vm.expectRevert(ToyVault.TransferFailed.selector);
        v.deposit(1e18);
    }

    /// @dev kills `data.length < 32` -> `data.length != 32` and `-> data.length > 32`. The check is a FLOOR,
    /// not an equality: a token that answers with a correct word and something appended is answering. Turning
    /// the floor into an equality refuses it, and that is a different contract.
    function test_a_balance_read_with_extra_data_after_the_word_is_accepted() public {
        ReturnDataToken t = new ReturnDataToken();
        ToyVault v = new ToyVault(address(t));
        t.mint(alice, 10e18);
        t.setReadShape(ReturnDataToken.Read.WIDE);

        vm.prank(alice);
        uint256 credited = v.deposit(1e18);
        assertEq(credited, 1e18, "the first word is the answer");
        assertEq(v.credit(alice), 1e18);
    }

    // ================================================================ the return data of `transferFrom`
    /// @dev kills `data.length != 0` -> `data.length < 0`, `-> data.length <= 0` and `-> data.length == 0`.
    /// All three stop the vault from ever reading the boolean, so a token that moved the tokens and then said
    /// `false` is accepted. The vault's written promise is the opposite: accept a token that returns nothing,
    /// refuse one that returns false.
    function test_a_transfer_that_returns_false_is_refused_even_though_the_tokens_moved() public {
        ReturnDataToken t = new ReturnDataToken();
        ToyVault v = new ToyVault(address(t));
        t.mint(alice, 10e18);
        t.setWriteShape(ReturnDataToken.Write.FALSE);

        vm.prank(alice);
        vm.expectRevert(ToyVault.TransferFailed.selector);
        v.deposit(1e18);

        assertEq(v.credit(alice), 0, "a refused deposit credits nothing");
    }

    /// @dev kills `data.length != 0` -> `data.length <= 0`, `-> data.length == 0`, `-> data.length >= 0` and
    /// `-> data.length != 0 == !abi.decode(...)`. Each of them makes the vault evaluate
    /// `abi.decode(data, (bool))` on an EMPTY buffer, which reverts - so the largest stablecoin by volume,
    /// which returns no data at all, stops working with the vault.
    function test_a_transfer_that_returns_no_data_at_all_is_accepted() public {
        token.setOmitReturnValue(true);

        uint256 credited = _deposit(alice, 4e18);
        assertEq(credited, 4e18, "a token that returns nothing still delivered");
        assertEq(vault.credit(alice), 4e18);

        vm.prank(alice); // and the payout side too
        vault.withdraw(4e18);
        assertEq(vault.credit(alice), 0);
    }
}
