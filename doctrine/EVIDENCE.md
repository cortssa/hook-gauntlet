# Evidence: what counts, how much, and how an agent fools itself

**This process does not measure security. It measures how much of your stated security model you managed to test.**
It can therefore be confidently wrong when the model is incomplete, when the oracle is wrong, or when the states you
tested exclude the attack. Everything below exists to make those three failures visible instead of green.

"No model is the judge" is the working rule, and execution is the best judge available. But a test is written by
someone, and that someone is usually the agent being judged. So the rule in full is: **no model is the SOLE judge, and
no single oracle is trusted.**

## 1. The labels

Every finding, every row of the spec's "proved by" column, and every claim in the dossier carries one:

| label | means | strength |
|---|---|---|
| **PROVED** | a symbolic or formal proof, with its bounds stated next to the word | for the stated bounds only |
| **MODEL-TESTED** | the contract agrees with an independently written reference model over generated inputs (section 5) | strongest against a shared misconception |
| **PROPERTY-TESTED** | the claim survived generated sequences over a stated domain, with the success and reach censuses attached | |
| **MUTATION-TESTED** | the test was SEEN RED on a deliberately broken version of the code - a plausible wrong implementation of THIS claim - by its own assertion, not by a revert of the broken code (`kill: assertion`, §2) (a finding's test: red on the code as it is, green on a fix variant with the everyday suite green on it too, the exact failure expected, and in a test of its own the same call on the same shape accepted, only the finding's condition different, §2) | the minimum for a test to count at all |
| **TESTED** | a test passes and nobody has seen it fail | **not evidence.** A label for work in progress |
| **SUPPORTED** | static analysis, a fork observation, a measurement that is consistent with the claim but does not isolate it | |
| **REASONED** | an argument, written down, that someone else can attack. Economic and ordering attacks often live here | real, and the auditor should know it is not more |
| **UNVERIFIED** | said, not checked | |

Do not force all security knowledge through a unit-test-shaped hole. A finding you cannot compile is still a finding:
label it REASONED, give the argument, and let it block (section 3).

## 2. Seen red, or it does not count

A test is evidence only after it has failed on code that is wrong in the way the test claims to detect.

- The mutant must be a **plausible wrong implementation of the claim**, not any breakage. `fee = 0` kills almost every
  fee test and proves nothing about the cap. For a boundary claim, move the boundary (`>=` to `>`); for an accounting
  claim, alter one term or one sign; for an ordering claim, move the state write across the external call; for an
  authority claim, change who may call. If the claim is high-stakes, kill one mutant from each family that applies.
- Expect the **exact** failure. A bare `expectRevert`, an assertion that does not depend on the code under test, a
  `bound()` that removes the interesting case, a handler `catch` that swallows the failure - each passes for the wrong
  reason (`LESSONS.md` 8, 11, 13).
- An agent that writes the test does not also certify it. The mutant is run by the executor's gate
  (`briefs/executor-with-gates.md`), and its output is pasted, not summarised.
- **The red has to come from a build that contains the mutant.** `scripts/mutate.sh` builds every mutant with
  `--force`, and a mutation run by hand starts from cleared `out/` and `cache/`; gas identical to the baseline to the
  unit is a reason to check the build before calling a mutant equivalent. The rule comes from one incident
  (2026-09-22): a subagent's batch of eight mutants of a contract the test deploys with `new` all reported SURVIVED
  with baseline gas, and five died on a cleared build. **The cause was not established.** The story told at the time -
  incremental builds keeping the stale creation code of a `new`-deployed contract - did not reproduce: the same shape
  on a dirty tree went red on the incremental build exactly as on the clean one. A mutation applied to a file forge
  never compiled explains the same symptoms. Treat the forced build as a cheap precaution and the incident as a
  symptom with an unknown cause, not as a measured property of forge.
- **A kill has a reason, and only an assertion's counts.** A mutant can turn a test red without the test's claim
  having anything to do with it: the broken code reverts - the pool manager's `CurrencyNotSettled`, a custom error, a
  bare `EvmError: Revert`, a handler call an invariant run counts as unexpected - and every test that touches it fails,
  whatever it asserts. `scripts/mutate.sh` reads, for each failing test, why it failed and writes `kill: <reason> -
  <the failing test>` in the mutant's report: `assertion` (an assert failed - `assertEq`, `assertTrue`, `panic:
  assertion failed`; and an expected revert that did not come, or came with another error: the test's oracle WAS that
  revert, and it broke), `revert` (the code reverted where the test expected nothing - and any message not read as an
  assertion's: `assertTrue(x, "msg")` prints only `msg`, as a `require` does; a comparison is an assertion's only when
  the message ends in two VALUES as forge prints them - `msg: 2 != 1`, `-5 < 3`, `0x...`, `true`, `[1, 2]` -, so a
  `require` whose string reads `fee > cap` or `f == 0` is a revert, and so is `assertEq` of two strings with a message
  of its own; outside an invariant prefer the assertions that print a comparison of values. A `require` whose own string
  ends in two values, `"0 != 1"`, still reads as an assertion: the `kill:` line shows the message - read it), or `setup`
  (`setUp()` failed: nothing was tested). **MUTATION-TESTED
  requires every kill it cites to be `assertion`**; a mutant killed only by reverts is written `KILLED (revert)` and
  does not count toward the label (measured on a first real case: an invariant labelled MUTATION-TESTED by a mutant the
  manager's revert killed, not the invariant's assertion).
- **A survivor that cannot die is a bad question, not a finding.** When a mutant survives, first ask whether the
  code can still reach the difference at all. A mutant that turns "due at or before this step" into "due at exactly
  this step" is equivalent the moment the loop visits every step, and it will sit in a brief reporting SURVIVED
  forever. Replace it with one that can fail, and say in the brief why the old one was retired.
- **A pattern that never matched is not a mutant.** `mutate.sh` matches a line at a time, so a two-line pattern
  matches nothing and the run exits 2. That is not a survivor and not a kill; it is a broken question, and a brief
  that prints its exit code without reading it will carry the hole for as long as nobody looks.
- **A test that returns early is a pass with zero assertions, and that pass is a lie.** The shape is always the same:
  a precondition the environment may not meet - no fork URL, no RPC, a feature flag off, a `.call` that returned false
  and was not checked, a `view` callee reached through `STATICCALL` that could not write - and a guard that `return`s
  instead of failing or skipping. The suite prints PASS in microseconds, the battery counts it, and nothing was tested.
  Measured 2026-09-22 on a fork test: 4 passed in 966 µs without `--fork-url`, zero assertions reached. The rule: a
  precondition that is not met is `vm.skip(true, why)` - a skip the battery refuses unless accepted on purpose
  (`ALLOW_SKIPS`), never a `return`; and a harness that calls into the contract under test checks the success flag of
  every low-level call, so that a harness that silently does nothing cannot report a green.
- **A finding's test gets past TESTED on a FIX variant, not on a mutant - by two runs, and a named failure.** A
  finding's test is red on the code as it is - the code is the broken version - and that red alone does not show the
  test fails FOR the claim. `scripts/pending-red.sh` runs a test in `pending/` and records its red, keyed by the file
  and `src/`: the record is what makes "red on the code" a fact the route can read (`next.sh` refuses a pending test
  without a current one, and `pending-red.sh` refuses one that passes on the code: it is not a finding's test). It is **MUTATION-TESTED** when all three hold, the outputs pasted:
  1. **Red on the code, green on a fix variant.** A plausible fix of THIS claim, one line, built by `scripts/mutate.sh`
     on a throwaway copy - never applied to `src/`, the owner absent or not (the fix is the owner's decision, `NEXT.md`
     row 6b) - with `TEST_FLAGS` naming that test's file (its control runs with it): `FOUNDRY_PROFILE=pending EXPECT=green BASELINE_MAY_BE_RED=1
     TEST_FLAGS="--match-path pending/<id>.t.sol" scripts/mutate.sh <proj> src/<Hook>.sol '<old>' '<fix>'`. Its baseline
     shows the red, `VARIANT PASSED` the green.
  2. **The everyday suite green on that SAME variant** - a second run, the same strings, `EXPECT=green`, no
     `BASELINE_MAY_BE_RED`, the battery's profile and filter (none: `EXPECT=green scripts/mutate.sh <proj> src/<Hook>.sol
     '<old>' '<fix>'`) -> `VARIANT PASSED`. A "fix" that deletes the test's subject - refuses every pool but the test's
     own, switches the function off - turns the finding's test green and breaks the everyday suite: it is not a fix, and
     the label is not earned (measured: a variant that let only the test's own pool initialize turned a
     stranger-initializes finding green alone, and the everyday suite red). The first run says it is half.
  3. **The finding's test expects the exact failure, and carries a tight control.** The exact failure:
     `vm.expectRevert(MyHook.NotRegistered.selector)` (or the exact bytes), an exact amount - never a bare
     `vm.expectRevert()`, a low-level `.call` whose success flag is only asserted false, or a `catch` that does not
     compare the error: each is green on ANY revert, the fix's or an unrelated guard's. The control: the SAME call on
     the SAME shape - the same key or pool shape, the same terms, the same caller - ACCEPTED, only the finding's
     condition different. Both, because the exact error excludes an unrelated guard only when that guard's error
     differs; the control excludes it when the error is the same. A control that changes more than the condition lets
     through a guard keyed to what else it changed. Measured on "a live launch cannot be registered again" (exact
     selector `BadTerms`): a control on a fresh key with another fee let two non-fixes pass both runs - a guard on the
     test's treasury and fee, and `if (l.treasury != address(0) && key.fee == 3000) revert BadTerms();` (any
     registered pool of the test's fee); the tight control - the same pool shape registered twice while NOT live,
     accepted - turned both red in the first run, and the true fix (`if (l.start != 0) revert BadTerms();`) passed both
     runs. **The control lives in the finding's own test file, in a test of its own**: the first run's `--match-path`
     runs the whole file, so a sibling test runs with the finding's. A control in another file does not run there and
     proves nothing (measured: a same-error guard passed the first run with its control in a file of its own). A
     control placed before the finding's call, in the same test, lets a guard that counts calls through (measured: a
     guard refusing a caller's third registration, live or not, passed both runs that way, and failed on the same
     control in a test of its own). What no control excludes: a variant keyed to the test's exact values (an
     address only the test uses) - that is why the label is evidence, not proof, and why condition 1 asks for a
     plausible fix. The first run warns on a test file that accepts any revert (`mutate: WARNING - ... accepts any
     revert`), reading its code, not its comments or strings - a heuristic that knows a few shapes only: its silence is
     not evidence, and not the control.

  **While a permission-bits finding is open** (the v4 harness refuses to deploy a hook that implements a callback
  without its bit - `V4Harness: <callback> implemented but its permission bit is not set`), every test that deploys
  that hook fails in `setUp()`, the pending tests of OTHER findings and the everyday suite included, and
  `scripts/pending-red.sh` records no `setUp()` failure as red - on this refusal it prints the harness's whole line and
  points here. The path, in this order. First the bits finding's own test, `pending/<id>.t.sol`: its own `setUp` sets
  `_skipPermissionCheck = true` before it deploys (without it the test dies in `setUp` and nothing is recorded), then a
  test function of its own calls `_checkHookPermissions(address(hook));` directly, with no `vm.expectRevert` - the
  harness's `function _checkHookPermissions(address hook) internal` - so that test fails on the harness's own line (one
  wrapped in `vm.expectRevert` passes, and a passing test is no finding's test); another may show the callback never
  running; `pending-red.sh` records that red, and its record carries the line
  (`permission-bits: ...`). The finding is then OPEN AND RECORDED. Then the flag in the suites: any suite that deploys
  the hook - the other pending tests, the everyday suite under `test/` - sets `_skipPermissionCheck = true` in `setUp`
  with a header line `// _skipPermissionCheck: <id> open`, and the hook runs as the manager would really drive it, the
  callback never called. Then the battery. That record stays current while `src/` is what its `anchor:` line says and
  `pending/<id>.t.sol` is unchanged: its red comes from the harness and `src/`, so the flag going into `test/`, or any
  later edit there or elsewhere in `pending/`, does not stale it (every other pending record is keyed to all of
  `src/`, `test/`, `pending/` and the configuration). `scripts/battery.sh` holds that rule: a file under `test/` that
  assigns the flag (any assignment, not only `= true`) with no such record is refused, saying which part of the record's
  key changed when there is one and naming `pending-red.sh` with the finding's file; with it the battery ends `BATTERY
  PASSED - green UNDER open permission-bits finding <id>`, and the dossier says the green is that. Drop the flag when
  the fix lands; a suite that keeps it after the fix is a smell the round names.

  In the layout `QUICKSTART.md` 7b recommends - the kit vendored beside the project, remappings through `../` - BOTH runs
  need `COPY_ROOT=<the directory that holds the project and the kit>` (run from the project: `COPY_ROOT=..`): without
  it the copy does not compile, `NOTHING PROVEN` (rc 2). A fix that turns other findings' tests green too is said with
  them; a test no fix variant passes both runs for stays TESTED.

## 3. What blocks the exit

The loop does not end while any of these is open:

- a high or medium finding that reproduces - as before;
- a **REASONED high or medium**. It closes in one of three ways: it becomes a test; the owner accepts the argument
  against it, in writing; or it is handed to the human audit by name, in the dossier's "what was NOT checked";
- in full mode, a judge marked "not done" with no reason from the owner (`JUDGES.md`).

**Acceptances are the owner's words.** Record who, when, the rationale as they gave it, and the residual risk. An agent
never writes an acceptance on the owner's behalf, never infers one from silence, and never treats "ok, continue" as
acceptance of a specific risk. If you did not ask about THIS finding and get an answer about THIS finding, it is open.

## 4. The spec may get weaker only with the owner's explicit yes

"The code is right and the sentence promised too much: fix the sentence" is legitimate engineering, and it is also the
easiest way for an agent to make a finding disappear. So classify every edit to a promise, an invariant, an admission
rule or an accepted trade-off:

`strengthens` · `preserves` (wording, numbers re-measured) · **`weakens`** - removes a requirement, narrows the domain,
adds an exception, raises an acceptable loss, widens who is trusted, moves a guarantee from the code to an operator.

Anything that weakens, **or that you cannot classify with confidence**, goes to the owner as a question that quotes the
old sentence and the new one. "I clarified an ambiguity" is what a weakening looks like from the inside.

## 5. An independent oracle for anything that does arithmetic or custom accounting

An agent can write the implementation, the invariant, the test and the expected value from one mental model, and all
four will agree on the same mistake. For a hook with its own arithmetic (fees, shares, prices, rounding) or its own
accounting (deltas, custody, claims), at least one security-critical property must be checked against a **reference
model that does not share the production code's structure**: a deliberately dumb re-implementation - in Solidity inside
the test, or in another language - fuzzed side by side with the contract, state transition by state transition.
Write it from the SPEC, not from the code, and preferably in a fresh context. Disagreement is a finding about one of
the two; agreement is the MODEL-TESTED label.

## 6. "Does not apply" is a claim, and it gets attacked

An attack class (`HOOK-ATTACKS.md`), a judge, a phase: marking one "does not apply" needs an **architectural
predicate** someone can check, not a search result.

- good: *"no externally controlled code runs between the write at L210 and the read at L244: the only calls in between
  are to the pool manager, which is trusted by construction (spec 2)"*;
- worthless: *"no reentrancy: grep found no `.call`"* - in v4 a token transfer, a settle, a take, a callback into the
  hook and a nested unlock are all places where someone else's code runs.

State the predicate, the evidence for it, and the counter-example you tried. One discovery round (`briefs/audit-round.md`)
is pointed at the does-not-apply list and at the spec's assumptions, with the instruction to break them.

## 7. Reached, not just succeeded

The success census (`INVARIANTS.md`) catches an action that never works. It does not catch four thousand successes that
were all tiny, all in one pool, all on one side of every branch. Keep a **reach census** next to it:
`_noteReached("fee at cap")`, `assertReached(...)` - set from INSIDE the real action paths when the state is observed,
never from a function that exists to set it. List the boundaries worth reaching in the spec: both sides of each key
branch, minimum and maximum of each bounded quantity, more than one pool, more than one position, the state right after
a hostile switch flips. A boundary reached only in a purpose-built unit test is a unit test; say so.

## 8. The model itself

Section 5 of the spec lists admission rules; section 7 lists what is out of scope. Add to the spec, next to them, the
**assumptions the whole document stands on** - which assets matter, which actors exist, what is trusted and why, what
the token is assumed to do, what liquidity or price conditions are assumed - each with what breaks if it is false.
That table is an attack surface like any other: the discovery round that attacks the does-not-apply list attacks it too.
It is the only defence this kit has against proving the wrong theorem beautifully, and it is a weak one. The strong
one is the human audit, which is why the route ends there.

## 9. Silence is a refusal - and what the records prove

**Silence is a refusal.** A record the route needs and cannot find is never a pass. From phase 2 (`NEXT.md` row 4b)
`scripts/next.sh` refuses a missing `.gauntlet/spec.sha256` or `src.sha256`, and the battery and `pending-red.sh` refuse a
missing `src.sha256`; a report a check reads (`01-build.txt`, `02-test.txt`, the census reports, `06-threats.txt`) is a
record only with the seal its script wrote beside it, `<report>.sha256` - its SHA-256 with the anchor of `src/` it ran
on - and is read as missing without one, with one that does not match it, or with one made on another `src/`; and
`last_audit_round`, the ceiling's `M used`, `blackbox` and `bytecode_changed_since`'s `last_audit_round` are held to
the ROUND lines `scripts/round.sh` writes. Said plainly: the anchors prove currency, not authorship. Every input of a seal,
an anchor or a red record is public, so a model that computes a sidecar by hand gets past it - the seals turn an
accidental fabrication (a report a model typed) into a deliberate act, and stop there; and a line 1 of `spec.sha256` or
`src.sha256` rewritten by hand, with no `re-recorded` line under it, is caught by no hash at all. The ROUND lines are
text too, and so are the `src/ at round <id>:` line under each and a `round <id> stopped` note: any of them can be typed
by hand, and `next.sh` reads what is written. The defence there is the verifier who confronts the ROUND lines with the
sealed reports (a round with no report, a report with no round, a count that does not add up). The defence against
a deliberate fabricator is not cryptographic: it is the verifier who reproduces the numbers from the commands
(`VERIFY.md`), and the owner who reads `LOG.md` and the dossier.
