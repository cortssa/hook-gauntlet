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
| **pays in-range LPs, or traders by volume** | per party, what it RECEIVED never exceeds what it was ENTITLED to by the spec's rule, plus a stated tolerance - below |

The last two rows are there because they are the ones most often forgotten. A fuzz suite that checks where the
money went and never checks what the contract **said** about it will pass while the quote and the event log lie.

## Who was paid, not only how much

A payout can be exact in every amount and still go to the wrong people. `manager.donate` pays the positions in range AT
THE MOMENT it runs; a sweep, a reward or a rebate paid "to whoever is in range" or "by volume" does the same kind of
thing. Every conservation invariant stays green while a position placed one call before the payout - or a trader who
is also the LP - takes what others earned: a fresh reader's hook lost about 100 % of each sweep that way with every
amount invariant and the census gate green (`HOOK-ATTACKS.md` class 20). The invariant that sees it is about PARTIES:

1. **Write the rule of entitlement in the spec, with its clock.** Who earns a payout, and WHEN is it earned: the
   liquidity in range when each fee was taken (the fee is the clock), liquidity x seconds over an interval, volume
   traded in an epoch. "The LPs" is not a rule.
2. **Feed a reference model at the moment the spec says a payout is earned**, not when it is paid: after each swap,
   after each interval, at the end of each epoch. It splits what was earned over the parties that qualified THEN, read
   from the manager (the tick, each position's liquidity) or from the swap events - never from the hook's own books.
3. **Measure what each party actually received from the truth**: for liquidity, the fees the manager paid it on every
   modification plus what it is owed now (fee growth inside the range, v4's own formula) - on a pool whose LP fee is 0
   every unit of fee growth is a payout; for traders, their balances.
4. **The invariant, per party: received <= entitled + tolerance**, and the tolerance DERIVED from the arithmetic (for a
   donation: the manager rounds each position down once per donation and once per modification, so a model kept in
   units of 2^-128 is within 1 wei per party over a whole campaign). The other direction, received >= entitled minus
   rounding once what is pending is counted, catches a payout that went missing.
5. **Put the actor that tries to be paid for what it did not earn in the handler** (`FUZZ-ACTIONS.md` question 4: the
   just-in-time recipient), and make the smoke test prove it was in range, and alone in range, at a payout.
6. **Attack the rule itself, not only the conformance to it.** The invariant checks that every payout CONFORMS to the
   rule of step 1. A rule can be exploitable, and then the invariant is green while the exploit works - by
   construction, because the rule is what pays. For each clause, ask who can make themselves qualify cheaply at the
   moment it pays (a dust position parked where nobody else is, a position placed at the price limit of a large swap,
   volume traded by one party on both sides), measure each as a scenario of its own, and write the result in the spec
   as a residual or change the rule.

The v4 module has all six on a worked example: `foundry-kit/v4/src/examples/InRangeDonateHook.sol` (the rule, D2),
`src/InRangeLedger.sol` (the model and the truth, reusable for any payout to in-range liquidity),
`src/JitRecipient.sol` (the actor), the campaign that shows the invariant red on the hook's first draft while every
amount invariant stays green, and step 6's example: its residual R3 - dust parked beyond every honest range, before
anything happens, is alone in range where a stranger's swap ends, and the rule owes it that whole fee while the WHO
invariant stays green (pinned as it is by a unit test). A volume rule needs a model of its own (traders, epochs); the
pattern is the same.

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

**Reaching the kit from a project that has no `lib/`:** remap it in `foundry.toml` - `remappings = ["gauntlet-kit/=<kit>/foundry-kit/src/", "forge-std/=<kit>/foundry-kit/lib/forge-std/src/"]` (`InvariantBase` imports forge-std, so both),
`<kit>` RELATIVE for a project that is handed over (`lib/hook-gauntlet`, or `../lib/hook-gauntlet` with `allow_paths`:
`QUICKSTART.md` step 7b); an absolute path only for a kit that lives elsewhere - it needs no `allow_paths` (measured on
forge 1.8.1), and the project is then not portable - and import `gauntlet-kit/InvariantBase.sol`.
A scenario or a suite for a hook off the v4 manager takes its tokens from `gauntlet-kit/HostileERC20.sol` or its own.

**Defence: count successes, not calls.** `HandlerBase` gives you `_noteSuccess(action)`, `successesOf(action)`,
`assertExercised(action, min)`, `printCallSummary()` for one run, and `writeCensus()` + `scripts/census.sh` for the campaign. Use them:

- a smoke test that walks the happy path and asserts every action succeeded at least a few times;
- after a long campaign, read the census. **An action near zero is an action you are not testing.** Fix the
  handler (fund the actors, bound the inputs to legal ranges) until the hostile branches and the honest ones
  are both reached;
- a revert the handler files as expected names its ERROR, never only a state (`FUZZ-ACTIONS.md`, "Make the actions
  land"): a catch that excuses every revert while a switch is on is a vacuous pass of its own, over exactly the runs
  the hostile switches were wired in for.

**Restrict your handler with `targetSelector` to the actions you wrote.** `targetContract(handler)` alone lets the
fuzzer call every non-view function the handler has, `HandlerBase`'s own included: `writeCensus(string)` is one. On a
toy handler with one action it took about half of a 64 x 64 campaign's calls, and before `writeCensus` learned to ignore
the fuzzer's calls (they arrive as their own transaction, `msg.sender == tx.origin`) it wrote the fuzzer's labels into
the census - 2 125 lines under 1 473 labels for 64 runs, and `scripts/census.sh` failed over bytes nobody could read. The
census is now safe; the calls are still spent - and counted: the census then shows the boundary `handler unrestricted:
bookkeeping selectors were fuzzed` and `census.sh` says so under the table. List the selectors, as both worked examples do.

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
