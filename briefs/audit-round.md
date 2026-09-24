# Brief template: audit round (phase 4)

Copy, fill every `{{PLACEHOLDER}}`, delete the notes in *italics*, keep the rules. The `doctrine/...` paths below are relative to the kit checkout, `{{KIT}}`. The rules are the length; what you add is the placeholders, nothing more.
Give it to an agent with a **fresh context**. Do not paste the previous report into the brief; point at it.

---

# AUDIT {{ROUND}} - attack `{{TARGET}}` with Foundry (adversarial, independent) - MODE: {{DISCOVERY_OR_REGRESSION}}

*Two kinds of round, and the orchestrator picks ONE per brief. **DISCOVERY**: the auditor gets the spec, the code, the
attack prompts and the spec's assumptions, and NO earlier report, no list of accepted findings (the phase-3 `pending` findings ARE named: they are open, not accepted), no account of what
changed - delete those sections. A reviewer who reads what the last one thought inherits the last one's blind spots;
rediscoveries are the price, and the orchestrator de-duplicates afterwards. Round 1 is a discovery round by nature,
and **the round that closes the loop must be one**. Point at least one discovery round at the spec's "does not apply"
list and at its assumptions, with the instruction to break them (`doctrine/EVIDENCE.md` 6 and 8). **REGRESSION**: the
sections below as written - aimed at the diff, told what was accepted. It verifies fixes; it does not count as an
independent look.*

You are auditor number {{ROUND}} of this series. Read FIRST, in this order:
`{{PREVIOUS_REPORT}}` (your predecessor - *in round 1 there is none: delete this item and the "re-verified" section
of the deliverables*), `{{SPEC}}` (the contract this code claims to honour, and your main
weapon), then every file in `{{SRC_DIR}}` and `{{TEST_DIR}}`. Method and vocabulary: `doctrine/LOOP.md`,
`doctrine/TRIAGE.md`, `doctrine/SEVERITY.md`.

## What changed since the last round, and is therefore your target

*One short paragraph per change. Be specific: name the function, say what the new behaviour is, and say what you
are afraid it broke. A new revert or a new guard on a hot path goes first.*

1. {{CHANGE_1}}
2. {{CHANGE_2}}

## Already accepted - re-examine, do not re-report

*List the IDs of findings that have been accepted as trade-offs or refused with a written reason. Without this
list you will pay for rediscoveries.*

{{ACCEPTED_IDS}}

## Where to press hardest

1. **{{PRESSURE_1}}** *- what the architect has least confidence in.*
2. **{{PRESSURE_2}}**
3. **The closing question: can a counterparty deny service or drain value?** {{N}} rounds say no (round 1: 0). Try again with
   what you learn (regression: from the changes above; discovery: from your own first routes), and say in the report **how many distinct routes you tried**.
4. **The open trade-offs.** Confirm each is still exactly as the spec describes, with your own number. One that is
   **worse** than documented is a finding.
5. **The spec as a document.** It ships with the code. Any line of it that does not reproduce is a finding.

## Rules (non-negotiable)

- Work **only** in `{{BENCH}}`. Never compile in another agent's bench or in the shared one. Dependencies by
  symlink.
- Read-only on the bench (the copy of the project you were given) except your own scratch directory `{{SCRATCH}}` and your report `{{REPORT}}`. `{{SCRATCH}}` is `test/audit/<round>/` INSIDE the bench: forge compiles `test/`, so your tests run with plain `forge test --match-path 'test/audit/<round>/*'`; nothing under `.gauntlet/` is in the bench, and the project's own `test/` is not yours to change.
- No mainnet writes, no keys, no broadcast, no installs, no browser.
- **Reproduce the baseline before attacking anything**: `{{BASELINE_TESTS}}` tests pass, `{{BASELINE_SIZES}}`,
  `{{BASELINE_GAS}}` (from the fork when the project has one; otherwise the gas of the hook's hot path in the battery's own tests, labelled `local`). If you cannot reproduce it, your bench is wrong and your findings are worthless - stop and
  report that.
- **Every claim is a Foundry test that PASSES.** No red tests in the report. A test that proves a bug asserts the
  wrong behaviour and is named so that this is obvious.
- Measured numbers only. Gas from the fork when there is one, never from the mock; the mock is inflated and is never a reason to
  change the contract.
- Where economics decide exploitability or severity: gas costs converted to money at two gas prices, so that "cost to attacker vs cost to victim" is a decision and
  not an intuition.
- **Severity:** a finding that needs the **asset's own code** to be hostile and only closes **that asset's own
  market** is **low**. Medium and high are for a counterparty that denies or drains, or for third parties paying - and
  a hook that POOLS every holder of one token makes that token's market everyone's money: a shortfall the last claimer
  eats is high whoever profited (`doctrine/SEVERITY.md`, "a loss with no beneficiary is still a loss").
  {{SEVERITY_ADAPTATION}}
- **Write the report incrementally**, from the first minute, with `LEDGER` and `ASSUMPTIONS` at the top. If you
  die on a rate limit, nothing is lost. Retry once on a rate limit.
- Platform gotchas: {{GOTCHAS}}

## Exit criterion - told to you honestly

This phase ends when a **discovery** round closes with zero high and zero medium findings, and no REASONED high or medium is left open. Your round may be the one that ends it. **Do not soften to make that happen and do not inflate to
avoid it.**

## Deliverables

`{{REPORT}}`, plus your tests and raw outputs in `{{SCRATCH}}`.

The report contains: `ASSUMPTIONS`, `LEDGER`, the previous round's findings re-verified **in the code** one by
one, then your new findings in the format below, then measured sizes and gas, then a verdict on whether this code
is ready for the next phase, and closes with the three fixed subsections below.

Finding format, one per finding:

```
ID · severity · claim (one falsifiable sentence)
who loses · cost to the attacker (gas, and money at two gas prices) · conditions required
fix you recommend, or "documented trade-off" with the number
test: <name>, in {{SCRATCH}}, and it PASSES
raw: <pasted output, not summarised>
```

Label every finding with its evidence (`doctrine/EVIDENCE.md`). A bug you reproduced with a test that passes on the current code is TESTED - and TESTED alone is the weakest label with a test: it becomes MODEL-TESTED only when an independently written reference model agrees, PROPERTY-TESTED when a fuzz campaign holds it, never PROVED, a word reserved for formal proofs. A finding you could not turn into a test is labelled
**REASONED**: give the argument in a form someone else can attack - economic and ordering attacks often cannot be
compiled, and dropping them because they would not compile is the worst outcome of a round. A REASONED high or
medium keeps the loop open until it is tested, answered by the owner in writing, or handed to the human audit by name.

### Close every round the same way

Three fixed subsections, in this order, every line carrying the evidence label it would earn in the dossier
(`doctrine/EVIDENCE.md` §1: PROVED / MODEL-TESTED / PROPERTY-TESTED / MUTATION-TESTED / TESTED / SUPPORTED / REASONED
/ UNVERIFIED). Same three headings every round, same order, so a reader comparing rounds is comparing like to like.

- **Explored.** What you actually walked this round - files read, entry points called, boundaries hit - one line
  each, with the label the coverage earns.
- **Not exercised.** What is in scope but this round did not reach - named, not left to be inferred from its
  absence - one line each, with why (time, a blocked precondition, outside the pressure list you were given).
- **Honest partiality.** What a deeper, paid review would still add that this round could not - the gap between
  REASONED and PROVED / MODEL-TESTED / MUTATION-TESTED, written as a claim someone else can attack, not as a
  disclaimer.

Goes red at the executor's gate (`briefs/executor-with-gates.md`) exactly like a red test: a report missing one of
the three, or carrying a line with no evidence label, does not pass. The report's last line is `END OF REPORT {{ROUND}}`,
written once, when it is complete: never as a placeholder. `scripts/size.sh` writes under `.gauntlet/reports/` of the
directory it runs in: in the bench that directory is yours to delete, or point `OUT_DIR` at `{{SCRATCH}}`.
