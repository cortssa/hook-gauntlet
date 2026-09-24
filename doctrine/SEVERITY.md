# Severity and the exit criterion

## Why this file exists

The exit criterion of phase 4 is "a discovery round with zero high and zero medium findings, nothing REASONED left open". That sentence is worth
nothing unless "medium" means the same thing in round 3 and in round 20.

Left alone, severity inflates. An auditor with a fresh context and an instruction to be adversarial will label an
edge case in a hostile token's own market as "medium", because from inside that finding it looks serious. Three
rounds later the exit criterion is unreachable and everyone is tired.

**So state the scale in every brief.** Not a link to this file: the actual rule, in the brief, in two lines.

## The scale

Severity is anchored to **who loses**, not to how clever the attack is.

| | |
|---|---|
| **high** | An attacker takes funds that are not theirs, or permanently denies the contract to honest users, or bricks state that cannot be recovered. Third parties pay. |
| **medium** | A participant is denied service or loses value in a case the spec claims is handled; or an owner/operator action can cause either; or a documented trade-off is measurably **worse** than the document says. |
| **low** | Real, reproducible, and bounded to the party that caused it: it needs a hostile asset or a hostile counterparty, and its blast radius is that party's own market or position. Also: anything the contract handles correctly but does not *say* it handles. |
| **informational** | Naming, documentation, gas, ergonomics, a test that asserts less than its name claims. |

The line that does the most work, and that belongs in every brief:

> Severity follows the **blast radius**: whose assets, how much, how recoverable, who can trigger it and at what
> cost. A hostile token is a CONDITION, not a verdict. If a token's own hostile code can only close **that token's own
> market**, it is **low**. If the same hostile token reaches a shared reserve, another pool, another party's funds or
> the hook's own holdings, it is whatever that damage is. Reserve medium and high for denial or drain that lands on
> someone other than the party who caused it.

Adapt the nouns to your hook. The structure is what matters: name the class of finding that your design has
*decided* to tolerate, and fix its severity by decree, so that rounds argue about facts instead of labels.

**A loss with no beneficiary is still a loss.** When a hostile asset makes the contract end short - the hook owes
more than it holds, and the last party to claim cannot - the severity is set by who is left unpaid, not by whether
anyone profited. If the shortfall lands on parties other than the one who brought the asset, it is **high**: the
fee sink of a fee-on-transfer token profiting instead of an attacker changes nothing for the maker who cannot claim.
(A blind-test auditor rated exactly this medium, "nobody profits"; the answer key said high.)

**Who can trigger it is part of the severity.** A state that only a privileged party's own mistake can create, and
whose damage is bounded to the thing they created (a pool that can be initialised and then never trades), is low -
nobody is robbed and nobody else is locked out. It still needs a written decision: a low finding nobody decided is
how a spec ends up promising less than the code does.

**On the `evidence` field.** `EVIDENCE.md` defines two more labels, TESTED (a passing test nobody has seen fail) and
UNVERIFIED. They are deliberately absent above: neither is evidence, and a finding that still carries one is not
finished - get it to MUTATION-TESTED, or write the argument and call it REASONED.

**On vocabularies.** Audit firms do not share one scale: some publish impact x likelihood matrices, some two prose
scales, one says "Major" where another says "High", and contest platforms pay only for high and medium. Keeping
impact (`severity`) and `difficulty` as separate fields is what lets an auditor paste a finding into their own tracker
without translating it. Do not merge them into one word.

## Two further rules

**A number that does not reproduce is a finding.** If the spec says a size, a gas figure or a limit, and it
measures differently, that is a real finding at the severity of what depends on it. Documents ship with the code
and operators act on them.

**Severity is not a vote on whether to fix.** Plenty of low findings get fixed because the fix is three lines, and
some mediums get accepted as documented trade-offs. Severity feeds the exit criterion. `TRIAGE.md` decides the
action. Keep them separate or you will start grading findings by how much you want to fix them.

## Shape of a finding

Every finding in every report, whatever the severity:

```
ID          short, stable, unique within the round
target      file:line (every professional report has this; ours did not)
severity    high | medium | low | informational   - the IMPACT if it happens
difficulty  low | medium | high                   - how hard it is to make it happen (privilege, capital, timing, luck)
category    access control | arithmetic / rounding | accounting | reentrancy / ordering | denial of service |
            data validation | configuration | events / views | documentation
evidence    PROVED | MODEL-TESTED | PROPERTY-TESTED | MUTATION-TESTED | SUPPORTED | REASONED   (EVIDENCE.md)
claim       one sentence, falsifiable
who loses   the party that ends up worse off, named
cost        what it costs the attacker (gas, and money at two gas prices WHEN economics decide the severity)
conditions  what the attack needs (hostile asset? admin? a pool configuration?)
fix         the change you recommend, or "documented trade-off" with the number
test        the test that reproduces it, by name, and it PASSES
raw         the raw output, pasted, not summarised
```

A finding without the `test` line is labelled **REASONED** (`EVIDENCE.md`). That is allowed - some of the best
observations in a round cannot be compiled - and it still counts: a REASONED high or medium keeps the loop open until
it becomes a test, the owner answers it in writing, or it is handed to the human audit by name.

## The exit criterion, stated the way a brief should state it

> This phase ends when a **discovery** round closes with zero high and zero medium findings, and no REASONED high or medium is left open. If your round closes clean, the phase ends. **Do not soften to make that happen and do
> not inflate to avoid it.** The only thing that makes this series worth anything is that no previous round did
> either.

Tell the round both halves. An auditor that does not know the criterion cannot calibrate against it; an auditor
that knows only that a clean round ends the series will find something.
