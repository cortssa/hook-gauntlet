# Quickstart - from a clone to your first adversarial round, in ten steps

Every command below was run on 2026-09-23 on Linux (WSL) with forge 1.8.1 and forge-std 1.16.2. Each step says what
"done" looks like, read from the output. The route ends in **audit-ready**; it never deploys, never broadcasts, never
holds a key. If a step needs a decision only you can make, it says so - the kit's agents stop there and ask.

Two readers walked the previous version of this kit with nothing but `AGENTS.md` and marked every place they had to
guess. This page exists so that the next reader does not.

## 0. What you need

- Foundry (`forge`, `cast`): supported versions are in `foundry-kit/README.md` (1.8.1 pinned, 1.8.3 CI-proven).
- `bash` 5, `git`, `rsync`. Linux, or Windows **inside WSL with the project on the Linux side** (`CRLF` breaks a shell
  script silently).
- Non-interactive shells (agents, CI, `wsl` from PowerShell) do not read your profile: put `~/.foundry/bin` on `PATH`
  yourself, or `export PATH="$HOME/.foundry/bin:$PATH"` at the top of your script.
- Slither only for the static-analysis judge in full mode - an install your agent must ask you for.
- Network only for two things: fetching Uniswap's sources at pinned commits (step 3) and the real pool manager's
  bytecode (step 8). Everything else runs offline.

## 1. Clone, one dependency, and prove the scripts before trusting them

```sh
git clone <url-of-this-repository> hook-gauntlet && cd hook-gauntlet
git clone --quiet --depth 1 --branch v1.16.2 https://github.com/foundry-rs/forge-std foundry-kit/lib/forge-std
scripts/selftest.sh
```

Done: the last line is `SELFTEST PASSED: every guard went red exactly where it was supposed to.` If it says
`INCOMPLETE`, forge or `foundry-kit/lib` is missing; that is not a pass. The self-test makes every guard in
`scripts/` fail on purpose and checks that it did - a guard never seen red is decoration (`doctrine/EVIDENCE.md` §2).

## 2. The worked example, root kit

```sh
scripts/battery.sh foundry-kit
```

Done: `BATTERY PASSED`, with a summary above it (`test rc=0 (passed N, failed 0, skipped 0)`, sizes, freshness).
Read the summary, not the exit code: the battery refuses an empty green (a filter that matched nothing, a skipped test).

## 3. The v4 module: Uniswap's sources, then the example hook

Uniswap's `PoolManager` is BUSL-1.1 and is **not** in this repository. Fetch it at the pinned commits (network), or
copy local clones you already have (offline - the pins are checked either way):

```sh
scripts/install-v4.sh foundry-kit/v4                          # network, pinned commits
V4_LOCAL_SRC=/path/to/clones scripts/install-v4.sh foundry-kit/v4   # offline: clones at the pin, verified
V4_MANAGER=source scripts/battery.sh foundry-kit/v4
```

Done: `INSTALL-V4 OK`, then `BATTERY PASSED` with `suites test=… test/examples=… test/sim=…`. `V4_MANAGER=source`
means the manager compiled from those sources; the manager that actually exists on your chain is step 8.

## 4. The eleventh judge on the example: the simulation sandbox

```sh
cd foundry-kit/v4 && mkdir -p census && rm -f census/sim.tsv
GAUNTLET_SIM=census/sim.tsv forge test --match-path test/sim/Calibration.t.sol
for s in 1 2 3 4 5; do SIM_SEED=$s GAUNTLET_SIM=census/sim.tsv forge test --match-path test/sim/Ordering.t.sol; done
GAUNTLET_SIM=census/sim.tsv forge test --match-path test/sim/Liquidity.t.sol --match-test over_seeds -vv
../../scripts/sim-report.sh census/sim.tsv
cd ../..
```

Done: a table per scenario and agent with `runs`, P&L, gas cost, net P&L. What the numbers mean and how this judge
lies: `doctrine/SIMULATE.md`. It is optional and owner-requested; nothing waits for it.

## 5. Install the state convention in YOUR project

The kit keeps nothing about your hook in its own tree. In your project:

```sh
mkdir -p .gauntlet/briefs .gauntlet/reports
cp hook-gauntlet/state/STATE.md hook-gauntlet/state/DECISIONS.md hook-gauntlet/state/LOG.md .gauntlet/
```

Then **empty the examples**: they describe a fictional `BlockCapHook`; delete its lines. `.gauntlet/` is the default
location; the project root works too - write which in `STATE.md`, it is a decision. Everything the route produces
for your hook lives beside them: `.gauntlet/SPEC.md`, the filled briefs in `.gauntlet/briefs/`, the round reports in
`.gauntlet/reports/`. Rules for the three files: `state/README.md` (five of them, one is "reads are not log entries").

## 6. Start the route with your agent

Tell your agent, in its own words: *"Read `hook-gauntlet/AGENTS.md`, all of it, then `doctrine/UPSTREAM.md`. My idea
is: … Start at phase 0 and interview me."* From then on its next step comes from one table, `doctrine/NEXT.md`: the
first row whose condition is true. It re-reads that table whenever it arrives with no context and whenever it
finishes anything.

Phase 0 is the interview: the agent copies `briefs/owner-interview.md` to `.gauntlet/briefs/00-interview.md` and you
answer it together. One question, the self-score against the Uniswap Foundation's security framework, needs the
framework's text (`doctrine/UPSTREAM.md`); offline, it is marked `UNVERIFIED` and the route continues - the gate
records it as not done, it does not hide it.

## 7. The spec that can be proved wrong

The agent copies `briefs/spec-template.md` to `.gauntlet/SPEC.md` and fills it: for every class in `doctrine/HOOK-ATTACKS.md`,
applies / does not apply / accepted / prevented, with the predicate, the test and the invariant that would go red.
Done: every line of the spec could fail. A line that cannot fail is not a promise.

## 8. The local judges, one command each

Deterministic tools on your machine, no model. Run them on your project directory (`<proj>`), read the outputs:

| judge | command | done when |
|---|---|---|
| build, lints, size | `forge build` in `<proj>`; `scripts/size.sh <proj>` | clean build; runtime AND initcode margins under your chain's limit |
| tests, sizes, freshness | `scripts/battery.sh <proj>` | `BATTERY PASSED` |
| long fuzz | `scripts/fuzz-long.sh <proj>` (a sub-directory project: `USE_BENCH=0`, or see `foundry-kit/v4/README.md`) | exit 0 with the campaign lines and `UNEXPLAINED revert: 0`; `NOTHING PROVEN` (exit 2) means no campaign ran - never a pass |
| campaign census | `CORE="deposit withdraw" REACH="fee at the cap" MIN_PCT=25 scripts/census.sh <proj>` | every CORE action and REACH boundary met the floor; set the floor **below** your measured range, never in it |
| mutation | `scripts/mutate.sh <proj> src/Hook.sol 'old' 'new'` for one aimed change; `forge test --mutate` for the score | `KILLED`; read every survivor (`doctrine/EVIDENCE.md` §2) |
| the REAL manager of your chain | `RPC_URL=… scripts/fetch-bytecode.sh <address>`, then `V4_MANAGER=fixture scripts/battery.sh <proj>` | the fixture battery green; required before the black-box round and before promotion, not before round 1 |
| simulation (11, optional) | step 4, on your binding | `doctrine/SIMULATE.md` §5 says what goes in the dossier |

A tool that does not fit your hook is not a reason to skip the question: answer it another way and write down how
(`AGENTS.md` 6b).

## 9. Your first adversarial round

```sh
scripts/bench.sh r01 <proj>            # a copy in ~/hg-r01 with dependencies linked (BENCH_ROOT to change the root)
cp hook-gauntlet/briefs/audit-round.md .gauntlet/briefs/r01.md   # fill the placeholders; do not rewrite the rules
```

A **fresh** agent - a new session, no memory of writing the hook - runs the brief inside the bench and writes
`.gauntlet/reports/r01.md`. Then you: read the WHOLE report; reproduce every finding (a test counts once seen RED);
decide each one - fix at the cause / refuse in writing / accept with a number - in `DECISIONS.md`; add the regression
test and the fuzz action that would have caught it; run the judges again; close the round with one `ROUND` line at the
top of the `LOG.md` entry (`state/README.md`). Then back to `doctrine/NEXT.md`.

Done for the loop: a DISCOVERY round with zero high and zero medium findings and nothing REASONED left open. The
black-box round (`briefs/black-box.md`, a bench WITHOUT the source) belongs early - after the first or second round.

## 10. Where it ends

`NEXT.md` row 18 (full mode: after promotion and rehearsal) or 18b (light mode: the owner declined promotion in
writing) sends you to the handoff dossier, `briefs/handoff-dossier.md`: what the judges said read from their outputs,
every divergence, and a non-empty list of what was **not** checked. **STOP there.** The next step is a human audit.
Never `forge script --broadcast`, never `cast send`: the kit has no step that deploys.

## If something here is wrong

That is a finding about the kit. `LOG.md` in this repository records where the last two readers stalled; open an issue
or a pull request with the command you ran and the output you got, not a description of it.
