# Arriving at a hook that already exists

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
| `open_findings` | the last review report, and whatever the project uses as a log. Anything reported and never answered is open |
| `last_audit_round`, `last_other_round` | same place |
| `ceiling` | ask the owner. An existing project almost never has one written down |
| `real_manager_battery` | grep the tests for `vm.etch`, `readFile`, `createSelectFork`. A suite that etches the real manager's bytecode, or runs on a fork of the target chain, has answered this - however it is named |
| `waiting_on_owner` | ask |

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

1. A bench of your own (`scripts/bench.sh`), never their working tree. Reproduce THEIR battery first, and their numbers.
   If you cannot, stop: everything after that is about a different project.
2. Each row of the ladder, with the result read from the output. Expect to diverge (`AGENTS.md` section 6b): a hook
   near the size limit will not compile for plain `forge coverage`; mass mutation must be aimed at one file and at the
   fast tests; a second engine may not be installed. Write every divergence as question / substitute / why.
3. `HOOK-ATTACKS.md`, class by class, against their spec. **The classes nobody decided are the finding** - prior
   reviews answer the questions somebody thought of; a fixed list asks the ones nobody did.
4. New tests are PROPOSALS: proven in your bench (they pass on the code, and they kill the mutant they exist for),
   handed over in a scratch directory. The owner's process promotes them.
5. A draft of the dossier from what exists, "not done" where it does not.
6. If something looks like a real bug: stop, write the deterministic test, tell the owner. Do not fix it.

Tell the owner before the long steps. Calibrate mutation on the smallest file first (`JUDGES.md`).

## 4. What you will not have, and should say

The reasoning behind old decisions, unless they wrote it down. Whether earlier reviews shared one model family's blind
spots. Whether the people who wrote the tests also wrote the code they test. Put these in "what was NOT checked".
