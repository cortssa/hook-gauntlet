# Adapter: Codex

> **UNTESTED - confirmations welcome.**
>
> Nobody has run this route end to end on Codex. This file is written from the documented conventions and from
> the shape of the core, which is deliberately vendor-neutral. Treat every instruction here as a proposal. If you
> run it, please open an issue saying what worked and what did not; that is the most useful contribution this
> repository can receive right now.

## Why it should work at all

The core of this kit is `AGENTS.md`, Markdown briefs and plain bash scripts. `AGENTS.md` is the convention Codex
and several other tools read on their own, so pointing the tool at the project should be enough for it to find
the route. Nothing in `doctrine/`, `briefs/`, `state/`, `foundry-kit/` or `scripts/` depends on a feature of one
vendor.

## Roles as separate tasks

The kit needs each role to run with a **fresh context** and its **own working directory**. Run each round as a
separate task or session, not as a continuation:

| role | how to run it |
|---|---|
| orchestrator | your own long-running session, holding the plan and reading the reports |
| auditor | one task per round, started from the brief file, working in `~/hg-a<NN>`. A DISCOVERY round's task is given no earlier reports at all; a REGRESSION round's task gets the diff and the accepted list |
| black-box attacker | one task, working in a bench that **does not contain the implementation source** |
| verifier | one task, ideally on a different vendor's model than the one that produced the fixes |
| executor | one task per applied decision, stopping at the first failed gate |
| scribe | one task, or fold it into the executor |

Start each task by pointing it at **one file**: the brief. If you have to explain the task in the prompt, the
brief is incomplete.

## Bench isolation

The black-box round's isolation must be **physical**. Build the bench so the source is simply absent, and list
the directory before launching to confirm. Do not rely on an instruction not to read a file - this is true on
every tool, and it is the single adaptation most likely to be skipped.

## Reports on disk, not in the reply

Every brief says to write the report incrementally to a file. Keep that. A task that ends, is interrupted, or
hits a limit then loses nothing, and the orchestrator reads the file rather than a summary.

## Chat-only tools

A conversational assistant with no terminal can usefully do **phase 0 (owner interview)** and **phase 1
(falsifiable spec)**, and can read finished reports. It cannot do phases 2 through 8: those need a toolchain,
because the judge in this kit is execution, not a model.

## What would count as a confirmation

If you try this, the useful report is:

1. did the tool find and follow `AGENTS.md` without being told to;
2. did a round run to completion from a brief file alone;
3. did it write the report incrementally, or only at the end;
4. did bench isolation hold, including for the black-box round;
5. round count, findings, false alarms and cost, so the numbers can sit next to the other adapter's.
