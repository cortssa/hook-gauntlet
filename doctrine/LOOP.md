# The adversarial loop

Phase 4 of the route. This is the part that decides whether the effort converges or circles.

## The shape of the cycle - do not change it

**One audit round at a time.** For each report that arrives:

1. **Read the report in full before touching code.** Always. Never decide from the agent's summary: the summary
   drops the measurements, and the measurements are where the decisions are.
2. **Decide as the architect.** The auditor recommends. The owner of the product decides. Refusing a
   recommendation is a legitimate outcome and will happen often - but the refusal must be **written into the spec
   with its reason**, or the next round re-reports it and you have burned a round.
3. **Fix the cause, not the symptom.** See `TRIAGE.md`.
4. **Write a regression test per accepted finding**, citing the auditor's own test name in yours, so the mapping
   survives. `test_B01` in their report becomes `test_r07_B01_<what_it_asserts>` in yours.
5. **Run the full battery**: unit, fork, invariants. Green means 100%, not 99%.
6. **Run the long fuzz** - and **read the campaign's census**, not only `Suite result: ok`: successes per action,
   boundaries reached, unexpected reverts (`scripts/census.sh`; the examples write it from `afterInvariant`, one line per
   run - the block forge prints on the screen is ONE run, not the campaign). The fuzzer's own `reverts:` line
   says 0 whenever `fail_on_revert = true` and every call is wrapped - it is not evidence of anything. A campaign in
   which an action rarely succeeds is a suite whose handler is rejecting your inputs, which means it is testing less than
   you think.
7. **Update the spec**: one line per finding with the decision and the measured number; the hostile-actor table
   corrected by what you measured; and a section saying **where the next round should press hardest**.
8. **Update the record**: `STATE.md`, `DECISIONS.md`, `LOG.md` (with the ROUND line) - and every document that repeats a number you just
   changed (the list kept in `SPEC.md` section 8). Never leave
   this step for later. It is the first thing to be dropped when context or budget runs out, and the only thing
   that cannot be recovered afterwards.
9. **Clone the scripts and the bench for the next round** (`r07` -> `r08`, `~/hg-a07` -> `~/hg-a08`,
   `Attack07.t.sol` -> `Attack08.t.sol`) and launch the next round with a fresh brief.

## Why it converges

Four mechanisms, and they only work together.

**The spec is a falsifiable contract.** The auditor receives *sentences*, not only code, and its job becomes
falsifying the sentences. In the project this was distilled from, three of the five high-severity findings of the
whole series were of the form "the fix is correct and the sentence that closes it is false". You cannot get that
finding from code alone, because someone reading code learns the real semantics and stops being able to see the
gap between the code and the promise.

**Every number in the spec is a measured number.** A wrong number in the spec is a guaranteed finding in the next
round, which is a wasted round. Re-measure gas, sizes and limits every revision and correct the document.

**Refusals are written down.** Without this, the loop has no memory, and rounds 8 through 12 re-litigate round 7.

**The next round is aimed.** The "where to press hardest" section directs the attack at what you have least
confidence in. Auditors follow it, and they come back with a measurement instead of an opinion.

## Aiming the next round

Write the section *after* you have made the fixes, not before, and aim it at:

- **Whatever you just changed**, especially a new revert or a new guard on a hot path. A new revert in a path that
  every ordinary transaction crosses is the highest-risk edit there is: it converts a hostile case into a denial of
  service for honest users.
- **Whatever you changed without fully understanding**, if you are honest that this happened.
- **The trade-offs you accepted**: ask the round to confirm each one is still exactly as bad as the document says,
  with the number. If one is *worse* than documented, that is a finding.
- **The parts nobody has attacked yet.** Track this explicitly; "the last round did not look at X" is not the same
  as "nobody has looked at X", and checking the earlier reports before you aim takes five minutes and stops you
  sending a round after something that already has an owner.

## The record of rounds

Every round leaves one ROUND line in `LOG.md` (`state/README.md`; `scripts/round.sh` writes it validated, and
`scripts/round.sh --json` reads the history back as JSON, computed on demand, never stored). The record exists so that
"which round next" can one day be chosen from the history - which type of round found the most per token, at which
phase, on which model, and how often a verdict's own `conf` was borne out - instead of by eye. Today it is a record, not
a policy: nothing reads it to decide anything; the next round comes from `NEXT.md` and is aimed by the section above.

## Exit

The loop ends when a **discovery** round closes with zero high and zero medium findings, and no REASONED high or medium is left open (`EVIDENCE.md` 3). Regression rounds verify
fixes; they cannot close the loop, because they inherit what earlier rounds believed. Apply it without softening. See `SEVERITY.md` for what those words are allowed to mean.

Do not tell the round that a clean result ends the series and then ask it to be honest. Tell it both, explicitly:
*"if your round closes clean, this phase ends; do not soften to make that happen and do not inflate to avoid it."*

The **black-box** round (phase 5) does not wait for this: it runs EARLY, after the first or second round, because
its findings are about the spec and the spec aims every later round. `NEXT.md` is the one place that says when each
thing happens; if any sentence anywhere disagrees with that table, the table wins and the sentence is a bug. After
the exit criterion is met - and a second black-box only if the promises or the events changed since the first - the
remaining phases are, in order: **promotion** (phase 6), **rehearsal** (phase 7), **handoff** (phase 8).

If the black-box round finds divergences between the spec and the code, that is normal and it is the point. Decide
per divergence whether the *code* is wrong or the *document* is wrong. A divergence closed by correcting the
document costs zero bytes and is often the right answer; say so in writing, with the reason, rather than quietly
editing the sentence.

## Hygiene when rounds run in parallel

Only do this if you must, and then:

- **One copy per agent** (`~/hg-a07`, `~/hg-a08`), with the dependency directory symlinked from a shared one.
  Never compile in another agent's copy: the build tool clears artifacts and you will corrupt a running round.
- **Hash the tree at the start, guard it at the end.** The round's last step prints "snapshot unchanged", an empty
  diff against the live tree, and zero files touched in other copies.
- **Make each agent declare edits it saw land underneath it.** Parallel work by the architect will be visible to
  an auditor; a declared observation in the report is fine, an undeclared one is confusion later.

## The brief is the lever

A round is as good as its brief. Keep briefs to roughly 40 lines and include, always:

1. what changed since the last round, and what the target is;
2. what is already **accepted**, so it is not re-reported;
3. the non-negotiable rules (bench, what may be written, no keys, no broadcast, no installs);
4. **where to press hardest**;
5. the **exit criterion**, stated honestly;
6. the **baseline to reproduce first** (test count, contract sizes, one gas figure) - an agent that cannot
   reproduce the baseline has a broken bench and its findings are worthless;
7. the severity rule, explicitly (see `SEVERITY.md`), because without it severity inflates and the exit criterion
   stops meaning anything;
8. the platform gotchas that will otherwise eat an hour;
9. **write the report incrementally** - an agent that dies on a rate limit then loses nothing.

`briefs/audit-round.md` is that structure as a template.
