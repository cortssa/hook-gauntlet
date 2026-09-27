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
#          FORGE_FLAGS  extra flags for forge     (e.g. --offline). The kit's own variable (forge does not read it):
#                       allowed, and when set the test line names it next to the filter - a path or a --match-* in it
#                       narrows the run like any filter (an endpoint or a key is printed as <set>, by its shape:
#                       scripts/lib/forge-env.sh, forge_flags_shown). A line break in it is refused: exit 2, nothing run.
#          FOUNDRY_PROFILE  the profile forge runs (allowed; the summary's `profile` line names it)
#          ALLOW_SKIPS  1 to accept skipped tests (default: a skipped test fails the battery - it tested nothing)
#          NOT read: TEST_FLAGS, nor anything else of forge's from the environment. The battery is the WHOLE suite: a
#          filter exported for scripts/mutate.sh (QUICKSTART's `TEST_FLAGS="--match-contract ..."`) made it run 5 tests
#          of 107 and say BATTERY PASSED (measured, 2026-09-27), and forge reads many more (scripts/lib/forge-env.sh):
#          every variable whose name, upper-cased, starts with FOUNDRY_, FORGE_ or DAPP_ is removed but the two above
#          (V4_MANAGER's corpus directory is set by the battery itself, after), and a line names each one removed. A
#          `.env` in the project that sets one is refused (forge loads it; the battery cannot remove it): BATTERY FAILED.
#          A filter in the project's own foundry.toml (`match_contract = ...`) is forge's configuration, not the
#          environment: it is not removed, and the summary names it. One in ~/.foundry/foundry.toml, the machine's
#          configuration that forge merges into every project's (a match_* / no_match_*, `skip` or `test` this run would
#          take from it), is refused: BATTERY FAILED, naming the file and the key, never the value. Any other key it
#          changes here (a fuzz budget the project does not set, say) is named at the top and in the summary.
#          A build cache written at another path (the project copied with its out/ and cache/) is rebuilt from nothing,
#          and a line says so: forge's incremental build there left tests running the OLD code. (scripts/lib/forge-env.sh)
# Exit:    0 all steps passed, 1 something failed - a failed test fails it whatever forge's exit code (`--allow-failure`
#          in FORGE_FLAGS exits 0 over one). The summary names which, and the test line names the filter in force.
#          2 nothing run: a line break in FORGE_FLAGS, or a variable the re-run could not remove.

set -uo pipefail

# resolved BEFORE the cd below: with a relative $0 it would otherwise point at nothing, and the freshness check
# would be reported as missing
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/parse.sh
. "$HERE/lib/parse.sh" || { echo "battery: $HERE/lib/parse.sh is missing"; exit 1; }
# shellcheck source=lib/forge-env.sh
. "$HERE/lib/forge-env.sh" || { echo "battery: $HERE/lib/forge-env.sh is missing"; exit 1; }
# forge's environment by allowlist (see the header): may re-run this script, once, without what it removed
forge_env_clean battery "FOUNDRY_PROFILE FORGE_FLAGS" "$0" "$@"
# never a filter inherited from the environment (see the header): the battery runs every test the project has
if [ -n "${TEST_FLAGS+x}" ]; then echo "battery: ignoring TEST_FLAGS from the environment"; unset TEST_FLAGS; fi

PROJECT="${1:-.}"
cd "$PROJECT" || { echo "battery: cannot enter $PROJECT"; exit 1; }
if ! forge_dotenv_check battery "$(pwd -P)"; then echo "BATTERY FAILED"; exit 1; fi
# the machine's ~/.foundry/foundry.toml: what it changes here is named; a filter from it is refused (the header says why)
forge_global_config battery
if [ -n "$FORGE_GLOBAL_NARROW" ]; then
  echo "battery: $FORGE_GLOBAL_FILE narrows the tests forge runs here ($FORGE_GLOBAL_NARROW), and the battery is the whole suite."
  echo "battery: take that key out of it - it narrows every project on this machine; a filter THIS project wants goes in its own foundry.toml, where the summary names it"
  echo "BATTERY FAILED"; exit 1
fi

OUT_DIR="${OUT_DIR:-.gauntlet/reports}"
FORGE_FLAGS="${FORGE_FLAGS:-}"
mkdir -p "$OUT_DIR"

# A fuzz corpus belongs to ONE deployment layout. The v4 module runs the same suite against two managers (V4_MANAGER =
# source | fixture) whose addresses differ, and a corpus recorded against one, replayed against the other, produces a
# counterexample that is not one - measured: "the hook thinks it is in the future", red 4 times in 4. One corpus per manager.
# That PREVENTS the cross-over; it does not cure one. After a single bare `forge test` against the wrong manager the
# invented failure is persisted in cache/invariant and replays first, whatever the corpus: delete cache/invariant.
if [ -n "${V4_MANAGER:-}" ]; then
  export FOUNDRY_INVARIANT_CORPUS_DIR="corpus/invariant-$V4_MANAGER"
  echo "battery: V4_MANAGER=$V4_MANAGER, so the invariant corpus is $FOUNDRY_INVARIANT_CORPUS_DIR"
fi

rc_build=0; rc_test=0; rc_sizes=0; rc_fresh=0

echo "== build =="
# a cache written at another path is not trusted (scripts/lib/forge-env.sh, forge_cache_rehome): built from nothing
forge_cache_rehome battery; rc_rehome=$?
if [ "$rc_rehome" -eq 2 ]; then echo "BATTERY FAILED"; exit 1; fi
# shellcheck disable=SC2086
forge build $FORGE_FLAGS 2>&1 | tee "$OUT_DIR/01-build.txt"
rc_build=${PIPESTATUS[0]}

echo "== test =="
# the filter in force, for the summary: none, unless the project's own configuration (the profile the battery runs under)
# sets one - forge prints a match_* / no_match_* key only when it is set
cfg_filter="$(forge config 2> /dev/null | awk '/^\[/ { if (seen) exit; if ($0 ~ /^\[profile\./) seen = 1; next }
  seen && $1 ~ /^(no_)?match_(test|contract|path)$/ { printf "%s%s", (n++ ? ", " : ""), $0 }')"
# where it came from: the project's own foundry.toml. One that ~/.foundry/foundry.toml would have set was refused above
# (forge_global_config compares forge's configuration with and without that file)
cfg_where="the project's foundry.toml"
# the profile in force, for the summary: forge falls back to the default one, with a warning, on a name it does not have
profile_shown="${FOUNDRY_PROFILE:-default}"; [ -z "${FOUNDRY_PROFILE:-}" ] || profile_shown="$profile_shown (FOUNDRY_PROFILE)"
# (captured, then matched: `| grep -q` under pipefail can kill forge with SIGPIPE and make the check false - fuzz-long.sh)
if [ -n "${FOUNDRY_PROFILE:-}" ]; then
  profile_warn="$(forge config 2>&1 > /dev/null)"
  case "$profile_warn" in *"does not exist"*) profile_shown="$FOUNDRY_PROFILE (FOUNDRY_PROFILE) - NOT a profile of this project: forge ran the default one" ;; esac
fi
# shellcheck disable=SC2086
forge test $FORGE_FLAGS -vv 2>&1 | tee "$OUT_DIR/02-test.txt"
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
  # a failed test is never a pass, whatever forge exited with: `--allow-failure` (FORGE_FLAGS) makes it exit 0 over one
  if [ "$tests_failed" != "0" ] && [ "$rc_test" -eq 0 ]; then
    echo "battery: forge exited 0, and $tests_failed test(s) FAILED (--allow-failure?). A failed test is never a pass."
    rc_test=1
  fi
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
filter_shown="none"; [ -z "$cfg_filter" ] || filter_shown="$cfg_filter ($cfg_where)"
[ -z "$FORGE_FLAGS" ] || filter_shown="$filter_shown; FORGE_FLAGS: $(forge_flags_shown "$FORGE_FLAGS")"
echo "test      rc=$rc_test   (passed $tests_passed, failed $tests_failed, skipped $tests_skipped; filter: $filter_shown)"
echo "profile   $profile_shown${FORGE_GLOBAL_KEYS:+; and from $FORGE_GLOBAL_FILE: $FORGE_GLOBAL_KEYS}"
[ "$rc_rehome" -ne 0 ] || echo "cache     written at another path: its record removed, built from nothing"
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
