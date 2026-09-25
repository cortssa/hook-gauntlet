# Quickstart - from a clone to your first adversarial round, in ten steps

Every command below was run on 2026-09-23 (`scripts/doctor.sh`: 2026-09-25) on Linux (WSL) with forge 1.8.1 and forge-std 1.16.2. Each step says what
"done" looks like, read from the output. The route ends in **audit-ready**; it never deploys, never broadcasts, never
holds a key. If a step needs a decision only you can make, it says so - the kit's agents stop there and ask.

Two readers walked the previous version of this kit with nothing but `AGENTS.md` and marked every place they had to
guess. This page exists so that the next reader does not.

## 0. What you need

**Run `scripts/doctor.sh` first** (step 1's first line clones the kit; it is the next command). It checks every item
below and prints one line each - `ok`, `missing` or `optional-missing` - with the exact command that installs what is
missing on your system (Linux: apt; macOS: brew; Windows outside WSL: the WSL steps, then the rest inside WSL), and its
last line is `doctor: ready` or `doctor: missing: ...`. It never installs anything, never uses the network and never
prints an environment variable's value (`RPC_URL`: set or not set). An agent that runs it shows the owner the commands
and installs only on the owner's yes.

- Foundry (`forge`, `cast`): supported versions are in `foundry-kit/README.md` (1.8.1 pinned, 1.8.3 CI-proven).
- `bash` 5, `git`, `rsync`, `python3` optional (standard library only: `scripts/assert-fresh-build.sh` uses it for the evidence lines, which file changed; the verdict is forge's own). `shellcheck` optional locally: the selftest runs it when present and says when it did not; CI always runs it. Linux, or Windows **inside WSL with the project on the Linux side** (`CRLF` breaks a shell
  script silently).
- Non-interactive shells (agents, CI, `wsl` from PowerShell) do not read your profile: put `~/.foundry/bin` on `PATH`
  yourself, or `export PATH="$HOME/.foundry/bin:$PATH"` at the top of your script.
- Slither only for the static-analysis judge in full mode - an install your agent must ask you for.
- Network only for three things: cloning forge-std (step 1; offline: `mkdir -p foundry-kit/lib` and copy any forge-std v1.16.2 checkout to
  `foundry-kit/lib/forge-std`, the battery checks nothing about where it came from), fetching Uniswap's sources at pinned
  commits (step 3, offline route there) and the real pool manager's bytecode (step 8). Everything else runs offline.

## 1. Clone, one dependency, and prove the scripts before trusting them

```sh
git clone <url-of-this-repository> hook-gauntlet && cd hook-gauntlet
scripts/doctor.sh      # here it lists forge-std (the next line) and v4-core (step 3) as missing; anything else: install it first
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

Done: a table per scenario and agent with `runs`, P&L, gas cost, net P&L. Binding YOUR hook: the shipped sandbox tests all target
`ExampleScenario`, so binding means writing your own scenario (`foundry-kit/v4/README.md`, steps 0-7; the calibration
test first). In YOUR project the sandbox lives in its own forge profile and directory (`sim/`, `[profile.sim]` with the optimizer on - the kit's own module above runs it under its default profile, which already has the optimizer on: with
forge's defaults the engine stops at "stack too deep"), because the optimizer changes YOUR hook's bytecode - a stranger
measured 1374 to 727 bytes - and the default profile, the one the battery, the sizes and the coverage judge, must never
see it. The layout, measured, is README step 0. The ledger writes to
`./census`, so your project's `foundry.toml` needs `fs_permissions = [{ access = "read-write", path = "./census" }]`
under `[profile.sim]` (or under `[profile.default]`, which the sim profile inherits);
without it the engine stops at init with `LedgerNotWritable` naming that line. What the numbers mean and how this judge
lies: `doctrine/SIMULATE.md`. It is optional and owner-requested; nothing waits for it.

## 5. Install the state convention in YOUR project

The kit keeps nothing about your hook in its own tree. In your project:

```sh
mkdir -p .gauntlet/briefs .gauntlet/reports
cp <kit>/state/STATE.md <kit>/state/DECISIONS.md <kit>/state/LOG.md .gauntlet/   # <kit> = where step 1 cloned it
```

Then **empty the examples**: they describe a fictional `BlockCapHook`; delete its lines but keep, in `STATE.md`, the section headers and the flag block at the top (the title is the one line that
names the hook: retitle it), and in `DECISIONS.md` and `LOG.md` the rules paragraph at the top (their only
headers are the fictional entries: delete those whole), set to the starting values `doctrine/NEXT.md` gives. `.gauntlet/` is the default
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

## 7b. The harness the judges need (phases 2 and 3 - the largest job on this page)

Nothing in step 8 measures anything until your project has: unit tests; a handler on the kit's `HandlerBase` with one
action per capability, the `HostileERC20` switches wired in as actions (they do not cover everything: `foundry-kit/README.md`
"Not covered yet" - a balance that changes with no transfer, a rebase, needs a token of your own), and `targetSelector` set; the invariants from
your spec's section 3 on `InvariantBase`; a smoke test that asserts every action succeeded a few times; `fail_on_revert =
true` and the census wiring (`writeCensus` in `afterInvariant`, `fs_permissions` for `./census`). How: `doctrine/INVARIANTS.md`
and `doctrine/FUZZ-ACTIONS.md`; the kit's own suites under `foundry-kit/test/` are the worked examples. A project with no
`lib/` reaches the kit through two absolute remappings, `gauntlet-kit/=<kit>/foundry-kit/src/` and
`forge-std/=<kit>/foundry-kit/lib/forge-std/src/` (no `allow_paths` needed). Absolute paths into a kit checkout are fine for an
exercise, and the dossier's section 10 then says so; a project going to a HANDOFF vendors the kit inside itself
(`lib/hook-gauntlet`, a submodule or a copy) and remaps relatively, so that section 10 runs on a clean machine. That is the layout of a hook OFF Uniswap's manager. A REAL v4 hook cannot be built on forge's defaults at all
(the PoolManager stops at "stack too deep"): start its `foundry.toml` and `remappings.txt` from the kit's own
`foundry-kit/v4/foundry.toml` and `foundry-kit/v4/remappings.txt` (drop its `libs = ["lib"]` and `allow_paths = ["../src"]`: with every dependency remapped by absolute path, `libs = []` and no `allow_paths` is what a reader measured to work; solc 0.8.26, evm cancun, the optimizer, the PoolManager's
IR compilation restrictions - its `paths` entry made absolute too, `<kit>/foundry-kit/v4/lib/v4-core/src/PoolManager.sol` -
and the file's remappings with `<kit>/foundry-kit/v4/` prefixed: `forge-std/`, `ds-test/`, `solmate/`, `@openzeppelin/`,
`v4-core/`, `@uniswap/v4-core/`, `v4-periphery/`, and `gauntlet-kit/=<kit>/foundry-kit/src/`; plus ONE the file does not
carry because the module reaches its own sources directly: `gauntlet-v4/=<kit>/foundry-kit/v4/src/` for `V4Harness` and
`HookMiner`), and its scenarios from `foundry-kit/v4/test/`. Every test that creates the PoolManager is then compiled under the
restricted via-IR profile, so the hook the tests, the fuzz and the mutants deploy is the `<Hook>.manager.json` build, not the
default `<Hook>.json`: THAT is the audited artefact - `size.sh` prints both rows, cite the `.manager` one; promotion hashes it;
a hook deployed from any other profile is a different artefact (`NEXT.md`, bytecode changed). A hook that HOLDS tokens has a worked example since 2026-09-24: `DeltaFeeHook` (a fee taken by
delta, a rebate, a per-block cap) in `foundry-kit/v4/src/examples/` with its unit, invariant and mutant tests; the
token-side hostile cases stay in `foundry-kit/test/` (ToyVault). Expect this to be a few hundred lines. Done: `forge test` green with `fail_on_revert` on, and a first census.
A promise that breaks under a token behaviour the owner has not decided: `doctrine/NEXT.md` row 6b, not a reason to leave
the action out.

## 8. The local judges, one command each

Deterministic tools on your machine, no model. Run them on your project directory (`<proj>`), read the outputs:

| judge | command | done when |
|---|---|---|
| build, lints, size | `forge build` in `<proj>`; `scripts/size.sh <proj>` | it compiles (forge's lint warnings, most of them in the kit's and v4-core's own files, belong to the static-triage row, not to the build); runtime AND initcode margins under your chain's limit |
| tests, sizes, freshness | `scripts/battery.sh <proj>` | `BATTERY PASSED` (forge's `passed N` counts test functions and campaigns, not the invariants inside one contract: read the campaign lines) |
| static triage | `forge lint src/` (Slither only if the owner allowed the install; write `static triage: forge lint only, Slither not installed` in `STATE.md` `notes:` otherwise) | every warning triaged in `.gauntlet/STATIC-TRIAGE.md`: fixed, or refused with the reason (`doctrine/JUDGES.md` row 1) |
| branch coverage | `forge coverage --report summary --no-match-coverage '<the regex in doctrine/JUDGES.md row 4>'` (this reruns your everyday campaign: about two minutes at forge's default 256 x 500, seconds at the v4 recipe's 64 x 64; a hook next to the PoolManager's IR restriction, the 7b layout: add `--ir-minimum`, or forge measures the wrong build and maps hits to the wrong lines - `doctrine/JUDGES.md` row 4) (`--ir-minimum` also if it will not compile) | branch numbers for `src/` in the dossier, and the uncovered branches named |
| dirty memory, junk bits | `forge test --brutalize` in `<proj>` | the same suite green (`doctrine/JUDGES.md` row 6) |
| long fuzz | `scripts/fuzz-long.sh <proj>` (needs a `[profile.long.invariant]` whose runs x depth is LARGER than your everyday budget - the script prints both and the block to paste; a sub-directory project: `USE_BENCH=0`, or see `foundry-kit/v4/README.md`) | exit 0 with the campaign lines and `runs in which the handler met an UNEXPLAINED revert: 0`; `NOTHING PROVEN` (exit 2) means no campaign ran - never a pass |
| campaign census | the GATE judges the long campaign: `CORE="deposit withdraw" REACH="fee at the cap" MIN_PCT=25 scripts/census.sh --aggregate <bench>/census/long.tsv <proj>` (the path `fuzz-long.sh` printed; the record goes to `<proj>/.gauntlet/reports/06-census-gate.txt` and the last line is `census gate: PASSED - ...` or `FAILED - ...`; with CORE and REACH both empty it says `NOTHING JUDGED`). `scripts/census.sh <proj>` without `--aggregate` runs the everyday campaign again and judges that one - a smoke check, not the gate; the two write different report files | every CORE action and REACH boundary met the floor; set the floor **below** your measured range, never in it |
| mutation | `TEST_FLAGS="--match-contract <YourUnitTests>" scripts/mutate.sh <proj> src/Hook.sol 'old' 'new'` for one aimed change (`TEST_FLAGS` is expanded unquoted by the script: no inner quotes - a `--match-path` needs its glob bare; without `TEST_FLAGS` each mutant reruns the whole battery, campaign included: minutes each on forge's defaults; dependencies reached by RELATIVE paths outside the project: `COPY_ROOT=<their common parent>`; absolute remappings need nothing; the mutated copy goes under `BENCH_ROOT`, else `TMPDIR`, else `/tmp`); `forge test --mutate src/Hook.sol --match-path 'test/unit/*'` for the score - against the fast tests only (`doctrine/JUDGES.md`, mutation) | `KILLED`; read every survivor (`doctrine/EVIDENCE.md` §2) |
| the REAL manager of your chain | `RPC_URL=… scripts/fetch-bytecode.sh <address>`, then `V4_MANAGER=fixture scripts/battery.sh <proj>` | the fixture battery green; required before the black-box round and before promotion, not before round 1 |
| simulation sandbox (optional) | step 4, on your binding | `doctrine/SIMULATE.md` §5 says what goes in the dossier |

A tool that does not fit your hook is not a reason to skip the question: answer it another way and write down how
(`AGENTS.md` 6b).

## 9. Your first adversarial round

```sh
scripts/bench.sh r01 <proj>            # a copy in $HOME/.gauntlet/bench/r01 (BENCH_ROOT to change the root), dependencies linked;
                                       # .gauntlet/ stays in the project: the auditor reads SPEC.md and the brief there, not in the bench
                                       # dependencies outside the project's own lib/: LINK_FROM=<dir with forge-std> scripts/bench.sh r01 <proj>
                                       # (when foundry.toml already points outside the project - an absolute `libs` path or absolute
                                       #  remappings - the script says "nothing to link" and LINK_FROM is not needed)
cp <kit>/briefs/audit-round.md .gauntlet/briefs/r01.md   # fill the placeholders; do not rewrite the rules
```

A **fresh** agent - a new session, no memory of writing the hook - runs the brief inside the bench and writes
`.gauntlet/reports/r01.md` (a project on the WSL side and an agent on the Windows side: the agent returns the report as text or writes it where it can, and you copy it there; the report's LAST line is `END OF REPORT r01` - a placeholder is not a report, and a poll waits for that line). Then you: read the WHOLE report; reproduce every HIGH and MEDIUM by your own means, on your own bench, and rerun the auditor's test for each low (`doctrine/VERIFY.md` 6; a test counts once seen RED);
decide each one - fix at the cause / refuse in writing / accept with a number - in `DECISIONS.md`; add the regression
test and the fuzz action that would have caught it; run the judges again; close the round with one `ROUND` line at the
top of the `LOG.md` entry (`state/README.md`). Then back to `doctrine/NEXT.md`.

Done for the loop: a DISCOVERY round with zero high and zero medium findings and nothing REASONED left open. The
black-box round (`briefs/black-box.md`, a bench WITHOUT the source) belongs early - after the first or second round.

## 10. Where it ends

`NEXT.md` row 18 (full mode: after promotion and rehearsal) or 18b (light mode: the owner declined promotion in
writing) sends you to the handoff dossier, `briefs/handoff-dossier.md` - and row 9b, when findings are open and the
owner is not there to triage, sends you to the same file as a skeleton: what the judges said read from their outputs,
every divergence, and a non-empty list of what was **not** checked. Then its reading copy for the auditor, the Markdown
staying the record: `python3 scripts/dossier-pdf.py .gauntlet/DOSSIER.md` (needs `reportlab`; without it, exit 2 and
nothing written - the Markdown goes alone). **STOP there.** The next step is a human audit.
Never `forge script --broadcast`, never `cast send`: the kit has no step that deploys.

## If something here is wrong

That is a finding about the kit: open an issue
or a pull request with the command you ran and the output you got, not a description of it.
