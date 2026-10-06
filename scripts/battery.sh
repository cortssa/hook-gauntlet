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
# Env:     OUT_DIR      where to write the logs   (default: <project>/.gauntlet/reports; a relative one is under <project>).
#                       Inside a project with no .gauntlet/ (someone else's tree, doctrine/RETROFIT.md) it refuses before
#                       running or writing anything, exit 2 - unless it is a bench or the kit's own (scripts/lib/owner-tree.sh)
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
#          and a line says so: forge's incremental build there left tests running the OLD code. So is one whose sources
#          changed where forge's incremental build does not follow them (a file outside src/ - the root kit under the v4
#          module, a remapped or linked directory, lib/ - or src/ reached through a symlink or a remapping), and one with
#          no record of what its last build read: the kit records that after each build it trusts. (scripts/lib/forge-env.sh)
# Before anything runs (v0.4.2), two checks of the project's own records:
#   - src/ is the owner's: with a record of its anchor, <project>/.gauntlet/src.sha256 (scripts/init-state.sh;
#     scripts/lib/src-anchor.sh), the battery says on every run whether src/ is as recorded, and refuses - exit 2, nothing
#     run - when it differs or is gone, with the spec's refusal for src/ (no escape, no command an agent could run). No
#     record: one line says how one is made (a project of the route), or that the tree is not anchored; the run goes on.
#   - an assignment to `_skipPermissionCheck` in a file under test/ (any: `= true`, `= !false`, a constant, `= false` -
#     in its code, a `//` comment's text aside; `==` is not one) runs the hook as the manager drives it, the callback whose
#     bit is missing never called - allowed only while that permission-bits finding is OPEN AND RECORDED: the file has a
#     header line `// _skipPermissionCheck: <id> open`, and pending/<id>.t.sol has a current red record
#     (scripts/pending-red.sh) whose failures include the v4 harness's permission-bits line (its `permission-bits:` line:
#     a test that holds the hook to the check, doctrine/EVIDENCE.md section 2). Such a record is current while src/ and
#     pending/<id>.t.sol are as recorded - the flag put into test/ after it, or any edit there, does not stale it
#     (scripts/lib/pending-record.sh). Otherwise refused, saying why (no record; or which part of its key changed since)
#     and naming scripts/pending-red.sh with the finding's own file: exit 2, nothing run. With it, the summary's `bits`
#     line and the last line say `green UNDER open permission-bits finding <id>`. Not checked - and said, `bits not
#     checked: <why>`, on a line before the run and in the summary - only where there are no records to hold it against
#     (scripts/lib/owner-tree.sh, bits_rule_skipped): the kit's own worked examples (its hostile hooks are mis-flagged on
#     purpose), a tree with no .gauntlet/ (a bench), a bench whose .gauntlet/ holds only reports/. A `.gauntlet-bench`
#     marker beside a .gauntlet/ with records in it skips nothing.
# Exit:    0 all steps passed, 1 something failed - a failed test fails it whatever forge's exit code (`--allow-failure`
#          in FORGE_FLAGS exits 0 over one). The summary names which, and the test line names the filter in force.
#          2 nothing run: a line break in FORGE_FLAGS, or a variable the re-run could not remove, or OUT_DIR refused, or src/
#          not as its anchor records it, or `_skipPermissionCheck` assigned under test/ with no current recorded
#          permission-bits finding (above).

set -uo pipefail

# resolved BEFORE the cd below: with a relative $0 it would otherwise point at nothing, and the freshness check
# would be reported as missing
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/parse.sh
. "$HERE/lib/parse.sh" || { echo "battery: $HERE/lib/parse.sh is missing"; exit 1; }
# shellcheck source=lib/forge-env.sh
. "$HERE/lib/forge-env.sh" || { echo "battery: $HERE/lib/forge-env.sh is missing"; exit 1; }
# shellcheck source=lib/owner-tree.sh
. "$HERE/lib/owner-tree.sh" || { echo "battery: $HERE/lib/owner-tree.sh is missing"; exit 1; }
# shellcheck source=lib/pending-record.sh
. "$HERE/lib/pending-record.sh" || { echo "battery: $HERE/lib/pending-record.sh is missing"; exit 1; }
# shellcheck source=lib/src-anchor.sh
. "$HERE/lib/src-anchor.sh" || { echo "battery: $HERE/lib/src-anchor.sh is missing"; exit 1; }
# forge's environment by allowlist (see the header): may re-run this script, once, without what it removed
forge_env_clean battery "FOUNDRY_PROFILE FORGE_FLAGS" "$0" "$@"
# never a filter inherited from the environment (see the header): the battery runs every test the project has
if [ -n "${TEST_FLAGS+x}" ]; then echo "battery: ignoring TEST_FLAGS from the environment"; unset TEST_FLAGS; fi

PROJECT="${1:-.}"
cd "$PROJECT" || { echo "battery: cannot enter $PROJECT"; exit 1; }
OUT_DIR="${OUT_DIR:-.gauntlet/reports}"
# never into a tree without the kit's convention (V26b: the battery made <proj>/.gauntlet/reports in one): refused before
# anything runs or is written - forge's own out/ and cache/ included (scripts/lib/owner-tree.sh)
report_dir_allowed battery "$(pwd -P)" "$OUT_DIR" || { echo "battery: nothing run."; exit 2; }
if ! forge_dotenv_check battery "$(pwd -P)"; then echo "BATTERY FAILED"; exit 1; fi
# the machine's ~/.foundry/foundry.toml: what it changes here is named; a filter from it is refused (the header says why)
forge_global_config battery
if [ -n "$FORGE_GLOBAL_NARROW" ]; then
  echo "battery: $FORGE_GLOBAL_FILE narrows the tests forge runs here ($FORGE_GLOBAL_NARROW), and the battery is the whole suite."
  echo "battery: take that key out of it - it narrows every project on this machine; a filter THIS project wants goes in its own foundry.toml, where the summary names it"
  echo "BATTERY FAILED"; exit 1
fi

# ------------------------------------------------------------------ the project's own records, before anything runs (v0.4.2)
PROJ_REAL="$(pwd -P)"
# src/ against its anchor: said on every run; changed or gone, refused (the header)
src_anchor_check battery "$PROJ_REAL"; sa_rc=$?
[ -z "$SRC_ANCHOR_LINE" ] || echo "$SRC_ANCHOR_LINE"
[ "$sa_rc" -eq 0 ] || { echo "battery: nothing run."; exit 2; }
# _skipPermissionCheck under test/: only while its permission-bits finding is open AND recorded (the header)
bits_refuse() { # bits_refuse <why> [<the finding's pending file>] [<its id>]: the refusal, naming the real file when known
  local pf="${2:-pending/<id>.t.sol}" id="${3:-<id>}"
  echo "battery: REFUSED - $1. A suite under test/ may assign _skipPermissionCheck only while that permission-bits finding is OPEN AND RECORDED, in this order: its own test, $pf, sets _skipPermissionCheck = true in its setUp, then a test function of its own calls _checkHookPermissions(address(hook)); directly (V4Harness: function _checkHookPermissions(address hook) internal), with no vm.expectRevert, so the harness's revert fails that test - $HERE/pending-red.sh $PROJ_REAL $pf records that red; then the suites carry the flag and a header line '// _skipPermissionCheck: $id open'; then this battery (doctrine/EVIDENCE.md section 2). That record stays current while src/ and $pf are as recorded. Without it the flag hides the finding from the everyday suite."
  echo "battery: nothing run."
  exit 2
}
BITS_UNDER="" BITS_FILES="" BITS_HOW="" BITS_SKIP=""
if [ -d test ] && bits_rule_skipped "$PROJ_REAL"; then
  BITS_SKIP="$BITS_SKIP_WHY"
  echo "battery: bits not checked: $BITS_SKIP"
elif [ -d test ]; then
  while IFS= read -r -d '' bf; do
    bf="${bf#./}"
    # ANY assignment to the flag in the code (`= true`, `= !false`, a constant, `= false`): what follows `//` on a line is
    # a comment; `==` is a comparison, not an assignment
    bset="$(sed -e 's#//.*$##' "$bf" | grep -m 1 -oE '_skipPermissionCheck[[:space:]]*=([^=][^;]*|$)' | head -1 | sed -E 's/[[:space:]]+$//; s/[[:space:]]+/ /g')"
    [ -n "$bset" ] || continue
    bid="$(LC_ALL=C sed -nE 's#^[[:space:]]*//+[[:space:]]*_skipPermissionCheck:[[:space:]]*([A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?).*#\1#p' "$bf" | head -1)"
    [ -n "$bid" ] || bits_refuse "$bf sets $bset and names no permission-bits finding (no line '// _skipPermissionCheck: <id> open' in it)"
    # its test in pending/: the file whose id (its name without .t.sol or .sol, as next.sh reads it) is that id
    bpf=""
    while IFS= read -r c; do
      b="${c##*/}"; b="${b%.sol}"; b="${b%.t}"; while [ "${b#.}" != "$b" ]; do b="${b#.}"; done
      if [ "${b,,}" = "${bid,,}" ]; then bpf="$c"; break; fi
    done < <(pending_files "$PROJ_REAL")
    [ -n "$bpf" ] || bits_refuse "$bf sets $bset under $bid, and there is no pending/$bid.t.sol" "pending/$bid.t.sol" "$bid"
    # its record: the full key, or a permission-bits record's own (src/ and that file as recorded: scripts/lib/pending-record.sh)
    pending_record_current "$PROJ_REAL" "$bpf" \
      || bits_refuse "$bf sets $bset under $bid, and $bpf has no current red record: $PR_WHY" "$bpf" "$bid"
    grep -q '^permission-bits: ' "$PR_REC" \
      || bits_refuse "$bf sets $bset under $bid, and the red record of $bpf has no permission-bits failure: its tests are red, but none of them on the harness's own line" "$bpf" "$bid"
    case " $BITS_UNDER " in *" $bid "*) ;; *)
      BITS_UNDER="${BITS_UNDER:+$BITS_UNDER }$bid"
      if [ "$PR_HOW" = bits ]; then BITS_HOW="${BITS_HOW:+$BITS_HOW; }$bid's record current on src/ and $bpf as recorded - a permission-bits record's key; other files of the full key changed since"
      else BITS_HOW="${BITS_HOW:+$BITS_HOW; }$bid's record current on the full key"; fi ;;
    esac
    BITS_FILES="${BITS_FILES:+$BITS_FILES, }$bf"
  done < <(find -L test -name '*.sol' -type f -print0 2> /dev/null | LC_ALL=C sort -z)
fi
BITS_UNDER="${BITS_UNDER// /, }"
[ -z "$BITS_UNDER" ] || echo "battery: $BITS_FILES set _skipPermissionCheck UNDER open permission-bits finding $BITS_UNDER (recorded red on the harness's line; $BITS_HOW)"

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
# a cache written at another path, or a source changed that forge's incremental build does not follow, or no record of
# what the last build read: not trusted (scripts/lib/forge-env.sh, forge_cache_rehome) - built from nothing
forge_cache_rehome battery; rc_rehome=$?
if [ "$rc_rehome" -eq 2 ]; then echo "BATTERY FAILED"; exit 1; fi
# what the build is about to read, as it is now: recorded after a build that succeeds (forge_sources_record)
sources_pre="$(forge_sources_snapshot)"
# shellcheck disable=SC2086
forge build $FORGE_FLAGS 2>&1 | tee "$OUT_DIR/01-build.txt"
rc_build=${PIPESTATUS[0]}
[ "$rc_build" -ne 0 ] || forge_sources_record "" "$sources_pre"

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
[ "$rc_rehome" -ne 0 ] || echo "cache     $FORGE_REHOME_WHY: its record removed, built from nothing"
# by NAME, per test directory, so a log shows which parts of the suite ran (e.g. the v4 sandbox's test/sim)
echo "suites    $(parse_suites_by_dir "$OUT_DIR/02-test.txt")"
echo "src       $SRC_ANCHOR_SHORT"
[ -z "$BITS_UNDER" ] || echo "bits      UNDER open permission-bits finding $BITS_UNDER: _skipPermissionCheck set in $BITS_FILES (each finding's test red on the harness's own line, .gauntlet/pending-red/)"
[ -z "$BITS_SKIP" ] || echo "bits      not checked: $BITS_SKIP"
echo "sizes     rc=$rc_sizes"
echo "freshness rc=$rc_fresh   (0: forge had nothing left to compile; 1: it had - what was measured was stale, now rebuilt; 2: not decided)"
echo "logs in   $OUT_DIR"

if [ "$rc_build" -ne 0 ] || [ "$rc_test" -ne 0 ] || [ "$rc_sizes" -ne 0 ] || [ "$rc_fresh" -ne 0 ]; then
  echo "BATTERY FAILED"
  exit 1
fi
echo "BATTERY PASSED${BITS_UNDER:+ - green UNDER open permission-bits finding $BITS_UNDER}"
