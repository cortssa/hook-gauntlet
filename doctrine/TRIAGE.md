# Triage: the three answers to a finding

Every finding in every report gets exactly one of three answers, and the answer is written down. Rewriting the spec
so that the finding stops being one is NOT a fourth answer: anything that weakens a promise is the owner's explicit
decision (`EVIDENCE.md` 4), and an acceptance is the owner's own words about that finding, never the agent's.

## 1. Fix it, at the cause

The default. The test is: **what does the fix erase?**

- If the fix is a new condition at one specific call site, you are probably at the **symptom**.
- If the fix makes a whole class of attacks stop existing, you are at the **cause**.

A concrete signal from the project this was distilled from: three separate hostile harnesses, from three separate
rounds, all turned into ordinary honest cases when one reading rule was changed in one place. That is what a cause
looks like. The three point fixes that had been proposed before it would each have closed one harness.

Cause-level fixes are also how you avoid the slow disaster of a contract that is a pile of special cases, where
nobody - including you - can say what it does any more.

After a cause-level fix, re-walk the whole hostile-actor table and write, for **each** row, what the contract does
**now** and why. A cause-level fix always changes more than one line of that table, and the rows it changed by
accident are where the next finding lives.

## 2. Refuse it, with the reason in writing

Legitimate and common. Auditors recommend from inside the finding; you decide from inside the product. Reasons
that are good enough:

- it widens the scope of the contract;
- it costs bytes the contract does not have;
- it trades a rare hostile case for a cost on every honest transaction;
- it is handled elsewhere, by procedure, by an admission rule, or by the owner's operating practice;
- the class it defends against is excluded by the spec, on purpose.

**The refusal goes in the spec, with the reason, before the next round is launched.** An undocumented refusal is
re-reported by the next auditor, and you pay for a whole round to learn something you already knew.

If the refusal is "handled by procedure and not by the contract", then the procedure must exist in writing
somewhere the operator will actually read it - the runbook, not the spec appendix. A refusal that depends on a
procedure that does not exist is not a refusal, it is an open finding.

## 3. Accept it as a trade-off - with a number

Some findings are real, are not going to be fixed, and the honest answer is to state the cost. The rule:

> **A trade-off without a number is not a trade-off, it is a hope.**

The entry must say, in the spec and in `DECISIONS.md`:

- exactly what an attacker achieves;
- **who loses**, and how much, in the worst case you measured;
- **what it costs the attacker** - in gas, and converted to money at two gas prices when the economics are what
  makes it exploitable or not;
- what conditions it needs (a hostile token? admin cooperation? a specific pool configuration?);
- what would close it, and why that is not being done now.

Economics decide severity more often than people expect. An attack that costs the attacker several times what the
victim loses, and that consumes itself, is a documented trade-off, not a high-severity finding - but you only get
to say that once you have measured both sides.

**The owner accepts the trade-off, not the agent.** This is one of the stop-and-ask points in `AGENTS.md`.

## Distinguishing cause from symptom in practice

Three questions, in order:

1. **Can I state the finding without naming a function?** If the general statement is true, fix the general thing.
   If it is only true at that one call site, the point fix may genuinely be right.
2. **How many of the earlier findings would this fix also have closed?** Go back through the reports and check.
   Zero is a warning sign. Two or more means you are at a cause.
3. **What does the fix make impossible to express?** A cause-level fix removes a capability. If your fix removes
   nothing and only adds a check, ask what the check is standing in for.

## The cheapest mistake to avoid

Do not accept a finding's own diagnosis of its cause. The finding is the **observation**; the cause is a claim
that you have to verify separately. A probe that shows your proposed fix does not work has falsified the fix. It
has **not** validated your explanation of why. Getting this backwards costs a round, and the wrong explanation
hides the cheap correct fix behind it. See `LESSONS.md`.
