// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev readable arguments for handler actions that take a flag as a full word (see `HandlerBase._bit`).
uint256 constant YES = 1;
uint256 constant NO = 0;

import {Test, console2} from "forge-std/Test.sol";

/// @notice the only thing the assertions need from a token.
interface IBalanceReader {
    function balanceOf(address who) external view returns (uint256);
}

/// @title HandlerBase
/// @notice The skeleton of a stateful-fuzz handler: a fixed cast of actors, a call census, and the ghost
/// variables that let an invariant close its books.
///
/// The rule this base exists to enforce: run the suite with `fail_on_revert = true`. Under that setting a
/// handler function that reverts fails the run, so every call into the contract under test is wrapped in
/// try/catch and the catch branch has to CLASSIFY the failure. That turns "it reverted" from noise into
/// evidence: a revert you predicted is a data point, a revert you did not predict is a finding. With
/// `fail_on_revert = false` the fuzzer happily spends a whole run bouncing off an input filter and reports
/// a green suite that tested nothing.
///
/// The corollary, which is the half people skip: `forge`'s own `reverts:` count is then ALWAYS 0, because
/// every revert was caught. It is a tautology, not a signal, and no gate should read it. What to read
/// instead is the census: `writeCensus()` called from `afterInvariant()`, added up over the whole campaign
/// by `scripts/census.sh`. (`printCallSummary()` next to it shows ONE run - forge prints one run's logs.)
/// Both worked examples do it.
///
/// Restrict the handler with `targetSelector` to the actions you wrote. Without it the fuzzer calls EVERY non-view
/// function the handler has, this base's included: `writeCensus(string)` is one, and on a toy handler with one action
/// it took about half of a 64 x 64 campaign's calls (the census counted 2 016 calls to the action; forge made 4 096).
/// `writeCensus` ignores a call
/// that arrives as its own transaction, which is how the fuzzer's arrive, so the census stays the suite's own - but the
/// calls are spent, and the fuzzer's labels used to reach the census (see `writeCensus`). They are COUNTED
/// (`fuzzedBookkeepingCalls`), and a run that had any says so in its census line, which `scripts/census.sh` turns into
/// a line under its table: "the fuzzer reached HandlerBase's own functions". `doctrine/INVARIANTS.md`,
/// "your handler"; both worked examples list their selectors.
abstract contract HandlerBase is Test {
    /// @notice the fixed cast. A fuzzer that can reach any address reaches none of them twice.
    address[] public actors;
    /// @notice the actor the current call is pranking as.
    address internal currentActor;

    uint256 public callsTotal;
    uint256 public callsCompleted;
    /// @notice reverts the handler predicted and classified.
    uint256 public revertsExpected;
    /// @notice reverts the handler could not explain. Any value above zero is a finding.
    uint256 public revertsUnexpected;
    /// @notice the reason given for the LAST unexplained failure, so the invariant that reads
    /// `revertsUnexpected` can say what happened instead of only that something did.
    string public lastUnexpected;

    /// @notice calls into this base's own bookkeeping that arrived as their own transaction - the FUZZER's, on a handler
    /// with no `targetSelector` (`writeCensus` is the one non-view function this base has). Above zero, the campaign
    /// spent calls here instead of on your actions, and `censusLine` carries the count as a boundary.
    uint256 public fuzzedBookkeepingCalls;

    string[] internal actionNames;
    mapping(bytes32 => uint256) internal actionCalls;
    mapping(bytes32 => uint256) internal actionSuccesses;
    string[] internal reachNames;
    mapping(bytes32 => uint256) internal reachCount;

    // ------------------------------------------------------------------ ghosts
    /// @notice everything the handler ever created out of nothing. The right hand side of a conservation
    /// invariant: no run can end with more tokens in the world than this.
    uint256 public ghostMinted;
    /// @notice per wallet, what the handler has seen the wallet gain and lose across the whole run.
    mapping(address => uint256) public ghostGained;
    mapping(address => uint256) public ghostLost;
    /// @notice tokens pushed straight at a contract, which no accounting of that contract owes anyone.
    mapping(address => mapping(address => uint256)) public ghostDonated;

    // ------------------------------------------------------------------ actors
    function actorCount() public view returns (uint256) {
        return actors.length;
    }

    function _addActor(address a) internal {
        actors.push(a);
    }

    function _actor(uint256 seed) internal view returns (address) {
        require(actors.length > 0, "HandlerBase: no actors");
        return actors[seed % actors.length];
    }

    modifier asActor(uint256 seed) {
        currentActor = _actor(seed);
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ census
    /// @notice Handler entry points take FULL WORDS only (`uint256`, `bytes32`), and derive anything narrower
    /// inside. A coverage-guided fuzzer mutates calldata at the byte level, so a `bool`, an `address`, a `uint8`
    /// or an enum parameter will sooner or later arrive with dirty high bits. Solidity's ABI decoder (coder v2, the default since 0.8.0) reverts on
    /// that before a single line of the handler runs - no try/catch can classify it - and under
    /// `fail_on_revert = true` the campaign reports a failure that has nothing to do with the contract.
    /// Measured: `donateToHook(uint256,bool)` with the bool encoded as 0x28560000, 588 gas, on the first run with
    /// `corpus_dir` set. Use `_bit(word)` for a flag, `actors[word % actors.length]` for a wallet.
    function _bit(uint256 word) internal pure returns (bool) {
        return word & 1 == 1;
    }

    /// @notice a flag that is true roughly one time in `n`, for the switches that are STICKY.
    ///
    /// `_bit` is true half the time, which is the right shape for a flag that only affects the call it is
    /// passed to. It is the wrong shape for a hostile switch that STAYS ON until the same action happens to
    /// be called again with the other value: the first such call parks the system in its broken state and
    /// the rest of the run is spent there. Every invariant still passes, because nothing can happen at all.
    ///
    /// Measured on this kit's own vault example, 64 runs x 64 calls, fresh corpus: with `_bit` on
    /// `setPaused`, `setVaultBlocked`, `setVaultUnreadable`, `setTrueNoMove` and `setGasHog`, **40 of 65
    /// runs ended with ZERO successful withdrawals**. Biasing those five toward the honest value and adding
    /// one action that clears them took it to the number in `foundry-kit/README.md`.
    ///
    /// So: `_bit` for a per-call flag, `_bitOneIn` for a switch that persists, and an action that turns
    /// them all off. Then read the census and check that it worked - the bias is a guess until it is
    /// measured, and the right `n` depends on how many actions your handler has.
    ///
    /// It agrees with `YES` and `NO` on purpose (`YES % n == 1` for every `n > 1`, `NO % n == 0`), so a
    /// smoke test that spells its arguments out reads the same whichever of the two helpers the action uses.
    /// `n < 2` means "no bias" and falls back to `_bit`.
    function _bitOneIn(uint256 word, uint256 n) internal pure returns (bool) {
        return n < 2 ? _bit(word) : word % n == 1;
    }

    /// @dev The first line is the safety net under `_unexpectedRevert`, which records a surprise and RETURNS. A suite
    /// that inherits this base and writes only its own invariants - the common case - has nothing that reads the
    /// counter, and used to stay green with eight surprises on record. So the NEXT counted call after a surprise
    /// reverts: red under `fail_on_revert = true`, and under `false` the counter stays where it is for an invariant
    /// to read, because this revert undoes nothing that was recorded by the call before it. It cannot see a surprise
    /// in the last call of a run; `invariant_no_unexplained_reverts` (both examples have it) can. Copy that too.
    /// Under `false` there is a cost to know about: after the first surprise EVERY later call of that run reverts
    /// here and the fuzzer swallows it - measured, 1 241 of 4 096 calls - so the run has stopped testing, quietly,
    /// and a suite without that invariant still ends green. And when one call meets several surprises, only the
    /// last reason is kept in `lastUnexpected`.
    modifier counted(string memory action) {
        _enter(action);
        _;
        callsCompleted += 1;
    }

    /// @notice `counted`, for an action that CANNOT FAIL - a switch on a mock, a donation, the clock moving: the
    /// success is noted for you. Without it those actions sit in the census at "successes 0" for ever, which by this
    /// file's own rule reads as "not being tested", and the rows that matter drown among them.
    modifier countedSetter(string memory action) {
        _enter(action);
        _;
        callsCompleted += 1;
        _noteSuccess(action);
    }

    function _enter(string memory action) private {
        require(
            revertsUnexpected == 0,
            string.concat("an earlier handler call met a failure nothing predicted: ", lastUnexpected)
        );
        callsTotal += 1;
        _countAction(action);
    }

    function _countAction(string memory action) private {
        bytes32 k = keccak256(bytes(action));
        if (actionCalls[k] == 0) actionNames.push(action);
        actionCalls[k] += 1;
    }

    function callsOf(string memory action) public view returns (uint256) {
        return actionCalls[keccak256(bytes(action))];
    }

    /// @notice the names the census has seen, in the order it first saw them. Exposed because otherwise the
    /// only thing that reads `actionNames` is `printCallSummary`, whose output nothing can assert: ten
    /// mutations of `if (actionCalls[k] == 0) actionNames.push(action)` - including the one that pushes the
    /// name on EVERY call, so the summary lists an action once per call - survived a mutation pass for want
    /// of a getter. A census nobody can assert on is a census nobody can trust.
    function actionCount() public view returns (uint256) {
        return actionNames.length;
    }

    function actionNameAt(uint256 i) public view returns (string memory) {
        return actionNames[i];
    }

    /// @notice record that `action` did real work: the call into the contract under test SUCCEEDED.
    /// Calls and successes are different numbers, and the second is the one that matters. A campaign whose
    /// actions mostly revert leaves the contract nearly empty, and every invariant then passes because
    /// nothing was there to break it. That is a vacuous pass, and it looks exactly like a real one.
    function _noteSuccess(string memory action) internal {
        actionSuccesses[keccak256(bytes(action))] += 1;
    }

    function successesOf(string memory action) public view returns (uint256) {
        return actionSuccesses[keccak256(bytes(action))];
    }

    /// @notice fail unless `action` succeeded at least `min` times. Use it in the smoke test; for a campaign, read
    /// `scripts/census.sh` (fed by `writeCensus`): an action that succeeded in few of the RUNS is an action you are
    /// not testing. `printCallSummary` shows one run, not the campaign.
    function assertExercised(string memory action, uint256 min) public view {
        require(successesOf(action) >= min, string.concat("action barely exercised: ", action));
    }

    // ---------------------------------------------------------------- the reach census
    /// @notice A success census catches an action that never works. It does not catch four thousand successes that
    /// were all tiny, all in one pool, all on one side of every branch. Call `_noteReached("fee at cap")` from INSIDE
    /// a real action, at the point where the handler OBSERVES the state - never from a function that exists to set
    /// it - and assert the boundaries that matter with `assertReached`. `doctrine/EVIDENCE.md` section 7.
    function _noteReached(string memory boundary) internal {
        bytes32 k = keccak256(bytes(boundary));
        if (reachCount[k] == 0) reachNames.push(boundary);
        reachCount[k] += 1;
    }

    function reachedCount(string memory boundary) public view returns (uint256) {
        return reachCount[keccak256(bytes(boundary))];
    }

    /// @notice the boundaries the reach census has seen, in first-seen order. Same reason as `actionCount`.
    function boundaryCount() public view returns (uint256) {
        return reachNames.length;
    }

    function boundaryNameAt(uint256 i) public view returns (string memory) {
        return reachNames[i];
    }

    function assertReached(string memory boundary, uint256 min) public view {
        require(reachedCount(boundary) >= min, string.concat("boundary never reached: ", boundary));
    }

    /// @notice print the census. Call it from `afterInvariant()` - see the two worked examples - so that the
    /// FUZZ CAMPAIGN's reach is on the record and not only the hand-driven smoke test's.
    ///
    /// `forge` prints the `reverts:` count of an invariant run, and under `fail_on_revert = true` with every
    /// call wrapped in try/catch that number is ALWAYS 0: it is a tautology, not a signal. This is the
    /// signal - FOR ONE RUN. `afterInvariant()` executes after every run, but forge prints the logs of only one
    /// of them (at `-vv`), so the block on the screen describes some 64 calls out of 4 096: measured, it said
    /// "withdrawsOk 0" over a campaign with 110 successful withdrawals. Use it to see the SHAPE of a run. For
    /// the campaign, call `writeCensus` next to it and read `scripts/census.sh`.
    function printCallSummary() public view {
        console2.log("handler calls", callsTotal);
        console2.log("  completed", callsCompleted);
        console2.log("  reverts expected", revertsExpected);
        console2.log("  reverts unexpected", revertsUnexpected);
        if (revertsUnexpected > 0) console2.log("  last unexpected:", lastUnexpected);
        for (uint256 i = 0; i < actionNames.length; i++) {
            bytes32 k = keccak256(bytes(actionNames[i]));
            console2.log(actionNames[i], actionCalls[k], "calls / successes", actionSuccesses[k]);
        }
    }

    /// @notice print the reach census next to the success census. An action that succeeded four thousand
    /// times on one side of every branch is not a tested action. `doctrine/EVIDENCE.md` section 7.
    function printReachSummary() public view {
        console2.log("boundaries reached", reachNames.length);
        for (uint256 i = 0; i < reachNames.length; i++) {
            console2.log(" ", reachNames[i], reachCount[keccak256(bytes(reachNames[i]))]);
        }
    }

    /// @notice THE CAMPAIGN'S CENSUS: append this run's numbers, as one line, to the file named by the environment
    /// variable `GAUNTLET_CENSUS`. Call it from `afterInvariant()`. `scripts/census.sh` sets the variable, runs the
    /// campaign and adds the lines up: in how many runs did each action succeed at least once, in how many was each
    /// boundary reached, in how many did the handler meet a surprise. With the variable unset this does nothing, so
    /// the everyday battery writes no files.
    /// @dev the path must be writable under `fs_permissions` in `foundry.toml` (the kit allows `./census`). Without
    /// the permission `vm.writeLine` reverts and the campaign goes red saying so, which is the right way round.
    ///
    /// A call that arrives as its OWN TRANSACTION (`msg.sender == tx.origin`) writes nothing and returns. That is how
    /// the invariant fuzzer's calls arrive (measured, forge 1.8.1: 2 016 fuzz calls into a toy handler's action, not
    /// one with `msg.sender != tx.origin`, none from the test contract). A handler with no `targetSelector` exposes this
    /// function to the fuzzer, and it used to be called with labels of the fuzzer's making: on that toy, 64 runs left
    /// 2 125 census lines under 1 473 labels, 1 427 of them not printable, and `scripts/census.sh` answered rc 1 over
    /// them. `afterInvariant()` calls it from the test contract - `msg.sender` is a contract - and the line is written
    /// (65 lines for 64 runs after the fix: forge calls `afterInvariant` once more than `runs`).
    function writeCensus(string memory label) public {
        // the fuzzer's own call, not the suite's: see above. Counted, so that the census can say the handler is unrestricted
        if (msg.sender == tx.origin) {
            fuzzedBookkeepingCalls += 1;
            return;
        }
        string memory path = vm.envOr("GAUNTLET_CENSUS", string(""));
        if (bytes(path).length == 0) return;
        vm.writeLine(path, censusLine(label));
    }

    /// @notice one run, one line, tab separated: `label  U=<unexpected>  A:<action>=<calls>/<successes> ...  B:<boundary>=<count> ...`
    /// When the fuzzer reached `writeCensus` in this run (`fuzzedBookkeepingCalls > 0`) the line ends with one boundary
    /// more, `B:handler unrestricted: bookkeeping selectors were fuzzed=<calls>`, and `scripts/census.sh` prints a line
    /// under its table that says to restrict the handler with `targetSelector`.
    function censusLine(string memory label) public view returns (string memory line) {
        line = string.concat(label, "\tU=", vm.toString(revertsUnexpected));
        for (uint256 i = 0; i < actionNames.length; i++) {
            bytes32 k = keccak256(bytes(actionNames[i]));
            line = string.concat(
                line, "\tA:", actionNames[i], "=", vm.toString(actionCalls[k]), "/", vm.toString(actionSuccesses[k])
            );
        }
        for (uint256 i = 0; i < reachNames.length; i++) {
            line = string.concat(
                line, "\tB:", reachNames[i], "=", vm.toString(reachCount[keccak256(bytes(reachNames[i]))])
            );
        }
        if (fuzzedBookkeepingCalls > 0) {
            line = string.concat(
                line, "\tB:handler unrestricted: bookkeeping selectors were fuzzed=", vm.toString(fuzzedBookkeepingCalls)
            );
        }
    }

    // ------------------------------------------------------------------ revert bookkeeping
    /// @notice a failure the spec predicts. Counting them proves the branch was reached.
    function _expectedRevert() internal {
        revertsExpected += 1;
    }

    /// @notice a failure nothing predicted. RECORD it - do not revert - and let
    /// `invariant_no_unexplained_reverts` be the thing that goes red, with `lastUnexpected` as the reason.
    ///
    /// It used to `revert` here, and that was wrong in a way worth keeping written down, because it is the
    /// shape of half the false greens in this kit. The revert rolled back the increment on the line above
    /// it, so `revertsUnexpected` could never be read above zero by anything - not by the invariant, not by
    /// the census, not by a test. The counter whose documentation says "any value above zero is a finding"
    /// was unobservable, and the invariant that reads it could not fail.
    ///
    /// What each setting did then, and does now:
    ///
    ///  * `fail_on_revert = true` (this kit's `foundry.toml`, and what `HandlerBase` is built around): the
    ///    revert failed the run, so the surprise was NOT lost - but the failure was reported as "the handler
    ///    reverted", the counter still read 0, and the invariant named after the problem was never the one
    ///    that went red. Now the call returns, the counter is real, and the run fails at the invariant with
    ///    the reason attached.
    ///  * `fail_on_revert = false` (FORGE'S DEFAULT, and therefore what any project that inherits this base
    ///    without copying the toml gets): the revert was swallowed by the fuzzer, the increment went with
    ///    it, the invariant read 0 and the campaign printed "reverts unexpected 0". The surprise vanished
    ///    completely. That is the case this fix exists for, and it is the common one.
    ///
    /// The cost of recording instead of reverting: the handler call CONTINUES after a surprise, so anything
    /// written after this line still runs. Return, or classify and return, right after calling it.
    function _unexpectedRevert(string memory why) internal {
        revertsUnexpected += 1;
        lastUnexpected = why;
        console2.log("UNEXPECTED REVERT:", why);
    }

    // ------------------------------------------------------------------ ghost bookkeeping
    function _noteMint(uint256 value) internal {
        ghostMinted += value;
    }

    /// @notice value the handler CREATED and pushed at `to`. Both ledgers move: it is a donation, and it is
    /// also new tokens in the world.
    function _noteDonation(address to, address token, uint256 value) internal {
        _noteInternalDonation(to, token, value);
        ghostMinted += value;
    }

    /// @notice value that arrived at `to` from somewhere ALREADY INSIDE the system - a rebate, a reflection,
    /// a fee refund paid out of a reserve the conservation list already counts - rather than being created
    /// by the handler.
    ///
    /// It is a donation for the purpose of "this contract holds no more than it owes plus what was pushed at
    /// it", and it must NOT touch `ghostMinted`, because nothing was minted: the tokens moved from one
    /// holder on the list to another, and adding them to the right-hand side of a conservation assertion
    /// would make an honest run go red.
    ///
    /// This function exists because a campaign found the hole. A token that pays its SENDER a rebate pays
    /// the vault on the way OUT, so a `withdraw(0)` left the vault richer by an amount nobody chose and
    /// nobody can claim, and the invariant that says a contract is not a wallet failed on correct
    /// behaviour. The lesson generalises: a ghost ledger has to record value that arrives by a route the
    /// handler did not take.
    function _noteInternalDonation(address to, address token, uint256 value) internal {
        ghostDonated[to][token] += value;
    }

    function _noteGain(address who, uint256 value) internal {
        ghostGained[who] += value;
    }

    function _noteLoss(address who, uint256 value) internal {
        ghostLost[who] += value;
    }

    /// @notice the balance delta of `who` across one action, recorded on both ghost ledgers.
    function _noteDelta(address who, uint256 pre, uint256 post) internal {
        if (post > pre) _noteGain(who, post - pre);
        else if (pre > post) _noteLoss(who, pre - post);
    }
}

/// @title InvariantAsserts
/// @notice The four assertions that catch most of what a token-facing contract gets wrong, written once so a
/// suite does not re-derive them per project.
///
/// A note on which balance to read. If the token can lie, there are two different readings of every balance:
/// the truth, and what the contract under test sees. An invariant has to say which one it uses, per
/// invariant, and the choice is not always "the truth". Solvency is about the truth. "The contract treated
/// this wallet fairly" is about what the contract could see: judging that against the truth accuses the
/// contract of not knowing something it was never told.
abstract contract InvariantAsserts is Test {
    /// @notice balances of `holders`, in order, for use as the `pre` side of the per-wallet assertions.
    function snapshotBalances(IBalanceReader token, address[] memory holders)
        internal
        view
        returns (uint256[] memory out)
    {
        out = new uint256[](holders.length);
        for (uint256 i = 0; i < holders.length; i++) out[i] = token.balanceOf(holders[i]);
    }

    function sumBalances(IBalanceReader token, address[] memory holders) internal view returns (uint256 total) {
        for (uint256 i = 0; i < holders.length; i++) total += token.balanceOf(holders[i]);
    }

    /// @notice GLOBAL CONSERVATION: nothing is created or destroyed. `holders` must be every address the
    /// token can reach, including the fee sink, the reserve, and the contracts under test. If the list is
    /// incomplete the assertion is not weaker, it is wrong: it will fail on honest behaviour.
    function assertConserved(
        IBalanceReader token,
        address[] memory holders,
        uint256 expectedTotal,
        string memory label
    ) internal view {
        assertEq(sumBalances(token, holders), expectedTotal, string.concat(label, ": tokens created or destroyed"));
    }

    /// @notice PER WALLET, AROUND ONE ACTION: whoever lost `lost` must have gained something in `gained`.
    /// `exempt` is the one address allowed to end the action poorer without being paid (the actor who chose
    /// to spend). Pass the zero address if nobody is exempt.
    ///
    /// This is the assertion that catches the whole family of "somebody was charged for a trade that was not
    /// theirs", and it only works around a SINGLE action: taken across a whole run it is trivially true.
    function assertPaidForLoss(
        IBalanceReader lost,
        IBalanceReader gained,
        address[] memory holders,
        uint256[] memory lostPre,
        uint256[] memory gainedPre,
        address exempt,
        string memory label
    ) internal view {
        for (uint256 i = 0; i < holders.length; i++) {
            address w = holders[i];
            if (w == exempt) continue;
            if (lost.balanceOf(w) >= lostPre[i]) continue;
            assertGt(
                gained.balanceOf(w),
                gainedPre[i],
                string.concat(label, ": a wallet lost tokens without being paid")
            );
        }
    }

    /// @notice NOBODY GETS MORE THAN THE OTHERS LOST: the winner's gain is backed, coin for coin, by the sum
    /// of everyone else's losses in the same token, plus `slack` for what was donated or was already loose in
    /// the system. Returns both sides so a test can log the margin.
    function assertGainBackedByLoss(
        IBalanceReader token,
        address[] memory holders,
        uint256[] memory pre,
        address winner,
        uint256 slack,
        string memory label
    ) internal view returns (uint256 gain, uint256 loss) {
        for (uint256 i = 0; i < holders.length; i++) {
            address w = holders[i];
            uint256 post = token.balanceOf(w);
            if (w == winner) {
                if (post > pre[i]) gain = post - pre[i];
                continue;
            }
            if (post < pre[i]) loss += pre[i] - post;
        }
        assertLe(gain, loss + slack, string.concat(label, ": the winner received more than the others lost"));
    }

    /// @notice THE CONTRACT IS NOT A WALLET: `who` holds nothing beyond what was pushed at it. Every token a
    /// contract holds between transactions is either owed to somebody, or is a donation nobody can claim; a
    /// contract that is meant to end every call empty and does not is leaking, and the leak has an owner.
    function assertHoldsOnlyDonations(IBalanceReader token, address who, uint256 donated, string memory label)
        internal
        view
    {
        assertEq(token.balanceOf(who), donated, string.concat(label, ": holds more than it was given"));
    }

    /// @notice the weaker form, for a contract that is allowed to retain a residue (rounding, retained fees):
    /// it may hold no more than what it owes plus what it was given.
    function assertHoldsNoMoreThan(IBalanceReader token, address who, uint256 cap, string memory label)
        internal
        view
    {
        assertLe(token.balanceOf(who), cap, string.concat(label, ": holds more than it can account for"));
    }

    /// @notice SOLVENCY: the contract can honour every claim against it, in the token's own units.
    function assertSolvent(IBalanceReader token, address who, uint256 owed, string memory label) internal view {
        assertGe(token.balanceOf(who), owed, string.concat(label, ": cannot honour what it owes"));
    }
}
