#!/usr/bin/env bash
#
# mutate.sh - apply ONE change to a throwaway copy of the project and say what the tests think of it.
#
# The problem it solves, twice:
#
#   EXPECT=red   (default) "does this test bite?" Break the code on purpose. A test that stays green over a
#                broken contract is not a test. Every new invariant, every regression test and every guard
#                gets one mutant it must kill, before it counts.
#   EXPECT=green "which of these alternatives do I take?" When a fix can be written two or three ways and the
#                hook is near the size limit or the gas ceiling, do not argue about it: build each variant,
#                run the battery on it, read the bytes. The decision is then a table, not an opinion.
#
# The original is never touched. The change is applied to a copy, and the copy is deleted afterwards.
# The change is a literal single-line string replacement that must match EXACTLY ONCE: a mutant that did not
# apply, or applied in three places, proves nothing and is reported as such (rc=2), never as a result.
#
# Usage:   scripts/mutate.sh <project-dir> <file-relative-to-project> <old-string> <new-string>
# Env:     EXPECT      red | green                          (default: red)
#          TEST_FLAGS  flags for forge test                  (e.g. --match-contract Invariants)
#          FORGE_FLAGS extra flags for forge                 (e.g. --offline)
#          LABEL       a name for the log                    (default: mutant)
#          OUT_DIR     where the log goes                    (default: <project>/.gauntlet/reports/mutants)
#          KEEP=1      keep the copy and print its path
#          BASELINE_MAY_BE_RED=1  only with EXPECT=green: accept a baseline with failing tests, for the flow "write the
#                      regression test first, see it red, then compare candidate fixes". The variant must still be all green.
#          COPY_ROOT   a parent directory to copy instead of the project alone, for a project that imports from
#                      outside itself (a remapping like ../src/). The project must be inside it.
#          BENCH_ROOT  where the throwaway copy is made (created if it does not exist); without it TMPDIR, then /tmp.
#                      A place the copy cannot be made is refused in one line naming the variable and the path (rc=2).
# Exit:    0 the outcome matched EXPECT      (red: the mutant was KILLED;  green: the variant PASSED)
#          1 the outcome did not match       (red: the mutant SURVIVED;   green: the variant FAILED)
#          2 nothing was proven              (bad arguments, no unique match, the change does not compile, the UNCHANGED
#                                             code is not green under the same TEST_FLAGS, or no test ran at all)
# A limit, stated: the baseline is run ONCE. A test that is flaky without a fixed seed can be green there and red on a
# mutant that changed nothing, and that reads as KILLED. Pin the seed in TEST_FLAGS (--fuzz-seed N) when the suite has
# such a test, and read the failing test's message every time - it is printed for that reason.

set -uo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: mutate.sh <project-dir> <file> <old-string> <new-string>"; exit 2
fi
PROJECT="$(cd "$1" 2> /dev/null && pwd)" || { echo "mutate: cannot enter $1"; exit 2; }
FILE="$2"; export MUT_OLD="$3"; export MUT_NEW="$4"
EXPECT="${EXPECT:-red}"
TEST_FLAGS="${TEST_FLAGS:-}"
FORGE_FLAGS="${FORGE_FLAGS:-}"
LABEL="${LABEL:-mutant}"
OUT_DIR="${OUT_DIR:-$PROJECT/.gauntlet/reports/mutants}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/parse.sh
. "$HERE/lib/parse.sh" || { echo "mutate: $HERE/lib/parse.sh is missing"; exit 2; }

case "$EXPECT" in red | green) ;; *) echo "mutate: EXPECT must be red or green"; exit 2 ;; esac
[ -f "$PROJECT/$FILE" ] || { echo "mutate: no such file $PROJECT/$FILE"; exit 2; }
[ -n "$MUT_OLD" ] || { echo "mutate: the old string is empty"; exit 2; }
[ "$MUT_OLD" != "$MUT_NEW" ] || { echo "mutate: old and new are the same string"; exit 2; }

mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/$LABEL.txt"
# The throwaway copy goes under BENCH_ROOT when there is one (so every write stays where the brief says), else TMPDIR, else
# /tmp. A BENCH_ROOT that does not exist yet is created. The copy's path is checked before anything is written into it:
# with a root that did not exist, `mktemp` failed, the path came back EMPTY, and this script ran `cp -a <project>/. /` - a
# fresh reader saw "cannot create directory '/./src': Permission denied", and as root it would have copied the project
# into the file system's root (FR8, 2026-09-24).
if [ -n "${BENCH_ROOT:-}" ]; then COPY_VAR="BENCH_ROOT"; COPY_PARENT="$BENCH_ROOT"
elif [ -n "${TMPDIR:-}" ]; then COPY_VAR="TMPDIR"; COPY_PARENT="$TMPDIR"
else COPY_VAR=""; COPY_PARENT="/tmp"; fi
case "$COPY_PARENT" in /*) ;; *) COPY_PARENT="$PWD/$COPY_PARENT" ;; esac   # absolute: the script cd's into the copy later
copy_refused() { # copy_refused <why>: one line, naming the variable that chose the place and the place itself
  if [ -n "$COPY_VAR" ]; then where="$COPY_VAR=$COPY_PARENT"; else where="$COPY_PARENT (neither BENCH_ROOT nor TMPDIR is set)"; fi
  echo "mutate: cannot make the throwaway copy under $where: $1. NOTHING PROVEN - set BENCH_ROOT to a directory you can write to."
  exit 2
}
if [ "$COPY_VAR" = "BENCH_ROOT" ] && [ ! -d "$COPY_PARENT" ]; then
  mkdir -p "$COPY_PARENT" 2> /dev/null || copy_refused "it does not exist and cannot be created"
fi
[ -d "$COPY_PARENT" ] || copy_refused "it is not a directory (it does not exist?)"
COPY="$(mktemp -d -p "$COPY_PARENT" mutate.XXXXXX 2> /dev/null)" || COPY=""
if [ -z "$COPY" ] || [ ! -d "$COPY" ]; then COPY=""; copy_refused "mktemp could not create a directory in it"; fi
cleanup() { if [ "${KEEP:-0}" = "1" ]; then echo "copy kept at $COPY"; else rm -rf "${COPY:?}"; fi; }
trap cleanup EXIT

# -a keeps symlinks as symlinks, so a lib/ that points at a shared directory is not duplicated
REL="."
if [ -n "${COPY_ROOT:-}" ]; then
  ROOT="$(cd "$COPY_ROOT" 2> /dev/null && pwd)" || { echo "mutate: cannot enter COPY_ROOT $COPY_ROOT"; exit 2; }
  case "$PROJECT/" in
    "$ROOT"/*) REL="${PROJECT#"$ROOT"}"; REL="${REL#/}"; [ -n "$REL" ] || REL="." ;;
    *) echo "mutate: the project $PROJECT is not inside COPY_ROOT $ROOT"; exit 2 ;;
  esac
  COPY_SRC="$ROOT"
else
  COPY_SRC="$PROJECT"
fi
# a copy that failed half-way (an unreadable file, a full disk) is not the project: building it proves nothing about it
if ! cp -a "$COPY_SRC/." "$COPY/"; then
  echo "mutate: the copy of $COPY_SRC into $COPY failed (the cp errors are above). NOTHING PROVEN."; exit 2
fi
WORK="$COPY/$REL"

# The file must be a file OF THE COPY. `cp -a` keeps a symlink as a symlink, so `lib/X.sol` in the copy can be the
# ORIGINAL `lib/X.sol` of whatever the link points at (a shared lib/, a monorepo's package): the mutation below would be
# written through the link into the original, and "the original is never touched" would be false. Found by an outside
# static review (2026-09-23): `mv` replaced the original through a symlinked lib/. Checked before anything is built.
real_path() {
  if command -v realpath > /dev/null 2>&1; then realpath "$1"; return; fi
  # no realpath (an old macOS): resolve the directory, and refuse a leaf that is itself a link rather than guess
  [ -L "$1" ] && { echo "$1 (a symlink, not resolved: no realpath on this machine)"; return; }
  printf '%s/%s\n' "$(cd -P "$(dirname "$1")" 2> /dev/null && pwd -P)" "$(basename "$1")"
}
work_real="$(cd -P "$WORK" && pwd -P)"
file_real="$(real_path "$WORK/$FILE" 2> /dev/null)"
if [ -z "$file_real" ] || [ ! -e "$WORK/$FILE" ]; then
  # it resolves to NOTHING in the copy. The refusal used to read "resolves to , which is OUTSIDE the throwaway copy
  # (a symlinked lib/?)": an empty path and a guessed cause. The one way here is a link whose target the copy lacks.
  if [ -L "$WORK/$FILE" ]; then what="it is a symlink (-> $(readlink "$WORK/$FILE")) whose target is not in the copy"
  else what="it is not in the copy at all"; fi
  echo "mutate: $FILE does not resolve inside the throwaway copy $work_real: $what. NOTHING PROVEN."
  echo "        Mutate a file that lives in the project (replace the link with a copy of its target), not a link out of it."
  exit 2
fi
case "$file_real" in
  "$work_real"/*) ;;
  *)
    echo "mutate: $FILE resolves to $file_real, which is OUTSIDE the throwaway copy $work_real (a symlinked lib/?)."
    echo "        Mutating it would change the ORIGINAL. NOTHING PROVEN. Mutate a file that lives in the project, or copy"
    echo "        the dependency into it first."
    exit 2 ;;
esac

# The UNCHANGED copy must build, or a failure further down would be blamed on the change.
# It is built with --force, from nothing. A build cache copied from another path is NOT trustworthy: forge has been
# measured reusing artifacts of the ORIGINAL source after the copy was mutated, which reported a broken contract as
# SURVIVED and a broken variant as PASSED - a false green in the one tool whose job is to catch false greens. After
# this forced build the cache belongs to this path, and the incremental build of the mutant is correct.
# shellcheck disable=SC2086
if ! (cd "$WORK" && forge build --force $FORGE_FLAGS > "$OUT_DIR/$LABEL.baseline.txt" 2>&1); then
  echo "mutate: the copy does not compile BEFORE any change was applied. NOTHING PROVEN."
  # the FIRST error, then the end: solc's errors and warnings share one listing in no fixed order, so the end of a
  # failed build can be all warnings and the import that did not resolve never on the screen (a fresh reader met that)
  echo "        first error: $(first_error_line "$OUT_DIR/$LABEL.baseline.txt" || echo "(none recognised - read the log)")"
  echo "        The end of the build log:"
  tail -n 12 "$OUT_DIR/$LABEL.baseline.txt" | sed "s/^/    | /"
  echo "        If the error is an unresolved import, the project reaches outside its own directory (a relative"
  echo "        remapping?): set COPY_ROOT to the parent that holds both. Otherwise fix the compile error first."
  echo "        Full log: $OUT_DIR/$LABEL.baseline.txt"
  exit 2
fi

# The UNCHANGED copy must also pass the SAME tests, and some must actually run. Otherwise "the tests went red" means
# nothing: a typo in TEST_FLAGS, a fork test with no RPC, a flaky test - each would make every mutant look KILLED, and a
# filter that matches nothing would make every broken variant look PASSED. This costs one extra run of the suite.
# the number of tests that passed, read by scripts/lib/parse.sh: empty when forge printed no summary or one it cannot read
passed_in() { local s; s="$(parse_test_summary "$1")" || return 0; printf '%s\n' "${s%% *}"; }
# shellcheck disable=SC2086
(cd "$WORK" && forge test $FORGE_FLAGS $TEST_FLAGS > "$OUT_DIR/$LABEL.baseline-test.txt" 2>&1)
rc_base=$?
base_passed="$(passed_in "$OUT_DIR/$LABEL.baseline-test.txt")"
base_red_ok=0
if [ "$EXPECT" = "green" ] && [ "${BASELINE_MAY_BE_RED:-0}" = "1" ] && [ "$rc_base" -ne 0 ] && [ -n "$base_passed" ] \
  && grep -qE '^\[FAIL' "$OUT_DIR/$LABEL.baseline-test.txt"; then
  # the one flow in which a red baseline is the POINT: the regression test was written first, it is red on the unchanged
  # code, and the variants are candidate fixes. The variant still has to come out fully green below.
  base_red_ok=1
  echo "mutate: the baseline is red, and BASELINE_MAY_BE_RED=1 says that is expected. Red before the change:"
  grep -E '^\[FAIL' "$OUT_DIR/$LABEL.baseline-test.txt" | cut -c1-160 | sort -u | head -20
fi
if [ "$base_red_ok" -eq 0 ] && { [ "$rc_base" -ne 0 ] || [ -z "$base_passed" ] || [ "$base_passed" = "0" ]; }; then
  echo "mutate: the UNCHANGED code does not pass these tests, or no test ran (rc=$rc_base, passed=${base_passed:-none})."
  echo "        A red or empty baseline makes every verdict meaningless. NOTHING PROVEN. The end of the log:"
  tail -n 8 "$OUT_DIR/$LABEL.baseline-test.txt" | sed "s/^/    | /"
  exit 2
fi

# literal replacement, counted. Strings come through the environment so that awk does not interpret backslashes.
export MUT_TARGET="$WORK/$FILE.mutated"
count="$(awk '
  BEGIN { old = ENVIRON["MUT_OLD"]; new = ENVIRON["MUT_NEW"]; n = 0 }
  { line = $0; out = ""
    while ((i = index(line, old)) > 0) { n++; out = out substr(line, 1, i - 1) new; line = substr(line, i + length(old)) }
    print out line > ENVIRON["MUT_TARGET"] }
  END { print n }' "$WORK/$FILE")"
if [ "$count" != "1" ]; then
  echo "mutate: the old string matched $count time(s) in $FILE; it must match exactly once. NOTHING PROVEN." | tee "$LOG"
  exit 2
fi
mv "$WORK/$FILE.mutated" "$WORK/$FILE"

{
  echo "== $LABEL (EXPECT=$EXPECT) =="
  echo "file: $FILE"
  echo "-    $MUT_OLD"
  echo "+    $MUT_NEW"
} | tee "$LOG"

cd "$WORK" || exit 2
# The mutant is built with --force, like the baseline above it. The reason is one incident (2026-09-22): a batch of
# eight mutants of a contract the test deploys with `new` all reported SURVIVED with gas identical to the baseline to
# the unit, and five died on a cleared build. The cause was NOT established - an attempt to reproduce the "stale
# creation code kept by an incremental build" story (same shape, dirty tree) went red on the incremental build exactly
# as on the clean one, and a mutation applied to a file forge never compiled explains the same symptoms. The "compiled
# nothing" guard below sees neither case, so the build is forced regardless. It costs a full compile per mutant, a
# fair price for a precaution in the one tool whose job is to tell a real red from a false green.
# shellcheck disable=SC2086
forge build --force $FORGE_FLAGS > "$LOG.build" 2>&1
rc_build=$?
cat "$LOG.build" >> "$LOG"
# kept as a belt over the braces: with --force this should be unreachable, and if it ever fires the assumption above
# is wrong and every result from this tool is in question
if [ "$rc_build" -eq 0 ] && grep -q -i "No files changed, compilation skipped" "$LOG.build"; then
  echo "mutate: forge compiled NOTHING after the change was applied, DESPITE --force. NOTHING PROVEN." | tee -a "$LOG"
  rm -f "$LOG.build"; exit 2
fi
rm -f "$LOG.build"
if [ "$rc_build" -ne 0 ]; then
  echo "mutate: the changed code does not compile. NOTHING PROVEN (see $LOG)." | tee -a "$LOG"
  echo "        first error: $(first_error_line "$LOG" || echo "(none recognised - read the log)")" | tee -a "$LOG"
  exit 2
fi

# shellcheck disable=SC2086
forge test $FORGE_FLAGS $TEST_FLAGS > "$LOG.test" 2>&1
rc_test=$?
cat "$LOG.test" >> "$LOG"
mut_passed="$(passed_in "$LOG.test")"
# forge prints every failing test twice (inside its suite, and again under "Failing tests:"): count DISTINCT lines
mut_fails="$(grep -E '^\[FAIL' "$LOG.test" | cut -c1-160 | sort -u | wc -l | tr -d ' ')"
# A mutant that breaks `setUp()` prints `[FAIL: setup failed: ...]` and would be counted as a kill, but NO TEST RAN
# and no claim was tested: the mutant broke the fixture, not the thing the test asserts. That is NOTHING PROVEN, the
# same as a mutant that does not compile. Found 2026-09-22 by a verifier reading this script rather than its output.
# forge has TWO shapes for this and the guard must match both: `[FAIL: setup failed: ...] testName()` and
# `[FAIL: <the revert reason>] setUp()`. The second one is what a real bricked fixture printed when this guard was
# first tried, and the first version of the guard missed it.
setup_fails="$(grep -E '^\[FAIL: setup failed|^\[FAIL.*\] setUp\(\)' "$LOG.test" | cut -c1-160 | sort -u | wc -l | tr -d ' ')"
rm -f "$LOG.test.keep"; mv "$LOG.test" "$LOG.test.keep"

if [ "$setup_fails" -gt 0 ]; then
  echo "mutate: the mutant broke setUp(), so no test ran and no claim was tested. NOTHING PROVEN (see $LOG):" | tee -a "$LOG"
  grep -E '^\[FAIL: setup failed|^\[FAIL.*\] setUp\(\)' "$LOG.test.keep" | cut -c1-160 | sort -u | head -5
  rm -f "$LOG.test.keep"; exit 2
fi

if [ "$EXPECT" = "red" ]; then
  if [ "$rc_test" -ne 0 ] && [ "$mut_fails" -gt 0 ]; then
    echo "KILLED - $mut_fails test(s) went red on the mutant, and the same tests were green without it. Failing tests:" | tee -a "$LOG"
    grep -E '^\[FAIL' "$LOG.test.keep" | cut -c1-160 | sort -u | head -20
    echo "READ the message: a test that fails for a reason unrelated to the claim has not killed anything."
    rm -f "$LOG.test.keep"; exit 0
  fi
  if [ "$rc_test" -ne 0 ]; then
    echo "mutate: forge test failed on the mutant WITHOUT a single failing test (a crash? a bad flag?). NOTHING PROVEN (see $LOG)." | tee -a "$LOG"
    rm -f "$LOG.test.keep"; exit 2
  fi
  echo "SURVIVED - the code was broken and every test stayed green. The rule you were checking does not bite." | tee -a "$LOG"
  exit 1
fi

# EXPECT=green: a variant. It must pass, and the bytes are part of the answer.
if [ "$rc_test" -ne 0 ]; then
  echo "VARIANT FAILED the tests (see $LOG)." | tee -a "$LOG"
  grep -E '^\[FAIL' "$LOG.test.keep" | cut -c1-160 | sort -u | head -20
  rm -f "$LOG.test.keep"; exit 1
fi
if [ -z "$mut_passed" ] || [ "$mut_passed" = "0" ]; then
  echo "mutate: no test ran against the variant. NOTHING PROVEN." | tee -a "$LOG"
  rm -f "$LOG.test.keep"; exit 2
fi
rm -f "$LOG.test.keep"
echo "VARIANT PASSED $mut_passed test(s). Sizes:" | tee -a "$LOG"
if [ -x "$HERE/size.sh" ]; then
  OUT_DIR="$OUT_DIR" LABEL="$LABEL-sizes" "$HERE/size.sh" "$WORK" | tee -a "$LOG"
else
  echo "size.sh not found next to mutate.sh: sizes NOT measured" | tee -a "$LOG"
fi
exit 0
