# foundry-kit

The Foundry pieces the gauntlet's phases lean on. Three things, plus a worked example:

| Piece | What it is |
| --- | --- |
| `src/HostileERC20.sol` | an ERC-20 for tests whose misbehaviour is switchable at runtime, per wallet and globally |
| `src/InvariantBase.sol` | `HandlerBase` (actors, call census, ghost accounting) and `InvariantAsserts` (the reusable assertions) |
| `src/examples/ToyVault.sol` | a tiny contract, with a written threat model, that exists only to show the harness working |
| `test/examples/ToyVault.invariants.t.sol` | the handler, the invariants and the non-vacuity smoke test for that contract |
| `test/examples/ToyVault.boundaries.t.sol` | one test per mutant the campaign did not kill, plus a fixture for return-data shapes |
| `src/MUTANTS.md` | the mutation score and survivor triage of the two CORE files, `HandlerBase`/`InvariantAsserts` and the hostile token |
| `src/examples/MUTANTS.md` | the same for the worked example: what was killed, and why the rest are equivalent |
| `v4/` | the Uniswap v4 module: its own Foundry project, with a harness, address mining and a worked hook. Run `scripts/install-v4.sh` first. See `v4/README.md` |

Everything here is self-contained: the only dependency is `forge-std`.

## Getting it running

```sh
forge install foundry-rs/forge-std        # the only dependency
forge build
forge test
```

Solidity 0.8.26, `evm_version = cancun`, optimizer on at 200 runs. The root kit uses no cheatcode newer than
`targetSelector`; the v4 module's sandbox reads forge's `lastFrameGas()` record, which is where a version shows first.

### Supported versions

What the kit's own gates (`.github/workflows/gates.yml`) run on. Outside this table nothing is claimed.

| component | version | where it is pinned | what breaks outside it |
| --- | --- | --- | --- |
| forge | **1.8.1** | `FOUNDRY_VERSION` in `gates.yml` (battery + selftest jobs) | flags renamed by a nightly (`doctrine/JUDGES.md` was checked flag by flag against 1.8.1); the shape of the test summary and of the `--sizes` table, which `scripts/lib/parse.sh` refuses rather than guesses; the length of the `lastFrameGas()` record (below) |
| forge | 1.8.3 | `FOUNDRY_VERSION_2` in `gates.yml` (job `battery-forge-1-8-3`) | **not yet seen green: unsupported until that job passes.** Added 2026-09-23 without a run (only 1.8.1 is on the machine that wrote it). If it goes red, the job is removed and this row says "unsupported" |
| forge-std | **1.16.2** (root kit) | `FORGE_STD_TAG` in `gates.yml` | its `Vm.Gas` declares six words (a trailing `gasStateUsed`) and forge 1.8.1 returns five, so code compiled against it that calls the typed `vm.lastCallGas()` fails in the decoder; `SimGasMeter` reads the raw record and accepts either length |
| forge-std | as pinned by v4-core (v4 module) | `V4_CORE_PIN` in `scripts/install-v4.sh` (the module remaps `forge-std/` into `lib/v4-core/lib/forge-std`; 1.9.3 on the bench that wrote this table) | the v4 tests compile against v4-core's own forge-std, not the root kit's: a cheatcode newer than that copy does not exist for them |
| solc | **0.8.26** | `solc_version` in both `foundry.toml` | the sizes (and the EIP-170 margins every hook note quotes) are for this compiler; another one changes every byte count |
| EVM | **cancun** | `evm_version` in both `foundry.toml` | transient storage (v4-core's `unlock` uses it) needs cancun or later; gas numbers are cancun's |
| `lastFrameGas()` record | 160 bytes (five words) or 192 bytes (six) | `SimGasMeter.decodeFrameGas` | any other length reverts `FrameGasLayoutUnknown(length)` and stops the run: a forge that changes the record is refused, never read at the wrong offsets |

**Keep your own examples inside `src/` and `test/`.** The worked example is at `src/examples/ToyVault.sol`
and `test/examples/ToyVault.invariants.t.sol`, not in an `examples/` tree of its own. `forge` compiles `src`,
`test` and `script` and nothing else, so an example outside them needs an import to be built at all - and,
worse, Foundry's `--mutate` and `--brutalize` copy only the standard directories into their temporary
workspace and then report a green nothing. The measurement is in "Native mutation, measured", below.

## HostileERC20

A mock you choose at construction time cannot express the attack that matters, because the attack is not
"a bad token", it is a token that behaves for the first half of a transaction and turns on you in the second
half. Every switch here can be flipped mid-test, from inside a callback, or by a fuzz handler between calls.

Each switch carries natspec saying which real class of token it imitates and what a naive contract gets wrong
with it. The list:

**On the read side** (`balanceOf`): reverts always; answers `type(uint256).max`; burns gas and then answers
honestly; reverts only when called with a fat gas frame; understates only when called with a fat gas frame;
lies to one named caller and tells everyone else the truth; reverts once the wallet has moved tokens;
overstates the wallet's balance after a move, so the drop looks smaller; understates it, so the drop looks
bigger.

**On the write side**: returns true and moves nothing; eats the whole gas frame, moves nothing, returns true;
a global fee on transfer; delivers a fraction of what was asked while spending the full allowance; pays the
recipient a bonus; refunds part of it to the sender; takes more from the sender than it delivers; blocks a
recipient; a global pause; a global "returns no data at all", which is what the largest stablecoin by volume
does.

**Callbacks**: ERC-777 style hooks on the sender before the move and on the recipient after it, each bounded
by a fire count so a test cannot recurse by accident.

Two accounting rules make it usable as a referee. Nothing is destroyed: fees and burns are parked at
`FEE_SINK`, and bonuses and rebates are paid out of `RESERVE`, which the test funds. And `trueBalanceOf`
answers the truth with every switch ignored.

**Which balance an invariant should read is a decision, and it is not always "the truth."** Solvency is about
the truth. "Did the contract treat this wallet fairly" is about what the contract could see; judging that
against the truth accuses the contract of not knowing something nobody told it. Write the choice down next to
the invariant.

## InvariantBase

`HandlerBase` gives a handler its fixed cast of actors, a per-action call census, counters for predicted and
unpredicted reverts, and ghost variables (everything minted, per-wallet gains and losses, donations per
contract and token).

It is built around `fail_on_revert = true`. Under that setting a handler function that reverts fails the run,
so every call into the contract under test is wrapped in try/catch and the catch branch has to classify the
failure. A revert you predicted is a data point; one you did not predict is a finding. With
`fail_on_revert = false` a fuzzer will happily spend a whole run bouncing off an input filter and report a
green suite that tested nothing.

`InvariantAsserts` has the assertions worth writing once:

- `assertConserved` - nothing created or destroyed, over a list of holders that has to be complete;
- `assertPaidForLoss` - around ONE action, whoever lost token A gained token B;
- `assertGainBackedByLoss` - the winner's gain is backed coin for coin by everyone else's losses, plus a
  declared slack;
- `assertHoldsOnlyDonations` / `assertHoldsNoMoreThan` - the contract is not a wallet;
- `assertSolvent` - it can honour what it owes.

## The worked example

`ToyVault` pulls tokens by allowance and credits what actually arrived. It is not a hook and it has no planted
bugs. Its value is the threat model written at the top of the file, before the fuzz: eight things it claims to
survive, two things it declares it does not defend, and one defence named per line of the model. A harness is
only as good as that list, and if the list is not written first it gets written afterwards to match whatever
the run happened to do.

**Line 8 of that model was added by an independent audit, and how it was missed is the most useful thing in
this file.** `withdraw` bounded its outflow from above — "refuse if leaving cost me more than the amount" —
and said nothing about it being too small. A token that returns true and moves nothing on the way *out*
therefore cleared the caller's credit, left the tokens in the vault, and took `totalCredit` to zero: the
vault owed nobody, and nobody could claim them. Neither tool in this repository could see it.

* the **mutation pass** changes operators; it does not invent the branch that is not there;
* the **invariant campaign** could not reach it, because the handler pointed `trueNoMove`, `shortDeliver` and
  `gasHog` at the ACTORS and never at the vault. The whole outbound half of the threat model had no action.

**And line 10 was added by the review of that fix.** The repaired vault refuses any payout that did not cost it
exactly the amount, and the file said this defended line 8. It bounds the VAULT's loss; it says nothing about what
reached the caller. A token that delivers a sixth and burns the other five sixths from the sender satisfies the
check to the wei while the caller is short-changed. This time a tool did see it - the kit's own fuzz campaign,
about once in four hundred campaigns, which also made the battery intermittent for a true reason. There is no
code fix inside a contract that measures only its own balance, so the model now says so: out of scope, declared,
pinned by a test that asserts the loss, and filed by the handler under its own census boundary.

Three rules come out of it. A defence is named by what it MEASURES, not by what you hope it implies. Write the threat model for **both directions** of every external call. Then, for
each line of it, name the handler action that reaches that line — and if you cannot, the line is not defended,
it is only written down.

Three more lessons from building it are worth stealing:

1. **Cap the gas on every call into the contract under test.** A token that eats the frame turns a catchable
   failure into a dead run, and `fail_on_revert = true` then reports a bug in your handler instead of the
   behaviour of the token.
2. **Prove your suite is not vacuous.** Every invariant in the example is true of a vault nobody ever used.
   `test_handler_smoke` drives the happy path by hand, asserts that deposits, withdrawals, hostile branches
   and re-entry attempts actually happened, and only then runs the invariants.
3. **A ghost ledger has to record value that arrives by a route the handler did not take.** A token that
   pays its *sender* a rebate pays the vault on the way out, out of the token's own reserve, so a
   `withdraw(0)` leaves the vault richer by an amount nobody chose and nobody can claim — and
   `invariant_vault_holds_only_credit_and_donations` went red on correct behaviour until the handler
   measured its own balance across the payout and booked the gain. It is booked with
   `_noteInternalDonation`, not `_noteDonation`: nothing was minted, the tokens came from a holder the
   conservation list already counts, and moving both ledgers would have broken the other invariant instead.

A fourth lesson is baked into `HostileERC20` itself: under Foundry you cannot check a gas-eating switch by
reading `gasleft()` before and after the call in the test contract, because that difference does not track
what the callee spent. Measured here, a callee given 199 776 gas came back with 4 838 while the test frame
reported 8 236 consumed. Test the consequence instead.

## The campaign's census, and the number that is not one

`forge` ends an invariant run with `(runs: 64, calls: 4096, reverts: 0)`, and several places used to treat
that `reverts: 0` as the sign that the campaign was healthy. **Under `fail_on_revert = true` with every call
wrapped in a try/catch it cannot be anything else.** It is a tautology. The only thing it tells you is that
the handler compiled.

The signal is the census: per action, calls and **successes**; per boundary, how often it was reached; and
whether the handler met a failure it had not predicted. Both examples produce it from `afterInvariant()`.

**And it has to be the census of the CAMPAIGN, which is not what forge shows you.** `afterInvariant()` runs
after every one of the 64 runs, but forge prints the logs of ONE of them. An earlier version of this file
said the block appears "once per run"; a second review counted the blocks (one) and found that block saying
`withdrawsOk 0` over a campaign with more than a hundred successful withdrawals. A gate read from it is red
or green by luck. So the handler appends one line per run to a file (`HandlerBase.writeCensus`, only when
`GAUNTLET_CENSUS` is set, so the everyday battery writes nothing), and a script adds them up:

```sh
CORE="deposit withdraw" REACH="withdrew the whole credit" ../scripts/census.sh .   # exit 1 below the floor
```

`CORE` names the actions that must have SUCCEEDED, `REACH` (semicolon separated - the names have spaces) the
boundaries that must have been REACHED, each in at least `MIN_PCT` per cent of the runs, judged per suite. `REACH`
exists because of a mutant: a hook that answered with the wrong selector from its fifth swap in a block kept every
action succeeding, and the one boundary its whole promise is about - "fee at the cap" - simply stopped appearing in
the table. Nothing is louder than a row that is not there, unless something is told to look for it.

`CORE` and its floor `MIN_PCT` are yours to set, in the spec. Put the floor below the range you measure, not inside
it: on sixteen campaigns of this very tree `withdraw` succeeded in 42 to 80 per cent of the runs, so a floor of 50
would have failed four campaigns in sixteen by luck, which teaches people to re-run gates until they pass. (The
first ten of those campaigns said "48 to 80"; the next six, by somebody else, put three of six below that. A range
measured once is a sample too.)

The column to read is **runs with ZERO ok**: a run in which the action that matters never succeeded tested
an empty contract, however green it was. `scripts/fuzz-long.sh` prints the same table after a long run.

Three things were measured while wiring it up, and all three are now in the handlers:

1. **A sticky switch set with `_bit` is on half the time and parks the campaign.** `setPaused`,
   `setVaultBlocked`, `setTrueNoMove` and the rest stay on until the fuzzer happens to call the same action
   again with an even word; measured, **38 to 48 of 65 runs of the vault campaign ended with ZERO successful
   withdrawals**. Use `_bitOneIn(word, n)` for anything that persists, and give the handler a `calmDown()`
   action that clears the lot — a campaign needs a cheap way *back* from a broken configuration, not only
   ways into one.
2. **Bound an action against the state, not against a constant.** `bound(amount, 0, MAX_AMOUNT)` against a
   credit of 3e18 is a machine for producing `InsufficientCredit`, and the exact boundary — withdrawing your
   whole credit — was reached in one run out of 65. Deriving the bound from `vault.credit(caller)`, and
   picking a caller that *has* a credit, is what turned that around.
3. **An action that does N things in a row has to actually do N.** The hook's fee cap needs ten swaps in one
   block; `swapBurst` drew its length uniformly from 2..14, so it was long enough about a third of the time,
   and the campaign reached the cap in as few as **3 of 65 runs**. Half the bursts are now deliberately long.

After all three, measured with `scripts/census.sh`, fresh corpus every time: vault runs with zero successful
withdrawals **25, 24, 13, 19, 22, 29, 27, 27, 34 and 16 of 65** over ten campaigns, and **35, 27, 20, 37, 22 and
38 of 65** over six more run by an independent reviewer; hook runs that reach the fee cap
**28, 31, 32, 22 and 27 of 65** over five. This is the one place these figures live.

**They are a range, not a value, and `--fuzz-seed` does not make them one.** An earlier version of this file
gave five numbers "across `--fuzz-seed 1..5`" and told you to write the seed down. A second review ran the
same seed twice and got 19 and 17: with a coverage-guided corpus the seed does not pin the draw on this forge.
So report a campaign's reach as a range over several campaigns, or say "in most runs" - and treat any single
campaign, green or red, as one sample. Two draws on the same tree once gave the hook 22 of 65 and 3 of 65. A
campaign is a sample, and a single green campaign is a
single sample — which is exactly how a sentence promising that a mutant "makes the invariant go red" got
into `v4/README.md` and was later watched to survive.

## Native mutation, measured

Foundry ships mutation testing (`forge test --mutate <file>`), a memory-poisoning mode (`--brutalize`) and
coverage. They are free, they take under a minute on a contract this size, and they belong before any round
you pay for. Here is what they cost and what they found on the kit's own examples, on forge 1.8.1.

### The trap: 100 % invalid, with exit code 0

The kit used to keep its worked example in an `examples/` directory of its own. Run against it:

```
forge test --mutate examples/ToyVault.sol
  -> 136 mutants, 136 INVALID, 0 killed, 0 survived, rc = 0, 2 s
forge test --brutalize
  -> compile failure
```

**`rc = 0`.** A script that checks the exit code reports a clean mutation run in which nothing was tested. The
cause: `--mutate` and `--brutalize` copy the project into a temporary workspace and carry only the standard
directories, `src` and `test`. An example outside them is gone by the time the mutant is compiled, so every
mutant fails to compile, and a mutant that fails to compile is "invalid", and invalid is not failure.

The fix is the layout: `src/examples/` and `test/examples/`. **If you keep any Solidity outside `src`, `test`
and `script`, check the *valid* mutant count, never the exit code.**

### What it found once it could run

Where each score lives - **one file per number**, because these were in three documents at once and the
three disagreed:

| | where the numbers and the survivor triage live | where it stands |
| --- | --- | --- |
| `src/examples/ToyVault.sol` | `src/examples/MUTANTS.md` | every survivor proven equivalent |
| `v4/src/examples/CappedDynamicFeeHook.sol` | `v4/src/examples/MUTANTS.md` | every survivor proven equivalent |
| `src/InvariantBase.sol` | `src/MUTANTS.md` | every survivor placed: equivalent, unobservable (the log printers), or killed outside forge by the self-test |
| `src/HostileERC20.sol` | `src/MUTANTS.md` | every survivor placed: equivalent, or unobservable by this oracle; none left killable-and-not-killed |

(No percentages in this table, on purpose: a second review found this very table disagreeing with the files it
points at. The figures are in those files and nowhere else.)

**The last two rows did not exist until an independent audit ran the command.** The kit published mutation
scores for its two EXAMPLES and none for the two files every suite inherits, where `assertExercised` - the
guard whose whole job is to stop a vacuous campaign being reported as a pass - survived being replaced by
`require(true, ...)`. Mutate the thing everything else inherits, first.

Both examples had a threat model written before the first test, a unit test per line of it, an invariant
campaign with a non-vacuity smoke test, and - for the hook - a hand-written mutant hunt done in review. The
survivors were still real. They clustered in three places a stateful campaign is structurally bad at:

* **the exact boundary.** Withdrawing your whole credit, the commonest thing a real user does, had never
  happened. A fuzzer proposes amounts; it does not propose *your* amount. Measured afterwards with the reach
  census, on the handler as it then was: **one campaign run in sixty-five** ever did it. (The number that
  used to be here, "128 000 fuzzed calls", was the long profile's budget, and the long profile has never
  been run on this kit - `Not covered yet`, below, says so. It has been replaced by something measured.)
* **the reason for a revert.** With `fail_on_revert = true` every call is inside a try/catch that counts the
  failure and drops the selector, so a contract answering an arithmetic panic where it promised a named error
  passes. Assert the selector by hand, once per named error.
* **the shape of the return data.** `HostileERC20` switches value, not bytes on the wire; it cannot even
  express "reverts with no data", because its own error is 36 bytes. A separate fixture had to be written.

And on the hook, one whole class: **`!=` on an address, mutated to `<`, survived twice.** Every caller the
suite owned - `0xB0B`, `0xA11CE`, `0xDEAD` - sorts below a mined hook address, so a guard reduced to "refuse
everyone below me" still refused every attacker the tests had. Whenever your hook compares an address with
`!=`, test one on each side of it.

### A survivor list needs reading, not a target number

Many of the survivors are **equivalent mutants**: different program text that no input can tell apart from
the original, where a test that killed them would have to assert something untrue. They are written up, one
argument each or one class each, in the three MUTANTS files - and two of the arguments rest on premises that
could rot (two flag bits staying disjoint, a fee cap staying below the override bit), so those premises are
asserted by a test rather than left as prose.

The other half of the honesty is the residue. Some survivors are not equivalent; they are simply invisible
to the oracle available - a suppressed `console2.log`, a zero-value event, a one-gas boundary. Those are
listed as what they are, and where one is killable and nobody killed it, the count says so. **A repository
that reports 100 % has usually deleted the second half of the job.**

And **run the pass again after you fix what it found.** The second pass on `ToyVault` found a gap the first
one had created: every test written for the first survivor list aimed at "withdraw exactly your whole
credit", so nothing took PART of a credit, and `have < amount` -> `have != amount` sailed through. Closing
one blind spot is how you acquire the next one.

### `--brutalize` and coverage, in one line each

`--brutalize` fills dirty memory with junk instead of zeros, which catches code that reads past what it
wrote. Both suites pass under it (95/95 and 61/61) and it costs no extra time - there is no reason not to run
it. `forge coverage --report summary` costs about 30 s here, and it is the cheapest way to find a switch
nobody flips: it is what showed `v4/src/HostileHook.sol` at **3.70 % of lines**, a switchboard with one test
against it, now at **72.97 %**.

## Scripts

The runners live in `../scripts`. `battery.sh` is the phase gate, `fuzz-long.sh` the overnight run,
`census.sh` the campaign's census added up over every run, `bench.sh` the per-agent copy, `release-guard.sh` and `assert-fresh-build.sh` the two publication guards, and
`selftest.sh` proves the guards go red when they should (every guard that can be exercised offline). The text
they read from forge - the test summary, the invariant `(runs, calls, reverts)` line, the `--sizes` table, the
sandbox ledger - is parsed in one place, `scripts/lib/parse.sh`, against real and near-miss samples in
`scripts/test/fixtures/`: a shape it does not recognise is refused, never read as 0.

## Not covered yet

The hostile token is a switchboard, not a catalogue. Behaviours that real tokens have and this mock does not model
yet, in rough order of how often they bite:

- **rebasing / shares accounting** - balances that change with no transfer at all (a global index applied in
  `balanceOf`);
- **the recipient's view inflating per move** - `viewOverstateAfterMove` is keyed on the SENDER having moved; a
  vault-side lie that grows with each deposit is only approximated by `balanceLieToCaller` with a fixed value;
- **a per-wallet transfer fee** - `feeBps` is global;
- **revert on zero-value transfer**, **revert on approve from non-zero to non-zero**, **`type(uint256).max` meaning
  "my whole balance"**;
- **sender blocklists** - only the recipient side (`blockIncoming`) and the global `paused` exist.

If your hook's spec names one of these as in scope, add the switch and its test before you trust a green campaign.
Contributions of switches, each with its one test, are the most useful kind.

