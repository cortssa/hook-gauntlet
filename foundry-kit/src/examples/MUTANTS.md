# The survivors of `forge test --mutate src/examples/ToyVault.sol`

A mutation score is not a grade, it is a reading list. The tool changes one operator, runs the suite, and
reports the changes the suite did not notice. Most of those are holes. Some are **equivalent mutants**: a
different program text that no input can distinguish from the original, where killing them is impossible and
pretending otherwise means writing a test that asserts something untrue.

This file is the second half of the work. Every survivor is either killed by a named test in
`test/examples/ToyVault.boundaries.t.sol`, or argued here. **An argument has to show that no input tells the
two programs apart.** "The campaign never reached that boundary" is not an argument, it is the hole.

Run it yourself:

```sh
forge test --mutate src/examples/ToyVault.sol
```

**This file is the only place the example's mutation numbers live.** They were in three documents once, with
three different values for the same run (`doctrine/JUDGES.md` said 20 survivors, `README.md` said 19, and
`README.md`'s own two rows did not add up). One source per number.

## Where it stands

| | generated | valid | killed | survived | invalid | skipped | score | time |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| the first run | 108 | 104 | 84 | **19** | 3 | 1 | 80.8 % | 31 s |
| after `ToyVault.boundaries.t.sol` | 108 | 104 | 101 | 3, all equivalent | 3 | 1 | 97.1 % | 25 s |
| after the audit's fix to `withdraw` | 108 | 103 | 99 | **4** | 3 | 2 | 96.1 % | 36 s |
| after the test that fourth one bought | 108 | 103 | **100** | 3, all equivalent | 3 | 2 | **97.1 %** | 34 s |
| after the second review (the contract's CODE did not change: its threat model did) | 108 | 103 | **100** | 3, the same three | 3 | 2 | **97.1 %** | 35 s |

forge 1.8.1, solc 0.8.26. The "skipped" column is forge's adaptive skipping and it MOVES between runs of the same
tree (2 here, 1 and 0 for two reviewers, with `valid` and `killed` moving with it: 103/100, 104/101, 105/102); the
three survivors and the 97.1 % do not. The valid count moves by one between the second and third rows because the
contract changed: `spent > amount` became `spent != amount`, which generates a different family.

## What the first run said

The example was written with a threat model on the front of it, seven defended cases and one declared out of
scope, and it was believed to be covered. The first mutation pass, which cost thirty seconds and no tokens,
returned **19 survivors**. Three of them are equivalent. The other sixteen were real gaps, every one of them
at a boundary or in the shape of some return data:

| what the campaign could not see | why |
| --- | --- |
| the exact boundary (`have == amount`) | the fuzzer proposes amounts, it does not propose *your* amount |
| `reverted for the wrong reason` | every call is in a try/catch that only counts the failure |
| the SHAPE of a token's return data | `HostileERC20` switches value, not bytes on the wire |

That third row bought a new fixture, `ReturnDataToken`, in the test file. It is worth stealing: the hostile
token is about *how much moved*, and the vault also has promises about *how many bytes came back*.

## What the SECOND run said, after the fix that an audit asked for

An independent audit found the hole no mutation pass can find: `withdraw` bounded its outflow only from
above, so a token that returned true and moved nothing on the way OUT cleared the caller's credit and left
the tokens unclaimable. **A mutation pass changes operators; it does not invent a branch that is not there.**
It is worth being precise about why, because it is the boundary of what the tool is for: `--mutate` explores
programs one edit away from yours, and a missing lower bound is not one edit away from a program that never
had one. Four new tests were written for the fix, and the pass was run again.

It came back with a survivor nobody expected: **`have < amount` -> `have != amount`**, which refuses every
PARTIAL withdrawal. Not one test in the file took part of a credit. They all took the whole thing — because
"withdraw exactly your whole credit" was the boundary the FIRST pass had pointed at, and the tests had been
written to that. *Closing one blind spot is how you acquire the next one.* Killed by
`test_withdrawing_part_of_the_credit_is_allowed`.

The campaign cannot see it either, for the reason this whole file exists: the mutant reverts with
`InsufficientCredit`, and the handler classifies that as a predicted failure and moves on.

## What the second review said, and no mutation pass could have

The repaired `withdraw` refuses any payout that did not cost the vault exactly the amount, and the threat model
claimed that this defended the caller against a short delivery. It bounds the VAULT's loss. A token that delivers
a sixth and burns the other five sixths from the sender satisfies `spent == amount` to the wei while the caller
is short-changed (`ToyVault.sol`, line 10 of the model, now out of scope and pinned by
`test_outOfScope_short_delivery_hidden_by_a_sender_side_burn`).

The score did not move, and that is the point: **a mutation pass grades the tests against the code; it has no
opinion about whether the code does what the prose says.** 97.1 % was true before and after. What found it was
the fuzz campaign, about once in four hundred campaigns - and a reviewer who read the failure instead of
re-running until it went away.

## Equivalent mutants (3)

### 1. `_lock == 1` -> `_lock >= 1` (the re-entrancy guard, line 97)

`_lock` is `private`, is read in exactly one place, and is written in exactly two, both of them in this
modifier and both with a literal: `_lock = 1` on entry and `_lock = 0` on exit. No execution can leave it
holding anything else, so over every reachable state `_lock >= 1` and `_lock == 1` are the same predicate.

Note what this argument depends on: `_lock` being private and having no other writer. Add a second writer -
an initialiser, an upgrade, a packed neighbour written by assembly - and this stops being an equivalent
mutant and becomes an untested boundary.

### 2. `pre > post` -> `pre >= post` (the outflow measurement, line 129)

```solidity
uint256 spent = pre > post ? pre - post : 0;
```

The two differ only when `pre == post`, and there the original takes the `else` branch and yields `0` while
the mutant takes the `then` branch and yields `pre - post`, which is also `0`. Same value, on the only input
that separates them, so no caller can tell.

The sibling mutations of the same line are NOT equivalent and are killed by tests: `pre != post` (the vault
ended richer: underflow instead of zero), `pre == post` and `pre % post` and `pre << post` (the outflow
measurement collapses and a payout that cost the vault nine times what it owed is accepted).

### 3. `data.length != 0` -> `data.length > 0` (the transfer's return data, line 147)

`data.length` is a `uint256`. For an unsigned integer `x`, `x > 0` and `x != 0` are the same predicate over
every value of the type; the compiler emits the same comparison. Nothing can distinguish them.

The four other mutations of the same subexpression are all killed: `< 0` and `<= 0` and `== 0` make the vault
accept a token that moved the tokens and returned `false`, and `>= 0` makes it decode an empty buffer and so
refuse the largest stablecoin by volume.

## The ones that were killed, and by what

| mutation | test that kills it |
| --- | --- |
| `post <= pre` -> `post < pre` | `test_a_deposit_that_delivers_nothing_is_refused_not_credited_as_zero` |
| `post <= pre` -> `post == pre` | `test_a_vault_balance_that_reads_smaller_after_the_transfer_is_refused_with_the_declared_error` |
| `have < amount` -> `have <= amount` | `test_withdrawing_exactly_the_whole_credit_is_allowed` |
| `have < amount` -> `have == amount` | `test_withdrawing_more_than_the_credit_is_refused_with_the_declared_error` |
| `have < amount` -> `have != amount` | `test_withdrawing_part_of_the_credit_is_allowed` |
| `pre > post` -> `pre != post` | `test_a_payout_that_leaves_the_vault_richer_is_refused_without_underflowing` |
| `pre > post` -> `pre == post` | `test_a_payout_that_costs_the_vault_far_more_than_the_amount_is_refused` |
| `pre - post` -> `pre % post` | same |
| `pre - post` -> `pre << post` | same |
| `spent != amount` -> `spent > amount` (the OLD code) | `test_a_payout_that_moves_nothing_is_refused_and_the_credit_survives`, `..._delivers_half_...`, `..._costs_the_vault_less_than_the_amount_is_refused_too` |
| `spent != amount` -> `spent == amount`, `-> <`, `-> <=`, `-> >=` | `test_a_payout_that_costs_exactly_the_amount_is_allowed` |
| `!ok \|\| len < 32` -> `!ok != len < 32` | `test_a_balance_read_that_reverts_with_no_data_is_refused_with_the_declared_error` |
| `len < 32` -> `len != 32` | `test_a_balance_read_with_extra_data_after_the_word_is_accepted` |
| `len < 32` -> `len > 32` | same, and `..._succeeds_with_no_data_...` |
| `len != 0` -> `len < 0` | `test_a_transfer_that_returns_false_is_refused_even_though_the_tokens_moved` |
| `len != 0` -> `len <= 0` | same |
| `len != 0` -> `len == 0` | same |
| `len != 0` -> `len >= 0` | `test_a_transfer_that_returns_no_data_at_all_is_accepted` |
| `len != 0 && !decode` -> `len != 0 == !decode` | same |

(More rows than mutants: one mutation is killed by two different tests, and several share one.)

## Four things this pass taught, that are not about this vault

1. **A boundary the fuzzer never proposes is a boundary nobody tested.** "Withdraw exactly your whole
   credit" is the single most common thing a real user does and the campaign had never once done it.
2. **`fail_on_revert = true` plus try/catch hides the REASON.** The handler classifies a revert as expected
   and moves on, so a contract that answers an arithmetic panic where it promised a named error passes.
   Assert the selector somewhere, by hand, at least once per named error.
3. **Not one survivor was a value bug.** They were all boundaries and return-data shapes - the two things a
   stateful campaign is worst at and a mutation pass is best at. They answer different questions; run both.
4. **Run the pass again after you fix what it found.** The second pass found a gap the first one had
   created, by pointing every new test at one boundary. A survivor list is not a checklist you complete.
