# Orchestration: how one strong model runs cheaper agents without fooling itself

`VERIFY.md` says how to check delegated work. This page says how to set the work up so that there is something honest
to check. Every rule below is here because breaking it cost something measurable while this kit was built; the cost
is named next to the rule.

## 1. One agent, one brief, one bench, one scratch directory

- **The brief is a file**, written before the agent starts, naming what it may read, what it may edit, what it must
  never touch, and what it must deliver. An agent briefed in the chat is briefed by a transcript nobody can audit.
- **A bench per agent, under a name that did not exist before.** `scripts/bench.sh` writes a marker (`.gauntlet-bench`) and refuses
  to refresh a directory that exists without it; never bypass that check: a reused name let a refresh with `--delete` wipe another
  audit's working copy - seven times in one day, all by the orchestrator's briefs.
- **A scratch directory per agent, named in the brief.** An orchestration harness may give every subagent the SAME
  session scratch directory. In a blind test that is contamination: one arm's finding tests sat, readable, in the
  directory the other arm was using. The second arm's result could only be recorded as self-declared.
- **Parallel agents never share a working tree they both write.** If one writes the tree the orchestrator commits,
  the orchestrator commits by file name, never `git add -A` - a sweeping commit once carried another agent's unreviewed
  work under a doctrine commit's message.

## 2. The author never certifies

- **Whoever wrote it does not verify it.** A fresh-context verifier, told to falsify, catches what the author cannot:
  in this kit a verifier caught a wrong causal story, un-counted gas that reversed a product conclusion, a bypassable
  price floor, and a phishing path that sent a real transaction.
- **The verifier does not fix.** It records what held, what did not, what it could not check. The orchestrator decides.
- **The orchestrator runs the gates itself before any commit** - the battery, the self-test, `scripts/release-guard.sh` from phase 6 on - on
  its own bench, and reads the numbers. An agent's "all green" is a claim; the orchestrator's run is the evidence.

## 3. Read the report, reproduce the load-bearing claim

- Read the subagent's report, not its transcript. Then reproduce, yourself, the one claim everything else rests on.
- **A number that moves when only the instrumentation moved is a defect of the meter until proven otherwise.** A gas
  figure rose 11-18 % between two runs with identical decisions; it was the test's own memory growth inside a
  `gasleft()` window, and a recommendation had already been drawn from it.
- **Before blaming the system under test, point at the line.** Twice in one day the orchestrator said "this is the
  contract, not the simulator" and both times it was the simulator. The rule is the one the kit gives auditors: no
  culprit without the line.

## 4. What the environment may refuse, and what to do about it

Two refusals were observed while running the route with agents. Neither is a defect of the kit; both change how a
step is written.

- **The harness may refuse a subagent permission to write report files** ("return findings as text"). Seen twice. The
  orchestrator saves the returned text to the report path itself and says so in the report's header.
- **The model provider's safety classifier may stop an agent at a step whose declared purpose is to produce an
  offensive artefact.** Seen three times, always at the same kind of step: writing a target with planted defects and
  its proof-of-concept exploits (twice, with an instruction not to retry even reworded), and writing a new
  "adversarial" agent for a specific hook (once). It was **not** seen on anything else the route asks for - tests that
  falsify a spec's promises, verifier rounds, black-box rounds, a phishing test of an app, or measurement with the
  sandbox's shipped population - across two days of such work. This is an observation, not knowledge of the
  classifier's rules, which are the provider's.

  So the route is written so that **no required step asks an agent to author an offensive artefact**:
  - findings are **tests of promises** (`AGENTS.md` 6.3), and the sandbox **measures with its shipped population**,
    parameterised for the hook (a binding and parameters, not a new attacker);
  - targets with known bugs for a blind test are **never written by an agent**: they come from public hooks with
    public fixes (the key is the fix) or from tool-generated mutants. Say which, and what it costs: a public fix may be
    in the auditor's training data, and a mutant is weaker than a real bug;
  - never rephrase a refused request to get it through. If a step the dossier needs was stopped, the dossier says so:
    `not run: stopped at <step>` in section 9. An economic defect that only a hook-specific strategy can show is then a
    known ceiling of the simulation judge, stated as one.

## 5. Match the model to the work, and let the route do its job

Measured once (blind run 2, `README.md` *Status*): on the same target and brief, a strong model reached every planted
defect in one discovery round; a cheaper one reached the same score only after the black-box and the verifier rounds,
for at least twice the tokens. So:

- a cheaper model is a fine worker **inside the route** - the route is what lifts it (as an orchestrator it is unmeasured;
  do not read this run as evidence either way);
- give decisions (doctrine, triage, what enters a recommendation) to the strongest model available, and grinding
  (mutants, sweeps, fixes against a written brief) to the cheaper one;
- nothing becomes a recommendation to the owner without a verifier that is not its author.

## 6. Cost is part of the record

Every agent's cost goes in its ROUND line (`state/README.md`). The harness does not always return a subagent's usage;
then the field says `not reported`, never an estimate written as a measure.
