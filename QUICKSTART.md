# Quickstart - from a clone to your first adversarial round, in ten steps

*This page is the route for a new project - and for an existing hook with no tests and no history: from phase 0, the
code as the sketch to specify (not `phase: sketch`, which only the owner declares: `doctrine/NEXT.md` row 0). A project
with tests, audits or a history to derive the flags from starts at `doctrine/RETROFIT.md` instead.*

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
- Slither and Aderyn only for the static-analysis judge - an install your agent must ask you for (the interview asks, question 17b); without them `scripts/static-triage.sh` runs `forge lint` alone and says so.
- Network only for three things: cloning forge-std (step 1; offline: `mkdir -p foundry-kit/lib` and copy a forge-std checkout to
  `foundry-kit/lib/forge-std` - the pinned v1.16.2, or the v1.9.3 that v4-core carries as `lib/forge-std` once step 3
  has run, which the root kit's 107 tests pass on and the doctor accepts as "nothing is claimed outside the pin"; the
  battery checks nothing about where it came from), fetching Uniswap's sources at pinned
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
What this step leaves is the marker `.gauntlet/selftest-passed` in the kit (the two lines above the last name it: the
SHA-256 of the kit's scripts, a hash of this machine's identity, the date, forge's version). `scripts/next.sh` names
no row without it - it answers `next: FIRST - prove the kit on this machine: ...`, saying whether the scripts, the
machine or forge is what changed - and a script edited since, another forge, or the kit on another machine (copied
with its `.gauntlet/`, or inside a copied project; the machine as `/etc/machine-id` or, without one, the hostname
tells it) needs the selftest again. Any ending but PASSED leaves no marker.

## 2. The worked example, root kit

*See the examples work - optional for a walk on the owner's hook: what proves the kit's tools on this machine is step
1's selftest marker, not this battery. Skipped, it is a choice: say so (`STATE.md` `notes:`), not a silent skip.*

```sh
scripts/battery.sh foundry-kit
```

Done: `BATTERY PASSED`, with a summary above it (`test rc=0 (passed N, failed 0, skipped 0; filter: none)`, sizes, freshness; a filter your own `foundry.toml` sets is named there instead of `none`). The battery runs the whole suite and says what it refused to let narrow or soften it - forge's environment variables, a project `.env`, a `~/.foundry/foundry.toml`, build artefacts from another path - and a failed test fails it whatever forge exited with (`foundry-kit/README.md`, "What the battery refuses").
Read the summary, not the exit code: the battery refuses an empty green (a filter that matched nothing, a skipped test).
Step 1 is the kit proven on this machine, and what it leaves for the route is its marker, which your dossier's section
10 cites ("the kit's selftest passed on <date> for scripts <hash>"); this step shows the kit's own example green.

## 3. The v4 module: Uniswap's sources, then the example hook

*The install (either of the first two commands) is needed for any v4 hook: step 7b's recipe remaps into it. The battery
on the kit's v4 module (the last command) is "see the examples work" - optional for a walk on the owner's hook, as step 2; skipped, say so.*

Uniswap's `PoolManager` is BUSL-1.1 and is **not** in this repository. Fetch it at the pinned commits (network), or
copy local clones you already have (offline - the pins are checked either way):

```sh
scripts/install-v4.sh foundry-kit/v4                          # network, pinned commits
V4_LOCAL_SRC=/path/to/clones scripts/install-v4.sh foundry-kit/v4   # offline: clones at the pin, verified
V4_MANAGER=source scripts/battery.sh foundry-kit/v4
```

Done: `INSTALL-V4 OK`, then `BATTERY PASSED` with `suites test=… test/examples=… test/sim=…`. `V4_MANAGER=source`
means the manager compiled from those sources; the manager that actually exists on your chain is step 8.

YOUR project reaches these sources through the kit, never through a copy: once the kit is vendored in it (step 7b's
`lib/hook-gauntlet`), one command writes its `remappings.txt` and `foundry.toml` lines and builds it -

```sh
<kit>/scripts/setup-deps.sh <proj>     # --dry-run first to see every line; it refuses a project with its own lib/v4-core
```

Done: `setup-deps: DONE - ... forge build green`. `scripts/doctor.sh <proj>` then says `deps: ok`. What it writes, and
why: step 7b.

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

The kit keeps nothing about your hook in its own tree. For your project:

```sh
<kit>/scripts/init-state.sh <proj>   # <kit> = where step 1 cloned it; --spec <file> when the spec is not <proj>/SPEC.md
mkdir -p <proj>/.gauntlet/briefs <proj>/.gauntlet/reports
```

It writes `<proj>/.gauntlet/`: `STATE.md` with a new project's starting values (the flag block `doctrine/NEXT.md`
reads, the section headers), `DECISIONS.md` and `LOG.md` with their rules and no entries, and `.gitignore` (the benches
live in `.gauntlet/bench/`, step 9: copies of the project, never committed) - and it records the spec's SHA-256: the
spec is the owner's, and `scripts/next.sh` refuses it changed until the owner re-records it, signed (`init-state.sh
--spec <spec> --by "<name>"`, refused without the signature; it writes a line in `LOG.md` and in `.gauntlet/spec.sha256`,
and `next.sh` repeats it under every answer). The route's own spec is `.gauntlet/SPEC.md`, never the owner's file. It
also anchors `src/` (`.gauntlet/src.sha256`, the hash of its file list and contents; nothing when there is no hook
yet): `scripts/pending-red.sh` and `scripts/battery.sh` refuse to run on a `src/` that changed since - a finding's fix is
the owner's, shown on a copy, never written into `src/` - until the owner re-records it, signed (`--src`, the same
act). It refuses a project that already has a `STATE.md` of its own.

Only as a fallback, by hand - it records no spec, so the spec check is off: copy `<kit>/state/STATE.md`,
`DECISIONS.md`, `LOG.md` and `.gitignore` into `.gauntlet/`, then **empty the examples**: they describe a fictional `BlockCapHook`; delete its lines but keep, in `STATE.md`, the section headers and the flag block at the top (the title is the one line that
names the hook: retitle it), and in `DECISIONS.md` and `LOG.md` the rules paragraph at the top (their only
headers are the fictional entries: delete those whole), set to the starting values `doctrine/NEXT.md` gives. `.gauntlet/` is the default
location; the project root works too - write which in `STATE.md`, it is a decision. Everything the route produces
for your hook lives beside them: `.gauntlet/SPEC.md`, the filled briefs in `.gauntlet/briefs/`, the round reports in
`.gauntlet/reports/`. Rules for the three files: `state/README.md` (five of them, one is "reads are not log entries").

## 6. Start the route with your agent

Tell your agent, in its own words: *"Read `hook-gauntlet/AGENTS.md`, all of it, then `doctrine/UPSTREAM.md`. My idea
is: … Start at phase 0 and interview me."* From then on its next step comes from one table, `doctrine/NEXT.md`: the
first row whose condition is true. It re-reads that table whenever it arrives with no context and whenever it
finishes anything. `scripts/next.sh .gauntlet/STATE.md` reads the flags, refuses a malformed one, and names that row
(and the rows only a judgement can decide, never guessed: `state/README.md`).
With skills: install them (`scripts/install-skills.sh --harness claude --project <your project>`, `skills/README.md`) and say *"Use the hook-gauntlet skills. My idea is: …"*.

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
and `doctrine/FUZZ-ACTIONS.md`; the kit's own suites under `foundry-kit/test/` are the worked examples.

**One command writes the dependency lines below: `<kit>/scripts/setup-deps.sh <proj>`.** It finds the kit walking up
from `<proj>` for `lib/hook-gauntlet` (or `--kit PATH`), writes or repairs `remappings.txt` and the `[profile.default]`
lines of `foundry.toml` for that layout, prints each line it wrote or changed, then runs `forge build` (`--dry-run`: it
prints, and writes and builds nothing). It also writes a `[profile.pending]` with `test = "pending"` and nothing else
when the project has none (row 6b's profile: `FOUNDRY_PROFILE=pending forge test --match-path 'pending/*'`; every
other key is inherited from `[profile.default]`), and the fuzz configuration this step needs when it is absent:
`fs_permissions` for `./census`, an `[invariant]` with `fail_on_revert = true` (the kit's v4 module's 64 x 64; one of
yours gets `fail_on_revert = true` if it has none) and a `[profile.long.invariant]` larger than it for
`scripts/fuzz-long.sh` - a line that is there is left as it is, and said. Before the import lines for your tests (below)
it prints the `COPY_ROOT` the layout needs for `scripts/mutate.sh` (`COPY_ROOT=..` for a `proj/` beside the kit; none
for the kit inside the project). It never copies a library into the project, and refuses one that has its own
`lib/forge-std` or `lib/v4-core` (a copy of the kit's? remove it, or `SETUP_DEPS_KEEP_LIB=1`), a kit without Uniswap's
sources (step 3), a project with no kit in reach. Measured 2026-09-30: FR16's layout (the eight remappings and the
`foundry.toml` lines it writes are that project's, byte for byte), a project with the kit's libraries copied into its
`lib/` (refused; then, `lib/` removed, repaired and built), the kit inside the project (built from nothing, 21 s). The
paragraphs below are what it writes, and why.

**`<kit>` in the remappings below: a RELATIVE path, for a portable project.** With the kit vendored at `lib/hook-gauntlet`
(a submodule or a copy - what the dossier's section 10 and the skills assume), `<kit>` is relative to the directory of
the `foundry.toml`: `lib/hook-gauntlet` when that is the project's root, beside the `lib/`; `../lib/hook-gauntlet` from a
sub-directory of it (a `proj/` beside the kit), which also needs `allow_paths = ["../lib/hook-gauntlet/foundry-kit"]` -
forge reads nothing above the project without it. Then section 10 runs on a clean machine. ABSOLUTE paths
(`/home/you/hook-gauntlet`) only when the kit lives elsewhere, a checkout of its own; they need no `allow_paths`, and then
the dossier's section 10 says the project is NOT portable (`not yet`: it runs on this machine only). Measured 2026-09-28,
forge 1.8.1, one v4 hook with its suite, the three ways: `../lib/hook-gauntlet` with `allow_paths` (22 s), the same
absolute (18 s), the kit copied inside the project as `lib/hook-gauntlet` (19 s) - each compiled from nothing and its 22
unit tests green; the `../` way compiles some of the kit's and v4-core's files twice, under the relative and the
absolute path (19 of 81: forge names those contracts `<name> (<path>)`; `scripts/size.sh` lists each once), and
`scripts/bench.sh` puts what `../` reaches beside the project's copy. A project with no `lib/` of its own reaches the
kit through two remappings, `gauntlet-kit/=<kit>/foundry-kit/src/` and `forge-std/=<kit>/foundry-kit/lib/forge-std/src/`.

That is the layout of a hook OFF Uniswap's manager. A REAL v4 hook cannot be built on forge's defaults at all
(the PoolManager stops at "stack too deep"): start its `foundry.toml` and `remappings.txt` from the kit's own
`foundry-kit/v4/foundry.toml` and `foundry-kit/v4/remappings.txt` (drop its `libs = ["lib"]` and `allow_paths = ["../src"]`: with every dependency remapped through `<kit>`, `libs = []` is what a reader measured to work, and `allow_paths` only the one line above when `<kit>` starts with `../`; solc 0.8.26, evm cancun, the optimizer - the owner's own `optimizer` and `optimizer_runs` stay in the default profile: the tests, the fuzz and the mutants deploy the `.manager` build (via IR, 44 444 444 runs), and that is the artefact the dossier cites - the PoolManager's
IR compilation restrictions - its `paths` entry through `<kit>` too, `<kit>/foundry-kit/v4/lib/v4-core/src/PoolManager.sol` -
and the file's remappings with `<kit>/foundry-kit/v4/` prefixed: `forge-std/`, `ds-test/`, `solmate/`, `@openzeppelin/`,
`v4-core/`, `@uniswap/v4-core/`, `v4-periphery/`, `permit2/`, `openzeppelin-contracts/` (the last two matter only with the
periphery installed, `V4_WITH_PERIPHERY=1`), and `gauntlet-kit/=<kit>/foundry-kit/src/`; plus ONE the file does not
carry because the module reaches its own sources directly: `gauntlet-v4/=<kit>/foundry-kit/v4/src/` for `V4Harness` and
`HookMiner`), and its scenarios from `foundry-kit/v4/test/`.

**The import lines, in your project's tests** - what `setup-deps.sh` prints last, verbatim; they compile through the
remappings above (`gauntlet-v4/` is `<kit>/foundry-kit/v4/src/`, so the file follows it directly - not
`gauntlet-v4/src/...`):

```
import {V4Harness} from "gauntlet-v4/V4Harness.sol";
import {MinimalRouter} from "gauntlet-v4/MinimalRouter.sol";
import {LiquidityHelper} from "gauntlet-v4/LiquidityHelper.sol";
import {HookMiner} from "gauntlet-v4/HookMiner.sol";
import {HostileERC20} from "gauntlet-kit/HostileERC20.sol";
The kit's own examples import these relative to the kit (../../src/...): do not copy their import lines.
```

Offline, this recipe is also the substitute for the
official `v4-template` layout that phase 2's gate names (`AGENTS.md` section 3): write it in the dossier's section 8 as a
divergence - the question (does the hook build the way Uniswap's template builds a hook?), this recipe as the answer,
and why the template was not fetched. In each test's `setUp`: `_setUpV4();` then
`hook = MyHook(_deployHook(type(MyHook).creationCode, abi.encode(manager), <its flags>));` - the harness mines the address
and refuses to run before the routers exist (`foundry-kit/v4/README.md`, "Address mining for the flag bits"). It also
refuses a hook that implements a callback whose permission bit is not set (`V4Harness: ... permission bit is not set`):
that is a finding, not a fix, and its path goes in this order - its test `pending/<id>.t.sol` (its own `setUp` sets
`_skipPermissionCheck = true`; a test function of its own calls `_checkHookPermissions(address(hook))` directly, with
no `vm.expectRevert`, so the harness's revert fails it),
recorded red by `scripts/pending-red.sh <proj> pending/<id>.t.sol`; then `_skipPermissionCheck = true` and the header
line `// _skipPermissionCheck: <id> open` in your suites; then the battery, which ends `green UNDER open permission-bits
finding <id>` (`doctrine/EVIDENCE.md` section 2). Every test that creates the PoolManager is then compiled under the
restricted via-IR profile, so the hook the tests, the fuzz and the mutants deploy is the `<Hook>.manager.json` build, not the
default `<Hook>.json`: THAT is the audited artefact - `size.sh` prints both rows, cite the `.manager` one; promotion hashes it;
a hook deployed from any other profile is a different artefact (`NEXT.md`, bytecode changed). A hook that HOLDS tokens has a worked example since 2026-09-24: `DeltaFeeHook` (a fee taken by
delta, a rebate, a per-block cap) in `foundry-kit/v4/src/examples/` with its unit, invariant and mutant tests; the
token-side hostile cases stay in `foundry-kit/test/` (ToyVault). **The handler to copy is `InRangeDonateHook`'s**
(`foundry-kit/v4/test/examples/InRangeDonateHook.invariants.t.sol`): it follows `doctrine/FUZZ-ACTIONS.md`'s rule - every
catch is unexpected unless the error is named. The `DeltaFeeHook`, `CappedDynamicFeeHook` and `ClaimsFeeHook` handlers
still excuse reverts by a switch's state or by what they do not name - a known gap in those examples, not the model:
copy their books and invariants, not their catches. Expect this to be a few hundred lines. Done: `forge test` green with `fail_on_revert` on, and a first census.
A promise that breaks under a token behaviour the owner has not decided: `doctrine/NEXT.md` row 6b, not a reason to leave
the action out.

## 8. The local judges, one command each

Deterministic tools on your machine, no model. Run them on your project directory (`<proj>`), read the outputs:

| judge | command | done when |
|---|---|---|
| build, lints, size | `forge build` in `<proj>`; `scripts/size.sh <proj>` | it compiles (forge's lint warnings, most of them in the kit's and v4-core's own files, belong to the static-triage row, not to the build); runtime AND initcode margins under your chain's limit |
| tests, sizes, freshness | `scripts/battery.sh <proj>` | `BATTERY PASSED` (forge's `passed N` counts test functions and campaigns, not the invariants inside one contract: read the campaign lines) |
| static triage | `scripts/static-triage.sh <proj>` (Slither and Aderyn when installed - an install is the owner's to allow - and always `forge lint`, on `src/`; `.gauntlet/reports/05-static.txt`, and the `static triage: ...` line it prints goes in `STATE.md` `notes:`) | every warning triaged in `.gauntlet/STATIC-TRIAGE.md`: fixed, or refused with the reason (`doctrine/JUDGES.md` row 1) |
| branch coverage | `forge coverage --report summary --no-match-coverage '<the regex in doctrine/JUDGES.md row 4>'` (this reruns your everyday campaign: about two minutes at forge's default 256 x 500, seconds at the v4 recipe's 64 x 64; a hook next to the PoolManager's IR restriction, the 7b layout: add `--ir-minimum`, or forge measures the wrong build and maps hits to the wrong lines - `doctrine/JUDGES.md` row 4) (`--ir-minimum` also if it will not compile) | branch numbers for `src/` in the dossier, and the uncovered branches named |
| dirty memory, junk bits | `forge test --brutalize` in `<proj>` | the same suite green (`doctrine/JUDGES.md` row 6) |
| long fuzz | say how long first (`AGENTS.md` section 5): `ESTIMATE_ONLY=1 scripts/fuzz-long.sh <proj>` prints what it will cost and stops, no campaign (the run prints it again before its campaign starts) - runs x depth, the everyday campaigns' time from the battery's last log scaled by calls, and that a failure is then shrunk (`shrink_run_limit`; about 10 minutes on a v4 hook, measured); read them to the owner, and stop there if it is too much. `scripts/fuzz-long.sh <proj>` (needs a `[profile.long.invariant]` whose runs x depth is LARGER than your everyday budget - the script prints both and the block to paste; a sub-directory project: `USE_BENCH=0`, or see `foundry-kit/v4/README.md`) | exit 0 with the campaign lines and `runs in which the handler met an UNEXPLAINED revert: 0`; `NOTHING PROVEN` (exit 2) means no campaign ran - never a pass |
| campaign census | the GATE judges the long campaign: `CORE="deposit withdraw" REACH="fee at the cap;pool at the price limit" MIN_PCT=25 scripts/census.sh --aggregate <bench>/census/long.tsv <proj>` (CORE names are separated by spaces, REACH names by `;` - a boundary's name has spaces in it; the path `fuzz-long.sh` printed; the record goes to `<proj>/.gauntlet/reports/06-census-gate.txt` and the last line is `census gate: PASSED - ...` or `FAILED - ...`; with CORE and REACH both empty it says `NOTHING JUDGED`). `scripts/census.sh <proj>` without `--aggregate` runs the everyday campaign again and judges that one - a smoke check, not the gate; the two write different report files | every CORE action and REACH boundary met the floor. The floor: run the short campaign three times (`scripts/census.sh <proj>`); the floor goes below the lowest - one campaign's number sits inside the noise |
| mutation | `TEST_FLAGS="--match-contract <YourUnitTests>" scripts/mutate.sh <proj> src/Hook.sol 'old' 'new'` for one aimed change (`TEST_FLAGS` is read by mutate.sh only - the battery ignores it; set it on the command line, not with `export`. It is expanded unquoted by the script: no inner quotes - a `--match-path` needs its glob bare; without `TEST_FLAGS` each mutant reruns the whole battery, campaign included: minutes each on forge's defaults; dependencies reached by RELATIVE paths outside the project: `COPY_ROOT=<their common parent>`; absolute remappings need nothing; the mutated copy goes under `BENCH_ROOT`, else `<proj>/.gauntlet/bench`); `forge test --mutate src/Hook.sol --match-path 'test/unit/*'` for the score - against the fast tests only (`doctrine/JUDGES.md`, mutation) | `KILLED`; read every survivor (`doctrine/EVIDENCE.md` §2) |
| the REAL manager of your chain | `RPC_URL=… scripts/fetch-bytecode.sh <address>`, then `V4_MANAGER=fixture scripts/battery.sh <proj>` | the fixture battery green; required before the black-box round and before promotion, not before round 1 |
| the kit's own suites on an Ethereum mainnet fork | `export RPC_URL=…` (in your own terminal), then `scripts/fetch-bytecode.sh --block 26050000 0x000000000004444c5dc75cB358380D2e3dE08A90 foundry-kit/v4/fixtures/PoolManager.hex`, then `FOUNDRY_PROFILE=fork V4_MANAGER=fork scripts/battery.sh foundry-kit/v4` (the default battery never runs the fork suites; `foundry-kit/v4/README.md`, "The fork") | `BATTERY PASSED` with `suites test/backtest=4 test/examples=4 test/fork=7`; fork tests for YOUR hook on YOUR chain are still yours to write (`AGENTS.md` phase 3) |
| simulation sandbox (optional) | step 4, on your binding | `doctrine/SIMULATE.md` §5 says what goes in the dossier |
| backtest (optional; the sandbox's second instrument) | `export RPC_URL=…` (an ARCHIVE endpoint, in your own terminal), a contract `<YourHook>Backtest is BacktestBase` in your project (`foundry-kit/v4/README.md`, "Backtests": what to override, the `foundry.toml` lines), then `scripts/backtest.sh <proj> --pool <poolId> --from <block> --to <block> --hook <YourHook>` - the swaps of blocks `from+1 .. to` fetched once into `<proj>/.gauntlet/backtests/` (commit them; never into the kit's module, which refuses the fetch) and replayed through your hook and a hook-less control on a fork at `from`; the pool id from its key: `cast keccak $(cast abi-encode ...)` ("Your hook, your pool"). A window with no swap is refused before the replay, and says how many the pool had in the 1 000 blocks before; a thin one is a warning. The kit's own: `scripts/backtest.sh foundry-kit/v4 --pool 0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27 --from 26049800 --to 26050000` | `backtest: REPORT WRITTEN` and `.gauntlet/reports/07-backtest-<id8>-<from>-<to>-<Hook>.txt` (one per pool, window and hook), read next to its control - the report prints each hook minus its control, and whether the control's drift was held on this window; SUPPORTED, never PROVED - `doctrine/SIMULATE.md` §6 says what the replay substitutes and what goes in the dossier |

A tool that does not fit your hook is not a reason to skip the question: answer it another way and write down how
(`AGENTS.md` 6b).

## 9. Your first adversarial round

```sh
scripts/bench.sh r01 <proj>            # a copy in <proj>/.gauntlet/bench/r01 (BENCH_ROOT to change the root; never $HOME), dependencies linked;
                                       # the default only once <proj>/.gauntlet/ exists (step 5 installs it): without it, refused - BENCH_ROOT outside
                                       # .gauntlet/ stays in the project: the auditor reads SPEC.md and the brief there, not in the bench
                                       # the kit reached by `../` (step 7b, a proj/ beside lib/hook-gauntlet): the copy is at
                                       #  <bench>/<proj's folder> with ../lib linked beside it - the LAST line printed is where to work
                                       # an absolute `libs` path or absolute remappings: "nothing to link"; forge-std elsewhere and
                                       #  named nowhere: LINK_FROM=<dir with forge-std> scripts/bench.sh r01 <proj>
cp <kit>/briefs/audit-round.md .gauntlet/briefs/r01.md   # fill the placeholders; do not rewrite the rules
```

A **fresh** agent - a new session, no memory of writing the hook - runs the brief inside the bench and writes
`.gauntlet/reports/r01.md` (a project on the WSL side and an agent on the Windows side: the agent returns the report as text or writes it where it can, and you copy it there; the report's LAST line is `END OF REPORT r01` - a placeholder is not a report, and a poll waits for that line). Then you: read the WHOLE report; reproduce every HIGH and MEDIUM by your own means, on your own bench, and rerun the auditor's test for each low (`doctrine/VERIFY.md` 6; a test counts once seen RED);
decide each one - fix at the cause / refuse in writing / accept with a number - in `DECISIONS.md`; add the regression
test and the fuzz action that would have caught it; run the judges again; close the round with one `ROUND` line at the
top of the `LOG.md` entry (`state/README.md`). Then back to `doctrine/NEXT.md`.

Done for the loop: a DISCOVERY round, zero high and zero medium findings still open (not yet fixed, refused in writing, accepted by the owner with a number, or handed to the human audit by name), and nothing REASONED left open (`doctrine/NEXT.md` row 14). The
black-box round (`briefs/black-box.md`, a bench WITHOUT the source) belongs early - after the first or second round.

## 10. Where it ends

`NEXT.md` row 18 (after promotion, and rehearsal if there is a runbook) or 18b (the owner declined promotion in writing: light
mode's default, or a full-mode owner's own decision) sends you to the handoff dossier, `briefs/handoff-dossier.md` - and row 9b, when findings are open and the
owner is not there to triage, sends you to the same file as a skeleton: what the judges said read from their outputs,
every divergence, and a non-empty list of what was **not** checked. With the owner absent that is where the route ENDS
until they answer: the skeleton names the open findings, `STATE.md` says so (`dossier: skeleton (K open, ...)`,
`waiting_on_owner: triage of <ids>`, every open high `to tell`), and `scripts/next.sh` answers `STOP - paused, waiting
on the owner` (`doctrine/NEXT.md` row 3). Then its reading copy for the auditor, the Markdown
staying the record: `python3 scripts/dossier-pdf.py .gauntlet/DOSSIER.md` (needs `reportlab`; without it, exit 2 and
nothing written - the Markdown goes alone). **STOP there.** The next step is a human audit.
Never `forge script --broadcast`, never `cast send`: the kit has no step that deploys.

## If something here is wrong

That is a finding about the kit: open an issue
or a pull request with the command you ran and the output you got, not a description of it.
