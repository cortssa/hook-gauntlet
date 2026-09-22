# Invariants: what ships is the floor, not the ceiling

The kit ships a handful of generic assertions: conservation, "this contract holds nothing but donations", "nobody
gains more than the others lost". They apply to almost any contract, which is exactly why they are not enough. The
invariants that find real bugs are the ones that only make sense for **your** hook. A suite that stops at the
generic ones goes green and tests nothing that matters.

**ADAPT: you may not leave phase 3 with only the invariants that ship in this kit.** Derive yours, write them in
words in `SPEC.md` first, then in code.

## What an invariant is

A unit test says: in this scenario, this happens. An invariant says: **in no scenario does this ever break.** It is
the till balancing at closing time - cash in the drawer equals opening float plus sales minus refunds - and it has
to hold however chaotic the day was. The fuzzer is the chaotic day: random actions, chained, with the invariants
checked after every one.

## Derive them backwards, from the damage

Do not start from the code. Start from the harm, and reason backwards to the rule.

1. **List who can lose what.** Every party that touches the hook: liquidity providers, traders, the fee
   recipient, the owner, a passer-by whose tokens are merely approved. For each: what is the worst thing that can
   happen to them? Losing funds, being paid less than promised, being locked out, being blamed for something the
   token did.
2. **Turn each harm into a sentence that must always be false.** "A provider lost tokens and received nothing."
   "A trader received more than the providers gave up." "An order filled twice."
3. **Negate it, and that is your invariant.** "Whenever a provider's balance falls, the counter-asset it is owed
   arrives in the same action."
4. **Ask what must be TRUE for each promise in the spec to hold.** Every necessary condition is either enforced
   by the code (then assert it) or is an assumption about the outside world (then it belongs in the spec as an
   admission rule, and in the runbook as a check somebody actually performs). A condition that is neither is a hole.

## Starting points by kind of hook

These are prompts, not a checklist. Your hook will need rules that are not here.

| kind of hook | invariants that only make sense there |
|---|---|
| **dynamic fees** | the fee never exceeds its cap; fees collected equal the sum of what each swap was charged; the fee cannot be moved by the swapper inside their own transaction |
| **limit orders** | an order fills at most once; the filled amount never exceeds the order size; a cancelled order never fills; whoever placed it is who gets paid |
| **custody outside the pool** | the hook never ends an action holding tokens; each provider loses only what was delivered on their behalf; a provider that cannot deliver is skipped, never charged |
| **oracle / TWAP** | the reported price cannot move more than X within one block; an observation cannot be written twice for one timestamp |
| **vault / rehypothecation** | shares times price never exceeds assets; nobody can withdraw more than they deposited plus their share of yield |
| **any hook that quotes** | the quote equals the execution when nothing changed in between; under a hostile token the execution is never MORE than the quote |
| **any hook that emits events** | the state rebuilt from the events alone equals the state on chain |

The last two rows are there because they are the ones most often forgotten. A fuzz suite that checks where the
money went and never checks what the contract **said** about it will pass while the quote and the event log lie.

## Two kinds of check, and you need both

- **Global invariants** (`invariant_*` functions): true of the whole state, checked after every action.
  Conservation, solvency, index-matches-contents.
- **Around-the-action checks** (inside the handler): snapshot before, act, compare after. "This provider lost
  exactly what this trader gained." These are the ones that work hardest, because they see the delta and know
  who was involved. Most real findings are caught here.

## The vacuous pass

An invariant can pass because nothing ever put it to the test. If ninety-five percent of the fuzzer's `join`
calls are rejected - no balance, bad parameters - the book is almost always empty, and "the book is consistent"
passes every time while testing nothing.

**Defence: count successes, not calls.** `HandlerBase` gives you `_noteSuccess(action)`, `successesOf(action)`,
`assertExercised(action, min)`, `printCallSummary()` for one run, and `writeCensus()` + `scripts/census.sh` for the campaign. Use them:

- a smoke test that walks the happy path and asserts every action succeeded at least a few times;
- after a long campaign, read the census. **An action near zero is an action you are not testing.** Fix the
  handler (fund the actors, bound the inputs to legal ranges) until the hostile branches and the honest ones
  are both reached.

## The arbiter has bugs too

Your handler's bookkeeping is code, and it is wrong sometimes. When the fuzzer reports a violation:

1. Turn the shrunk sequence into a **deterministic test**. Never debug from the campaign.
2. Ask first whether the **referee** is wrong: is it reading the same thing the contract reads? A handler that
   reads a balance as an outsider, while the contract reads it as itself, will disagree with the contract the
   first time a token answers differently to different callers - and the contract may be the one that is right.
3. If you compare two revisions, replay the **sequence**, not the seed. Fuzzers build their inputs from what the
   code emits; change the events and the same seed is a different campaign.

## The rule that makes the suite grow

**Every bug found by something other than the fuzzer is a missing invariant or a missing action.**

After every finding from an audit round, a black-box round or a human: ask *which rule, in the fuzz, would have
caught this on its own?* Write that rule. Then check that it fails on the old code and passes on the fix.

This is how the suite stops being a snapshot of what you thought of on day one and becomes a record of everything
that ever went wrong. In the project this kit was distilled from, the most important late findings all landed in
places where the fuzz had no rule at all - the quote, the event log, the view contract. The fuzzer had not failed.
Nobody had ever asked it the question.
