# The judges: the questions every step answers, and the usual tool for each

No model is the judge. These are. Each one answers **one question**, and the question is what you owe the owner -
the tool next to it is only the usual way to get the answer. If the tool does not fit this hook, answer the question
another way and write it down (`AGENTS.md` section 6b). If the question does not apply, say why, in the dossier.

Almost everything here costs no model tokens: it runs on the owner's CPU - loudly, sometimes for an hour (see "What
the local judges cost" below). Exhaust it before buying a round (`COST.md`).

Every flag in the "usual tool" column was checked by RUNNING it on forge 1.8.1 (2026-09-22: `--mutate`, `--brutalize`,
`--symbolic`, `--fuzz-seed`, `-j/--threads`, `corpus_dir`, `FOUNDRY_INVARIANT_CORPUS_DIR`) - not against `--help`, which
on 1.8.1 does not list `--mutate` or `--brutalize` although both work. Foundry renames flags between releases: before
trusting a row, run the flag on YOUR forge, and read <https://getfoundry.sh/llms.txt> for the current page (`doctrine/UPSTREAM.md` 1b).

The "usual tool" column is how THIS kit's harness answers the question. A project that already answers it another
way - it etches the real manager's bytecode in its own tests, it has a fork suite - has answered it. Judge the
question, not the presence of the script.

## The ladder

| # | the question | usual tool | full-mode gate? |
|---|---|---|---|
| 1 | Does it build clean, and is there a basic mistake a machine would catch? | `forge build` with lints, `forge lint`, **Slither** with a written triage | yes - the triage |
| 2 | Does each promise have a test that passes? | `forge test` - at least one piece of evidence per row of the spec's hostile-actor table: a unit test, a property, or REASONED with the reason | yes |
| 3 | Does any SEQUENCE of actions break a rule? | Foundry invariant fuzzing, handler + hostile token, **corpus on** | yes |
| 4 | Is the campaign reaching everything? | the campaign census (`scripts/census.sh`: runs in which each action succeeded, each boundary was reached; `CORE` and `REACH` make the ones that matter a gate), `forge coverage --report summary --no-match-coverage '^([^st]|s($|[^r])|sr($|[^c])|src($|[^/])|t($|[^e])|te($|[^s])|tes($|[^t])|test($|[^/]))'` by **branch** (the regex keeps only your `src/` and `test/` in the totals, wherever the kit and forge-std live - forge reports remapped files by the path they came in on, and 1.8.1 has no `--match-coverage`; `foundry-kit/v4/README.md`, coverage; if it will not compile: `--ir-minimum`; if that will not either: "not done", with the compiler error) | yes - branch numbers, or the reason there are none |
| 5 | Do my tests bite? | `forge test --mutate`; `scripts/mutate.sh` for one aimed change | yes - score + survivors read |
| 6 | Does the code survive dirty memory and junk in unused bits? | `forge test --brutalize` | no |
| 7 | Does the manager's deployed BYTECODE behave like the one I compiled? (Its STATE - owner, fees, existing pools, real periphery - is a different question, answered only by a fork suite, which this kit does not ship: see the next row and the phase-3 gate) | the real manager's runtime bytecode etched into the tests (here: `scripts/fetch-bytecode.sh` + `V4_MANAGER=fixture`). This is its code, NOT its state: no owner, no protocol fee, no pools, the test chain id. Anything that depends on deployed state, real tokens or real periphery needs a FORK suite, which this kit does not ship | yes, once the chain is known |
| 8 | Does this arithmetic hold for EVERY input, not the ones I tried? | `forge test --symbolic` (needs an SMT solver), Halmos, Kontrol, Certora | optional to run; in full mode "not done" needs the owner's written reason. Say what was and was not proven |
| 8b | Would an independently written model agree? | a deliberately dumb reference model, written from the SPEC, fuzzed side by side with the contract (`EVIDENCE.md` section 5) | yes, for a hook with its own arithmetic or accounting |
| 9 | Would a different engine reach what mine does not? | Medusa, Echidna, on the same properties (Chimera layout) | optional to run; in full mode "not done" needs the owner's written reason |
| 10 | Does it fit, and what does it cost? | `scripts/size.sh`, `forge snapshot` regenerated at promotion | yes - size and margin |
| 11 | What would a named population of makers and takers do against this hook, and what does it cost them? | the simulation sandbox (`foundry-kit/v4/src/sim/`, `SIMULATE.md`): agents, a clock at the chain's cadence, an ordering model, a ledger that charges gas | no - a judge the owner asks for in writing; its numbers are SUPPORTED, never a gate, and it cannot see the agent nobody wrote |

**Row 7, extended - vendored dependency provenance.** The question in row 7 is not only about the pool manager's
bytecode: it applies to every dependency vendored as source instead of installed as a package - a library copied in,
a forked interface, a pinned commit checked in by hand. Before trusting a vendored copy, `sha256` it against the
artifact of the real tagged release it claims to be. Goes red the moment the hashes differ; when that happens, do not
patch the vendored copy and move on - flag it, do not use it as the basis for any claim until the mismatch is
resolved with the owner, and say so in the dossier's dependency row (`briefs/handoff-dossier.md` section 1,
`{{DEPS}}`).

"Full mode" is the route for an immutable contract or one that holds other people's funds (`COST.md` section 1). In
light mode the gates in the last column are recommendations - which does not make them skippable in silence: not
following one is a divergence, and `AGENTS.md` section 6b says what a divergence owes (the question, the reason,
`DECISIONS.md`, the dossier; and the owner's written yes if the step is skipped outright). Rows 8 and 9 are never gates: they are where you spend
effort when a specific worry justifies it. "Not done" is an honest line in the dossier - and in full mode it is the
OWNER's line: they say why, in `DECISIONS.md`. An agent does not get to decide alone that a proof was not worth it.

What each result is WORTH as evidence - and why a passing test nobody has seen fail is worth nothing - is in
`EVIDENCE.md`.

## How each judge lies to you, measured on this kit's own examples

A tool that ran is not a question that was answered. Read the result, not the exit code.

- **Mutation, all invalid, exit code 0.** Run against this kit when its examples lived outside `src/` and `test/`:
  136 mutants, 136 "invalid", green exit, two seconds. Foundry's mutation and brutalize modes build in a temporary
  workspace that carries the standard directories only. *Zero mutants killed is zero evidence.* Keep a standard layout
  (a `lib/` that is a symlink is fine - measured), and read the whole ledger before the score:
  `killed + survived + invalid + skipped + timed out = total`. **`invalid` should be a small fraction.** `skipped` is
  not a problem: current forge stops testing a source span once one mutant of it has survived (`Skipping mutant
  (adaptive: span already has surviving mutation)`), so on a real contract half the generated mutants may be skipped
  and the run is still good. A span with a survivor is a span to read, whatever the count says.
- **Mutation sized from a toy.** Mutant count scales with source bytes, not with intuition: a 3 KB library gave ~900
  mutants, a 50 KB hook ~4,400 (1,900 tested after adaptive skipping, 13 minutes on 16 threads with a unit suite that
  runs in a third of a second). **Calibrate first:** mutate the smallest file in `src/`, scale by file size, and take
  that estimate to the owner before the real run. What you control is the SUITE's runtime, not the compile: mutate
  against the fast unit tests (`--match-contract`), not against a two-minute invariant campaign - that is the
  difference between forty minutes and several days. Say in the dossier that the stateful suite's killing power was
  therefore not measured, and which files were not mutated at all.
- **Mutation, a score without reading the survivors.** Standard layout, same example, first run: roughly a fifth of the mutants
  survived. Some survivors were *equivalent* (no input can tell `_lock == 1` from `_lock >= 1` when the variable is only
  ever 0 or 1). Sixteen were real: nobody had ever tested withdrawing exactly the whole credit; several tests only
  checked THAT a call reverted, not WHY. On the example hook, a guard mutated from `!=` to `<` survived because every
  test address sorted below the hook's (`LESSONS.md` 11). After the work the scores are in the three `MUTANTS.md` files of `foundry-kit/` (the one source for them), and the survivors
  are each ACCOUNTED FOR in a `MUTANTS.md` next to the contract: proven equivalent (with a test asserting the
  premises that could rot), unobservable by construction, or - for the two helper contracts - declared NOT
  equivalent and left as a named gap. The score is a headline; **the survivor list is the finding.** Every survivor
  ends as a new test, as a written proof of equivalence, or as a gap with its name on it in the dossier. "The
  suite never tried that" is not a proof.
- **Mutation by hand, over a copied cache.** `LESSONS.md` 12. `scripts/mutate.sh` builds its copy from nothing for
  this reason; if you write your own helper, do the same.
- **Mutation under `via_ir` or a very high optimizer setting.** Each mutant is a full compile. Expect timeouts to
  dominate. Diverge: mutate with a fast profile (`--mutation-via-ir false`, low `--mutation-optimizer-runs`) and say
  so; or aim single mutants at the lines that guard value with `scripts/mutate.sh`.
- **Coverage without assertions.** A line that ran is not a line that was checked. Coverage tells you what the suite
  **cannot** have tested; only mutation tells you what it did. Report branches, not just lines, and name every
  uncovered branch in the dossier.
- **Coverage measured on a build that is not yours, and on a red suite.** `forge coverage` turns the optimizer AND
  `via_ir` off. On a hook that needs them to fit the size limit, expect: "stack too deep" (use `--ir-minimum`, and say
  the source map may have drifted); size assertions and gas ceilings failing, because the contract is twice as big;
  and - the dangerous one - **a test that fails stops executing, so everything after its failing assertion is reported
  as uncovered.** Read the pass/fail line of the coverage run BEFORE the percentages, and name every test that
  aborted; a contract at "22 % branches" may simply sit behind one. If a test fails there for a *behavioural* reason
  (not a size or gas ceiling), you have learned something about the contract: absolute gas budgets in the code are
  tied to the build configuration, and belong in the spec's measured numbers.
- **Coverage that under-counts reverts.** Measured: eight functions whose whole body is `revert NotImplemented()`,
  each called by a test under `vm.expectRevert`, reported as 0 hits for seven of them and "53 % of lines" for the
  file. Before you chase an uncovered line, check whether it is a line that only ever reverts; say so in the dossier
  rather than quoting the raw percentage in either direction.
- **Coverage that finds furniture.** On this kit it showed a 180-line helper at 3.7 %: a switchboard nobody flipped.
  Code in the test harness that no test exercises is a claim with no evidence, exactly like a sentence in the spec.
- **Fuzzing that passes because nothing happened.** `INVARIANTS.md`, "The vacuous pass". Count successes, not calls.
- **A red campaign that is a replay, not a discovery.** Forge persists a failing sequence under `cache/invariant/`
  and replays it before it fuzzes anything. `runs: 1, calls: 1` is yesterday's counterexample. Clear that directory
  before any run whose result you mean to compare with another.
- **Fuzzing from zero every time.** Set `corpus_dir` under `[invariant]` (and `[fuzz]`): the fuzzer becomes
  coverage-guided and keeps what it learned between runs. Without it, every campaign re-discovers the easy paths.
  Keep the corpus out of git. It lies in two ways, both measured here on the first day we turned it on, both FALSE
  REDS - they waste an hour, they do not hide a bug:
  - **Malformed calldata.** The guided fuzzer mutates bytes, so a `bool`, `address`, `uint8` or enum parameter of a
    handler action arrives with dirty high bits; Solidity's ABI decoder reverts before the handler runs (a revert at
    a few hundred gas, at the handler's entry, args that LOOK valid in the trace), and `fail_on_revert = true` fails
    the campaign. Handler actions take full words only; derive the rest inside (`HandlerBase._bit`).
  - **A corpus belongs to one deployment layout.** It stores raw addresses. Replay it against a setup that deploys
    things elsewhere - another manager, a changed `setUp`, a new constructor argument - and it calls whatever now
    lives at the old addresses, bypassing `targetContract`. The tell: a sequence step whose `addr` is not your
    handler. One corpus directory per configuration (`FOUNDRY_INVARIANT_CORPUS_DIR`), and delete `corpus/` AND
    `cache/invariant/` (persisted failures are replayed first) whenever `setUp` or the action list changes shape.
- **Static analysis, raw.** Most of what it says about a hook is the design itself: pulling tokens from a wallet that
  approved you *is* "arbitrary from in transferFrom"; measuring a balance before and after a call *is* "reentrancy
  with a balance read". Do not suppress, do not hand over the raw log: triage it (below). A human auditor runs the same
  tool on day one, and what they want to find is that you already answered every line.
- **Symbolic proof of the wrong sentence.** It proves what you wrote, for the bounds you set. Loops over ticks, orders
  or arrays are unrolled to a bound or time out. Aim it at small pure arithmetic - rounding direction, a fee formula,
  a price conversion - where one bad input in 2^256 is the whole risk. State the loop bound next to the word "proven".
- **The mock that says yes.** A pool manager you wrote will agree with the hook you wrote. Row 7 exists because the
  real one does not have to.

## What the local judges cost the owner's machine

"Free" means no model tokens. It does not mean quiet. Mutation testing compiles and runs the whole suite once per
mutant, on every core by default; a long fuzz campaign pins the CPU for its whole length. Measured on an 8-core /
16-thread desktop with the kit's own small examples: 93 mutants of a 260-line hook in about a minute (49 to 64 s across
runs) with every core busy;
a 64 x 64 invariant campaign in about a second; 1000 x 64 on a real project in roughly a quarter of an hour. A laptop
will take several times longer and will sound like it.

- **Say so first.** `AGENTS.md` section 5: tell the owner before anything you expect to run for more than a few minutes.
- **Throttle when asked:** `--mutation-jobs N` for mutation, `--threads N` (or `-j N`) for tests and fuzzing.
- **Aim before you scale:** mutate the files that guard value, not the whole tree; run the long campaign before a gate,
  the short one on every change.
- Two agents compiling at once double the load and gain nothing. One bench per agent, one heavy job at a time.

## The static-analysis triage (row 1)

One file, `STATIC-TRIAGE.md`, regenerated each revision. One line per finding above "informational" - **or per
homogeneous group**: findings of the same detector whose verdict and justification are identical, with the count and
the locations on the line. A real hook gives a hundred findings and twenty groups; a hundred copy-pasted lines are a
document nobody reads. Start the file with the tool version, the exact command, and the count per verdict. The
linter's output (`forge lint`, which also runs inside `forge build`) gets the same treatment, grouped by rule -
`unsafe-typecast` on a hook that packs storage is a real triage, and the static analyser does not report it.

```
| detector | where | verdict | why | proved by |
| arbitrary-send-erc20 | OrderHook._fill L210 | by design | orders are filled from the maker's wallet by allowance; SPEC section 3 row 4 | test_fill_needs_allowance |
| unchecked-transfer   | OrderHook._fill L210 | by design | the credit is the measured delta, never the return value | test_token_returns_nothing |
| divide-before-multiply | OrderHook._cost L188 | accepted, 1-2 wei | rounds against the taker; bounded in SPEC section 6 T3 | testFuzz_rounding_bound |
| uninitialized-local  | OrderView.rows L51 | FIXED in r07 | - | - |
```

Verdicts: **fixed**, **by design** (cite the spec row), **accepted with a number** (the owner accepts it, `TRIAGE.md`),
**false positive** (say what the tool misread). "By design" with no test behind it is an opinion: fill the last column.
Count the findings per verdict at the top, with the tool's version and the exact command.

## What none of these can see

Whether the spec describes a hook worth building; economic attacks that respect every rule (ordering, MEV, incentives)
- for these the simulation sandbox (`foundry-kit/v4/src/sim/`, `SIMULATE.md`) MEASURES what a named population of
agents earns under a stated ordering model, and cannot see the agent nobody wrote; a blind spot shared by every model and every
tool you used; a bug in the rule itself. That is what the black-box
round, a second vendor, and the human audit at the end of this route are for. The dossier says so in those words.

## Origin, stated honestly

The project this kit was distilled from used rows 2, 3, 5 (by hand), 7 and 10, and none of the others, for its whole
life. Rows 1, 4, 5 (native), 6 and the corpus were added to the kit afterwards, tried on the kit's own examples first,
and the numbers above are from those runs. Rows 8 and 9 have not been run by us at all.
