// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {HostileERC20, IHostileTokenCallback} from "../../src/HostileERC20.sol";
import {HandlerBase, InvariantAsserts, IBalanceReader, YES, NO} from "../../src/InvariantBase.sol";
import {ToyVault} from "../../src/examples/ToyVault.sol";

// The example lives in the standard directories - `src/examples/` for the contract, `test/examples/` for this
// file - and not in an `examples/` tree of its own. That is not a matter of taste: `forge test --mutate` and
// `forge --brutalize` copy only `src/` and `test/` into their temporary workspace, so an example kept outside
// them produces 136 mutants, 136 INVALID and exit code 0 - a green tick over a tool that tested nothing.
//
// ADAPT: this file is a worked TOY, not a template to fill in. The actions and the invariants below belong to a
// vault that pulls tokens by allowance. Yours come from your hook: derive them with doctrine/INVARIANTS.md
// (backwards, from who can lose what) and doctrine/FUZZ-ACTIONS.md (one action per entry point, plus time, plus the
// token misbehaving mid-campaign, plus the strange actors, plus the reads). What carries over is the SHAPE: a truth
// reader the contract never sees, snapshot-act-compare inside each action, expected vs unexpected reverts, and
// _noteSuccess() so the census can prove the campaign was not vacuous.

/// @notice the referee's reader: the truth, with every switch of the token ignored. The contract under test
/// never sees this; only the invariants do, and only for the questions that are ABOUT the truth (solvency).
contract TruthReader is IBalanceReader {
    HostileERC20 private immutable token;

    constructor(HostileERC20 t) {
        token = t;
    }

    function balanceOf(address who) external view returns (uint256) {
        return token.trueBalanceOf(who);
    }
}

/// @notice an actor that re-enters the vault from inside the token's transfer hooks. Every re-entry is
/// expected to fail; if one ever succeeds the counter says so and the invariant fails.
contract ReentrantActor is IHostileTokenCallback {
    ToyVault public immutable vault;
    HostileERC20 public immutable token;
    uint256 public reenteredDeposit;
    uint256 public reenteredWithdraw;
    uint256 public blocked;

    constructor(ToyVault v, HostileERC20 t) {
        vault = v;
        token = t;
        t.approve(address(v), type(uint256).max);
    }

    function tokensToSend(address, address, uint256) external override {
        try vault.deposit(1) {
            reenteredDeposit += 1;
        } catch {
            blocked += 1;
        }
        try vault.withdraw(1) {
            reenteredWithdraw += 1;
        } catch {
            blocked += 1;
        }
    }

    function tokensReceived(address, address, uint256) external override {
        try vault.withdraw(1) {
            reenteredWithdraw += 1;
        } catch {
            blocked += 1;
        }
    }
}

/// @notice Drives the vault against the hostile token. Every call into the vault is wrapped in try/catch AND
/// capped in gas: without the cap, a token that eats the frame turns a catchable failure into a dead run, and
/// `fail_on_revert = true` would report a bug in the handler instead of the behaviour of the token.
contract ToyVaultHandler is HandlerBase, InvariantAsserts {
    HostileERC20 public token;
    ToyVault public vault;
    IBalanceReader public truth;
    ReentrantActor public attacker;

    uint256 public depositsOk;
    uint256 public withdrawsOk;

    uint256 private constant CALL_GAS = 600_000;
    uint256 private constant MAX_AMOUNT = 20e18;

    constructor(HostileERC20 t, ToyVault v, IBalanceReader truth_, ReentrantActor a) {
        token = t;
        vault = v;
        truth = truth_;
        attacker = a;
        for (uint256 i = 0; i < 4; i++) _addActor(address(uint160(0x1000 + i)));
        _addActor(address(a));
    }

    /// @notice every address the token can reach in this test. A conservation invariant over an incomplete
    /// list is not a weaker check, it is a wrong one.
    function holders() public view returns (address[] memory out) {
        out = new address[](actors.length + 3);
        for (uint256 i = 0; i < actors.length; i++) out[i] = actors[i];
        out[actors.length] = address(vault);
        out[actors.length + 1] = token.FEE_SINK();
        out[actors.length + 2] = token.RESERVE();
    }

    // ------------------------------------------------------------------ actions on the vault
    function deposit(uint256 actorSeed, uint256 amount) public counted("deposit") {
        address a = _actor(actorSeed);
        amount = bound(amount, 0, MAX_AMOUNT);
        token.mint(a, amount);
        _noteMint(amount);

        vm.prank(a);
        token.approve(address(vault), type(uint256).max);

        address[] memory hs = holders();
        uint256[] memory pre = snapshotBalances(truth, hs);
        uint256 vaultPre = truth.balanceOf(address(vault));
        uint256 creditPre = vault.credit(a);

        vm.prank(a);
        try vault.deposit{gas: CALL_GAS}(amount) returns (uint256 credited) {
            depositsOk += 1;
            _noteSuccess("deposit");
            uint256 vaultPost = truth.balanceOf(address(vault));
            assertEq(vaultPost - vaultPre, credited, "credited a number that did not arrive");
            assertEq(vault.credit(a) - creditPre, credited, "the ledger moved by something other than the delivery");
            _noteDelta(a, pre[actorSeed % actors.length], truth.balanceOf(a));
            if (credited < amount) _noteReached("deposit credited less than was asked");
            if (credited > amount) _noteReached("deposit credited more than was asked");
            // the vault may only gain what the others lost, and the token's reserve is one of the others
            assertGainBackedByLoss(truth, hs, pre, address(vault), 0, "deposit");
        } catch (bytes memory err) {
            _classify(err, "deposit", a);
        }
    }

    /// @notice the wallet a withdrawal is aimed at.
    ///
    /// A fuzzer proposes a WALLET. It does not propose a wallet that has anything to withdraw, and in a
    /// five-actor cast driven by twenty-four actions at depth 64 most of them never will: measured, the
    /// campaign spent whole runs asking empty wallets for money and `withdraw` succeeded in 5 to 7 per cent
    /// of its calls. So a share of the calls take the seed as given - the `InsufficientCredit` branch is a
    /// promise too and has to be exercised - and the rest land on a wallet that actually has a credit.
    ///
    /// This is the same move as bounding the amount against the state instead of against a constant, and it
    /// is the one to reach for whenever an action needs a precondition the fuzzer cannot know about.
    /// @dev `seed` is a FULL WORD from the fuzzer, so it reaches `type(uint256).max`, and `seed + i` there
    /// is an overflow panic in the handler - a red campaign that says nothing about the vault. Reduce it
    /// first, then walk. The campaign found this in seventeen calls, in a helper written to make the
    /// campaign better.
    function _withdrawer(uint256 seed) internal view returns (address) {
        address a = _actor(seed);
        if (_bitOneIn(seed, 4) || vault.credit(a) > 0) return a;
        uint256 start = seed % actors.length;
        for (uint256 i = 1; i < actors.length; i++) {
            address c = actors[(start + i) % actors.length];
            if (vault.credit(c) > 0) return c;
        }
        return a;
    }

    function withdraw(uint256 actorSeed, uint256 amount) public counted("withdraw") {
        address a = _withdrawer(actorSeed);
        uint256 creditPre = vault.credit(a);

        // BOUND AGAINST WHAT THE CALLER HAS, not against a fixed ceiling, and this is the most useful line
        // in the file to copy. With `bound(amount, 0, MAX_AMOUNT)` the fuzzer asks for 20e18 against a
        // credit of 3e18 almost every time, and the action becomes a machine for producing
        // `InsufficientCredit`: measured, 38 to 48 of 65 runs ended with ZERO successful withdrawals, and a
        // whole credit - the amount a real user asks for first, and a boundary a mutation pass had already
        // caught the suite missing - was withdrawn in one run in 65. With this and `_withdrawer` below the
        // runs with none fall to roughly a fifth to two fifths of the 65, and the whole credit is withdrawn
        // in a handful of them (the measured draws live in `foundry-kit/README.md`, and only there).
        //
        // A share of the calls still asks for more than the caller has, because that branch is a promise
        // too. Deriving the bound from the STATE rather than from a constant is the general move.
        if (creditPre > 0 && _bitOneIn(amount, 8)) {
            amount = creditPre; // the whole credit, on purpose
        } else if (creditPre > 0 && !_bitOneIn(amount, 4)) {
            amount = bound(amount, 0, creditPre); // something the caller can afford
        } else {
            amount = bound(amount, 0, MAX_AMOUNT); // and sometimes more than it has
        }

        uint256 totalPre = vault.totalCredit();
        uint256 walletPre = truth.balanceOf(a);
        uint256 vaultPre = truth.balanceOf(address(vault));

        vm.prank(a);
        try vault.withdraw{gas: CALL_GAS}(amount) {
            withdrawsOk += 1;
            _noteSuccess("withdraw");
            assertEq(creditPre - vault.credit(a), amount, "the caller's credit did not fall by the amount asked");
            assertEq(totalPre - vault.totalCredit(), amount, "the total did not follow the caller's credit");
            // Case 8 of the model, as an assertion AROUND THE ACTION and not only as a revert inside the
            // vault: a payout that cleared the credit and delivered nothing is the finding an independent
            // audit found here, and the handler had no way to see it. The fee on transfer is the one thing
            // the caller is expected to lose, so it is subtracted rather than ignored.
            //
            // With ONE exception, which is line 10 of the model and out of scope by declaration: a short
            // delivery whose shortfall is hidden from the vault by a sender-side burn of the same size. The
            // vault cannot see it, this assertion can, and for a while the campaign went red on it about once
            // in four hundred campaigns - a true finding against the threat model's wording, and after that
            // an intermittent battery. It is CLASSIFIED here, by reading the token's switches, and counted in
            // the reach census so that "out of scope" stays a number somebody can look at and not a shrug.
            //
            // Classified NARROWLY: only when the caller really was short-changed AND both switches are on. The
            // first version filed every payout made with both switches on, and the census showed it in up to 13
            // runs of 65, most of them payouts in which nobody lost anything (a zero withdrawal whose burn is
            // cancelled by a rebate goes through, for one). A classification wider than the thing it names is
            // where the next real finding hides.
            //
            // A side effect worth knowing: before the hand-driven test of this line existed the campaign met
            // the combination about once in four hundred campaigns; with it, in anything from none to eleven of
            // the 65 RUNS of a campaign (eleven campaigns measured, by two people) - and in
            // every one of 19 logged occurrences the values were that test's own literals (12e17, 6, 1e18).
            // Forge seeds its fuzz dictionary from the constants in the test contract, so writing the
            // scenario down by hand is also how you teach the campaign to reach it.
            (,,, uint256 shortDiv,,, uint256 senderBurn) = token.moveSwitch(address(vault));
            uint256 owedToTheCaller = amount - (amount * token.feeBps() / 10_000);
            uint256 received = truth.balanceOf(a) - walletPre;
            if (received < owedToTheCaller && shortDiv > 1 && senderBurn > 0) {
                _noteReached("OUT OF SCOPE (model line 10): a payout went through with short delivery and a sender-side burn both on");
            } else {
                assertGe(received, owedToTheCaller, "the credit was spent and the caller was not paid");
            }
            if (amount == creditPre && amount > 0) _noteReached("withdrew the whole credit");
            if (amount == 0) _noteReached("withdrew nothing");

            // A token that pays its SENDER a rebate pays the VAULT on the way out, from the token's own
            // reserve. The vault ends a payout RICHER, by an amount nobody chose and nobody can claim. It
            // is a donation that arrived by a route this handler did not take, and the ghost ledger has to
            // say so: `invariant_vault_holds_only_credit_and_donations` failed on correct behaviour until
            // it did. Not `_noteDonation` - nothing was minted, the tokens came from a holder already on
            // the conservation list, and counting them twice would break the other invariant.
            uint256 vaultPost = truth.balanceOf(address(vault));
            if (vaultPost > vaultPre) {
                _noteInternalDonation(address(vault), address(token), vaultPost - vaultPre);
                _noteReached("the vault ended a payout richer than it started");
            }
        } catch (bytes memory err) {
            _classify(err, "withdraw", address(vault));
        }
    }

    // ------------------------------------------------------------------ classifying a failure
    /// @notice The catch branch is where a campaign run with `fail_on_revert = true` either becomes evidence
    /// or becomes noise. `_expectedRevert()` on everything is noise: it says "something failed" and files it
    /// under "predicted", which is exactly what an unpredicted failure would also look like.
    ///
    /// So: the vault's own declared errors are data points; an empty revert is the frame-eating token, which
    /// the model predicts (case 5) and which arrives with no data because the call ran out of gas; anything
    /// else - an arithmetic panic, a `require` string nobody wrote here, a selector from somewhere else - is
    /// a surprise, and `_unexpectedRevert` records it for `invariant_no_unexplained_reverts` to fail on.
    /// @param sender the wallet the token was asked to move FROM in this call: the actor on a deposit, the vault on a
    /// payout. Only ITS frame-eating switch can explain an empty revert here - the other wallet's is not in play.
    function _classify(bytes memory err, string memory where, address sender) internal {
        if (err.length == 0) {
            // no revert data at all: out of gas inside the capped frame. Predicted by case 5 of the model - but ONLY
            // while something is switched on that eats gas. An unbounded loop in the contract under test dies with
            // exactly the same face, so with every gas switch off an empty revert is a surprise, not a data point.
            (, bool senderHog,,,,,) = token.moveSwitch(sender);
            (,,,, uint256 readBurn,,,) = token.readSwitch(address(vault));
            if (senderHog || readBurn > 0) {
                _expectedRevert();
                _noteReached("a call died with no revert data");
            } else {
                _unexpectedRevert(string.concat(where, " died with no revert data and no gas switch was on"));
            }
            return;
        }
        bytes4 sel = bytes4(err);
        if (
            sel == ToyVault.NothingDelivered.selector || sel == ToyVault.InsufficientCredit.selector
                || sel == ToyVault.TransferFailed.selector || sel == ToyVault.PaidOtherThanAsked.selector
                || sel == ToyVault.Reentrancy.selector
        ) {
            _expectedRevert();
            _noteReached(string.concat(where, " refused with a declared error"));
            return;
        }
        _unexpectedRevert(string.concat(where, " failed with something nothing predicted: ", vm.toString(err)));
    }

    /// @notice tokens pushed straight at the vault. Nobody can claim them, and the vault must not credit them.
    function donate(uint256 amount) public countedSetter("donate") {
        amount = bound(amount, 0, MAX_AMOUNT);
        token.mint(address(vault), amount);
        _noteDonation(address(vault), address(token), amount);
    }

    function fundReserve(uint256 amount) public countedSetter("fundReserve") {
        amount = bound(amount, 0, MAX_AMOUNT);
        token.fundReserve(amount);
        _noteMint(amount);
    }

    // ------------------------------------------------------------------ switches on the token
    //
    // A note on the shape of the arguments, and it is the most transferable thing in this file. A hostile
    // switch STAYS ON until some later call happens to turn it off. With `_bit(word)` - on half the time -
    // the campaign parks itself in the broken state almost immediately and stays there: measured on this
    // example, 40 of 65 runs ended with ZERO successful withdrawals, and every invariant passed over a vault
    // nobody could use. So the switches that block everything downstream are biased toward the honest value
    // with `_bitOneIn`, and `calmDown()` below can clear the lot. Then the census is read to check it worked.
    function setFee(uint256 bps) public countedSetter("setFee") {
        uint256 v = bound(bps, 0, 2_000);
        token.setFeeBps(v <= 500 ? 0 : v); // a quarter of the range means "no fee"
    }

    function setPaused(uint256 onWord) public countedSetter("setPaused") {
        token.setPaused(_bitOneIn(onWord, 4));
    }

    function setOmitReturn(uint256 onWord) public countedSetter("setOmitReturn") {
        // not biased: the vault is supposed to work with a token that returns no data, so this one is not a
        // switch that stops the campaign, it is a branch the campaign should spend half its life in.
        bool on = _bit(onWord);
        token.setOmitReturnValue(on);
    }

    function setShortDeliver(uint256 actorSeed, uint256 div) public countedSetter("setShortDeliver") {
        token.setShortDeliver(_actor(actorSeed), bound(div, 0, 5)); // 0 and 1 both mean "honest"
    }

    function setTrueNoMove(uint256 actorSeed, uint256 onWord) public countedSetter("setTrueNoMove") {
        token.setTrueNoMove(_actor(actorSeed), _bitOneIn(onWord, 3));
    }

    function setGasHog(uint256 actorSeed, uint256 onWord) public countedSetter("setGasHog") {
        token.setGasHogTransfer(_actor(actorSeed), _bitOneIn(onWord, 3));
    }

    function setRebate(uint256 actorSeed, uint256 n) public countedSetter("setRebate") {
        uint256 v = bound(n, 0, 1e18);
        token.setRebateFrom(_actor(actorSeed), v <= 25e16 ? 0 : v);
    }

    function setExtraBurnActor(uint256 actorSeed, uint256 n) public countedSetter("setExtraBurnActor") {
        uint256 v = bound(n, 0, 1e18);
        token.setExtraBurnFrom(_actor(actorSeed), v <= 25e16 ? 0 : v);
    }

    function setActorUnreadable(uint256 actorSeed, uint256 onWord) public countedSetter("setActorUnreadable") {
        token.setBalanceRevert(_actor(actorSeed), _bitOneIn(onWord, 4));
    }

    /// @notice case 7 of the model: leaving the vault costs the vault more than it pays out.
    function setExtraBurnVault(uint256 n) public countedSetter("setExtraBurnVault") {
        uint256 v = bound(n, 0, 1e18);
        token.setExtraBurnFrom(address(vault), v <= 25e16 ? 0 : v);
    }

    // ---------------------------------------------------------- case 8: the same tokens, on the way OUT
    // These three point the switches at the VAULT as the SENDER. Until an independent audit asked for them
    // the handler could only aim them at the actors, so the whole outbound half of the threat model was
    // unreachable by the campaign - and `withdraw`'s missing lower bound survived every run of it.
    // All four are biased HARDER than their inbound twins, and the reason is worth reading before you copy
    // the list. Every one of them makes `withdraw` revert for as long as it is on, so four new sticky
    // switches aimed at the one action that was already the hardest to get through is a fast way to make
    // the campaign worse at the very thing it was extended to test. Measured while tuning them, one draw
    // each: at the inbound bias, the runs with zero successful withdrawals went straight back up to 40 of
    // 65, which is where they started.
    // Adding an action to reach a branch is half the job; the other half is checking the census afterwards.
    /// @notice the token returns true and moves nothing when the VAULT pays out.
    function setVaultTrueNoMove(uint256 onWord) public countedSetter("setVaultTrueNoMove") {
        token.setTrueNoMove(address(vault), _bitOneIn(onWord, 6));
    }

    /// @notice the token delivers a fraction of what the VAULT told it to.
    function setVaultShortDeliver(uint256 div) public countedSetter("setVaultShortDeliver") {
        uint256 d = bound(div, 0, 11);
        token.setShortDeliver(address(vault), d < 6 ? 0 : d); // half the range means "honest"
    }

    /// @notice the token eats the frame when the VAULT pays out.
    function setVaultGasHog(uint256 onWord) public countedSetter("setVaultGasHog") {
        token.setGasHogTransfer(address(vault), _bitOneIn(onWord, 6));
    }

    /// @notice the token pays the VAULT back part of what it just sent. Honest-looking, and refused: the
    /// vault cannot tell a rebate from a short delivery. See the note at the top of `ToyVault.sol`.
    function setVaultRebate(uint256 n) public countedSetter("setVaultRebate") {
        uint256 v = bound(n, 0, 1e18);
        token.setRebateFrom(address(vault), v < 5e17 ? 0 : v);
    }

    /// @notice turn every sticky switch OFF, on the token and on the vault.
    ///
    /// A campaign needs an action that CLEARS state, not only actions that set it. The fuzzer gets to a
    /// broken configuration in a call or two; without this it has no cheap way back, and the rest of the run
    /// is spent in a world where nothing can succeed. Give your own handler one, and count it in the census
    /// so you can see how often the fuzzer chose to use it.
    function calmDown() public counted("calmDown") {
        token.setPaused(false);
        token.setFeeBps(0);
        token.setOmitReturnValue(false);
        token.setBlockIncoming(address(vault), false);
        token.setBalanceRevert(address(vault), false);
        token.setBalanceGasBurn(address(vault), 0);
        token.setExtraBurnFrom(address(vault), 0);
        token.setRebateFrom(address(vault), 0);
        token.setTrueNoMove(address(vault), false);
        token.setShortDeliver(address(vault), 0);
        token.setGasHogTransfer(address(vault), false);
        for (uint256 i = 0; i < actors.length; i++) {
            token.setTrueNoMove(actors[i], false);
            token.setGasHogTransfer(actors[i], false);
            token.setShortDeliver(actors[i], 0);
            token.setExtraBurnFrom(actors[i], 0);
            token.setRebateFrom(actors[i], 0);
            token.setBalanceRevert(actors[i], false);
        }
        _noteSuccess("calmDown");
    }

    /// @notice case 3 of the model: the vault is paid a bonus on receipt, out of the token's reserve.
    function setBonusToVault(uint256 n) public countedSetter("setBonusToVault") {
        token.setBonusTo(address(vault), bound(n, 0, 1e18));
    }

    /// @notice case 4 of the model: the vault is on the token's blocklist.
    function setVaultBlocked(uint256 onWord) public countedSetter("setVaultBlocked") {
        token.setBlockIncoming(address(vault), _bitOneIn(onWord, 4));
    }

    /// @notice case 5 of the model: reading the vault's own balance reverts, or costs a great deal of gas.
    function setVaultUnreadable(uint256 onWord) public countedSetter("setVaultUnreadable") {
        token.setBalanceRevert(address(vault), _bitOneIn(onWord, 4));
    }

    function setVaultReadExpensive(uint256 rounds) public countedSetter("setVaultReadExpensive") {
        token.setBalanceGasBurn(address(vault), bound(rounds, 0, 2_000));
    }

    /// @notice case 6 of the model: the token hands control to the attacker in the middle of the transfer.
    function armAttacker(uint256 fires) public countedSetter("armAttacker") {
        uint256 n = bound(fires, 0, 3);
        token.setSendCallback(address(attacker), address(attacker), n);
        token.setReceiveCallback(address(attacker), address(attacker), n);
    }
}

contract ToyVaultInvariants is Test, InvariantAsserts {
    HostileERC20 token;
    ToyVault vault;
    TruthReader truth;
    ReentrantActor attacker;
    ToyVaultHandler handler;

    function setUp() public {
        token = new HostileERC20("Hostile", "HOSS", 18);
        vault = new ToyVault(address(token));
        truth = new TruthReader(token);
        attacker = new ReentrantActor(vault, token);
        handler = new ToyVaultHandler(token, vault, IBalanceReader(address(truth)), attacker);

        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](24);
        sel[0] = ToyVaultHandler.deposit.selector;
        sel[1] = ToyVaultHandler.withdraw.selector;
        sel[2] = ToyVaultHandler.donate.selector;
        sel[3] = ToyVaultHandler.fundReserve.selector;
        sel[4] = ToyVaultHandler.setFee.selector;
        sel[5] = ToyVaultHandler.setPaused.selector;
        sel[6] = ToyVaultHandler.setOmitReturn.selector;
        sel[7] = ToyVaultHandler.setShortDeliver.selector;
        sel[8] = ToyVaultHandler.setTrueNoMove.selector;
        sel[9] = ToyVaultHandler.setGasHog.selector;
        sel[10] = ToyVaultHandler.setRebate.selector;
        sel[11] = ToyVaultHandler.setExtraBurnActor.selector;
        sel[12] = ToyVaultHandler.setActorUnreadable.selector;
        sel[13] = ToyVaultHandler.setExtraBurnVault.selector;
        sel[14] = ToyVaultHandler.setBonusToVault.selector;
        sel[15] = ToyVaultHandler.setVaultBlocked.selector;
        sel[16] = ToyVaultHandler.armAttacker.selector;
        sel[17] = ToyVaultHandler.setVaultUnreadable.selector;
        sel[18] = ToyVaultHandler.setVaultReadExpensive.selector;
        sel[19] = ToyVaultHandler.setVaultTrueNoMove.selector;
        sel[20] = ToyVaultHandler.setVaultShortDeliver.selector;
        sel[21] = ToyVaultHandler.setVaultGasHog.selector;
        sel[22] = ToyVaultHandler.setVaultRebate.selector;
        sel[23] = ToyVaultHandler.calmDown.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        // Every public action of the handler is in this list. An action that exists and is not registered
        // never runs, and forge does not warn you: count the rows of the selector table in the output
        // against the actions in the handler, once, whenever you add one.
        assertEq(sel.length, 24, "the selector list and the handler have drifted apart");
    }

    /// @notice THE CAMPAIGN'S OWN CENSUS: one line per run into a file, added up by `scripts/census.sh`.
    ///
    /// `forge` prints `(runs: 64, calls: 4096, reverts: 0)` and that `reverts: 0` is a tautology here: with
    /// `fail_on_revert = true` and every call in a try/catch, it cannot be anything else. It says nothing
    /// about what the campaign achieved. The census does - and it has to be the census of EVERY run. This
    /// function executes after each run, but forge prints the logs of ONE of them: the block you see at `-vv`
    /// is a sample of 1 in 64, and it has been seen to say "withdrawsOk 0" over a campaign with more than a
    /// hundred successful withdrawals. So `writeCensus` appends each run to a file, and the question to ask of
    /// the total is: in how many runs did the actions that matter succeed at least ONCE? A run where they
    /// did not tested an empty vault.
    function afterInvariant() public virtual {
        handler.writeCensus("ToyVault");
        handler.printCallSummary();
        handler.printReachSummary();
        console2.log("CAMPAIGN depositsOk", handler.depositsOk());
        console2.log("CAMPAIGN withdrawsOk", handler.withdrawsOk());
    }

    // ------------------------------------------------------------------ invariants
    /// @notice the ledger adds up.
    function invariant_credits_sum_to_total() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.actorCount(); i++) sum += vault.credit(handler.actors(i));
        assertEq(sum, vault.totalCredit(), "totalCredit is not the sum of the credits");
    }

    /// @notice SOLVENCY, against the truth: whatever the token says, the vault really can pay everyone.
    function invariant_vault_is_solvent() public view {
        assertSolvent(IBalanceReader(address(truth)), address(vault), vault.totalCredit(), "toy vault");
    }

    /// @notice and it is not a piggy bank either: it holds what it owes plus what was pushed at it, no more.
    function invariant_vault_holds_only_credit_and_donations() public view {
        uint256 cap = vault.totalCredit() + handler.ghostDonated(address(vault), address(token));
        assertHoldsNoMoreThan(IBalanceReader(address(truth)), address(vault), cap, "toy vault");
    }

    /// @notice nothing was created or destroyed anywhere the token can reach.
    function invariant_global_conservation() public view {
        assertConserved(IBalanceReader(address(truth)), handler.holders(), handler.ghostMinted(), "hostile token");
    }

    /// @notice the guard held every single time the token handed control to the attacker.
    function invariant_reentrancy_never_succeeded() public view {
        assertEq(attacker.reenteredDeposit(), 0, "a re-entrant deposit went through");
        assertEq(attacker.reenteredWithdraw(), 0, "a re-entrant withdraw went through");
    }

    /// @notice no handler call ended in a failure the handler could not explain. This one can now actually
    /// fail: `_unexpectedRevert` records instead of reverting, so the counter survives to be read here and
    /// the reason travels with it. See the note in `HandlerBase._unexpectedRevert`.
    function invariant_no_unexplained_reverts() public view {
        assertEq(
            handler.revertsUnexpected(),
            0,
            string.concat("the handler met a failure it did not predict: ", handler.lastUnexpected())
        );
    }

    // ------------------------------------------------------------------ the out-of-scope line, driven by hand
    /// @notice Line 10 of the vault's model through the HANDLER, because the campaign meets it about once in four
    /// hundred campaigns and a classification nobody has seen working is a guess. A sixth delivered, five sixths
    /// burnt from the vault, amounts chosen so that they cancel: the payout goes through, the handler must file it
    /// under "out of scope" and must NOT raise "the credit was spent and the caller was not paid". With the
    /// classification removed this test goes red on exactly that message.
    function test_handler_files_the_out_of_scope_payout_instead_of_failing_on_it() public {
        handler.deposit(0, 6e18);
        handler.setVaultShortDeliver(6);
        handler.setExtraBurnVault(1e18); // 12e17 asked = 2e17 delivered + 1e18 burnt from the vault
        uint256 before = handler.withdrawsOk();

        handler.withdraw(0, 12e17);

        assertEq(handler.withdrawsOk(), before + 1, "the vault refused a payout this test needs it to accept");
        assertEq(
            handler.reachedCount(
                "OUT OF SCOPE (model line 10): a payout went through with short delivery and a sender-side burn both on"
            ),
            1,
            "the handler did not recognise the combination the model puts out of scope"
        );
        assertEq(token.trueBalanceOf(handler.actors(0)), 2e17, "and the caller really was short-changed: a sixth arrived");
        invariant_vault_is_solvent();
        invariant_global_conservation();
    }

    // ------------------------------------------------------------------ non vacuity
    /// @notice The invariants above are all true of a vault nobody ever used. This test drives the happy path
    /// by hand and proves the harness reaches the code, then runs every invariant on the result. Without it,
    /// a fuzz run that spent itself bouncing off one input filter would still be green.
    function test_handler_smoke() public {
        handler.fundReserve(10e18);
        handler.deposit(0, 5e18);
        handler.deposit(1, 7e18);
        handler.withdraw(0, 2e18);

        handler.setFee(900);
        handler.deposit(2, 4e18);

        handler.setShortDeliver(3, 2);
        handler.deposit(3, 4e18);

        handler.setBonusToVault(1e16);
        handler.deposit(0, 1e18);

        handler.armAttacker(2);
        handler.deposit(4, 3e18);
        handler.withdraw(4, 1e18);

        handler.donate(1e18);
        handler.setVaultBlocked(YES);
        handler.deposit(1, 1e18);
        handler.setVaultBlocked(NO);

        handler.setGasHog(2, YES);
        handler.deposit(2, 1e18);
        handler.setGasHog(2, NO);

        handler.setExtraBurnVault(1e18);
        handler.withdraw(1, 1e18);
        handler.calmDown();

        // case 8 of the model, driven by hand: the three ways a token can misbehave on the way OUT. Each
        // one must leave the caller's credit where it was - the vault refuses the payout, it does not
        // "succeed" at delivering nothing.
        handler.deposit(0, 3e18);
        uint256 creditBefore = vault.credit(handler.actors(0));
        handler.setVaultTrueNoMove(YES);
        handler.withdraw(0, 1e18);
        assertEq(vault.credit(handler.actors(0)), creditBefore, "a payout that moved nothing burnt the credit");
        handler.setVaultTrueNoMove(NO);

        handler.setVaultShortDeliver(6); // the action treats the lower half of its range as "honest"
        handler.withdraw(0, 1e18);
        assertEq(vault.credit(handler.actors(0)), creditBefore, "a short delivery burnt the credit");
        handler.setVaultShortDeliver(0);

        handler.setVaultGasHog(YES);
        handler.withdraw(0, 1e18);
        assertEq(vault.credit(handler.actors(0)), creditBefore, "a payout that ate the frame burnt the credit");
        handler.setVaultGasHog(NO);

        handler.withdraw(0, creditBefore); // and the whole credit, once the token is honest again
        assertEq(vault.credit(handler.actors(0)), 0, "the honest payout did not go through");

        assertGe(handler.depositsOk(), 5, "the smoke path really deposited");
        assertGe(handler.withdrawsOk(), 1, "and really withdrew");
        handler.assertExercised("deposit", 5);
        handler.assertExercised("withdraw", 1);
        handler.assertExercised("calmDown", 1);
        handler.assertReached("withdrew the whole credit", 1);
        handler.assertReached("withdraw refused with a declared error", 2);
        handler.assertReached("deposit credited less than was asked", 1);
        assertGt(handler.revertsExpected(), 0, "and really met the hostile branches");
        assertGt(attacker.blocked(), 0, "and the attacker really tried to re-enter");

        handler.printCallSummary();
        handler.printReachSummary();
        console2.log("vault true balance", token.trueBalanceOf(address(vault)));
        console2.log("vault total credit", vault.totalCredit());

        invariant_credits_sum_to_total();
        invariant_vault_is_solvent();
        invariant_vault_holds_only_credit_and_donations();
        invariant_global_conservation();
        invariant_reentrancy_never_succeeded();
        invariant_no_unexplained_reverts();
    }
}
