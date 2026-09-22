# Brief template: verifier (a short round, after fixes)

Use this when an audit round voted "ready, with corrections" and the corrections have been applied **after** it
finished. Nobody has attacked the corrected code. The verifier is not the agent that confirms your work: it is
the agent that **re-derives** it.

Run it on a model from a **different vendor** than the one that produced the fixes, whenever you can. This is the
round where shared blind spots are cheapest to break, because the surface is small.

---

# VERIFY {{ROUND}} - re-derive the corrections applied to `{{TARGET}}` (adversarial, short)

The previous round voted "{{PREVIOUS_VOTE}}". The corrections were applied **after** it ended, so nobody has
attacked them. You are not here to confirm. **Assume I applied them badly, that the new text lies, and that the
previous round let something through.**

## Read

1. `{{PREVIOUS_REPORT}}` - what was asked for.
2. `{{REVISION_NOTES}}` - what was done, and the text proposed for the spec.
3. `{{DIFF}}` - the diff from the previous revision to this one. Confirm that it touches only the files it claims
   to touch.
4. All the code, freely. The spec, to compare against the proposed text.

## What you verify

1. **The edits are exactly the ones that were measured, and nothing else came in.** Compare against the variants
   the previous round measured. Is there any semantic difference between what was measured and what was applied?
2. **The edit that touches control flow.** *Name it.* This is where the risk is. Ask: does it swallow a failure
   that should have propagated? Does it have enough gas left to fail with a name in the worst case? Can it let
   execution continue in an inconsistent state? Does it change the read-only path as well as the write path?
3. **Every new number.** Sizes, gas on the fork, limits, boundaries. Did any documented boundary move? The cost of
   the change on **ordinary honest transactions**, measured against the previous revision, test by test.
4. **The new regression tests assert what their names claim.** A test that passes for the wrong reason is worse
   than no test. **Mutate**: remove the guard, swap an argument, delete the event, change a reason code. Does each
   regression catch its own mutant? Report any mutant that survives - that is a finding.
5. **The new text, sentence by sentence.** Falsify each one against the code as it now stands. Are all the
   corrections the previous round asked for present, and are they right?
6. **An honest wallet that this change now treats differently.** Every new guard refuses someone. Say who, and
   whether that is coherent with the rest of the design.

## If there is a competing candidate

{{CANDIDATE_BLOCK}}

*Use this block when the owner has to choose between two versions. Describe candidate B, say where its diff is,
and instruct: apply it in your own bench, run the whole battery and the invariants, then attack it - (a) what
changes for an **honest** party; (b) does it open any new door (a failure path that now returns a value where it
used to revert, a zero that now passes a check); (c) do the existing tests still assert what they claim? Write the
regression that is missing.* **Vote separately on A and on B.** The owner decides with your vote in hand, and the
chosen one is promoted **verbatim**.

## Rules

- Bench `{{BENCH}}`. Never compile in another bench. Do not use the promotion battery if its drift guard is
  designed to fail while the sketch is ahead - use the development runner `{{DEV_RUNNER}}`.
- You write **only** in `{{SCRATCH}}` and in your report. Never in the canonical copy.
- No mainnet writes, no keys, no broadcast, no installs, no browser, no commits.
- Baselines to reproduce: {{BASELINES}}.
- Every claim is a test that passes AND has been seen red on the broken version, with both raw outputs pasted.
- Platform gotchas: {{GOTCHAS}}

## Deliverables

`{{REPORT}}`, written at the start and updated at the end of each numbered point above, `LEDGER` and `ASSUMPTIONS`
at the top. Findings in the format of `briefs/audit-round.md`. A clear **vote**: ready / ready with corrections /
not ready - and, if there are two candidates, one vote each. Final summary of at most 20 lines.
