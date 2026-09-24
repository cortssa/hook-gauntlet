#!/usr/bin/env bash
#
# battery.sh - build, test, sizes, and a freshness check, in one command with one exit code.
#
# The problem it solves: "the tests pass" is three different claims, and people check them at three different
# moments and then remember the best one. A phase gate has to be a single command with a single exit code,
# and it has to leave its output on disk so the next agent, or the next human, can read the numbers instead
# of taking somebody's word for them. The freshness check is here for the same reason: a green run against
# stale artifacts is the most expensive kind of green.
#
# Usage:   scripts/battery.sh [project-dir]
# Env:     OUT_DIR      where to write the logs   (default: <project>/.gauntlet/reports)
#          FORGE_FLAGS  extra flags for forge     (e.g. --offline)
#          TEST_FLAGS   extra flags for forge test (e.g. -vvv, --match-contract X)
#          ALLOW_SKIPS  1 to accept skipped tests (default: a skipped test fails the battery - it tested nothing)
# Exit:    0 all steps passed, 1 something failed. The summary names which.

set -uo pipefail

# resolved BEFORE the cd below: with a relative $0 it would otherwise point at nothing, and the freshness check
# would be reported as missing
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/parse.sh
. "$HERE/lib/parse.sh" || { echo "battery: $HERE/lib/parse.sh is missing"; exit 1; }

PROJECT="${1:-.}"
cd "$PROJECT" || { echo "battery: cannot enter $PROJECT"; exit 1; }

OUT_DIR="${OUT_DIR:-.gauntlet/reports}"
FORGE_FLAGS="${FORGE_FLAGS:-}"
TEST_FLAGS="${TEST_FLAGS:--vv}"
mkdir -p "$OUT_DIR"

# A fuzz corpus belongs to ONE deployment layout. The v4 module runs the same suite against two managers (V4_MANAGER =
# source | fixture) whose addresses differ, and a corpus recorded against one, replayed against the other, produces a
# counterexample that is not one - measured: "the hook thinks it is in the future", red 4 times in 4. One corpus per manager.
# That PREVENTS the cross-over; it does not cure one. After a single bare `forge test` against the wrong manager the
# invented failure is persisted in cache/invariant and replays first, whatever the corpus: delete cache/invariant.
if [ -n "${V4_MANAGER:-}" ] && [ -z "${FOUNDRY_INVARIANT_CORPUS_DIR:-}" ]; then
  export FOUNDRY_INVARIANT_CORPUS_DIR="corpus/invariant-$V4_MANAGER"
  echo "battery: V4_MANAGER=$V4_MANAGER, so the invariant corpus is $FOUNDRY_INVARIANT_CORPUS_DIR"
fi

rc_build=0; rc_test=0; rc_sizes=0; rc_fresh=0

echo "== build =="
# shellcheck disable=SC2086
forge build $FORGE_FLAGS 2>&1 | tee "$OUT_DIR/01-build.txt"
rc_build=${PIPESTATUS[0]}

echo "== test =="
# shellcheck disable=SC2086
forge test $FORGE_FLAGS $TEST_FLAGS 2>&1 | tee "$OUT_DIR/02-test.txt"
rc_test=${PIPESTATUS[0]}

# forge exits 0 when a filter matches nothing, and when every suite skipped itself. Neither is a pass: read the numbers.
# Read by scripts/lib/parse.sh, which REFUSES a summary line it does not recognise instead of reading it as a number.
tests_passed="?"; tests_failed="?"; tests_skipped="?"
summary="$(parse_test_summary "$OUT_DIR/02-test.txt")"
rc_parse=$?
if [ "$rc_parse" -eq 1 ]; then
  echo "battery: forge printed no test summary - NO TESTS RAN (a filter that matches nothing?)"
  rc_test=1
elif [ "$rc_parse" -ne 0 ]; then
  echo "battery: forge's summary line is not of a shape this kit can read (another forge version?) - REFUSED, not guessed:"
  grep -E '^Ran [0-9]+ test suites? ' "$OUT_DIR/02-test.txt" | tail -1 | sed 's/^/    | /'
  rc_test=1
else
  read -r tests_passed tests_failed tests_skipped _ <<< "$summary"
  if [ "$tests_passed" = "0" ]; then echo "battery: 0 tests passed - NO TESTS RAN"; rc_test=1; fi
  if [ "$tests_skipped" != "0" ] && [ "${ALLOW_SKIPS:-0}" != "1" ]; then
    echo "battery: $tests_skipped test(s) SKIPPED. A skipped suite has tested nothing (a missing fixture?). ALLOW_SKIPS=1 to accept."
    rc_test=1
  fi
fi

echo "== sizes =="
# shellcheck disable=SC2086
forge build $FORGE_FLAGS --sizes 2>&1 | tee "$OUT_DIR/03-sizes.txt"
rc_sizes=${PIPESTATUS[0]}

echo "== freshness =="
if [ -x "$HERE/assert-fresh-build.sh" ]; then
  # The check asks forge whether anything is left to compile, with the battery's own FORGE_FLAGS and profile. Right after
  # the build above that is a no-op, so rc 0 means what it says: the artifacts the tests and sizes read were the sources
  # and settings as they are now. rc 1 means forge still had something to compile - a file changed while the battery ran,
  # or the steps were built differently - so what was measured above was stale (the check has rebuilt it). rc 2: not decided.
  # OUT_DIR means "reports" here and "artifacts" in the freshness check: do not let ours leak into it
  env -u OUT_DIR FORGE_FLAGS="$FORGE_FLAGS" "$HERE/assert-fresh-build.sh" . 2>&1 | tee "$OUT_DIR/04-freshness.txt"
  rc_fresh=${PIPESTATUS[0]}
else
  echo "assert-fresh-build.sh not found next to battery.sh: freshness NOT checked" | tee "$OUT_DIR/04-freshness.txt"
  rc_fresh=1
fi

echo
echo "== battery summary =="
echo "build     rc=$rc_build"
echo "test      rc=$rc_test   (passed $tests_passed, failed $tests_failed, skipped $tests_skipped)"
# by NAME, per test directory, so a log shows which parts of the suite ran (e.g. the v4 sandbox's test/sim)
echo "suites    $(parse_suites_by_dir "$OUT_DIR/02-test.txt")"
echo "sizes     rc=$rc_sizes"
echo "freshness rc=$rc_fresh   (0: forge had nothing left to compile; 1: it had - what was measured was stale, now rebuilt; 2: not decided)"
echo "logs in   $OUT_DIR"

if [ "$rc_build" -ne 0 ] || [ "$rc_test" -ne 0 ] || [ "$rc_sizes" -ne 0 ] || [ "$rc_fresh" -ne 0 ]; then
  echo "BATTERY FAILED"
  exit 1
fi
echo "BATTERY PASSED"
