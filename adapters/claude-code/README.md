# Adapter: Claude Code

This is the path the method was actually run on. Everything here is a convenience over the core; if any of it
breaks or ages out, the core still works - `AGENTS.md`, the briefs and the scripts depend on no vendor feature.

## Roles to subagents

Run each role as a **separate subagent with a fresh context**. The isolation is the point: an auditor that has
watched you write the code has already learned the semantics, and stops being able to see the gap between the
code and what the spec promises.

| role | subagent | model tier | why |
|---|---|---|---|
| orchestrator | the main session | the strongest reasoning model you have | it writes the briefs, reads every report in full, and decides. This is the highest-leverage choice in the whole method |
| auditor | one per round, fresh. DISCOVERY rounds get no earlier reports at all; REGRESSION rounds get the diff and the accepted list | strong | it has to measure, not opine. A cheap model here produces rounds that cost you triage time |
| black-box attacker | one per round, fresh, **isolated bench** | strong, ideally a **different vendor** | see `doctrine/LESSONS.md` §9 |
| verifier | one, fresh | strong, ideally a different vendor | it re-derives; shared blind spots are cheapest to break here |
| executor | one per task | strong for Solidity, mid-tier for documents | it applies a decision verbatim through gates; it does not need to invent |
| scribe | one | mid-tier | keeping `STATE.md`, `DECISIONS.md` and `LOG.md` current is cheap work that must actually happen |
| judge | **not a model** | - | Foundry |

Match the model to the difficulty. Do not default everything to the most expensive one; the cost shows up in
the ROUND lines of `LOG.md` and you will want it to be honest.

## Launching a round

1. **Write the brief to a file** in the owner's project, from the template in `briefs/`. Do not improvise it in
   the prompt. The brief is the artifact that makes a round reproducible and comparable.
2. **Create the bench** (`scripts/` has the helper): a copy of the project at `$HOME/.gauntlet/bench/<round>` (`BENCH_ROOT` to change it), dependencies
   symlinked from a shared directory, never the shared working tree itself.
   For a black-box round, build the bench **without the implementation source** and check it by listing the bench
   before you launch.
3. **Launch the subagent** with: the path to the brief, the path to the bench, and nothing else. If you find
   yourself explaining the task in the prompt, the brief is incomplete - fix the brief.
4. **Let it write its own report** incrementally in the project. Do not ask it to return the findings in its final
   message; a final message is lost, a file is not.
5. When it finishes, **read the report in full**. Never act on the subagent's summary. Then check it the way
   `doctrine/VERIFY.md` says: reproduce the findings on a bench of your own, verify with your own mutants, ask why each
   gate is green.
6. Write the round's ROUND line at the top of its `LOG.md` entry, update `STATE.md`, and only then start the next round.

## One round at a time

Two reasons, and the second is the one people underestimate.

**Mechanical:** parallel agents compiling in the same directory clear each other's build artifacts. One bench per
agent, always.

**Editorial:** a report that lands while you are mid-fix cannot be acted on cleanly. You do not know whether its
findings are against the code you have or the code you had. If you must run two, give each its own bench, and
require each report to **declare** any edit it observed landing underneath it.

## Permissions and safety

- Never allow a broadcast, a key, or a write outside the bench and the scratch directory. Say so in every brief,
  not only in the settings.
- Agents die on rate limits. Every brief says "write the report incrementally" and "retry once on a rate limit",
  so a death costs minutes instead of a round.
- Long fuzz campaigns are tens of minutes. Run them in the background and check the campaign's census, not only the
  suite result.

## Slash commands

Not shipped in v0. The briefs are the source of truth; a command that wraps a brief is convenience, and it is the
part of this repository most likely to be out of date with the tool. If you build your own, keep them thin: fill
placeholders, create the bench, launch the subagent. Do not put doctrine in a command.

## Project memory

Put a `CLAUDE.md` in the **owner's project** with: the path to this kit, the current phase, the non-negotiable
rules (no broadcast, no keys, bench naming, which directories are writable), and a pointer to `STATE.md`. Keep
volatile numbers out of it, or add it to the stale-number list in `SPEC.md` section 8 - that list exists precisely
because hand-copied numbers rot.
