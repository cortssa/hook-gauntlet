# AGENTS.md - hook-gauntlet

If you were asked to take a Uniswap v4 hook from an idea to audit-ready, or to test an existing one hard, start here.
Read this file to the end before you touch anything. It is written for an agent with no prior context.

## 1. What this kit is

A route, in nine phases, each with a gate. You walk it with the owner of the hook. The output of the last phase is a
**dossier for human auditors**, not a deployment.

The kit gives you: doctrine (how the adversarial loop works and why it converges), brief templates (one per role),
a state convention you install in the owner's project, a Foundry kit (hostile token, invariant skeleton with a
call-and-success census, a worked toy example, and a v4 module in `foundry-kit/v4/`: a harness that runs one suite
against a pool manager compiled from source or against the real bytecode of the one deployed on your chain, address
mining for the permission bits, and a small worked hook), and scripts (battery, long fuzz, campaign census, per-agent bench, mutants, publication guard, stale-build check, and a self-test of all of them).

**Read upstream first.** This kit is a method, not the documentation of Uniswap v4, not a hook library, and not the
ecosystem's security standard. Those exist and are maintained by the people who own the protocol:
`doctrine/UPSTREAM.md` lists them (the official v4 docs, the `v4-template`, the Uniswap Foundation's Hook Security
Framework, OpenZeppelin's hook library), gives a topic-by-topic table of where each fact lives - including the two
indexes those sites publish FOR agents (`llms.txt`) - and says where each plugs into the route. **Never state a fact
about the protocol, the toolchain, the compiler or the target chain from memory: fetch the page, cite it with the
date.** Where upstream and this kit disagree, upstream wins.

**Golden rule: the route ends at "audit-ready". Never at deploy.** Do not broadcast a transaction. Do not write,
read or ask for a private key. If the owner asks you to deploy, say that this kit stops one step earlier and that
the next step is a human audit.

**Scope rule: only code the owner owns or is authorised to test, and only on a local bench.** Every "attack" in
this kit is a Foundry test run against a local copy or a local fork. Nothing here is pointed at a contract somebody
else deployed, at a live network, or at real funds. If you are asked to use these methods against a third party's
live contract, that is outside this kit: stop and say so.

**Second rule: no model is the judge - and no single test is, either.** A test is evidence only after it has been
SEEN RED on code that is wrong in the way the test claims to detect; a passing test nobody has watched fail is a
label, not evidence. A finding you cannot compile still counts - labelled REASONED, triaged like the rest, its severity
set by the owner's triage and never argued down by the round that would like to close. Passing every gate does not mean "secure": this
process measures how much of the STATED security model got tested, and says where that stops (`doctrine/EVIDENCE.md`).
**Words you never write about a hook this route has touched** - in a dossier, a report, a README, a commit message or a
reply to the owner: "safe", "secure", "battle-tested", "fully verified", and "audited" as a claim about the hook (the
audit is the human step after this route). Each one claims an outcome - no exploitable bug, or a review by people with
security training - that nothing in this kit measures, and each is a sentence a paid auditor would have to walk back.
The defensible phrase is "adversarial pre-audit testing, including invariant fuzzing, mutation testing, hostile-token
testing and independent review rounds" - with only the parts that were actually done, each pointing at its evidence label.
Agents propose and attack. What decides whether a claim is true is
execution: a Foundry test that passes, a fork run, a fuzz campaign.

## 2. The roles

One agent can hold several roles in a small project. Keep them separate in writing even when they are not separate
in wall-clock time.

| role | does | must not |
|---|---|---|
| **orchestrator** | holds the plan, writes the briefs, reads every report in full, REPRODUCES what it is told before acting on it (`doctrine/VERIFY.md`), decides | run the rounds itself while a round is open; believe a result it did not check |
| **auditor** | attacks the code with a fresh context, one round at a time, and reports with measurements | edit the code under audit |
| **black-box attacker** | attacks the *promises* in the spec from outside, without the source | open the source, or read earlier reports |
| **executor** | applies decisions verbatim, through gates, and stops at the first gate that fails | improvise a fix the decision did not authorise |
| **scribe** | keeps `STATE.md`, `DECISIONS.md` and `LOG.md` current | invent a number it did not read from an output |
| **judge** | **is the execution**: the test suite, the fork, the fuzzer | be a model |

Run **one round at a time**. Parallel auditors on the same bench destroy each other's build artifacts, and a
report that arrives while you are mid-fix cannot be acted on cleanly. If you do run two, give each its own bench
directory and make each declare, in its report, any edit it saw land underneath it.

## 3. The nine phases and their gates

Each phase has a brief template in `briefs/`. Fill the `{{PLACEHOLDERS}}`, do not rewrite the rules.

**Not every project walks all nine.** Phases 0-4 and 8 are the core. Phase 5 is part of the core too, and
belongs EARLY - after the first or second adversarial round, not after the last. Phases 6 and 7 are for a release
candidate that has stopped moving. Size the route to the stakes with the owner in phase 0, and write a ceiling
(rounds or money) in `DECISIONS.md`: see `doctrine/COST.md`. A toy does not need what an immutable contract
holding third-party funds needs, and the reverse is worse.

**If the idea itself is still moving, you are not on the route yet.** That is sketch mode: local judges only, no
model rounds, and nothing leaves it without passing through phase 1. `doctrine/CHANGES.md` section 1.

| # | phase | you produce | gate to pass (all of it, measured) |
|---|---|---|---|
| 0 | **Owner interview** | scope, threat model, non-goals | the owner has answered every question in `briefs/owner-interview.md` - an explicit dated "undecided" is an answer, listed as a blocker for the phase that needs it - including the self-score against the Uniswap Foundation's security framework (`doctrine/UPSTREAM.md`; offline, `UNVERIFIED` and the route continues, `QUICKSTART.md` step 6) - and the answers are written in `DECISIONS.md` |
| 1 | **Falsifiable spec** | `SPEC.md` | every class in `doctrine/HOOK-ATTACKS.md` is decided (applies / does not apply, with its predicate / accepted / prevented by an admission rule); the assumptions the spec stands on are listed; the "what a hostile actor can do -> what the contract answers" table covers every external entry point; invariants are written in words; out-of-scope is explicit; the owner has read it (absent: `waiting_on_owner`, as in phase 0) |
| 2 | **Foundry sketch** | a compiling hook | `forge build` compiles (forge's lint warnings are row 7's static triage, not a build failure); runtime size measured and under the target chain's code-size limit (24,576 bytes on Ethereum, EIP-170 - check your chain's current limit, and the EIPs in flight), AND initcode size under the initcode limit (49,152 bytes on Ethereum, EIP-3860: a hook is deployed by CREATE2 from initcode that carries its constructor arguments), both margins written down; built on the official `v4-template` layout (a hook on no v4 manager: its own layout, named in `DECISIONS.md` - that is not a divergence) |
| 3 | **Battery** | unit + fork + invariant tests | 100% green, not 99%; at least one fork test against the real tokens and periphery of the target chain - the kit ships no fork suite, so this is written for the hook, and if the owner has no endpoint it is "not done" in the dossier with that reason; invariant suite running against the hostile-token mock; **`fail_on_revert = true` AND the census, as a pair** - the first without the second is the false green `JUDGES.md` warns about, because the way to satisfy it is a handler that swallows everything; **invariants and fuzz actions derived for THIS hook** (`doctrine/INVARIANTS.md`, `doctrine/FUZZ-ACTIONS.md`) - the ones that ship are the floor; every action shown to SUCCEED in the census, not merely to be called |
| 4 | **Adversarial loop** | one report per round | **a DISCOVERY round with zero high and zero medium findings, and no REASONED high or medium left open**. See `doctrine/LOOP.md` |
| 5 | **Black-box** | a divergence report | every promise in the spec has been tested from outside; every divergence is either fixed or written into the spec |
| 6 | **Promotion** | canonical copy + manifest | the loop is over and the black-box round is current (`NEXT.md` rows 14-16) - or the owner decided in writing to skip it, and the dossier says so under "not checked"; copy is byte-identical to the sketch; hash manifest reproduces; drift guard fails when it should; the **bytecode** reproduces, not only the source |
| 7 | **Rehearsal** | a followed runbook | an agent that did not write the runbook follows it literally on a fork, simulated only, and reports every step that was wrong, out of order or missing; AND it asserts that `HookMiner.find(deployer, flags, initcode)` with the runbook's DEPLOYER and constructor arguments reproduces the recorded salt and address byte for byte - the triple upstream names as the usual cause of a failed hook deployment, and the one thing a rehearsal by a different party can check without a key |
| 8 | **Handoff** | the dossier (`briefs/handoff-dossier.md`) | every "must" section filled or marked "not done" with a reason; what the judges said, read from outputs; every divergence; a non-empty list of what was **not** checked; a fresh agent can reproduce the numbers from the dossier alone |

**Phase 8 is the end.** Hand the dossier to humans.

## 3b. What do I do next?

The phases say what exists. **`doctrine/NEXT.md` says when.** It is a decision table: take the first row whose
condition is true. Run it every time you arrive with no context and every time you finish anything. It is how you
know that the battery and the long fuzz come before a model round, that the black-box goes early, that a change
with no bytecode gets a verifier and not a round, that a change after promotion sends you back, and when to stop.
`scripts/next.sh <STATE.md>` computes it from the flags: it refuses a flag it cannot read, and names the row, or the rows
that need your judgement first (`state/README.md`).

## 4. State on disk

Before phase 0, install the state convention in the owner's project: copy the three files from `state/` into
`.gauntlet/` (the default; the project root also works - write which in `STATE.md`) and empty the examples, which
describe a fictional hook:

```
mkdir -p .gauntlet/briefs .gauntlet/reports
cp <kit>/state/STATE.md <kit>/state/DECISIONS.md <kit>/state/LOG.md .gauntlet/

STATE.md        current phase, what is open, what blocks it
DECISIONS.md    one entry per owner decision, dated, with the reason
LOG.md          one entry per change, never for reads
```

Everything the route produces for the hook lives beside them: `.gauntlet/SPEC.md` (phase 1; a project that already has
its own `SPEC.md` keeps it, and the route's spec links to it rather than copying), the filled briefs in
`.gauntlet/briefs/` (`00-interview.md`, `r01.md`, …), the round reports in `.gauntlet/reports/`, the dossier or its skeleton at `.gauntlet/DOSSIER.md`. The commands for every
judge, with what "done" looks like, are in `QUICKSTART.md` step 8.

Any agent that arrives with no context reads those three files and continues. If they disagree with the repository,
the repository wins and you fix the files. Write to them **incrementally**: an agent that dies mid-round loses
nothing if the report and the state were written as it went.

## 5. When you STOP and ask the owner

Stop, write the question in `STATE.md`, and wait. Do not choose for them:

- **Scope.** Anything that widens what the hook does, or adds an entry point.
- **Skipping a core phase.** The owner may decide to skip the black-box round, or any other gate - it is their
  project. You may not decide it for them, and you may not do it quietly: say what the skipped step would have
  answered, write the decision in `DECISIONS.md`, and carry it into the dossier's "what was NOT checked".
- **Anything that weakens the spec.** Removing a requirement, narrowing a domain, adding an exception, moving a
  guarantee from the code to an operator - or any edit you cannot confidently call harmless. Quote the old sentence
  and the new one and ask. "Fix the sentence, not the code" is the easiest way to make a finding vanish.
- **Trade-offs.** Any finding you propose to accept rather than fix. The owner accepts it, with a number, in
  `DECISIONS.md`. See `doctrine/TRIAGE.md`.
- **Anything irreversible or public.** Deploying, broadcasting, publishing, creating a remote repository, spending
  money, installing software the project does not already have.
- **Cost.** Before a long fuzz campaign or a round you expect to be expensive. Say how long and how much. And
  **whenever the ceiling agreed in phase 0 is reached**, whatever state the work is in.
- **A high finding.** Report it the moment it reproduces. Do not batch it with the rest of the round.
- **Anything secret.** When a step needs an RPC endpoint or an API key (fork tests, fetching the real bytecode of
  a deployed contract), **never ask for it in the chat and never write it in a file that is tracked.** Ask the
  owner to `export RPC_URL=...` in their own terminal, or to put it in a git-ignored `.env`; the scripts read the
  environment variable and never print it. Then stop until the step works. If a public endpoint that needs no key
  serves the call, prefer it. If the owner pastes an endpoint into the chat anyway: do not use it, do not repeat it,
  do not write it anywhere. Tell them a key that has been in a transcript should be treated as exposed and rotated,
  and ask for the new one the right way.
  **When this comes up:** as soon as the target chain is known, run the suite against the pool manager that
  actually exists there, not only the one compiled from source - before the black-box round at the latest, and
  always before promotion. `foundry-kit/v4/README.md`, "Get the manager that actually exists".

An acceptance is the owner's own words about THAT item, with a date. You never write one for them, never infer one
from silence, and never stretch "ok, continue" over a specific risk.

Everything else, you do.

## 6. Working rules for every round

1. **Read the whole report before touching code.** Never act on an agent's summary. The summary drops the
   measurements, and the measurements are where the decisions are. If it does not fit in your context next to what you
   need, read it in sections and keep a written ledger of each - never summarise it internally and report "read".
2. **One bench per agent.** Never compile in another agent's directory; the build tool will clear its artifacts.
3. **Every claim carries its evidence** (`doctrine/EVIDENCE.md`). What can be tested is a test that has been SEEN RED
   on broken code and now passes - no red tests in reports: a test that proves a bug asserts the wrong behaviour,
   and is named so that it is obvious. When the fix lands, that test is inverted into the regression test - it now
   asserts the promise, and it must be seen RED on the old code before it counts. What cannot be compiled is written
   as an argument, labelled REASONED, and is
   not dropped.
4. **Measure, do not infer.** A probe that falsifies a proposed fix does not validate your diagnosis of the cause.
   When a fix can be written more than one way, build each variant and read the bytes and the gas before you
   choose (`scripts/mutate.sh` with `EXPECT=green`, `scripts/size.sh`). `doctrine/CHANGES.md` section 2.
5. **Fix the cause, not the symptom.** If the fix is a new condition at one specific place, you are probably at the
   symptom. If the fix erases a whole class of attacks, you are at the cause.
6. **Write the refusals down.** A recommendation you decline must be recorded in the spec with the reason, or the
   next round re-reports it and you have burned a round.
7. **Regression test every accepted finding**, citing the auditor's own test name. Prove the test bites: break the
   code on purpose and watch it go red (`scripts/mutate.sh`). Then ask which invariant and
   which fuzz action would have caught it without the auditor, and add them. When none could - an economic attack, a
   deployment mistake, a wrong assumption about an external system - say so: that is a class the fuzzer cannot reach,
   and the dossier's "not checked" section is where it goes.
8. **Re-run the full battery and the long fuzz** after every change, and read the CAMPAIGN'S census
   (`scripts/census.sh`: in how many runs each action succeeded, each boundary was reached, a surprise was met) -
   not just the pass line, not the block of logs forge prints (that is ONE run of the campaign), and not the
   fuzzer's `reverts:` figure, which in a GREEN campaign under `fail_on_revert = true` cannot be anything but 0 (in a
   red one it is the run that failed - read that one).
9. **A tool that ran is not a question that was answered.** Read the result, not the exit code: a mutation run with
   zero mutants killed, a fuzz campaign where nothing succeeded, a fixture suite that skipped - all exit green.
   `doctrine/JUDGES.md` lists each judge, its question, and how it lies.
10. **Local judges before model rounds.** The judges are deterministic tools on the owner's machine; a round is run by a
   model and spends tokens. Never launch a round on code whose own long fuzz has not run since the last
   change; REGRESSION rounds are aimed at the diff, DISCOVERY rounds get no earlier reports at all (round 1 and the
   round that closes the loop are discovery rounds); a change that touches no bytecode gets a cheap verifier
   pass, not a round. `doctrine/COST.md`.

## 6b. When you may diverge from this kit, and when you may not

Every hook is a different case, and this kit was distilled from one. **The questions are fixed; the tools are not.**
Each step here exists to answer a question - *do my tests bite? is there a basic mistake a machine would catch? does
the fuzzer reach everything? does the manager that exists behave like the one I compiled?* The tool named next to it
is the usual way to answer, not the only one. `doctrine/JUDGES.md` lists the questions with their usual tools.

You may replace a tool or reorder the local judges on your own. You may SKIP a step only with the owner's written yes
(section 5) - "it does not apply to this hook" is your argument to them, not your decision. Either way, do all four:

1. say which **question** the step was answering;
2. say how your substitute answers it, or why the question does not apply to THIS hook (a hook that never touches a
   token has no use for the hostile token; a hook with no loops has no unbounded-walk question);
3. write it in `DECISIONS.md`, dated - and for a skip, with the owner's answer in their own words;
4. carry it into the handoff dossier: section 9 ("what was NOT checked") and, if you answered a question another way, section 8 ("where we diverged").

A divergence that is written down is engineering. A step silently skipped is a hole with a green tick on it. And a
substitute is not four sentences: it PRODUCES something - a test output, a tool's report, a measurement - that goes
in the dossier next to the question it answers. "I read the tests and they look sharp" answers nothing.

## 6c. How an agent following this literally goes wrong

Five ways, each seen or predicted by an outside reviewer. Know them before you start.

1. **Gaming the gate**: narrowing scope, weakening an invariant, declaring a class "does not apply" until the gate
   passes. Against it: a skip needs the owner's written yes (6b); "does not apply" needs a predicate the spec states
   (phase 1 gate); a spec weakened to pass is a spec change the owner confirms in writing (section 5).
2. **Trusting your own spec**: you wrote the spec, derived the tests from it, and verified the code against it - a
   closed loop that proves the code matches YOUR model, not the world. Against it: the owner interview, the black-box
   round, a different vendor for the closing round, and `HOOK-ATTACKS.md` as prompts you did not write.
3. **Reading exit codes instead of outputs**: the scripts refuse a green exit on empty results, and the census exists
   for this; still, read the file, not the summary line.
4. **Not being able to read the whole report**: a round is a quarter of a million tokens. If it does not fit next to
   the spec and the source, read it in sections and write the ledger as you go - never summarise it internally and
   report that you read it. Say in the log how you read it.
5. **Ending on a lazy round**: the exit is a discovery round that finds nothing, so the cheapest way to finish is an
   auditor that did not look. Against it: the ROUND line carries the round's EFFORT (tokens, files opened, tests
   written); a closing round with a thin ROUND line is not a closing round.

And one that is yours to avoid: spending the budget on the three state files instead of on the code (`NEXT.md`,
"Ceremony check").

You may **not** diverge on these, whatever the hook, whatever the owner says in the moment:

- never deploy, broadcast, or handle a key; the route ends at audit-ready;
- the owner's decisions stay the owner's (scope, accepted trade-offs, the ceiling, anything public or irreversible);
- every claim carries its evidence label, and a test counts only once seen red; no model is the judge;
- read the whole report before touching code;
- the dossier says honestly what was NOT checked.

If following the kit literally would make the work worse for this hook, that is a finding about the kit. Diverge, write
down why, and tell the owner - the maintainers would rather hear it than have you obey.

## 7. Where things are

```
doctrine/UPSTREAM.md    READ FIRST: Uniswap's own docs, template and security framework, and where each plugs in
doctrine/LOOP.md        the cycle, step by step, and why it converges
doctrine/TRIAGE.md      the three answers to a finding
doctrine/SEVERITY.md    the scale and the exit criterion
doctrine/LESSONS.md     generic lessons, each with the mistake that taught it
doctrine/NEXT.md        the decision table: given the state, what happens next
doctrine/COST.md        how to size the route to the stakes and not burn tokens
doctrine/INVARIANTS.md  ADAPT: how to derive the invariants of YOUR hook, backwards from the damage
doctrine/FUZZ-ACTIONS.md ADAPT: how to derive the handler's actions, and how to prove the campaign is not vacuous
doctrine/HOOK-ATTACKS.md ADAPT: baseline PROMPTS - classes of things that go wrong in v4 hooks; not a taxonomy, not coverage
doctrine/VERIFY.md      the orchestrator's discipline: how to check delegated work, outside reviewers, and yourself
doctrine/EVIDENCE.md    what counts as evidence and how much; seen-red; what blocks the exit; how an agent fools itself
doctrine/V4-ACCOUNTING.md how the pool manager keeps its books, operation by operation, and twelve things that bite hook authors
doctrine/JUDGES.md      the questions every step answers, the usual tool for each, when to skip, what each cannot see
doctrine/RETROFIT.md    arriving at a hook that already exists: mapping it onto the kit without modifying it
doctrine/CHANGES.md     sketch mode, measuring variants before deciding, comparing two revisions, reopening a release
doctrine/SIMULATE.md    the simulation sandbox: when to run it, the rules that make a number mean something, how it lies
doctrine/ORCHESTRATION.md one strong model running cheaper agents: briefs, benches, isolation, who certifies, refusals
briefs/                 one template per role; fill the placeholders
state/                  the convention to install in the owner's project
foundry-kit/            hostile token, invariant skeleton + census, toy example
foundry-kit/v4/         the v4 harness (two managers), flag-bit address mining, a worked hook. Needs scripts/install-v4.sh
scripts/                battery, long fuzz, campaign census, per-agent bench, publication guard, mutants and variants, sizes,
                        selftest.sh (run it first if you do not trust these scripts - it makes each guard go red),
                        install-v4 (pinned Uniswap sources), fetch-bytecode (the manager that exists on your chain)
adapters/claude-code/   role -> subagent and model map
adapters/experimental/codex/  the same roles as separate tasks (experimental: no end-to-end run yet)
```

The core (this file, `doctrine/`, `briefs/`, `state/`, `scripts/`) depends on no vendor feature. The adapters are
the thin layer that does, and they are the part that ages.

## 8. Honest limits, so you do not oversell the result

- The kit has been through two blind runs on one small target (run 1: one audit round; run 2: the full light route,
  one strong and one cheaper model; n = 1 each, one model family) and several independent reviews of itself. It is
  distilled from one real hardening effort. That is evidence about a method, not a validation of it: `README.md`, *Status*.
- Running the route with agents meets two refusals that are not the kit's: a harness that will not let a subagent write
  report files, and a model provider's safety classifier that may stop an agent asked to author an offensive artefact.
  The route avoids needing one; `doctrine/ORCHESTRATION.md` §4 says how, and what to write when a step is stopped.
- Decisions need the strongest model available (`doctrine/ORCHESTRATION.md` §5). A route run only by a weak model
  produces rounds that opine instead of measuring.
- Models from one family share blind spots. Run **at least one round** - the verifier or the black-box - on a model
  from a different vendor.
- Passing every gate means "ready for humans to audit". It does not mean "safe".
