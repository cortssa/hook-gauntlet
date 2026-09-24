# What do I do next? The decision table

*Arriving at a project that did not start with this kit? Read `RETROFIT.md` first: the flags below can be derived
read-only, and you do not have to install anything to use this table.*

The nine phases say what exists. This file says **when** each thing happens. Run it every time you arrive with no
context, and every time you finish anything. It is a table on purpose: you should be able to answer each condition
from `STATE.md` and the repository, without judgement calls. Where a judgement call is unavoidable, it says STOP.

## The flags `STATE.md` must carry

Keep these lines at the top of `STATE.md`, and update them as part of closing any piece of work. They are
what makes the table computable.

```
phase:                     sketch | 0-8       (advances the moment the phase's gate in `AGENTS.md` §3 is met, measured)
bytecode_changed_since:    last_battery=yes|no  last_long_fuzz=yes|no  last_other_free_judges=yes|no  last_audit_round=yes|no  last_promotion=yes|no|n/a
battery:                   never | green | red  (as of its last run; red = a failing, skipped or missing test)
blackbox:                  never_run | current | stale (promises, events or ABI changed since it ran) | skipped_by_owner (date)
open_findings:             high=N medium=N low=N reasoned_high_or_medium=N   (not yet fixed, refused in writing, accepted by the OWNER with a number, or handed to the human audit by name)
                           (a finding counts as REASONED only when it has NO test; one with a tested part and a reasoned part counts as tested, and the ROUND line's `reasoned` counts the same way)
last_audit_round:          id, discovery | regression, result (e.g. r06 regression 0H 1M 3L)   - black-box and verifier rounds do NOT go here
last_other_round:          id, black-box | verifier, result
ceiling:                   what the owner agreed in phase 0, and how much of it is used (see below what counts)
real_manager_battery:      n/a (chain not chosen) | never | stale (bytecode changed since) | current
waiting_on_owner:          none | the question(s), each named (triage of <ids> · chain · severity of <id> · reason for <judge> not run · ...)
location:                  .gauntlet/ | root       (where these files and the dossier live)
dossier:                   none | skeleton (K open, N judges not done) | complete (N judges not done)
notes:                     free lines the table reads by name: `static triage: forge lint only, Slither not installed` · `not fuzzable: <id> - <why>` · `real manager: <what replaced it>` · `fork: <answer or n/a - why>`
```

A new project starts with: `phase: 0`, every `bytecode_changed_since` flag `yes` (nothing has run yet), `battery: never`,
`blackbox: never_run`, `open_findings` all 0, `last_audit_round: none`, `last_other_round: none`, `ceiling: not agreed
(phase 0)`, `real_manager_battery: n/a (chain not chosen)`, `waiting_on_owner: none`, `location:` as chosen, `dossier: none`,
`notes:` empty. `last_promotion` starts `n/a`, not `yes`: there was no promotion to change since.

"Bytecode changed" means anything that changes compiled output: an edit under `src/`, OR a compiler setting in
`foundry.toml` (`optimizer`, `optimizer_runs`, `via_ir`, `solc`, `evm_version`) of the profile the battery builds with.
A stranger measured a hook go from 1374 to 727 bytes with no edit under `src/`, from one `optimizer = true`; every flag
stayed `no`. The sandbox therefore lives in its own profile (`QUICKSTART.md` step 4), so that binding it never changes
the audited artefact. Comments change metadata, and therefore the deployed address, but not behaviour: they count for
promotion, not for rounds.

## The table - take the FIRST row whose condition is true

| # | if this is true | do this | why |
|---|---|---|---|
| 0 | `phase` is `sketch` (the design is still moving) | local judges only: compiler, unit tests, a first fuzz. **No model rounds.** When the design has stopped moving, write the spec and continue at row 4 | `CHANGES.md` section 1: an audit of a moving target is money spent on code that will not exist |
| 1 | a **high** finding reproduces and the owner has not been told | tell them now, with the test, before anything else in this table (owner absent: `waiting_on_owner: high <id> - to tell` in `STATE.md` and on the skeleton's status line; the route continues) | never batch a high; nothing outranks it, not even the ceiling |
| 2 | the ceiling is reached | **no more model rounds.** Report what was bought, what is open and what the next unit would cost. Then the route CONTINUES without rounds: every open finding is triaged (row 9: fixed, refused in writing, or accepted with a number) or, when the owner is not there to triage, row 9b: the skeleton hands each open finding to the human audit BY NAME; then rows 16-18 with `ceiling_reached: yes` written in the dossier's status line (the line above section 0). The owner may raise the ceiling in writing instead | a route without a ceiling does not end - and a route that stops dead at the ceiling never delivers the dossier, which is the one thing it exists to produce |
| 3 | `waiting_on_owner` is not `none` | skip every row below whose action depends on the answer, take the first that does not; if none, stop and say what is waiting. An undecided light/full mode does not block round 1: the mode is READ from `COST.md` §1's table by the hook's own facts (immutable, or third-party funds without a cap: full; the heavier row wins), light only when no row decides, with its ceiling (light: 3 model rounds + 1 black-box = 4; full: the ceiling stays `undecided` and row 2 cannot fire until the owner sets one), written in `DECISIONS.md` with `source: assumed, owner absent` | the owner's decisions are the owner's |
| 4 | phase 0 or 1 is incomplete (no answered interview, or a spec row that cannot be falsified) | finish it | every later phase is aimed by the spec |
| 4b | phase 2 or 3 is not closed: no compiling hook, or no invariant suite, or no census, or the fork question unanswered (`notes: fork: <what ran against what exists, or n/a - no chain, no manager yet>`) | close it against that phase's gate in `AGENTS.md` §3, measured. An invariant suite is never "not applicable": a hook with no invariant has no promise to test, and that is a phase-1 problem | rows 6-11 judge what phase 3 produced; before it there is nothing to judge |
| 5 | the fuzzer reported a violation of a promise that is not yet a deterministic test | turn the shrunk sequence into a test. Decide: arbiter or contract? (`INVARIANTS.md`). An ENVIRONMENT failure (a path not allowed, a missing directory) is not a violation: fix the config and delete `cache/invariant/failures/<suite>/`, which forge would otherwise replay (`JUDGES.md`, "a replay, not a discovery") | never debug from a campaign |
| 6 | bytecode changed since the last battery, or `battery` is `never` | run the battery | local judge |
| 6b | `battery` is `red` | make it green: fix the code or the test, at the cause. **No model round of any kind runs on a red battery.** One exception, and it is a finding, not a fix: a hostile-token ACTION (`FUZZ-ACTIONS.md` 3) breaks a promise the owner has not decided on - then open the finding (its id, its test seen red), move THAT invariant or action to `pending/<id>.t.sol` OUTSIDE `test/` - forge compiles only the directories it is pointed at, so the battery is honestly green - and run it on purpose with `FOUNDRY_PROFILE=pending forge test --match-path 'pending/*'` from a `[profile.pending]` whose `test = "pending"` (the same mechanism the sandbox uses for `sim/`; without `--match-path` forge also runs the base suite the pending file imports, a whole extra campaign). Then delete `cache/invariant/failures/<suite>/` AND `corpus/` for the everyday suite (its action list changed shape: `JUDGES.md`, corpus): that counterexample is now the pending test's red, and forge would replay it into the battery. Give the finding a PROVISIONAL severity on `SEVERITY.md` (marked `provisional`, the owner's triage sets it); a provisional high is row 1's, write `pending: <id> - <promise>, owner undecided` in `STATE.md` `notes:`, and the round brief names it. Never silently leave the hostile action out | an auditor's first act is to reproduce the baseline; a red one means they are attacking something else |
| 7 | bytecode changed since the last long fuzz or since the other local judges ran, and the battery is green | run the long fuzz (corpus on; it runs the suite phase 3 wrote - if there is none, row 4b came first) and set `last_long_fuzz=no`; then the other local judges that apply: static triage (Slither if the owner allowed the install; otherwise `forge lint` and the line `static triage: forge lint only, Slither not installed` in `STATE.md` - the row does not wait on the owner), coverage by branch, mutation (`JUDGES.md`) | local judges; a violation here is a finding you did not pay a round for |
| 7b | the target chain is known, the hook runs on Uniswap v4's `PoolManager`, and `real_manager_battery` is `never` or `stale` (a hook on its own or another manager: answer the question - does the code I test run against the thing that exists? - another way, `AGENTS.md` 6b, and write what replaced it in dossier §8 - owed before rows 12 and 16, never before round 1; a substitute answered in §8 is not a skip and needs no owner's yes, a judge not run at all is) | fetch the real pool manager's bytecode and run the battery against it (`scripts/fetch-bytecode.sh`, then `V4_MANAGER=fixture scripts/battery.sh` - through the script, which gives each manager its OWN fuzz corpus; a bare `forge test` needs `FOUNDRY_INVARIANT_CORPUS_DIR=corpus/invariant-fixture`, or the other manager's corpus replays as a counterexample that is not one). No endpoint? Ask the owner to set `RPC_URL` in their own terminal - never in the chat - and wait (row 3) | local judge, and the only one that meets the manager that exists. A suite that SKIPPED this leg has not run it |
| 8 | an ACCEPTED or FIXED finding (row 9 triaged it) came from outside the fuzzer and has no rule for it yet | add the invariant and/or the action that would have caught it; show it fails on the old code. A finding no fuzz action can reach (constructor arguments, deployment) gets a unit test instead and the line `not fuzzable: <id> - <why>` in `STATE.md` `notes:`; the row is then quiet for it | the growth rule (`AGENTS.md` 6.7); an untriaged finding is row 9's, not this row's |
| 9 | there are open findings from the last round with no answer, and the owner is there to answer | triage each: fix at the cause / refuse in writing / accept with a number (the owner accepts). Then rows 6-8 | `TRIAGE.md` |
| 9b | open findings FROM A ROUND (row 9's) wait on the owner's triage and the owner is not available now (an exercise, or away) - phase-3 `pending:` findings do not trigger this row (no triage is asked before a round): they ride into round 1 in its brief, they are listed in dossier section 4 with status `pending - owner undecided`, and a provisional high among them is row 1's | write the dossier skeleton anyway: each open finding listed by id in section 4 with status `open - owner triage pending`, sections 0, 4, 5, 6, 7, 8, 9 honest; then set `waiting_on_owner: triage of <ids>` in `STATE.md` (row 3 now holds the table), STOP and wait. Nothing moves to promotion | a dossier with open findings is a status report, not a handoff |
| 10 | only documents, comments, scripts or tests changed since the last round (before any round: false), and they make claims about the code | a **verifier pass**: one agent, short brief, "falsify these sentences" | no bytecode, no adversarial round |
| 11b | a model round was STOPPED by the environment before delivering (the harness, the provider's classifier), not by the ceiling | retry ONCE, a fresh agent, the same brief; stopped again: the round counts as spent, dossier section 9 gets `not run: stopped at <step>` and `STATE.md` `notes:` gets `round <id> stopped`, then the skeleton (row 9b's file, phase-3 pending findings ride in it) | a stopped round is neither clean nor finding-free (`ORCHESTRATION.md` §4) |
| 11 | no adversarial round has ever run, the battery is green, and rows 4-7 are quiet - 4b included: no round 1 without phase 3's suite - (7b, the real manager, may still be waiting on the owner: it is required before rows 12 and 16, not before round 1) | round 1: a DISCOVERY round, reads everything | |
| 12 | at least one round has run, the battery is green, the spec's promises did not change in the last triage (no triage yet counts as unchanged), and `blackbox` is `never_run` (not `skipped_by_owner`: that is a recorded decision, and it goes in the dossier) | the black-box round, on a source-free bench | it finds what reading cannot, and it re-aims every later round - so it goes EARLY |
| 13 | bytecode changed since the last audit round, and the battery is green | a REGRESSION round, **aimed at the diff** and at the two or three places trusted least | |
| 13b | `last_audit_round` closed with 0 high and 0 medium but was NOT a discovery round (or a REASONED high or medium is still open). Black-box and verifier rounds never trigger this row: they are in `last_other_round` | close what is REASONED (test it, ask the owner, or hand it to the human audit by name); then a DISCOVERY round: no earlier reports, pointed also at the "does not apply" list and the spec's assumptions | a regression round inherits the blind spots of the rounds it read; only an independent look can close the loop |
| 14 | `last_audit_round` was a **discovery** round (no earlier reports in its brief) and closed with 0 high and 0 medium, no REASONED high or medium is open (`EVIDENCE.md` 3), AND no bytecode changed since - OR the ceiling was reached and every open finding is triaged or handed to the human audit by name (row 2) | the loop is over. Go to row 15 | the exit criterion is a STOP RULE for spending, not a security claim: zero findings from one model family is not evidence of absence, and the dossier says so. In full mode the closing discovery round runs on a different vendor when one is available; "none available" is a declared limit in the dossier |
| 15 | the loop is over, and `blackbox` is `stale` or `never_run` | the black-box round (a second one, if it is `stale`) | the first one attacked a spec that no longer exists - or row 12 never fired, because the promises kept changing until the end |
| 16 | the loop is over, `blackbox` is `current` or `skipped_by_owner`, and the owner wants to freeze a release candidate | promotion (phase 6): canonical copy, manifest, guard, reproducible bytecode, stale-build check | only for code that has stopped moving |
| 17 | promoted, and a deployment runbook is part of the dossier | rehearsal (phase 7): an agent that did not write the runbook follows it literally on a fork | |
| 18 | promoted (and rehearsed, if applicable) | the handoff dossier (phase 8). **STOP. This is the end of the route.** | the next step is human |
| 18b | **light mode**: the loop is over (row 2's ceiling, or a CLEAN discovery round), and the owner declined promotion in writing (`COST.md`: light mode skips phase 6) | the handoff dossier (phase 8) with the promotion and rehearsal judges (this table's rows 16-17) marked in dossier section 6 "not done: light mode, owner's decision" and section 9 saying what promotion would have added. **STOP.** | the next step is human |

## The loops inside the table

- **Any bytecode change, at any phase, sends you back to row 6.** Including after promotion: a promoted artifact
  whose source changed is no longer promoted - reopen it on purpose, `CHANGES.md` section 4. Fix, battery, long fuzz, a diff-aimed round, then promote again.
  Expect this to happen at least once; the late rounds and the black-box exist to cause it.
- **A black-box divergence is fixed in the document or in the code.** If in the document, row 10 (verifier). If
  in the code, row 6.
- **The battery means both managers, once the chain is known.** From the moment the owner names the target chain,
  "the battery is green" includes a run against the real bytecode of that chain's pool manager
  (`scripts/fetch-bytecode.sh`, `V4_MANAGER=fixture scripts/battery.sh`). A suite that SKIPPED that path has not run it. Required
  before row 12 and before row 16.
- **What counts against the ceiling:** every model round - adversarial and black-box alike - counts as one. Verifier
  passes do not count, but they get a ROUND line in `LOG.md` like everything else. "Light mode: 3 rounds and a
  black-box" is a ceiling of 4.
- **If you take the same row twice in a row and nothing changed in between, or NO row is true, STOP.** You forgot to update a flag, or
  the table has a hole. Say which, in `STATE.md`, and ask - do not invent a flag change to get moving again. A reviewer
  found this table non-total once (light mode at its ceiling with a medium open had no row to phase 8); the fix was
  row 2, not a flag.
- **Ceremony check.** If the last hour of work produced no test run and no measurement - only state files, briefs
  and prose - stop and run one. The three state files exist so that work can be RESUMED, not so that they can be
  polished; an agent that spends its budget on them has walked the route without touching the code.
- **Rows 6-8 are local** - tools on the owner's machine, CPU time and nothing else. Rows 11-13 and 15 are run by a
  model and spend tokens. The table is ordered so that you never reach a model row while a local one is still true.

## Judgement calls the table cannot make for you

- **"Did the spec's promises change?"** Yes if a row of the hostile-actor table, an invariant, an admission rule
  or an event's meaning changed. No if only numbers, wording or examples did.
- **"Which places are trusted least?"** The orchestrator's call, written in the brief. Default: whatever the last
  fix touched, anything on the hot path that gained a branch, and the oldest accepted trade-off nobody has
  re-measured.
- **Which of two fixes?** Not a judgement call: build both and read the numbers. `CHANGES.md` section 2.
- **Fix the code or fix the sentence?** When the code does what was designed and the sentence promised more, fix
  the sentence. When the sentence is what the owner actually wants, fix the code. If you cannot tell, that is an
  owner decision: row 3.
