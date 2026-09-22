// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HostileERC20} from "../src/HostileERC20.sol";
import {HandlerBase, InvariantAsserts, IBalanceReader, YES, NO} from "../src/InvariantBase.sol";

// This file is the kit's own core under test, and until an independent audit ran `forge test --mutate` on
// `src/InvariantBase.sol` nobody had ever seen it red: the published mutation scores were both of the
// EXAMPLES, and the base everyone inherits had none. The pass returned 69 survivors, among them
// `assertExercised` reduced to `require(true)` - the guard whose whole job is to stop a vacuous campaign
// being reported as a pass. By the kit's own rule (`doctrine/EVIDENCE.md` section 2) that made it TESTED,
// which is not evidence.
//
// Two things follow, and they are the transferable part:
//
//  1. **Mutate the thing everything else inherits, first.** A hole there is a hole in every suite built on
//     it, and it is the file least likely to be re-read.
//  2. **A bare `vm.expectRevert()` is not a test.** It passes when the assertion under test fails for a
//     reason that has nothing to do with the claim - a typo in a helper, a mis-sized array, a cheatcode
//     that changed - and it passes when a DIFFERENT line reverts first. Every expectation below either
//     names the exact string (for the `require`s in `HandlerBase`, which revert with `Error(string)`) or
//     goes through `_revertMessage`, which decodes what forge's own assertion actually carries.
//     `src/MUTANTS.md` has the score and the survivor triage.

/// @notice somewhere for the pranked call to land.
contract Sink {
    address public lastCaller;

    function poke() external {
        lastCaller = msg.sender;
    }
}

/// @notice a minimal handler, only to exercise the base.
contract DemoHandler is HandlerBase {
    Sink public sink;

    constructor(Sink s) {
        sink = s;
        _addActor(address(0xA11CE));
        _addActor(address(0xB0B));
    }

    function ping(uint256 seed) public counted("ping") asActor(seed) {
        sink.poke();
    }

    /// a real action that OBSERVES a boundary while doing its job
    function pingBig(uint256 seed, uint256 size) public counted("pingBig") asActor(seed) {
        sink.poke();
        if (size >= 1e18) _noteReached("a large ping");
    }

    function mintGhost(uint256 value) public counted("mintGhost") {
        _noteMint(value);
    }

    function donateGhost(address to, address token, uint256 value) public counted("donateGhost") {
        _noteDonation(to, token, value);
    }

    function internalDonateGhost(address to, address token, uint256 value) public counted("internalDonate") {
        _noteInternalDonation(to, token, value);
    }

    function delta(address who, uint256 pre, uint256 post) public counted("delta") {
        _noteDelta(who, pre, post);
    }

    function predictedFailure() public counted("predictedFailure") {
        _expectedRevert();
    }

    function surprise() public counted("surprise") {
        _unexpectedRevert("the vault paid twice");
    }

    function doubleSurprise() public counted("doubleSurprise") {
        _unexpectedRevert("the vault paid twice");
        _unexpectedRevert("and then it paid a third time");
    }

    /// an action that cannot fail - a switch on a mock - so its success is noted by the modifier
    bool public flipped;

    function flip(uint256 onWord) public countedSetter("flip") {
        flipped = _bit(onWord);
    }

    /// an action that does real work, so the SUCCESS census has something in it that is not a call count
    function succeed() public counted("succeed") {
        sink.poke();
        _noteSuccess("succeed");
    }

    /// the same action failing: calls go up, successes do not. This is the pair `assertExercised` is about.
    function attempt() public counted("attempt") {
        // no _noteSuccess: it was tried and it did not work
    }

    // ---- the two pure helpers, exposed so they can be tested directly rather than through an action.
    // `_bit` had THIRTEEN surviving mutants because nothing called it except handlers that were testing
    // something else, and every one of them happened to pass an even or an odd word consistently.
    function bit(uint256 word) public pure returns (bool) {
        return _bit(word);
    }

    function bitOneIn(uint256 word, uint256 n) public pure returns (bool) {
        return _bitOneIn(word, n);
    }

    function actorAt(uint256 seed) public view returns (address) {
        return _actor(seed);
    }
}

/// @notice a handler whose cast is EMPTY, so that the guard in `_actor` can be seen going red. Without one
/// the guard is unreachable from any test and `require(actors.length > 0, ...)` survives being replaced by
/// `require(true)` - which is how it was found.
contract NoActorHandler is HandlerBase {
    function actorAt(uint256 seed) public view returns (address) {
        return _actor(seed);
    }
}

/// @notice the assertions are `internal`, so they need one frame of their own for `expectRevert` to see them.
contract AssertHarness is InvariantAsserts {
    function conserved(IBalanceReader t, address[] memory h, uint256 e) external view {
        assertConserved(t, h, e, "case");
    }

    function paidForLoss(
        IBalanceReader lost,
        IBalanceReader gained,
        address[] memory h,
        uint256[] memory lostPre,
        uint256[] memory gainedPre,
        address exempt
    ) external view {
        assertPaidForLoss(lost, gained, h, lostPre, gainedPre, exempt, "case");
    }

    function gainBackedByLoss(
        IBalanceReader t,
        address[] memory h,
        uint256[] memory pre,
        address winner,
        uint256 slack
    ) external view returns (uint256, uint256) {
        return assertGainBackedByLoss(t, h, pre, winner, slack, "case");
    }

    function holdsOnlyDonations(IBalanceReader t, address who, uint256 donated) external view {
        assertHoldsOnlyDonations(t, who, donated, "case");
    }

    function holdsNoMoreThan(IBalanceReader t, address who, uint256 cap) external view {
        assertHoldsNoMoreThan(t, who, cap, "case");
    }

    function solvent(IBalanceReader t, address who, uint256 owed) external view {
        assertSolvent(t, who, owed, "case");
    }

    function snapshot(IBalanceReader t, address[] memory h) external view returns (uint256[] memory) {
        return snapshotBalances(t, h);
    }
}

contract HandlerBaseTest is Test {
    DemoHandler h;
    Sink sink;

    function setUp() public {
        sink = new Sink();
        h = new DemoHandler(sink);
    }

    function test_the_reach_census_counts_boundaries_not_calls() public {
        h.pingBig(0, 1);
        h.pingBig(1, 5);
        assertEq(h.reachedCount("a large ping"), 0, "two successful small pings reach nothing");
        vm.expectRevert(bytes("boundary never reached: a large ping"));
        h.assertReached("a large ping", 1);
        h.pingBig(0, 1e18);
        assertEq(h.reachedCount("a large ping"), 1);
        h.assertReached("a large ping", 1);
    }

    /// @dev kills `reachedCount(boundary) >= min` -> `== min`, which the test above cannot: there the count
    /// and the minimum are both 1, and the two predicates agree on every input where they are equal. A
    /// boundary reached MORE than the minimum is the ordinary case, and it has to pass.
    function test_assertReached_passes_when_the_boundary_was_reached_more_often_than_asked() public {
        h.pingBig(0, 1e18);
        h.pingBig(1, 2e18);
        h.pingBig(0, 3e18);
        assertEq(h.reachedCount("a large ping"), 3, "three large pings");
        h.assertReached("a large ping", 1); // 3 >= 1: must not revert
        h.assertReached("a large ping", 3); // and exactly at the minimum

        vm.expectRevert(bytes("boundary never reached: a large ping"));
        h.assertReached("a large ping", 4);
    }

    // ---------------------------------------------------------------- assertExercised, the anti-vacuity guard
    /// @dev THE ONE THAT WAS NEVER SEEN RED. `assertExercised` is the line that stops a campaign which
    /// achieved nothing from being reported as a pass, and `require(successesOf(action) >= min, ...)`
    /// survived being replaced by `require(true, ...)` - because nothing in the kit had ever asked it to
    /// fail. The exact message matters: it is what tells whoever reads the output WHICH action was hollow.
    function test_assertExercised_fails_by_name_when_an_action_never_worked() public {
        h.attempt();
        h.attempt();
        h.attempt();
        assertEq(h.callsOf("attempt"), 3, "three calls");
        assertEq(h.successesOf("attempt"), 0, "and not one of them did anything");

        vm.expectRevert(bytes("action barely exercised: attempt"));
        h.assertExercised("attempt", 1);

        // and an action nobody ever called at all is the same failure, not a different one
        vm.expectRevert(bytes("action barely exercised: never mentioned"));
        h.assertExercised("never mentioned", 1);
    }

    /// @dev kills `successesOf(action) >= min` -> `> min` and -> `!= min`. Both of them refuse an action
    /// that succeeded EXACTLY as many times as was asked, which is the commonest way a smoke test is
    /// written, and neither is visible from a test that only makes the guard fail.
    function test_assertExercised_passes_at_exactly_the_minimum_and_above_it() public {
        h.succeed();
        h.succeed();
        assertEq(h.successesOf("succeed"), 2);
        h.assertExercised("succeed", 2); // exactly: must not revert
        h.assertExercised("succeed", 1); // above: must not revert
        vm.expectRevert(bytes("action barely exercised: succeed"));
        h.assertExercised("succeed", 3);
    }

    /// @dev calls and successes are different numbers, and the second is the one the guard reads. A handler
    /// whose census counted calls would report this action as exercised.
    function test_a_census_of_calls_is_not_a_census_of_successes() public {
        h.attempt();
        h.succeed();
        assertEq(h.callsOf("attempt"), 1);
        assertEq(h.successesOf("attempt"), 0);
        assertEq(h.callsOf("succeed"), 1);
        assertEq(h.successesOf("succeed"), 1);
    }

    // ---------------------------------------------------------------- the actor cast
    /// @dev kills `require(actors.length > 0, "HandlerBase: no actors")` -> `require(true, ...)`, which
    /// turns a handler nobody gave actors to into a modulo by zero - a panic, in a place that says nothing
    /// about what went wrong. Nothing in the kit had an actorless handler, so nothing could reach the guard.
    function test_a_handler_with_no_actors_says_so_instead_of_dividing_by_zero() public {
        NoActorHandler empty = new NoActorHandler();
        assertEq(empty.actorCount(), 0, "no cast");
        vm.expectRevert(bytes("HandlerBase: no actors"));
        empty.actorAt(0);
        vm.expectRevert(bytes("HandlerBase: no actors"));
        empty.actorAt(7);
    }

    // ---------------------------------------------------------------- _bit and _bitOneIn
    /// @dev THIRTEEN mutants of `_bit` survived, because it is called only from handlers that are testing
    /// something else and those happened to agree with every wrong version on the words they passed. It is
    /// four characters of code and it decides whether a fuzzed flag is on, which makes it the cheapest
    /// possible place for a silent bias.
    ///
    /// `_bit` reads THE LOWEST BIT AND NOTHING ELSE. That is the claim, and every mutation of `& 1 == 1`
    /// breaks it on one of the words below.
    function test_bit_reads_the_lowest_bit_of_the_word_and_nothing_else() public view {
        assertFalse(h.bit(0), "0 is even");
        assertTrue(h.bit(1), "1 is odd");
        assertFalse(h.bit(2), "2 is even");
        assertTrue(h.bit(3), "3 is odd");
        assertFalse(h.bit(4), "4 is even");
        assertTrue(h.bit(255), "255 is odd");
        assertFalse(h.bit(256), "256 is even");
        assertTrue(h.bit(type(uint256).max), "all ones is odd");
        assertFalse(h.bit(1 << 255), "the top bit alone is even");
        assertTrue(h.bit((1 << 255) | 1), "the top bit plus one is odd");

        // the measured case from the natspec: a `bool` argument the fuzzer filled with dirty high bits.
        assertFalse(h.bit(0x28560000), "the high bits must not decide the flag");

        // and the constants the smoke tests are written with
        assertTrue(h.bit(YES), "YES is on");
        assertFalse(h.bit(NO), "NO is off");
    }

    /// @dev `_bitOneIn` is the biased form, for a switch that STAYS ON until something turns it off. It has
    /// to agree with YES and NO, or every hand-written smoke test in the kit means the opposite of what it
    /// says, and it has to be true about one word in `n` over a run of them.
    function test_bitOneIn_is_biased_and_still_agrees_with_YES_and_NO() public view {
        assertTrue(h.bitOneIn(YES, 4), "YES must still mean on");
        assertFalse(h.bitOneIn(NO, 4), "NO must still mean off");
        assertTrue(h.bitOneIn(YES, 3), "and at every bias");
        assertFalse(h.bitOneIn(NO, 3));

        uint256 on;
        for (uint256 w = 0; w < 400; w++) {
            if (h.bitOneIn(w, 4)) on += 1;
        }
        assertEq(on, 100, "one word in four, over four hundred of them");

        uint256 half;
        for (uint256 w = 0; w < 400; w++) {
            if (h.bitOneIn(w, 1)) half += 1;
        }
        assertEq(half, 200, "n below two means no bias at all: back to _bit");
    }

    function test_actors_are_a_fixed_cast() public view {
        assertEq(h.actorCount(), 2, "two actors");
        assertEq(h.actors(0), address(0xA11CE), "in order");
    }

    function test_asActor_pranks_the_chosen_actor() public {
        h.ping(0);
        assertEq(sink.lastCaller(), address(0xA11CE), "seed 0 is the first actor");
        h.ping(1);
        assertEq(sink.lastCaller(), address(0xB0B), "seed 1 is the second");
        h.ping(2);
        assertEq(sink.lastCaller(), address(0xA11CE), "and the seed wraps");
    }

    function test_census_counts_every_call_by_name() public {
        h.ping(0);
        h.ping(1);
        h.mintGhost(5);
        assertEq(h.callsTotal(), 3, "three calls");
        assertEq(h.callsCompleted(), 3, "all completed");
        assertEq(h.callsOf("ping"), 2, "two pings");
        assertEq(h.callsOf("mintGhost"), 1, "one mint");
        assertEq(h.callsOf("never"), 0, "and nothing invented");
    }

    /// @dev the NAME LIST, which is what the printed census iterates over. An action is listed once, the
    /// first time it is seen, however many times it is called - and the mutation that pushes the name on
    /// every call (so the summary lists `ping` twice and its numbers twice) is invisible to every assertion
    /// above, because they all read the counts and not the list. Ten mutants lived there.
    function test_each_action_is_named_once_however_often_it_is_called() public {
        assertEq(h.actionCount(), 0, "nothing seen yet");
        h.ping(0);
        assertEq(h.actionCount(), 1, "the first call names its action");
        h.ping(1);
        h.ping(2);
        assertEq(h.actionCount(), 1, "and three calls of it are still one name");
        assertEq(h.actionNameAt(0), "ping");

        h.mintGhost(5);
        assertEq(h.actionCount(), 2, "a second action is a second name");
        assertEq(h.actionNameAt(1), "mintGhost", "in the order they were first seen");
        assertEq(h.callsOf("ping"), 3, "and the counts are untouched by any of this");
    }

    /// @dev the same for the reach census.
    function test_each_boundary_is_named_once_however_often_it_is_reached() public {
        assertEq(h.boundaryCount(), 0);
        h.pingBig(0, 1e18);
        h.pingBig(1, 2e18);
        h.pingBig(0, 3e18);
        assertEq(h.boundaryCount(), 1, "three arrivals at one boundary are one name");
        assertEq(h.boundaryNameAt(0), "a large ping");
        assertEq(h.reachedCount("a large ping"), 3, "and the count still counts them all");
    }

    function test_ghosts_track_minting_donations_and_deltas() public {
        h.mintGhost(10);
        h.donateGhost(address(sink), address(0xDEC), 4);
        assertEq(h.ghostMinted(), 14, "a donation is also a mint");
        assertEq(h.ghostDonated(address(sink), address(0xDEC)), 4, "and is remembered per contract and token");

        // an INTERNAL donation moves one ledger and not the other: the tokens were not created, they came
        // from a holder the conservation list already counts (a rebate, a reflection, a fee refund).
        h.internalDonateGhost(address(sink), address(0xDEC), 6);
        assertEq(h.ghostDonated(address(sink), address(0xDEC)), 10, "it is still a donation");
        assertEq(h.ghostMinted(), 14, "but nothing was minted, and counting it twice breaks conservation");

        h.delta(address(0xA11CE), 100, 130);
        h.delta(address(0xA11CE), 130, 120);
        assertEq(h.ghostGained(address(0xA11CE)), 30, "gains accumulate");
        assertEq(h.ghostLost(address(0xA11CE)), 10, "and so do losses");
    }

    /// @dev `+=` on a ghost survived being replaced by `|=` and by `^=`, because every test above recorded
    /// each wallet's gain and loss exactly ONCE and on one input a bitwise-or is indistinguishable from a
    /// sum. A ledger's whole job is to accumulate: make it accumulate at least twice, and pick numbers whose
    /// bits overlap. Also kills `post - pre` -> `post % pre`, which agrees with subtraction on 100 -> 130
    /// (both 30) and not on 3 -> 10 (7 against 1).
    function test_the_ghost_ledgers_accumulate_rather_than_merge() public {
        h.delta(address(0xB0B), 0, 30);
        h.delta(address(0xB0B), 0, 20); // 30 + 20 = 50, but 30 | 20 = 30 and 30 ^ 20 = 10
        assertEq(h.ghostGained(address(0xB0B)), 50, "two gains must add, not merge");

        h.delta(address(0xB0B), 30, 0);
        h.delta(address(0xB0B), 20, 0);
        assertEq(h.ghostLost(address(0xB0B)), 50, "and two losses must add");

        h.delta(address(0xDEAD), 3, 10);
        assertEq(h.ghostGained(address(0xDEAD)), 7, "the gain is the difference, not a remainder");
    }

    /// @dev three, not one. `revertsExpected += 1` survived being replaced by `|= 1`, which agrees with the
    /// sum while the count is 0 or 1 and stops moving at 3. A counter tested once is a counter tested at the
    /// only value where almost every wrong version is right.
    function test_expected_reverts_are_counted_and_surprises_are_not_swallowed() public {
        h.predictedFailure();
        assertEq(h.revertsExpected(), 1, "a predicted failure is evidence, not noise");
        assertEq(h.revertsUnexpected(), 0, "and no surprises yet");

        h.predictedFailure();
        assertEq(h.revertsExpected(), 2, "two");
        h.predictedFailure();
        assertEq(h.revertsExpected(), 3, "and three: `|= 1` stops here, a sum does not");
    }

    /// @dev THE COUNTER THAT COULD NOT BE READ. `_unexpectedRevert` used to increment `revertsUnexpected`
    /// and then `revert` on the next line, so the increment was rolled back with everything else and the
    /// counter documented as "any value above zero is a finding" could never be above zero - not here, not
    /// in an invariant, not in the census. Nine mutants of that line survived, which is exactly what an
    /// unobservable counter looks like from a mutation pass.
    ///
    /// It now RECORDS: the count is real, the reason is in `lastUnexpected`, the call completes, and
    /// `invariant_no_unexplained_reverts` is the thing that goes red. The old shape is asserted against
    /// below - the handler call must NOT revert - because that is the half a reader will not expect.
    function test_an_unexplained_failure_is_recorded_where_an_invariant_can_read_it() public {
        h.surprise();

        assertEq(h.revertsUnexpected(), 1, "the counter has to survive the call that fed it");
        assertEq(h.lastUnexpected(), "the vault paid twice", "with the reason attached");
        assertEq(h.callsTotal(), 1, "the census of the call survives too");
        assertEq(h.callsCompleted(), 1, "and the call completed: recording is not reverting");
        assertEq(h.revertsExpected(), 0, "a surprise is not an expected revert");

    }

    /// @dev two surprises inside ONE call, because after a surprise the next counted call is refused (below), and
    /// `revertsUnexpected = 1` would otherwise agree with `+= 1` everywhere a test can look.
    function test_each_unexplained_failure_counts_once() public {
        h.doubleSurprise();
        assertEq(h.revertsUnexpected(), 2, "each one counts once");
        assertEq(h.lastUnexpected(), "and then it paid a third time", "the reason kept is the LAST one");
    }

    /// @dev THE SAFETY NET UNDER THE RECORDING. `_unexpectedRevert` returns, so a suite that inherits the base and
    /// writes only its own invariants has nothing that reads the counter: measured, such a suite stayed green under
    /// `fail_on_revert = true` with eight surprises on record. So the next counted call after a surprise reverts,
    /// naming the reason - and that revert undoes nothing, because the record was made by the call before it.
    function test_after_a_surprise_the_next_counted_call_is_refused_and_the_record_survives() public {
        h.succeed();
        h.surprise();

        vm.expectRevert(bytes("an earlier handler call met a failure nothing predicted: the vault paid twice"));
        h.succeed();
        vm.expectRevert(bytes("an earlier handler call met a failure nothing predicted: the vault paid twice"));
        h.flip(1);

        assertEq(h.revertsUnexpected(), 1, "the refusal undid the record it was refusing over");
        assertEq(h.callsTotal(), 2, "a refused call is not counted as a call");
        assertEq(h.successesOf("succeed"), 1);
    }

    /// @dev an action that cannot fail notes its own success. Without it, every switch of a handler sits in the
    /// census at "successes 0", which by this file's own rule reads as "not being tested".
    function test_countedSetter_counts_the_call_and_the_success() public {
        h.flip(1);
        h.flip(0);
        assertEq(h.callsOf("flip"), 2);
        assertEq(h.successesOf("flip"), 2, "a setter's success has to be noted for it");
        assertEq(h.callsTotal(), 2);
        assertEq(h.callsCompleted(), 2);
    }

    /// @dev the line `scripts/census.sh` adds up. The format is an interface: tab separated, the label first, then
    /// `U=`, then `A:<name>=<calls>/<successes>` in first-seen order, then `B:<name>=<count>`.
    function test_censusLine_is_the_run_in_one_line() public {
        assertEq(h.censusLine("Demo"), "Demo\tU=0", "an empty run is a label and a zero");

        h.succeed();
        h.attempt();
        h.succeed();
        h.pingBig(0, 1e18);
        h.pingBig(1, 2e18);
        h.surprise();

        assertEq(
            h.censusLine("Demo"),
            "Demo\tU=1\tA:succeed=2/2\tA:attempt=1/0\tA:pingBig=2/0\tA:surprise=1/0\tB:a large ping=2"
        );
    }

    /// @dev with GAUNTLET_CENSUS unset - the everyday battery - `writeCensus` must write nothing and must not
    /// revert. The half that DOES write is proven end to end by `scripts/selftest.sh`, which runs a campaign
    /// through `scripts/census.sh`: setting the variable here would leak into the campaigns running in parallel.
    function test_writeCensus_is_silent_when_nobody_asked_for_a_census() public {
        h.succeed();
        h.writeCensus("Demo");
        assertEq(h.callsTotal(), 1);
    }
}

contract InvariantAssertsTest is Test {
    AssertHarness a;
    HostileERC20 tokenA;
    HostileERC20 tokenB;
    IBalanceReader rA;
    IBalanceReader rB;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address vaultish = address(0x7A17);

    address[] holders;

    function setUp() public {
        a = new AssertHarness();
        tokenA = new HostileERC20("A", "A", 18);
        tokenB = new HostileERC20("B", "B", 18);
        rA = IBalanceReader(address(tokenA));
        rB = IBalanceReader(address(tokenB));
        holders = [alice, bob, vaultish];
        tokenA.mint(alice, 100);
        tokenA.mint(bob, 50);
    }

    function _holders() internal view returns (address[] memory out) {
        out = new address[](holders.length);
        for (uint256 i = 0; i < holders.length; i++) out[i] = holders[i];
    }

    // ---------------------------------------------------------------- expecting the EXACT failure
    /// @notice call `target` with `data`, require that it reverted, and hand back the message it carried.
    ///
    /// Why this exists instead of `vm.expectRevert()`. A bare `expectRevert` accepts ANY failure: a typo in
    /// the harness, an array of the wrong length, a cheatcode whose behaviour changed, a line before the one
    /// under test. Eight of the expectations in this file were bare, in the file that tests the assertions
    /// every suite in the kit is built on - the pattern `doctrine/EVIDENCE.md` section 2 names as passing
    /// for the wrong reason, in the repository that names it.
    ///
    /// The honest alternative is not `vm.expectRevert(bytes("..."))` either: forge's own assertions do not
    /// revert with `Error(string)`, they revert with a custom error carrying a string, and the string ends
    /// with forge's rendering of the two values ("...: 151 != 150"). So this decodes the string and compares
    /// the PREFIX: the whole of the message this repository wrote, exactly, and nothing about how forge
    /// chooses to print a mismatch - which is not ours and may change with a version.
    function _assertRevertsWith(address target, bytes memory data, string memory expected) internal {
        (bool ok, bytes memory ret) = target.call(data);
        assertFalse(ok, string.concat("it did not revert at all; wanted: ", expected));
        assertGe(ret.length, 4, string.concat("it reverted with no data; wanted: ", expected));
        bytes memory body = new bytes(ret.length - 4);
        for (uint256 i = 4; i < ret.length; i++) body[i - 4] = ret[i];
        string memory got = abi.decode(body, (string));
        bytes memory g = bytes(got);
        bytes memory e = bytes(expected);
        bool same = g.length >= e.length;
        for (uint256 i = 0; same && i < e.length; i++) {
            if (g[i] != e[i]) same = false;
        }
        assertTrue(same, string.concat("wrong failure. wanted \"", expected, "...\", got \"", got, "\""));
    }

    function test_assertConserved_passes_on_a_closed_book() public view {
        a.conserved(rA, holders, 150);
    }

    function test_assertConserved_fails_when_a_holder_is_missing_from_the_list() public {
        tokenA.mint(address(0xFEE1), 7); // a holder nobody listed
        _assertRevertsWith(
            address(a),
            abi.encodeCall(AssertHarness.conserved, (rA, _holders(), 157)),
            "case: tokens created or destroyed"
        );
    }

    function test_assertConserved_fails_when_tokens_appear() public {
        tokenA.mint(alice, 1);
        _assertRevertsWith(
            address(a),
            abi.encodeCall(AssertHarness.conserved, (rA, _holders(), 150)),
            "case: tokens created or destroyed"
        );
    }

    function test_assertPaidForLoss_passes_when_the_loser_was_paid() public {
        uint256[] memory preA = a.snapshot(rA, holders);
        uint256[] memory preB = a.snapshot(rB, holders);

        vm.prank(alice);
        tokenA.transfer(vaultish, 10);
        tokenB.mint(alice, 10);

        a.paidForLoss(rA, rB, holders, preA, preB, address(0));
    }

    function test_assertPaidForLoss_fails_when_the_loser_was_not_paid() public {
        uint256[] memory preA = a.snapshot(rA, holders);
        uint256[] memory preB = a.snapshot(rB, holders);

        vm.prank(alice);
        tokenA.transfer(vaultish, 10);

        _assertRevertsWith(
            address(a),
            abi.encodeCall(AssertHarness.paidForLoss, (rA, rB, _holders(), preA, preB, address(0))),
            "case: a wallet lost tokens without being paid"
        );
    }

    function test_assertPaidForLoss_lets_the_exempt_wallet_spend() public {
        uint256[] memory preA = a.snapshot(rA, holders);
        uint256[] memory preB = a.snapshot(rB, holders);

        vm.prank(alice);
        tokenA.transfer(vaultish, 10);

        a.paidForLoss(rA, rB, holders, preA, preB, alice);
    }

    /// @dev AN ADDRESS IS AN IDENTITY, NOT AN ORDERING - the same lesson the hook example learned from its
    /// own mutation pass, and the core had it too: `if (w == exempt) continue;` survived being replaced by
    /// `w <= exempt`, which excuses every holder sorted BELOW the exempt address from ever being paid.
    ///
    /// Invisible to the three tests above, because they use `exempt = address(0)` (nothing is below it) or
    /// exempt a wallet that is the only loser. Here the loser is `vaultish` (0x7A17), which sorts below the
    /// exempt `alice` (0xA11CE), and it really did lose without being paid: the assertion must still fail.
    function test_assertPaidForLoss_does_not_excuse_a_wallet_merely_because_it_sorts_below_the_exempt_one()
        public
    {
        assertLt(uint160(vaultish), uint160(alice), "the probe only works if the two really are on these sides");
        tokenA.mint(vaultish, 40);

        uint256[] memory preA = a.snapshot(rA, holders);
        uint256[] memory preB = a.snapshot(rB, holders);

        vm.prank(vaultish); // the wallet below the exempt one loses, and nobody pays it
        tokenA.transfer(bob, 10);

        _assertRevertsWith(
            address(a),
            abi.encodeCall(AssertHarness.paidForLoss, (rA, rB, _holders(), preA, preB, alice)),
            "case: a wallet lost tokens without being paid"
        );
    }

    function test_assertGainBackedByLoss_passes_when_the_gain_is_backed() public {
        uint256[] memory pre = a.snapshot(rA, holders);
        vm.prank(alice);
        tokenA.transfer(vaultish, 30);

        (uint256 gain, uint256 loss) = a.gainBackedByLoss(rA, holders, pre, vaultish, 0);
        assertEq(gain, 30, "the winner gained thirty");
        assertEq(loss, 30, "and thirty were lost");
    }

    /// @dev the winner's OWN side of the ledger, which the test above cannot reach because its winner
    /// started at zero. Two mutants lived there:
    ///   * `post - pre[i]` -> `post >> pre[i]`, which agrees with subtraction whenever `pre[i] == 0`
    ///     (`30 >> 0 == 30`) and on nothing else. Give the winner a balance to start from.
    ///   * `post > pre[i]` -> `post != pre[i]`, which computes `post - pre[i]` when the winner ended POORER
    ///     and answers with an arithmetic panic instead of a gain of zero. A "winner" that lost is an
    ///     ordinary state for an assertion applied around every action, and nothing here had ever done it.
    function test_assertGainBackedByLoss_measures_the_winner_from_where_it_started() public {
        tokenA.mint(vaultish, 25); // the winner does NOT start at zero
        uint256[] memory pre = a.snapshot(rA, holders);
        vm.prank(alice);
        tokenA.transfer(vaultish, 30);

        (uint256 gain, uint256 loss) = a.gainBackedByLoss(rA, holders, pre, vaultish, 0);
        assertEq(gain, 30, "the gain is the delta, not the balance and not a shift of it");
        assertEq(loss, 30);
    }

    function test_assertGainBackedByLoss_reports_no_gain_when_the_winner_ended_poorer() public {
        tokenA.mint(vaultish, 25);
        uint256[] memory pre = a.snapshot(rA, holders);

        vm.prank(vaultish); // the nominated winner is the one that lost
        tokenA.transfer(bob, 10);

        (uint256 gain, uint256 loss) = a.gainBackedByLoss(rA, holders, pre, vaultish, 0);
        assertEq(gain, 0, "a winner that ended poorer gained nothing; it did not gain a negative number");
        assertEq(loss, 0, "and nobody else lost anything");
    }

    function test_assertGainBackedByLoss_fails_when_the_token_invents_tokens() public {
        tokenA.fundReserve(1_000);
        tokenA.setBonusTo(vaultish, 25); // the recipient is paid more than the sender lost

        // the reserve is not on the holders list, so its loss cannot back the gain: this is exactly the
        // mistake the assertion is meant to catch in a real suite.
        uint256[] memory pre = a.snapshot(rA, holders);
        vm.prank(alice);
        tokenA.transfer(vaultish, 10);

        _assertRevertsWith(
            address(a),
            abi.encodeCall(AssertHarness.gainBackedByLoss, (rA, _holders(), pre, vaultish, 0)),
            "case: the winner received more than the others lost"
        );
    }

    function test_assertGainBackedByLoss_accepts_the_declared_slack() public {
        tokenA.fundReserve(1_000);
        tokenA.setBonusTo(vaultish, 25);

        uint256[] memory pre = a.snapshot(rA, holders);
        vm.prank(alice);
        tokenA.transfer(vaultish, 10);

        (uint256 gain,) = a.gainBackedByLoss(rA, holders, pre, vaultish, 25);
        assertEq(gain, 35, "ten moved and twenty five came from somewhere the list does not see");
    }

    /// @dev the boundary of `assertLe(gain, loss + slack)`, from both sides and by one unit. Five of the
    /// mutants that survived the audit's pass were on this line, and every one of them is a comparison
    /// moved by one: a test that only checks "obviously fine" and "obviously not" cannot see any of them.
    function test_assertGainBackedByLoss_is_exact_at_the_boundary() public {
        tokenA.fundReserve(1_000);
        tokenA.setBonusTo(vaultish, 25);

        uint256[] memory pre = a.snapshot(rA, holders);
        vm.prank(alice);
        tokenA.transfer(vaultish, 10); // gain 35, loss 10

        // slack exactly covers the difference: allowed
        (uint256 gain, uint256 loss) = a.gainBackedByLoss(rA, _holders(), pre, vaultish, 25);
        assertEq(gain, 35);
        assertEq(loss, 10);
        // one MORE than needed: still allowed
        a.gainBackedByLoss(rA, _holders(), pre, vaultish, 26);
        // one LESS: refused
        _assertRevertsWith(
            address(a),
            abi.encodeCall(AssertHarness.gainBackedByLoss, (rA, _holders(), pre, vaultish, 24)),
            "case: the winner received more than the others lost"
        );
    }

    function test_assertHoldsOnlyDonations() public {
        tokenA.mint(vaultish, 9);
        a.holdsOnlyDonations(rA, vaultish, 9);

        tokenA.mint(vaultish, 1);
        _assertRevertsWith(
            address(a),
            abi.encodeCall(AssertHarness.holdsOnlyDonations, (rA, vaultish, 9)),
            "case: holds more than it was given"
        );
        // and it is an EQUALITY, not a floor: holding less than it was given fails too, because a contract
        // that lost a donation has lost something
        _assertRevertsWith(
            address(a),
            abi.encodeCall(AssertHarness.holdsOnlyDonations, (rA, vaultish, 11)),
            "case: holds more than it was given"
        );
    }

    function test_assertHoldsNoMoreThan() public {
        tokenA.mint(vaultish, 9);
        a.holdsNoMoreThan(rA, vaultish, 10);
        a.holdsNoMoreThan(rA, vaultish, 9); // the boundary itself is allowed

        _assertRevertsWith(
            address(a),
            abi.encodeCall(AssertHarness.holdsNoMoreThan, (rA, vaultish, 8)),
            "case: holds more than it can account for"
        );
    }

    function test_assertSolvent() public {
        tokenA.mint(vaultish, 9);
        a.solvent(rA, vaultish, 9); // owing exactly what it holds is solvent

        _assertRevertsWith(
            address(a),
            abi.encodeCall(AssertHarness.solvent, (rA, vaultish, 10)),
            "case: cannot honour what it owes"
        );
    }

    /// @notice the reader matters: a token that lies makes solvency answer two different things.
    function test_the_referee_must_choose_which_reading_it_judges() public {
        tokenA.mint(vaultish, 9);
        tokenA.setBalanceMax(vaultish, true);

        // judged on what the world sees, this vault is infinitely solvent
        a.solvent(rA, vaultish, type(uint256).max);

        // judged on the truth, it holds nine
        TruthOf truth = new TruthOf(tokenA);
        _assertRevertsWith(
            address(a),
            abi.encodeCall(AssertHarness.solvent, (IBalanceReader(address(truth)), vaultish, 10)),
            "case: cannot honour what it owes"
        );
        a.solvent(IBalanceReader(address(truth)), vaultish, 9);
    }
}

contract TruthOf is IBalanceReader {
    HostileERC20 private immutable token;

    constructor(HostileERC20 t) {
        token = t;
    }

    function balanceOf(address who) external view returns (uint256) {
        return token.trueBalanceOf(who);
    }
}
