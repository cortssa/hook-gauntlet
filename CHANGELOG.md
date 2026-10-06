# Changelog

## Unreleased (v0.5)

- **Static triage is a script:** `scripts/static-triage.sh <proj>` runs what this machine has, in this order, on the
  project's `src/` only - Slither (`--include-paths` on the project's resolved `src/`, `--checklist --fail-none
  --skip-clean`; with the project's own `slither.config.json`, its filters), Aderyn, and always `forge lint src` - and
  writes `.gauntlet/reports/05-static.txt`: each tool and its version (or `not installed`), its findings as it printed
  them, and the counts (Slither by impact, checked against its own `<n> result(s) found`; Aderyn by its Issue Summary,
  checked against its headings; forge lint by level, rule and `--severity`). A count that does not add up is "not read",
  never guessed. It installs and fetches nothing, prints the `static triage: <tools>` line for `STATE.md` `notes:`
  (`forge lint only, Slither not installed`, or `forge lint only - the owner declined the install` when the last
  `Q17b static analyzers: no` in `DECISIONS.md` says so) and, last, that the findings go to `pending/` or
  `DECISIONS.md` like any finding. Exit 0 once forge lint ran; 2, nothing written, with no `src/`. Not
  `--filter-paths lib`: Slither matches it against each result's absolute path and drops a result when any element
  matches - measured, 0 of 43 results for a project under a directory named `library`. Slither's own build deletes
  forge's persisted failures, `cache/invariant/` and `cache/fuzz/` (measured, and a configured directory too): the
  script reads both from the project's `forge config --json` (`invariant.failure_persist_dir`,
  `fuzz.failure_persist_dir`; `cache/invariant` and `cache/fuzz` by default), keeps each aside, puts it back byte for
  byte and says so in the report's note (one outside the project is not kept, and said). Measured with Slither
  0.11.6 and forge 1.8.1 (the root kit: 43 findings, 49 lints; the v4 module: 317 findings, 523 lints, 41 s).
  **Aderyn was not on any machine this was written on**: its report's shape is assumed, and only a fake has run it
  (the selftest).
- **`scripts/doctor.sh`** reports the analysers as one line, never a missing item: `static: slither <v>`, `static:
  aderyn <v>`, both, or `static: forge lint only` with the install lines for the owner's yes.
- **The owner interview asks it** (`briefs/owner-interview.md`, question 17b): may the kit install Slither and Aderyn -
  yes / no / already installed - recorded in `DECISIONS.md` as `Q17b static analyzers: <answer>`.
- `doctrine/NEXT.md` row 7, `QUICKSTART.md` step 8, `doctrine/JUDGES.md` (the triage's input) and
  `briefs/handoff-dossier.md` section 6 (what ran and what was triaged, from `05-static.txt`) name the script; the
  battery skill carries row 7 as before, regenerated.
- `README.md` *Honest costs*: what one walk cost, measured once (about 52 minutes, 39.4M tokens of cache reads).

## v0.4 - 2026-10-06 - discipline moved from text into scripts that refuse

Written for a small model on a local machine to follow: one run of the route by a 27B model in Hermes
(`adapters/local-models/README.md`) left the kit's example `STATE.md` unfilled, answered by `next.sh` as a real state;
cited tests that never existed; copied the kit's libraries into the project by hand; and had its planted clock bug
hidden by a harness timestamp of 1. Each of those is now a script that refuses, and each refusal names its escape.

- **`scripts/next.sh` refuses the kit's example:** a `STATE.md`, or the `DECISIONS.md` or `LOG.md` beside it, that
  still carries the example's marker line (in `DECISIONS.md` and `LOG.md` as a line of its own: a log that quotes it
  is not the example) or `BlockCapHook` in its title - `next: FIRST - fill STATE.md: it is still the kit's example`
  (exit 2, no escape: an example is never a state) - or a `STATE.md` whose flag block shares three or more
  non-generic lines with the example's, whatever the spacing (the example with its marker deleted and retitled): `next:
  FIRST - fill STATE.md: its values are still the kit's example's (<line>)`. `doctrine/NEXT.md` row 0 says so;
  `state/README.md` gives the starting values a new project writes.
- **A test in `pending/` must have been seen red on the code as it stands:** `scripts/pending-red.sh <proj>
  [pending/<file>]` runs each file under row 6b's profile and writes a record to `.gauntlet/pending-red/` only when it
  compiles and at least one of its tests fails - not `setUp()`: a broken harness is not a finding - keyed by the
  SHA-256 of the file list and contents of `src/`, `test/`, `pending/`, `foundry.toml` and `remappings.txt`. Every
  run builds from nothing in a build directory of its own (forge's incremental build ran an edited helper in `test/`
  as it was before). A test that passes on the code is refused, "it is not a finding's test". The record's first line
  is `pending-red: red <file> key=<key> <date>`, then the failing tests and the last 20 lines of forge's output.
  `next.sh` refuses a pending test without a current record, or with one whose first line is not that ("record
  unreadable"), and a directory in `pending/` named `*.sol` (`PENDING_RED=0` skips the record check, and says so).
  When the v4 harness refuses the deploy on a permission bit, `pending-red.sh` prints the harness's whole line and
  says that refusal is the finding.
- **A file the record cites must exist:** a path under `pending/`, `test/`, `src/` or `.gauntlet/reports/` that
  `STATE.md` or `DECISIONS.md` cites and that is not a non-empty regular file - not there, empty, or a directory - is
  refused, saying which (`CITED_FILES=0` skips it, and says so).
  `LOG.md` is not read for this: a log is history, and a file it names may have been moved or deleted since.
- **`next.sh <proj>`:** a project's directory reads its `.gauntlet/STATE.md`, then its `STATE.md`.
- **One command for a project's dependencies:** `scripts/setup-deps.sh <proj>` writes or repairs `remappings.txt` and
  the `[profile.default]` lines of `foundry.toml` for the kit vendored in the project (relative paths), prints every
  line it wrote, and builds; it never copies a library into the project and refuses one that has its own
  `lib/forge-std` or `lib/v4-core` (`SETUP_DEPS_KEEP_LIB=1`). `--dry-run`, `--check`. `scripts/doctor.sh <proj>`
  gains a `deps:` line. QUICKSTART steps 3 and 7b point at it.
- **`scripts/install-skills.sh --harness hermes`:** `--user` installs into `${HERMES_HOME:-~/.hermes}/skills`;
  `--project` into `.agents/skills` and prints the two `skills.external_dirs` lines Hermes needs; both print the start
  line `hermes chat -s hook-gauntlet`. `skills/README.md` has a table of harnesses with what was measured on each.
- **Local models:** `adapters/local-models/README.md` - the server and agent configuration of the one run, what was
  measured and what was not; `AGENTS.md` section 7 points at it. A measurement, not a supported path.
- **`V4Harness`, a realistic clock and the permission bits checked:** the source manager's setup warps to `V4_T0`
  (2026-01-02 03:10:57 UTC, off every minute, hour, day and week boundary) and a matching block, so time-keyed state
  is exercised (the fork keeps the chain's clock). `_deployHook` calls the ten callbacks as the manager would and
  fails with the callback's name when one is implemented and its permission bit is not set; a bit set on a callback
  that is not implemented is a warning. Escape: `_skipPermissionCheck` (the kit's hostile hooks, which answer every
  callback, use it). Two suites of their own; the v4 battery 271 -> 287.
- **The entry skill ends with the first command:** "Your next command is `lib/hook-gauntlet/scripts/next.sh <proj>`.
  Run it; do not read it." (the kit's path as installed), and a new step 2 says to run `scripts/setup-deps.sh <proj>` -
  both sentences of `AGENTS.md` (sections 3b and 4), quoted by the generator and checked there.

Known gaps, each written where it lives:
- `setup-deps.sh` does not write the periphery's remappings (`v4-periphery/`, `permit2/`, `openzeppelin-contracts/`):
  a project that uses the periphery adds them by hand (QUICKSTART 7b). A Hermes that reads the user-level install
  (`HERMES_HOME/skills`) was not run; the `external_dirs` lines are the ones that worked in the one run.
- An honest `DECISIONS.md` that names a file moved or deleted since is refused: rewrite the entry to the file's new
  place, or `CITED_FILES=0`. A path written `reports/...` without `.gauntlet/` is not read; `scripts/round.sh` does
  not check citations. The red record's key does not include the libraries or the compiler (the run itself is a
  build from nothing, so its verdict is not a stale one; a record is just not staled by them).
- A callback that only returns its selector counts as implemented: the check fails on it (remove it, set its bit, or
  `_skipPermissionCheck`). A finding's fix that leaves a callback implemented without its bit - a dead one, kept -
  fails in `setUp()`, so a finding's test that must pass on the fixed code needs the fix to remove or declare that
  callback. The harness's refusal now points at `doctrine/EVIDENCE.md` section 2, not at a fix: the owner decides the
  fix (row 6b).
- The two checks meet on a hook whose finding IS such a callback: every suite's `setUp()` fails, and `pending-red.sh`
  does not count a `setUp()` failure as red. Measured on FR16's project with this kit: `setup-deps.sh` rewrote its
  eight remappings byte for byte and built; then all five of its pending tests failed in `setUp()` on the permission
  check (a real defect of that hook), none got a record, and `next.sh` refused the first. The way out is written in
  `doctrine/EVIDENCE.md` section 2, "while a permission-bits finding is open" (and in `foundry-kit/v4/README.md`, the
  harness's section): the bits finding's own test deploys with `_skipPermissionCheck` and shows the callback never
  running; the other pending tests set the same flag, say so in their header, and drop it with the fix.
  `pending-red.sh` names that section when the harness refuses the deploy. Measured on a copy of FR16's project:
  with the flag in the five pending tests as that section says, 5/5 red, each on its own assertion. (v0.4.2 changed
  that way out - the everyday suite may set the flag too, while the finding is recorded: below.)

**v0.4.1, in this release: what runs on hosted models showed, turned into refusals.** One run of a hosted 120B-class
model through Hermes (2026-10-01, stopped at 112 minutes) appended 35 "owner decisions" to the owner's spec before it
read the hook, moved its phase from 0 to 2 by hand, spent 83 minutes guessing the import line of the harness, and wrote
a test file inside the vendored kit; two other runs had the selftest cut by their tool timeout.
- **The spec is the owner's:** `scripts/init-state.sh <proj> [--spec <file>] [--by <name>]` writes an empty `.gauntlet/`
  (refusing a `STATE.md` of the project's own) and records the spec's SHA-256 in `.gauntlet/spec.sha256`; `next.sh`
  refuses a spec that changed since, or is missing, and never prints a command an agent could run. The route's own
  spec is `.gauntlet/SPEC.md` (the owner's spec is its source, linked by a `Source:` line, never edited by the route).
  A re-record is the owner's, signed, and refused without the signature: on a project that already has a `STATE.md`,
  `--spec` is refused by default - the kit cannot tell whose hands changed it, so it records nothing - and `--by
  "<name>"` is the only way through (a signature, not a password), appending `re-recorded <date> by "<name>" <old 8
  hex> -> <new 8 hex>` to `.gauntlet/spec.sha256` and a matching paragraph to the project's `LOG.md`, `<date> spec
  re-recorded: <spec> <old 8 hex> -> <new 8 hex>, signed --by "<name>" (...)`, which `next.sh` repeats under every
  answer. The example refusal names `init-state.sh`, as does the refusal of a project with no
  state (`<kit>/scripts/init-state.sh <proj> writes one`). `AGENTS.md` section 4 (and so the entry skill's step 4),
  `QUICKSTART.md` step 5 and `state/README.md` run `init-state.sh` first; installing the state by hand is a fallback
  that records no spec, so the spec check is off. **init-state replaces an example:** a `.gauntlet/STATE.md` that `next.sh`
  would refuse as the kit's example (marker, title or values - the same test, `scripts/lib/state-example.sh`, which
  both read) is overwritten in the same step, `replaced the kit's example STATE.md`, with an example `DECISIONS.md` or
  `LOG.md` beside it; a `STATE.md` that is not the example is still refused, and wins over an example beside it - so
  the example refusal's ` - scripts/init-state.sh <proj> writes an empty one` is one command.
- **Phase claims against records:** `next.sh` refuses `phase:` 2 or higher with no green `.gauntlet/reports/01-build.txt`,
  and 3 or higher with `battery: never` (no escape: each record is one command away).
- **The selftest's cost on the FIRST line:** it says how many minutes the selftest takes and to give it a tool timeout
  above that, or run it in the background.
- **`key:value` collapsed:** a flag line with no space after its colon (`ceiling:8`) is compared as `key: value`, so a
  copy of the example spelled that way is refused too.
- **The import lines:** `setup-deps.sh` ends with the lines a project's tests import the kit with
  (`import {V4Harness} from "gauntlet-v4/V4Harness.sol";`, `MinimalRouter`, `LiquidityHelper`, `HookMiner`,
  `HostileERC20` from `gauntlet-kit/`) and a sentence: the kit's own examples import relative to the kit, do not copy
  theirs. The same block in QUICKSTART 7b and in the entry skill's step 2 (generated from `setup-deps.sh` itself), and a
  header line in each of the kit's test files that imports the kit relatively (the examples, the module's own tests,
  `fork/` and `test-periphery/`). It also writes `[profile.pending]` with `test =
  "pending"` (row 6b's profile; every other key inherited) when the project has none, and says so; a project set up
  before is "not set up" for `--check` and `doctor.sh <proj>` until `setup-deps.sh` runs again.
- **The harness's bits refusal names the act:** `... This is a finding, not a fix (doctrine/NEXT.md row 6b): write the
  test that shows it as pending/<id>.t.sol, record it red with scripts/pending-red.sh <proj> pending/<id>.t.sol, count
  it in STATE.md; set _skipPermissionCheck = true only in pending tests, while that finding is open
  (doctrine/EVIDENCE.md section 2).` - `_skipPermissionCheck` is a flag, set to `true`, not a call, and the other
  findings' pending tests set it too while the bits finding is open, as that section says. The v4 battery holds the
  whole line (287 -> 288). (v0.4.2 replaced its last clause: below.)
- **The kit's MANIFEST:** `MANIFEST` at the kit's root (SHA-256 and path of every file the kit ships), written by
  `scripts/gen-manifest.sh`, `--check` naming each difference; the selftest checks it is current. `doctor.sh` prints
  `kit: N files not in MANIFEST: <first three>` (or `kit: no MANIFEST`), and `next.sh` a note under its answer.
  **Generated directories excluded:** one rule, in the same words in `gen-manifest.sh`, `doctor.sh` and `next.sh` (the
  selftest holds them equal) - `.git`, and every `lib/` (but `scripts/lib/`), `cache/`, `out/`, `corpus/`, `census/`,
  `broadcast/` and `.gauntlet/` directory anywhere under the kit: after the selftest and the kit's own batteries
  `doctor.sh` had named 152 of their outputs as files not in MANIFEST.
- **`adapters/local-models/README.md`:** the same harness on a hosted model - Hermes's compression guard measured
  switching compression off for the rest of a session, `api_max_retries: 8` enough on a paid endpoint, a model that
  rewrites a file whole, the cost.

Known gaps of v0.4.1: the bits refusal names a pending test and has no command that writes its skeleton (one waits for
a run that reaches that refusal and fails there); Hermes's compression guard has no remedy measured; the MANIFEST note
is not a refusal - the kit cannot know whether the operator meant the file - and outside a git checkout `gen-manifest.sh
--check` names a file MANIFEST does not list without failing on it; a file written under a `lib/`, `cache/`, `out/`,
`corpus/`, `census/`, `broadcast/` or `.gauntlet/` directory of the kit is not seen, and the two backtest fixtures the
kit tracks under `foundry-kit/v4/.gauntlet/` are not in MANIFEST for that reason; `init-state.sh` replaces an example
in `.gauntlet/` only - the example copied to the project's root is still refused, to be deleted first (two steps
there); `doctrine/NEXT.md` row 6's `battery: never` branch is no longer reachable by a state `next.sh` accepts (phase
0-1 is row 4, phase 2-3 row 4b, phase 3 or higher with `battery: never` refused) - the row is unchanged.

**v0.4.2, in this release: what round 4 showed, fixed before the clean run.** Two strong models walked v0.4.1b on the
round-3 hook (2026-10-02): both found the four planted defects, no false green - and the judge reproduced the friction
that cost them: a battery that could not go green with a permission-bits finding open, phases advanced by hand past
their gate, a fuzz configuration written by hand, a stale long-fuzz corpus read as a counterexample, two selftests in
one kit that both failed. And a local model had "fixed" the hook it was auditing in `src/` when the harness refused its
permission bits (2026-09-30), with nothing to say so.
- **A permission-bits finding and the everyday suite:** while such a finding is OPEN AND RECORDED - its test,
  `pending/<id>.t.sol`, sets `_skipPermissionCheck = true` in its own `setUp` and a test function of its own calls
  `_checkHookPermissions(address(hook));` directly, with no `vm.expectRevert` (the harness's revert fails it; wrapped in
  `vm.expectRevert` it passes, and `pending-red.sh` refuses a passing test as no finding's test), and
  `scripts/pending-red.sh` records that red, the record
  carrying a `permission-bits:` line - any suite may set `_skipPermissionCheck = true` in `setUp` with a header line
  `// _skipPermissionCheck: <id> open`: the everyday suite under `test/` too, the hook then running as the manager
  drives it. The order, in the harness's refusal, `doctrine/EVIDENCE.md` section 2, the v4 README, QUICKSTART 7b and the
  battery skill: record the red, then the flag and header in the suites, then the battery. Such a record stays current
  while `src/` (the hash on its `anchor:` line) and the finding's own file are as recorded: putting the flag into
  `test/`, or any later edit there or elsewhere in `pending/`, does not stale it (its red comes from the harness and
  `src/`; every other pending record keeps the full key). `scripts/battery.sh` holds the rule: a file under `test/` that
  assigns the flag (in its code; any assignment - `= true`, `= !false`, `= false`) without that record is refused before
  anything runs, saying why - no record, or which part of its key changed since (each record now hashes each part alone,
  its `keyed:` line; `next.sh`'s refusal of a stale pending test says the same) - and naming `pending-red.sh` with the
  finding's own file; with it the battery ends `BATTERY PASSED - green UNDER open permission-bits finding <id>`. The rule
  is skipped only where there are no records to hold the flag against - the kit's own tree, a tree with no `.gauntlet/`,
  a bench whose `.gauntlet/` holds only reports - and the battery says so, `bits not checked: <why>`; a `.gauntlet-bench`
  marker beside a `.gauntlet/` with records skips nothing. "only in pending tests" is gone (this history aside).
- **The flags against their records (`next.sh`):** `battery: green` with the battery's test record
  (`.gauntlet/reports/02-test.txt`) absent or not green is refused, naming the battery; `phase:` 3 or higher with a test
  record that shows no test ran (a battery that failed before its tests left a green build record) likewise; `phase:` 4
  or higher with no invariant suite under `test/`, no census report or no `fork:` note is refused, each naming its
  command. The judge's phase walk, replayed: every hand edit it got through is now refused. The phase-2 refusal says
  what phase 2 open needs - `next: REFUSED - phase <n> is open but there is no green build record (...): run
  <kit>/scripts/setup-deps.sh <proj> then <kit>/scripts/battery.sh <proj> (they may run at phase 1), or write the phase
  that is open` - after two walkers in a row read its earlier wording ("claims a compiling hook") as a loop.
- **`setup-deps.sh` writes the fuzz configuration** QUICKSTART 7b needs when it is absent - `fs_permissions` for
  `./census`, an `[invariant]` with `fail_on_revert = true` (the v4 module's 64 x 64; `fail_on_revert` added to one of
  yours that has none), a `[profile.long.invariant]` larger than it - each line said, a line that is there left as it is
  and said; and it prints the `COPY_ROOT` its layout needs for `mutate.sh`. Measured from nothing on the round-3
  project with round 4's tests: the battery, the census and the long fuzz ran with no hand edit.
- **The long fuzz's bench corpus is keyed to the test directory:** `fuzz-long.sh` keeps the hash of the profile's test
  directory beside the bench's corpus; a changed handler clears the bench's `corpus/` and `cache/invariant/` before the
  campaign, and says so; unchanged, it says the corpus is kept. `doctrine/NEXT.md` row 6b says it.
- **The selftest's marker by `mktemp`:** two selftests in one kit no longer share a temporary file.
- **No selftest case pipes into `grep -q`:** under `pipefail`, `grep -q` leaving at its match can kill the command
  writing to it with SIGPIPE, and the case failed with the text there (one case, measured: about 1 run in 100). Each
  such case now captures the output, then matches it; a case of the selftest holds that none is left.
- **`src/` is anchored like the spec:** `init-state.sh` records `.gauntlet/src.sha256` (the hash of `src/`'s file list
  and contents); `pending-red.sh` and `battery.sh` say on every run whether `src/` is as recorded and refuse, before
  anything runs, a `src/` that changed - the spec's refusal, with no command an agent could run; the owner re-records a
  change of their own by the same signed act (`init-state.sh --src --by`, a line in `src.sha256` and in `LOG.md`); a
  project with its state and no anchor is told how one is made, and not refused. Each red record names the anchor it
  was made on.
- **No refusal prints an escape:** `PENDING_RED=0` and `CITED_FILES=0` are in `next.sh`'s header only; one used that
  lets something through appends a line to the `LOG.md` beside `STATE.md`, naming what it let through.
- **Text:** the dossier template's PROPERTY-TESTED is `EVIDENCE.md`'s; QUICKSTART says REACH's separator is `;` and
  the census floor goes below the lowest of three short campaigns; `NEXT.md` says `next.sh`'s refusals and its two `FIRST -
  fill` lines go to stderr, and the selftest's `FIRST` line to stdout (exit 0); the battery skill points at `_setUpV4()`
  warping `block.timestamp`; `doctor.sh` on a kit vendored under `/mnt/c` says to copy the project, kit included, to the
  Linux side (no clone, no network). The FIRST line says the selftest takes about 8 minutes (measured 371-457 s at 1636
  cases, two at once the slowest). `setup-deps.sh`, leaving a user's `fail_on_revert = false` in `[invariant]`, says the
  long profile's `fail_on_revert = true` judges differently. "src/ has no anchor" is said once per project (the first
  command leaves `.gauntlet/src-anchor-told`), not on every command; the summaries and records keep saying it.

Known gaps of v0.4.2: `init-state.sh` has no lock against a second run writing the same `.gauntlet/` - a lock held by a
script that runs for milliseconds says nothing about a session that writes for an hour, and the kit sees no process for
a session: the marker fix alone. The anchor covers `src/` only (not a library, a test helper or the configuration), and
it is a signature, not a proof of whose hands; `next.sh` does not read it (`pending-red.sh` and the battery do); a hook
still to be written has no anchor until the owner signs one. The bits rule after the verifier (V60): every pending
record that is NOT a permission-bits one keeps the full key, so an edit under `test/` or `pending/` still stales it and
`next.sh` refuses that test until `pending-red.sh` runs again (named, with the part that changed - the battery reads only
the bits record); the bits record itself is staled by its own file or `src/` only - a helper in `test/` its test imports,
`foundry.toml` or `remappings.txt` changing does not stale it, although its red could change with them (the next
`pending-red.sh` run would show it), and a record made before v0.4.2's `keyed:` line keeps the full key and is named
stale without its part. The battery reads an assignment to the flag in the text of a file's code: one in a `/* */`
comment is refused as if it were code, and one made outside `test/` (a helper under `pending/` or `lib/`), through a
tuple or in assembly is not seen; the header's `open` is not checked (`<id> fixed` reads as the id). The rule is not
applied in the kit's own tree, in a tree with no `.gauntlet/` or in a bench whose `.gauntlet/` holds only reports - said
on each run (`bits not checked`), not refused. "src/ has no anchor" is told once per project: a later session on it
reads it in the summaries and records only. `battery: green` is read against
forge's summary line, so skipped tests count as green there (the battery's own verdict, with `ALLOW_SKIPS`, is not
recorded). Phase 4's checks are of existence - a `function invariant` under `test/`, a census report that is not a
FAILED campaign's, a `fork:` note - not of their quality. A walker's everyday suite may encode the current behaviour of
a defect still open, planted or found: on the clean run's suite, with the four planted defects fixed afterwards, 20 of
its 22 everyday tests passed - one leaned on the epoch clock a permission-bits fix moves (that finding has no fix
variant, so the suite had never run on the fixed hook), one on a claim-window boundary another fix moves. These notes do
not claim the everyday suite survives the owner's fixes: the fix cycle re-runs it (`doctrine/NEXT.md` row 6b,
`AGENTS.md` 6.3). The long fuzz's corpus key is the profile's test directory
alone: a handler elsewhere, or `src/`, is not in it; a bench's first run has no key, so a corpus merged in from the project is cleared then (measured); the project's own `corpus/` is not touched. The fuzz configuration
`setup-deps.sh` writes is the module's budget, not one measured on the project's hook, and a project set up before is
"not set up" for `--check` and `doctor.sh <proj>` until `setup-deps.sh` runs again. An escape set with nothing to let
through leaves only its stderr line, and both stay documented in `next.sh`'s header (discoverable, not printed).
`doctor.sh`'s `/mnt/c` hint is not in the selftest (it needs a kit under `/mnt`): measured by hand.

## v0.3 - 2026-09-29 - skills as the way in, a window of real swaps, and a finding's test that must discriminate

- **Thin skills** (`skills/`, `scripts/install-skills.sh`): nine skills - the entry one and one per phase or role -
  generated by `scripts/gen-skills.sh` from `AGENTS.md` and `doctrine/NEXT.md`, never written by hand;
  `scripts/skills-check.sh` regenerates them and fails on any drift or on a skill over 9000 bytes. A skill is a way
  in and a discipline, not a second doctrine: it quotes the six invariant rules and the rows it serves, and points at
  the sections it does not repeat. The installer copies them into a harness's skills directory (`claude`, `codex` or
  `agents`, `devin` - the directories as each harness documents them, not re-verified) with the kit's path substituted.
  Measured on one model family inside one harness: an A/B round on a planted-defect hook and a fresh reader with skills
  on a hook nobody had seen - every planted defect found, no false green (every judge re-run by a separate judge), the
  state and `scripts/next.sh` used from the first minutes; about 15 % less of the kit in the agent's context than the
  round before (the 30 % aimed at was not reached), and the three long files still read whole. The design is Pedro
  Santana's (`skills/README.md`).
- **Backtests:** `scripts/backtest.sh <proj> --pool <id> --from <block> --to <block>` fetches the pool's `Swap`
  events (block-pinned fixture with a sidecar: blockHash, SHA-256, request count; refused when they disagree), replays
  them through the hook on a fork at the window's first block - the real pool's price and active liquidity in one
  full-range position, each swap at its real block and timestamp - next to a control without the hook, and writes
  `07-backtest-<pool>-<from>-<to>-<hook>.txt`: what the hook took, returned, refused or paid, per swap and in total,
  the largest price deviations, the RPC requests. An empty window is refused, a thin pool is named. Measured on the
  chain's ETH/USDC 0.05 % pool, 200 blocks, 44 swaps, the three fee-taking examples: prices within 2 ppm of the real
  pool (control 1), DeltaFee's totals equal to its own counters to the wei; a cold replay costs ~124 requests, a warm
  one 16, the fetch 27. A replay is a sandbox report, not a proof - `doctrine/SIMULATE.md` 6 says what it substitutes
  (the LP set, MEV, the hook's effect on later swaps) and this window's own limits.
- **The kit is proven on this machine before the route uses it:** `scripts/selftest.sh`, ending PASSED, leaves a
  marker (the SHA-256 of the kit's scripts, a hash of the machine's identity, forge's version); `scripts/next.sh`
  answers `next: FIRST - prove the kit on this machine` when any of the three differs. A fresh clone, an edited
  script, another forge or a kit copied to another machine starts with the selftest.
- **A pending test the STATE does not name is refused:** `next.sh` walks `pending/` as forge's pending profile does
  (subdirectories, hidden files, every `.sol`) and refuses a file no `pending:` note names, and a note whose file does
  not exist. Row 10 leaves the route's own workspace (`.gauntlet/`) out.
- **A finding's test must discriminate** (`doctrine/EVIDENCE.md` section 2): a finding is MUTATION-TESTED when its
  test is red on the code, green on a FIX variant built by `scripts/mutate.sh` (never applied to `src/`), the
  everyday suite green on that same variant (a second run - a variant that deletes the test's subject breaks it), the
  exact failure expected, and a control in a test of its own in the same file: the same call on the same shape
  ACCEPTED when only the finding's condition differs. Each piece closed a way a non-fix earned the label, measured. `mutate.sh` warns when
  the finding's test accepts any revert (a bare `expectRevert()`, a low-level call only asserted false, a `catch`
  that does not compare the error) and says its silence is not evidence.
- **What the fresh reader of v0.3 (a new hook, the kit vendored beside it) found, closed:**
  - `scripts/bench.sh` follows a remapping out of the project (`../lib/hook-gauntlet/...`): the target is copied or
    linked into the bench, the black-box isolation check scans the whole bench, anything an earlier layout left at
    the bench's root is removed and said, a `../` target that resolves into the project is refused, and a copied
    target's contents are named.
  - Editing a test or a handler makes the battery and the long fuzz stale, not only a bytecode change.
  - `scripts/fuzz-long.sh` says what the campaign will cost before it starts; `ESTIMATE_ONLY=1` stops there.
  - Expected reverts are classified by the error, never by a state (`doctrine/FUZZ-ACTIONS.md`); the handler to copy
    is `InRangeDonateHook`'s.
  - The spec's gate accepts `pass (read-back pending)` while the owner has not read it back.
  - QUICKSTART 7b: remappings relative to the project with the kit vendored; absolute paths make the dossier say
    "not portable".
  - The kit's own example batteries (QUICKSTART steps 2-3) are "see the examples work", optional on an owner's hook,
    and skipping them is said.
  - `scripts/size.sh` lists a source compiled by two paths once; the dossier's evidence sentence matches EVIDENCE's
    labels.

Known gaps, each written where it lives:
- No control excludes a fix variant keyed to the test's exact values: the label is evidence, not proof, and asks for
  a plausible fix. The control in a test of its own was measured against one counting guard (a caller's third call),
  not against every shape of counter.
- The any-revert warning knows a few shapes: a flag asserted false through a helper, `if (ok) fail();`,
  `assertTrue(ok == false)`, a `catch` that only checks the error's length pass silently; it reads only the first
  run's files.
- The v4 examples DeltaFee, Capped and Claims still excuse reverts by a switch's state in their handlers.
- `mutate.sh`'s "baseline came out GREEN" line reaches the console, not the log; a glob in `TEST_FLAGS` is expanded
  by the shell (NOTHING PROVEN, the safe side).
- `bench.sh`'s rsync skips a file with the same size and the same mtime second; a layout change deletes what
  `BENCH_KEEP` kept (said on the line that removes it).
- `ESTIMATE_ONLY`'s `profile=long ... in <proj>` line names the project, not the bench the campaign would run in.
- "Another machine" is `/etc/machine-id`, else the hostname (macOS): a clone that kept both is not seen; only forge's
  first version line is compared.
- Measured on one model family inside one harness; no human has reviewed this kit. Other harnesses and local models
  are the next measurement.

## v0.2.1 - 2026-09-28 - four small things the last verifiers and the thirteenth fresh reader left

- The source record the judging scripts keep (a change forge's incremental build misses: a remapping, a symlink)
  hashes with SHA-256 (`sha256sum`, else `shasum -a 256`, else `openssl`; none: refused, never a pass); a v0.2
  record (cksum) is read as no record, one rebuild. A file edited to keep its CRC and size is seen now.
- A finding id must contain a letter and a digit, in `open_findings` and in `high <ids> - to tell`: `all`, `TBA`,
  `pending`, `1` are refused as ids and can no longer quiet row 1.
- Row 9b is decided by the flags once the skeleton names every open finding; it is asked only when the dossier does
  not, and then only about the owner's availability.
- The round brief names phase-3 pending findings as known: a round confirms them briefly and spends itself on what
  they do not cover.

Known gaps: a hashing tool that is present but broken makes every run a rebuild from scratch (honest, slow); a
non-id that carries a letter and a digit (`TBD1`, `Q3`) still passes as an id.

## v0.2 - 2026-09-28 - the kit against the chain that exists, and against itself

- **A mainnet fork at a pinned block** (`V4_MANAGER=fork`, `FOUNDRY_PROFILE=fork`): the deployed PoolManager, real
  USDC / WETH / ETH, the USDC blocklist and pause measured on the example hooks (`doctrine/V4-ACCOUNTING.md` 28-29);
  a block-pinned fixture; `FORK_BLOCK` read strictly.
- **Uniswap's real periphery** (`V4_WITH_PERIPHERY=1`, profiles `periphery` and `periphery-fork`): the example hooks
  through PositionManager, V4Router and Permit2, on the source manager and on the fork; what `sender`, `msgSender()` and
  `hookData` are there (items 30-32); the deployed UniversalRouter reads an older swap layout than the pinned periphery
  - on a native pool the hook gets empty `hookData`.
- **Who was paid, not only how much:** `JitRecipient` (a position exactly around the price just before a payout, out
  right after; after a push; as the trader too), `InRangeLedger` (a reference model of who was entitled), an example
  hook that donates to in-range liquidity and defends by paying before anything can change who is in range - with its
  residuals named (R1-R4), one of them the entitlement rule itself being exploitable. `doctrine/INVARIANTS.md`, "Who
  was paid".
- **No false green from behind forge's back:** the judging scripts strip forge's environment variables, refuse a
  project `.env` that sets one and a global `~/.foundry/foundry.toml` filter, rebuild from scratch on a build cache
  from another path or a source forge's incremental build misses (a remapping, a symlink), redact secrets in
  `FORGE_FLAGS`, and never call a failed test a pass whatever forge exited with. The selftest refuses a CI workflow
  that does not parse (four pushes ran no job over one unquoted colon).
- **The decision table closes:** `scripts/next.sh` reads `STATE.md` and names the row (rows as data, a drift guard
  with a hash of each condition); rows 2 and 14 are gates; a `rehearsal` flag; the ceiling as a gate, not a stop, and a
  ceiling the operator may set with the owner absent; the route ENDS with the owner absent - the skeleton names the open
  findings and `next.sh` answers `STOP - paused, waiting on the owner`; row 1 quiet only when every open high is
  recorded to tell, by id; one exit criterion everywhere (zero high and zero medium still OPEN); a phase-3 bug with the
  owner absent goes to `pending/`, the owner decides; benches live in `<project>/.gauntlet/bench`, never `$HOME`, and
  no script writes into an owner's tree without the convention installed.
- `scripts/doctor.sh` (checks, never installs), a one-page entry to the dossier, the forbidden words, issue forms for a
  stuck step and for what the kit missed; the v4 clean build measured at about 200 s and 9 GB, not 26 s and 1.3 GB.
- Known gaps, each written where it lives (the first two closed in v0.2.1): the source record is a CRC; a non-id
  written as an open high and as told still quiets row 1; the black-box bench refusal reads the word `src`; the
  "through the periphery" check can be fooled by a handler that pranks as the router; a treasury skim below 3 wei per
  donation passes the campaign.

## v0.1.1 - 2026-09-25 - the dossier as a PDF, and what a handoff must be

- `scripts/dossier-pdf.py` renders the handoff dossier as a PDF for the human auditor (status lines boxed first,
  tables with wrapped cells and repeated headers, nothing dropped); QUICKSTART step 10 hands over `DOSSIER.md` and
  `DOSSIER.pdf`, the Markdown being the record. Needs `reportlab` (optional); CI renders the template on every push.
- A handoff, as opposed to an exercise, now requires a git repository with its commit on the dossier's first line,
  every judge output cited from inside the project, and section 10 runnable on a clean machine (the kit vendored into
  the project with relative remappings).
- The DeltaFeeHook campaign's intermittent red in CI was the test harness, not the hook: a test router that kept an
  unused prepayment, and a handler that misread a correct refusal. Both fixed, pinned as replays, verified.

## v0.1 - 2026-09-24 - pre-audit workflow for Uniswap v4 hooks

First public release. Measured on one model family (Claude) inside one agent harness (Claude Code): two blind runs on one
small planted-defect target, twelve walks of the route by agents that had never seen it, each on a hook nobody had seen,
and a v4 module closed one area at a time with a second agent verifying each area. Numbers and limits: `README.md`, *Status*.

Worked examples in `foundry-kit/v4/`, each with unit, invariant, mutant and edge tests:

- an ordinary before/after hook with a capped dynamic fee (`CappedDynamicFeeHook`);
- a hook that returns deltas - fee on the unspecified side, rebate on the specified side, a per-pool cap (`DeltaFeeHook`);
- native-currency pools in the router and the liquidity helper, with a hostile native counterparty;
- a hook that keeps its fee as ERC-6909 claims, with conservation per party (`ClaimsFeeHook`);
- settlement re-entrancy through a token's own transfer, every manager door (`TokenCallbackActor`);
- a second pool sharing a currency, and state per pool;
- a 60-swap edge grid per hook at tick spacing 1 and 32 767 and at the price limits.

Not covered, said in the README and in the module's own gap list: fork tests and a block-pinned fixture; a JIT-recipient
actor for hooks that pay "whoever is in range"; v4-periphery; the token behaviours `foundry-kit/README.md` lists.

The route ends at audit-ready. It never deploys, never broadcasts, never handles a key, and never calls a hook safe.
