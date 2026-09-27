# Arriving at a hook that already exists

*An existing hook with **no tests and no history** - no audits, no reports, no log, nothing to derive a flag from -
does not start here: it takes the new-project route from phase 0 (`QUICKSTART.md`), the code as the sketch to specify
(phases 0 and 1 write its spec; this is not `phase: sketch`, which only the owner declares - `NEXT.md` row 0). This
file is for a project with tests, audits or a history to derive the flags from.*

`AGENTS.md` offers two ways in: from an idea, or "test an existing hook hard". Everything else in this kit is written
for the first. This file is for the second: a project with its own history, its own documents, possibly in another
language, and an owner who may have told you **not to modify it**.

## 1. You do not have to install anything

The state convention (`STATE.md`, `DECISIONS.md`, `LOG.md`) is how a project that GROWS with this kit
remembers itself. A project that already has a memory does not need a second one. **Derive the state read-only, into
your own report**, and install the convention only if the owner asks for it.

The flags `NEXT.md` needs, and where an existing project usually keeps them:

| flag | look in |
|---|---|
| `phase` | is there a frozen release (a canonical copy, a tag, a manifest of hashes)? then 6-8. A spec and a green battery but no rounds? 3. No spec you could falsify? 1, whatever the code looks like |
| `bytecode_changed_since` | `git log` on `src/` against the dates of the last test run, the last long fuzz, the last review, the last release. No git? compare hashes against the manifest |
| `battery`, `blackbox` | run their battery yourself: green or red. Has a source-free review ever happened? usually `never_run` |
| `open_findings` | the last review report, and whatever the project uses as a log. Anything reported and never answered is open. Each open high by its id, in parentheses after the count: `high=2 (F-3, R2-1)` (none when it is 0) |
| `last_audit_round`, `last_other_round` | same place |
| `ceiling` | ask the owner. An existing project almost never has one written down |
| `real_manager_battery` | grep the tests for `vm.etch`, `readFile`, `createSelectFork`. A suite that etches the real manager's bytecode, or runs on a fork of the target chain, has answered this - however it is named |
| `waiting_on_owner` | ask |
| `rehearsal` | is there a deployment runbook? none: `n/a (no runbook)`. One, and a record of someone who did not write it following it on a fork: `done (YYYY-MM-DD)`, the day it was followed; otherwise `not yet` |

Write the derived flags at the top of your report, each with **where you read it**. A flag you could not establish is
`unknown`, and an `unknown` on `bytecode_changed_since` means: run the local judges again: they cost CPU time and nothing else.

## 2. Map their documents onto the questions, not onto the templates

You are looking for the ANSWERS the templates ask for, wherever they live:

- the promises, and what a hostile actor can do (spec section 3) - may be a threat-model section, a README, a series of
  review replies. If it exists only in people's heads, that is your first finding, and phase 1 is where you are;
- the invariants in words (section 4); the admission or configuration rules (5); the accepted trade-offs **with
  numbers** (6); what is out of scope (7); the measured numbers (8).

Do not translate or re-shape their documents. Cite them by file and section in your own report. If the spec is in a
language the eventual auditor may not read, say so in the dossier (`briefs/handoff-dossier.md`).

## 3. The free-judges pass: the natural first job

On a finished project the cheapest useful thing is `JUDGES.md` from top to bottom, on a COPY, changing no bytecode:

1. A bench of your own (`scripts/bench.sh`), never their working tree: set `BENCH_ROOT` to a directory OUTSIDE their
   tree. No script of the kit writes into a tree where its convention is not installed (`<project>/.gauntlet/` does
   not exist): each refuses before writing anything, says why, and asks for a place outside it -
   - `bench.sh`, `mutate.sh`, `fuzz-long.sh`: their default bench (`<project>/.gauntlet/bench`) - set `BENCH_ROOT`;
   - `battery.sh`, `size.sh`, `census.sh` (the run and the `--aggregate` gate), `mutate.sh` and `fuzz-long.sh`
     (`USE_BENCH=0` too): their reports (`<project>/.gauntlet/reports/` by default) - set `OUT_DIR` outside the tree.
   A bench is yours: `bench.sh` marks it (`.gauntlet-bench`), and the scripts write their reports inside it, so the
   simplest way is to run everything in the bench, `USE_BENCH=0` for `fuzz-long.sh` there. `OUT_DIR` moves the reports
   only: a battery, a census or a long fuzz run IN their tree still leaves forge's `out/` and `cache/` (and the census
   file, the corpus) in it. Reproduce THEIR battery first, and their numbers.
   If you cannot, stop: everything after that is about a different project.
2. Each row of the ladder, with the result read from the output. Expect to diverge (`AGENTS.md` section 6b): a hook
   near the size limit will not compile for plain `forge coverage`; mass mutation must be aimed at one file and at the
   fast tests; a second engine may not be installed. Write every divergence as question / substitute / why.
3. `HOOK-ATTACKS.md`, class by class, against their spec. **The classes nobody decided are the finding** - prior
   reviews answer the questions somebody thought of; a fixed list asks the ones nobody did.
4. New tests are PROPOSALS: proven in your bench (they pass on the code, and they kill the mutant they exist for),
   handed over in a scratch directory. The owner's process promotes them.
5. A draft of the dossier from what exists, "not done" where it does not.
6. If something looks like a real bug: stop, write the deterministic test, tell the owner. Do not fix it: the owner
   decides. While they are absent the red test goes to `pending/` as a finding with a provisional severity, and the
   battery stays honestly green (`NEXT.md` row 6b).

Tell the owner before the long steps. Calibrate mutation on the smallest file first (`JUDGES.md`).

## 4. What you will not have, and should say

The reasoning behind old decisions, unless they wrote it down. Whether earlier reviews shared one model family's blind
spots. Whether the people who wrote the tests also wrote the code they test. Put these in "what was NOT checked".
