# Lessons

Each of these cost a round, or nearly cost something worse. They are written with the mistake that taught them,
because a rule without its mistake attached is a rule people talk themselves out of at 2 a.m.

---

## 1. Measure before you decide, including about yourself

**The mistake.** Two "holes" were raised as targets for the next round on the strength of reading a report and
thinking hard. Both already had owners: one was handled in the code, on a line that had been there for a dozen
revisions, and the other had been closed by an invariant three rounds earlier. Both were withdrawn.

**The rule.** "The last round did not look at this" is not "nobody looked at this". Before you aim a round at
something, grep the earlier reports for it. It takes five minutes and it is the cheapest check in the method.

The same rule applies to design changes: build the variant, measure the size and the gas, *then* argue about it.
Features get built and reverted because they do not fit, and that is a normal, healthy outcome. An argument about
whether something fits, conducted without a measurement, is not.

---

## 2. A probe that falsifies a fix does not validate your diagnosis

**The mistake.** A proposed change was dropped after a probe showed it did not produce the expected behaviour. The
stated cause was confidently wrong. The next round traced the actual mechanism: the failure happened one call
earlier than assumed, inside a different contract. The correct fix was cheap, was in the same neighbourhood, and
had been considered and discarded on the strength of the wrong diagnosis.

**The rule.** The probe tested the *fix*. It said nothing about the *cause*. Mechanisms are established with a
trace, not with an inference from an outcome. When you cut something, write down what you measured and what you
inferred, separately, so a later round can attack the inference.

This is the single most expensive mistake in the file, and it is expensive precisely because the probe felt like
evidence.

---

## 3. The same seed is not the same campaign when the code changes the logs

**The mistake.** A long fuzz campaign failed on a new revision. To find out whether the failure was new, the same
seed was run against the previous revision: clean, 1000 runs. Conclusion drawn: the bug is new. Wrong.

The fuzzer's dictionary is fed by the values it sees, including those in emitted events. The revision had changed
the events. Same seed, different campaign; the comparison discriminated nothing.

**The rule.** To compare two revisions, take the failing sequence, **reduce it**, and turn it into a deterministic
test. Run *that* against both. In this case the reduced sequence failed identically on both revisions, which
proved the problem was old - and it was actually two problems, see lesson 6.

---

## 4. Hand-copied numbers rot

**The mistake.** Sizes, gas figures, test counts and limits were quoted in a spec, a manifest, a runbook and a
project readme. Each revision updated some of them. Two consecutive rounds found wrong numbers in the documents,
and a wrong number in a document that ships with the code is a real finding, because operators act on documents.

**The rule.** Every number you write is read from an output in that session, never from memory and never from
another document. Keep an explicit list of every place a volatile number appears, and run a grep for the previous
values as a gate before closing a phase: each hit is either corrected or marked as history on purpose.

---

## 5. A guard that compares two copies does not see them change together

**The mistake.** After promotion, a guard compared the canonical copy against the working sketch and failed the
battery on any difference. It worked. It also could not, by construction, detect a change applied to **both**
copies - which is exactly what a careless bulk edit does.

**The rule.** A drift guard needs an anchor outside the two things it compares: a manifest of hashes, written once
at promotion, reviewed by a human, and checked against both copies. And make the guard fail when it should: add a
difference on purpose and confirm the battery goes red. Check it covers **added** and **deleted** files, not only
modified ones - a guard that loops over the files it knows about is blind to a new one.

---

## 6. An old build directory can make you simulate the wrong code

**The near miss.** The final dry run before handoff printed a runtime size belonging to the **previous** revision.
The source guard was green: the sources were correct, the manifest matched, everything a human would look at said
the right thing. The build tool had printed "no files changed, compilation skipped" and reused an artifact from an
earlier build of a *different* file in the same project.

If that had been a real deployment instead of a simulation, it would have published bytecode nobody had audited,
with every check green.

**The rule.** *A guard that validates sources does not validate what the compiler reused.* Clean the build
directory inside the deploy-simulation script, and make the last gate before any irreversible step compare the
**runtime bytecode size** printed by the simulation against the manifest. Prove the bytecode, not the source.

---

## 7. The test harness's arbiter has bugs too

**The mistake.** A fuzz campaign failed with an invariant violation that looked serious. The reduced sequence
showed the contract behaving exactly as specified. The bug was in the **invariant's own arbiter**: it computed
which positions were backed by reading a balance from a vantage point the contract never uses. The contract and
the arbiter disagreed about reality, and the arbiter was wrong.

**The rule.** When an invariant fails, the first hypothesis is the contract and the second is the arbiter, but the
second gets checked with the same rigour. Write the arbiter to read the world the way the contract reads it. And
note that this class of failure is *latent*: it sat undiscovered for several revisions because it needed a
specific multi-step sequence on the same actor.

The harness must also grow with the contract. For each new behaviour, a new switch in the hostile mock that
exercises it - **and a test proving the switch reaches the line**. One round measured that a guard added in the
previous revision was never once exercised across ten thousand fuzz calls. The recurring symptom, in three
separate reports, was one sentence: *the buttons the fuzzer has no longer test the surface that exists.*

Related and non-negotiable: run the invariant suite with **`fail_on_revert = true`**. With `false`, every
`require` in your handler is a silent revert instead of a checked invariant, and the suite reports success while
testing a fraction of what you think. And once it is `true` and every call is wrapped, the fuzzer's own `reverts:`
figure is 0 by construction and says nothing: what gets read every time is the campaign's census
(`scripts/census.sh`) - in how many runs each action SUCCEEDED, and whether the handler met a failure it had not
predicted.

---

## 8. Test the tests, by mutation

**The mistake.** A regression test was added for a finding, passed, and was believed. It passed for the wrong
reason: it asserted a selector, and the selector was identical for two different argument orders, one of which was
the bug.

**The rule.** For each regression test that matters, **break the thing it is supposed to catch** and confirm the
test goes red. Remove the guard, swap an argument, delete the event, change a reason code. A test that survives
its own mutant is not a test, it is a comment. Assert the full payload, not the selector. And when an auditor
hands you a mutation that survives your suite, that is a finding, at the severity of what it hides.

---

## 9. The black box sees what reading cannot

**The observation.** After more than twenty rounds of reading the code, a round that was forbidden from opening
the source, and given only the spec, found divergences that none of the reading rounds could have found.

**The reason.** Reading the code teaches you the real semantics. Once you know them, you cannot see the gap
between what the code does and what the document promises: you read the promise and fill in the meaning. The
attacker who only has the promise has to take it literally, and literal is where the gap is.

**The rules that follow.**

- Isolate the black-box agent **physically**, not by instruction. Its bench contains the spec, the ABI and the
  harness, and does **not** contain the source. Obedience is not a security boundary, and removing the files works
  in every tool.
- Deny it the earlier reports too. They are the answers.
- Run it **earlier than feels natural**. The natural instinct is to put it at the end, as a final check. Its
  findings are about the spec, and the spec is the thing every later round is aimed by - so a divergence found
  early is worth more than the same divergence found last.
- A failing black-box test does not prove a bug in the contract. It proves a **divergence between the spec and the
  code**, and deciding which of the two is wrong is the owner's call.
- Make it also play the part of an **outside consumer**: reconstruct the state from events and public storage
  alone, and compare with the views. Where two different histories leave identical logs, or where an event reads
  backwards from what happened, that is a finding - and on an immutable contract, event shape is frozen forever
  once deployed, so it is the cheapest thing to get right before and the most expensive after.

---

## 10. Write the record as you go, or lose it

**The mistake, repeatedly.** The documentation step is step 8 of 9 in the loop, and it is the one that gets
dropped when context runs short, the rate limit hits, or the session ends. It is also the only step whose output
cannot be reconstructed afterwards, because what is lost is *why* a decision was made.

**The rule.** Reports and state files are written **incrementally**, from the first minute of a round. An agent
that dies halfway then loses nothing. Put `LEDGER` and `ASSUMPTIONS` sections at the top of every report and keep
them current: what has been done so far, and what is being taken on faith.

And separate, always and explicitly, **what you measured** from **what you inferred**. Every handoff, every log
entry and every report ends with a list of what was *not* checked. The value of that list is much higher than it
looks, and it is the first casualty of wanting to look finished.

## 11. An address is an identity, not an ordering

**The mistake.** A guard read `if (msg.sender != address(manager)) revert`. A mutation tool changed `!=` to `<`, and
every test stayed green - on a hook that already had a unit test for that exact guard, an invariant campaign and a
hand-made mutant hunt. The reason: every caller the suite owned (`0xB0B`, `0xA11CE`, `0xDEAD`, the test contract)
sorts numerically **below** a freshly deployed manager and below a mined hook address. A guard reduced to "refuse
everyone below me" refused every attacker the tests had, and looked exactly like a working guard.

**The rule.** Wherever the contract compares an address, test one address on **each side** of it
(`address(uint160(target) - 1)` and `+ 1`), and assert that the two probes really are on opposite sides before you
use them. In v4 this matters more than usual: a hook's address is mined for its permission bits, which puts it in a
region of the address space that hand-written fixtures never reach.

Note what this is a lesson about. The guard in the story was **correct**. The hole was in the suite: nothing in it
could tell `!=` from `<`, so the day someone refactors that comparison, every test stays green. On a larger hook the
same mutation survived in seven guards at once - the pool-manager check, the registrar check, ownership checks, a
settlement check - against a suite of well over a hundred passing tests.

**The wider lesson.** Test fixtures are not random. Small round addresses, amounts like `1e18`, a block number that
only moves forwards, a single pool: each is a shape the suite never leaves, and a guard can be wrong everywhere
outside that shape. Mutation testing is the cheap way to find out which shapes you are stuck in.

## 12. A copied build cache is not your build

**The mistake.** A helper script copied a project - build cache included - into a temporary directory, applied a
mutation there, rebuilt and ran the tests. The build tool decided from the copied cache that nothing had changed,
reused the artifacts of the ORIGINAL source, and the script reported "the mutant SURVIVED" and "the variant PASSED"
about code it had never compiled. A false green, inside the tool whose whole job is catching false greens. It was
found only because a second agent ran the same case four ways and got two different answers.

**The rule.** Build artifacts belong to the path they were built in. After copying a project, build from nothing
(`forge build --force`, or delete `out/` and `cache/`). And make every tool that says "unchanged" prove that it looked:
if the build reports that it compiled nothing right after you changed a file, stop - that is not a result.
Lesson 6 is the same trap at promotion time; this is the same trap at test time.

## 13. A bare `expectRevert` proves that something reverted, not that your thing did

**The mistake.** A test meant to show "a pool in this configuration cannot trade" sent an order and wrapped it in
`vm.expectRevert()` with no argument. It passed. The order had been built with a missing price limit and died at the
ROUTER's own input check; it never reached the hook. The comment above the assertion described, in confident detail,
a revert deep inside the hook that the test had never once produced. A reviewer checked THAT the test passed, not WHY,
and promoted it. The next agent to touch the area measured the real behaviour, found the test was vacuous, and found a
fact about the contract that the vacuous test had been hiding.

**The rule.** Expect the exact error - the selector, and the arguments when they carry the meaning. When the revert
crosses a boundary that wraps it (a pool manager wrapping a hook's failure), assert the wrapper AND what it wraps. If
you cannot say which line reverts, you do not yet know what the test proves. A reviewer promoting a test reads the
trace of the revert once; it costs a minute.

Mutation testing catches part of this (a test that would pass for any revert kills few mutants). It does not catch
the case where the code under test is never reached at all - nothing to mutate there changes the outcome.
