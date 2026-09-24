# The survivors of `forge test --mutate` on the CORE: `InvariantBase.sol` and `HostileERC20.sol`

The two examples had a mutation pass and a survivor list from the first day. The two files every suite in
this kit **inherits** had neither, and nobody noticed until an independent audit ran the command:

```sh
forge test --mutate src/InvariantBase.sol
forge test --mutate src/HostileERC20.sol
```

It came back with `assertExercised` — the guard whose entire job is to stop a campaign that achieved nothing
from being reported as a pass — surviving replacement by `require(true, ...)`. By this kit's own rule
(`doctrine/EVIDENCE.md` section 2) that made it TESTED, which is the label for work in progress, not
evidence. Along with it: `_bit` with thirteen survivors, `_unexpectedRevert` with nine (its counter could not
be observed at all — see `HandlerBase._unexpectedRevert`), the actor-count guard, and five on the boundary of
`assertGainBackedByLoss`.

**Mutate the thing everything else inherits, first.** A hole there is a hole in every suite built on it, and
it is the file least likely to be re-read.

This file is the only place these numbers live.

## Where it stands

| file | generated | valid | killed | survived | invalid | score | time |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `InvariantBase.sol`, as the audit found it | 335 | 321 | 252 | **69** | 14 | 78.5 % | 2 m 33 s |
| `InvariantBase.sol`, after the tests below | 370 | 362 | **329** | 33 | 8 | **90.9 %** | 3 m 25 s |
| `HostileERC20.sol`, as the audit found it | 393 | 379 | 325 | **54** | 14 | 85.8 % | 2 m 2 s |

(Counts above predate the `returnsFalse` switch of 2026-09-24 and the `fuzzedBookkeepingCalls` counter in `InvariantBase.sol` of 2026-09-23; the files changed, the scores were not re-run. The next mutation run replaces this table.)
| `HostileERC20.sol`, after the tests below | 393 | 379 | **342** | 37 | 14 | **90.2 %** | 2 m 33 s |
| `InvariantBase.sol`, after the second review (the file grew again: `countedSetter`, the net under `_unexpectedRevert`, `writeCensus`) | 411 | 403 | **365** | 38 | 8 | **90.6 %** | 3 m 44 s |
| `HostileERC20.sol`, after the second review (one test, for the survivor this file used to confess) | 393 | 379 | **343** | 36 | 14 | **90.5 %** | 2 m 38 s |

forge 1.8.1, solc 0.8.26, on sixteen cores. `InvariantBase` generates more mutants than it did because the
file grew (`_bitOneIn`, `_noteInternalDonation`, the two census getters and the reach printer).

**A number here reproduces only over a green battery.** A reviewer re-ran `HostileERC20` and measured 98.9 %, not
90.2 %: a real counterexample in the vault example (since declared out of scope, `src/examples/ToyVault.sol` line
10) had been persisted in the mutation workspace, every later campaign replayed it and failed, and the equivalent
mutants "died" with everything else. A mutation score measured while any test is red for its own reasons is
inflated by exactly that much. Two of the printer mutants below are also killable BY CHANCE (they panic out of
bounds when a fuzz run happens to end with no boundary reached), so the survivor count moves by one or two
between runs: 38 is this run, 40 is the ceiling.

## `InvariantBase.sol`: the 38 survivors, every one of them accounted for

**Nothing in this list is a guard.** `assertExercised`, `assertReached`, `_unexpectedRevert` and
`require(actors.length > 0, ...)` are gone from it entirely, and `_bit` is down to one equivalent.

### Equivalent mutants (24)

*Unsigned comparisons that are the same predicate.* `actors.length > 0` -> `!= 0`, `actionCalls[k] == 0` ->
`<= 0`, `reachCount[k] == 0` -> `<= 0`, and since the second review `revertsUnexpected == 0` -> `<= 0` in the net
under `counted` and `bytes(path).length == 0` -> `<= 0` in `writeCensus`. For a `uint256` these are the same test and the compiler emits the
same code. (The `require(true, ...)` mutation of the actor guard is a different mutant, and it is killed by
`test_a_handler_with_no_actors_says_so_instead_of_dividing_by_zero`.)

*`_bit`: `word & 1 == 1` -> `word & 1 >= 1`.* `word & 1` can only be 0 or 1, so "at least one" and "exactly
one" are the same statement about it. The other twelve mutations of that line are killed by
`test_bit_reads_the_lowest_bit_of_the_word_and_nothing_else`, which probes it with fourteen words including
`1 << 255`, `type(uint256).max` and the dirty-calldata value from its own natspec.

*`_bitOneIn`: `n < 2` -> `n <= 2`.* The two differ only at `n == 2`, and there the original evaluates
`word % 2 == 1` while the mutant falls back to `_bit(word)`, which is `word & 1 == 1`. Those are the same
predicate for every word. The equivalence is bought by the fallback being `_bit` and nothing else; change it
and this becomes an untested boundary.

*Loop shapes, in the four assertion loops and the two loops of `censusLine` (12 mutants; the printers' loops are
counted in the next class, not here - an earlier version of this paragraph counted them twice).* `i < holders.length` ->
`i != holders.length`, and `i++` -> `++i`. A loop that starts at zero and increments by one reaches the
length exactly once, so `<` and `!=` terminate together; and the value of an increment used as a statement is
discarded, so prefix and postfix are the same program.

*Comparisons where the two branches produce the same value (5 mutants).* `post > pre` -> `post >= pre` in
`_noteDelta` (at equality the mutant notes a gain of zero, which adds nothing); `pre > post` -> `pre != post`
in the same `else if` (which only runs when `post <= pre`, so there the two are identical) and -> `pre >=
post` (a loss of zero); `post > pre[i]` -> `post >= pre[i]` and `post < pre[i]` -> `post <= pre[i]` in
`assertGainBackedByLoss` (a gain or a loss of zero). The NON-equivalent siblings of those last two - the ones
that underflow, or that measure the winner from the wrong place - are killed by
`test_assertGainBackedByLoss_measures_the_winner_from_where_it_started` and
`..._reports_no_gain_when_the_winner_ended_poorer`.

### Unobservable by construction: the two census printers (13 in this run, 15 at most)

Lines 238, 239 and 249 are inside `printCallSummary()` and `printReachSummary()`: a `console2.log` guarded by
`revertsUnexpected > 0`, and the two loops that print one line per action and per boundary. Mutating them
changes what a human reads and nothing else — a suppressed line, a line printed twice, a loop that prints
nothing at all.

**This is not an equivalence argument, and it should not be dressed up as one.** The programs really do
differ; no test can tell, because forge-std has no cheatcode that reads back what `console2.log` printed.
It is a limit of the oracle. Two consequences, and both are the reason the number is published here rather
than quietly dropped:

* the printed census is a **diagnostic, not an assertion**. What it says is unguarded. Everything the kit
  actually *asserts* about the census goes through `callsOf`, `successesOf`, `reachedCount`, `actionCount`
  and `boundaryNameAt` — all of which have tests, and all of whose mutants die;
* when a number from the census has to be trusted, it is aggregated **outside forge** from a file, the way
  `README.md`'s per-run figures were measured, and not read off a log by eye.

Ten mutants moved out of this class during the work: `if (actionCalls[k] == 0) actionNames.push(action)` and
its twin in the reach census used to be reachable only by the printers, so the mutation that pushes a name on
EVERY call — making the summary list an action once per call — survived. They are killed now by
`test_each_action_is_named_once_however_often_it_is_called`, which reads the name list through the getters
the fix added. *If a mutant is unkillable because nothing can observe the state, the fix is usually a getter,
not an argument.*

### Killed outside forge: `writeCensus` that never writes (1)

`bytes(path).length == 0` -> `>= 0` makes `writeCensus` return before it writes, always. No unit test can see it,
on purpose: the unit tests run with `GAUNTLET_CENSUS` unset (setting it would leak into the campaigns running in
parallel), and with it unset the original returns early too. The half that writes is proven end to end by
`scripts/selftest.sh`, which runs the vault campaign through `scripts/census.sh` and fails when no line reaches the
file. It is listed here so that the 38 add up: 24 + 13 + 1.

## `HostileERC20.sol`: the 36 survivors, by class

Triaged as classes rather than one line each, because they really are classes: thirty-six survivors across
nine shapes. Every one is placed, and the residue that is *killable and not killed* is named at the end
rather than hidden inside a percentage.

### Strictly equivalent: the two programs cannot be told apart by any input (25)

| shape | where | why no input separates them |
| --- | --- | --- |
| `x > 0` -> `x != 0` (8) | `gasBurnRounds`, `overstateAfterMove`, `missing`, `feeBps`, `fee`, `extra`, `bonus`, `rebate` | `uint256`: the same predicate, the same opcode |
| `x > 0` -> `x >= 0` (5) | `gasBurnRounds`, `missing`, `feeBps`, `bonus`, `rebate` | always true, and the guarded work is a no-op at zero: `_burnRounds(0)` loops zero times, `b - 0` is `b`, a fee of `debit * 0 / 10_000` is zero, and `_payFromReserve(to, 0)` returns immediately |
| `x <= 0` -> `x == 0` (2) | `paid`, `cb.firesLeft` | `uint256` again |
| address compared as an unsigned number (3) | `lie.caller != address(0)` -> `>` and `>=`; `cb.target == address(0)` -> `<=` | `> address(0)` is `!= address(0)`; `<= address(0)` is `== address(0)`; and `>= address(0)` is always true, after which the branch still needs `msg.sender == lie.caller`, which cannot hold for the zero address |
| a boundary where both branches produce the same value (5) | `understateWhenRichDiv > 1` -> `>= 1` (dividing by one), `shortDeliverDiv > 1` -> `>= 1` (same), `b > missing` -> `>=` (zero either way), `want > have` -> `>=` (the same payout), `a != type(uint256).max` -> `a <` (no `uint256` exceeds the maximum) | |
| loop shape (2) | `i != rounds`, `++i` in `_burnRounds` | a 0-based `++` loop terminates identically; the value of a statement-increment is discarded |

The **non**-equivalent siblings of several of these are killed, and each bought a test:
`msg.sender == lie.caller` -> `<=` by `test_the_caller_lie_is_told_to_one_address_and_not_to_everyone_below_it`
(an address is an identity, not an ordering - the third time this kit has learned that);
`b > missing` -> `b != missing` by `test_understating_more_than_the_wallet_holds_reads_zero_and_does_not_panic`;
the five bitwise mutations of `debit + extra` by
`test_the_balance_check_covers_the_delivery_and_the_extra_burn_together`;
`cb.firesLeft -= 1` -> `>>= 1` by `test_the_fire_count_is_decremented_and_not_halved`;
and the whole `a - value` family by `test_a_finite_allowance_is_spent_by_exactly_what_was_moved` - which had
survived because every fixture in the suite approves `type(uint256).max`, the one value that never takes the
branch.

### Not equivalent, but nothing in this suite can observe them (11)

Stated as a limit of the ORACLE, not as a proof, because that is what it is.

* **An extra zero-value `Transfer` event (3).** `fee >= 0`, `extra >= 0` and `paid < 0` each make the token
  move zero tokens and emit a log saying so. No balance changes. Killable by an `expectEmit`-style test on
  the *absence* of an event, which forge does not express directly; it would need a log-count assertion.
* **A one-gas boundary (3).** `gasleft() > gasThreshold` in two places and `gasleft() > FRAME_FLOOR` in
  `_burnFrame`, each mutated to `>=`. The two programs differ only when `gasleft()` is *exactly* the
  threshold, and no test can place it there: the gas left at a point inside a call is a function of
  everything the compiler did on the way.
* **The optimiser guard (4).** `if (uint256(h) == 1) revert Unreachable();` mutated to `< 1` and `<= 1`, in
  both burn loops. `h` is a keccak digest; the line exists only so that the compiler cannot delete the loop
  whose gas cost is the point (see its natspec). It is unreachable by construction, which is exactly why the
  mutation is invisible.
* **One extra round of a gas-burning loop (1).** `i < rounds` -> `i <= rounds` in `_burnRounds`: the mock
  burns a little more gas and answers the same number.

### Killable, not killed: 0 (it was 1)

`cb.target == address(0)` -> `cb.target < address(0)`, which is never true, so a callback registered with a
zero target and a non-zero fire count would be *called* instead of skipped. This file used to say "it is a
two-line test and it is not written". A reviewer would be right to laugh at that sentence, so the test exists
now: `test_a_callback_with_no_target_is_skipped_and_not_called`. 25 + 11 = 36.

## What the two passes cost and what they bought

Six minutes of a sixteen-core machine and no tokens, on files that had thirty-odd tests each and had been
read by an auditor. Between them they produced: a guard against vacuous campaigns that had never been seen
red; a counter that could not be read above zero; a census whose name list nothing could inspect; a ledger
that had never been made to accumulate twice; an address compared as an ordering, twice, in two different
files; an allowance decrement that had never run because every fixture approves `type(uint256).max`; and a
`require` on a 100 % fee that nothing had ever tripped.

None of them was a value bug. All of them were things the suite had never asked.
