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
| **MUTATION-TESTED** | the test was SEEN RED on a deliberately broken version of the code - a plausible wrong implementation of THIS claim | the minimum for a test to count at all |
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
