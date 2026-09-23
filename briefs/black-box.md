# Brief template: black-box attacker (phase 5)

This is the round that finds what reading cannot. See `doctrine/LESSONS.md` §9.

**Before you write the brief, build the bench.** Isolation is physical, not instructed. Create
`{{BENCH}}` containing the spec, the ABI, the test harness, the mocks, and **not** the
source of the contracts under test. Obedience is not a security boundary; an absent file is.

Use `scripts/bench.sh` with `BENCH_EXCLUDE="src script"` and `BENCH_ARTIFACTS="<the contracts under test>"`: the
bench then holds the **compiled artifact** (ABI and bytecode, which any integrator can obtain) and no source, and the
attacker deploys the target with `deployCode("artifacts/X.sol/X.json", args)`. Without the artifact a source-free
bench cannot deploy the thing it is supposed to attack. Withhold more than `src`: earlier reports, the state files, the
regression tests whose names give the answers (`BENCH_EXCLUDE="src script reports STATE.md DECISIONS.md LOG.md"` and the
regression test files by name). With `BENCH_EXCLUDE` set the script never copies an excluded path the project has and
removes any stale copy of one from the bench (a bench of the same name made earlier without the exclude), COPIES the
dependency directories instead of linking them (a link into the project leads straight back to its source), and
refuses to hand over a bench in which an excluded path of the project or any symlink remains. A matching path that only
the BENCH has (a fixture fetched into it) is its own and is kept, and the script says so. Still list the bench yourself
before launching.

Run it **earlier than feels natural** - as soon as the spec is stable and the battery is green, not as a final
ceremony. Its findings are about the spec, and the spec aims every later round.

---

# BLACK-BOX {{ROUND}} - attack the promises of `{{TARGET}}`, without the source

You attack what this project **promises**. You do not read how it keeps the promises.

## What this is, and what it is not

This is a defensive review of **the owner's own, undeployed code**, requested by the owner, on a local bench: no
network, no keys, no live system, nothing of anyone else's. "Attack" here means writing Foundry tests that try to
falsify the spec, so that the failures are found before a human audit and before any money is at stake. The output
is a report and tests, never a tool for use against a deployed contract.
(Orchestrator: keep this paragraph only if every word of it is true for your round. If the target is deployed or is
not the owner's, this kit is the wrong tool - STOP and ask.)

A test of yours that fails does **not** prove a bug in the contract. It proves a **divergence between the spec and
the code**, which the reading rounds cannot see, because someone who reads the source learns the real semantics
and stops being able to see the gap.

## The one rule you cannot break

**You do not open the implementation source.** Not with any tool, not by accident, not through a quoted excerpt in
another document. You also do not open **any earlier report** or the scratch directories of earlier rounds: those
are the answers, and they contaminate you. If it happens anyway, **declare it in your report** - a declared
contamination is a manageable fact, an undeclared one poisons the round.

## What you may read, and should

- **`{{SPEC}}`** - the consolidated contract: the principle, the "hostile actor -> contract's answer" table, the
  invariants, the admission or configuration rules, the trade-offs with their numbers. **This is what you attack.**
- **`{{RUNBOOK}}`** - the operator's procedure is also a promise.
- **The manifest**, if the artifact has been promoted.
- **The ABI, function signatures, natspec, custom errors, events, contract sizes and the storage layout**, through
  `forge inspect --offline`. An integrator can get all of these. **Storage and events are the only truth an
  outside consumer ever sees.**
- The mocks and the setup helpers in the harness, so you can build a bench. **Do not read the regression tests**
  (`test_r*_*` and similar): their names and assertions tell you the answers.

## Method

1. **Falsify, line by line.** For every row of the hostile-actor table, every invariant, and every number in the
   spec: write a test that tries to make it false. Each ends as **CONFIRMED** (with your number), **DIVERGENT**
   (the most valuable result) or **NOT VERIFIABLE FROM OUTSIDE** (also a result - say so).
2. **What the spec does not say.** Wrong order. Twice in the same transaction. Re-entered from inside your own
   callback. Boundary values the ABI accepts and the spec never mentions. A contract where a wallet is expected -
   as caller, as recipient, as a recipient that reverts. The clumsy integrator: quote with one argument and
   execute with another, paginate a view wrongly, trust a quote a block later. Unusual configurations: extreme
   parameters, tokens with unusual decimals, a pool at a limit.
3. **Be the outside consumer.** Reconstruct the full state from **events and public storage only**, and compare
   with the views. Two different histories that leave identical logs is a finding. An event that reads backwards
   from what happened is a finding. Anything important that emits **no** event at all is a finding. Start from the
   events that an indexer would key off.
4. **If the project ships an indexing guide, follow it literally**, as someone who has never seen the code. If
   following it produces a wrong state, that is a finding, and a cheap one to fix now: on an immutable contract
   the shape of the events is frozen at deployment forever.

## What is not a finding

Everything the spec already accepts **in writing, with a number**. Read the trade-offs section **before** you
report. If it is there, confirm it with your own measurement and move on.

## Rules

- Bench `{{BENCH}}` only. Never compile elsewhere. Tests in `{{SCRATCH}}`.
- No mainnet writes, no keys, no broadcast, no installs, no browser.
- You write **only** in `{{SCRATCH}}` and in your report `{{REPORT}}`.
- Reproduce the baseline first: `{{BASELINE_TESTS}}` tests pass, `{{BASELINE_SIZES}}`.
- Every claim is a test that **passes** and that you have SEEN FAIL when the promise is broken (you have no source to
  mutate: break the SCENARIO instead - the same test must go red when you remove the hostile step). Measured numbers
  only. A divergence you can argue but not execute is reported as REASONED, not dropped.
- Write the report incrementally, `LEDGER` and `ASSUMPTIONS` at the top. Retry once on a rate limit.

## Deliverables

`{{REPORT}}`, containing:

1. the rules you followed and an explicit **statement of non-reading** (what you opened, what you did not, and any
   contamination);
2. a table **promise -> test -> result** covering the hostile-actor table and the invariants in full;
3. new findings, in the format of `briefs/audit-round.md`, each with severity, who loses, cost to the attacker,
   and the recommended fix - saying clearly whether you recommend fixing the **code** or the **document**;
4. the outside-consumer section: what reconstructs from events, what does not, and what the log does not say;
5. a verdict on one question: **does the spec honestly describe what the code does, and does what it emits let
   someone outside know the truth?**
