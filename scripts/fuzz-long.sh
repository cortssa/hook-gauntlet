#!/usr/bin/env bash
#
# fuzz-long.sh - the same invariants, for much longer, in a bench of their own.
#
# The problem it solves, twice over:
#
#  * The suite you run on every edit has to be fast, so its fuzz budget is small, and a small budget finds
#    the shallow counterexamples only. The deep ones need a run nobody wants to wait for. Making that run a
#    separate command, with its own profile, is what stops the everyday battery from being quietly widened
#    until nobody runs it either.
#  * A long run holds the build directory for a long time. Put it in its own bench and the rest of the work
#    carries on next to it.
#
# When it fails, WRITE DOWN THE SEED it prints. A counterexample you cannot reproduce is a rumour.
#
# Usage:   scripts/fuzz-long.sh [project-dir]
# Env:     MATCH      forge filter (default: --match-contract Invariant)
#          RUNS       override FOUNDRY_INVARIANT_RUNS
#          DEPTH      override FOUNDRY_INVARIANT_DEPTH
#          SEED       replay a specific seed
#          USE_BENCH  1 to run in a bench copy (default: 1). A project whose foundry.toml or remappings.txt reach
#                     outside it (`../src`, as the v4 module does) is benched from the parent they reach - one or two
#                     levels up - and run at its own place inside that bench; deeper than two levels is refused.
#                     The bench keeps the campaign's corpus/ and census/ from one run to the next (bench.sh BENCH_KEEP):
#                     a refresh never deletes them, and a corpus/ the project has is merged in. census/long.tsv is THIS run's
#                     census and starts empty; another run's census under another name (GAUNTLET_CENSUS) stays.
#                     When the campaign PASSED and wrote one, its absolute path is printed alone on a line,
#                     `census: <path>`: the file the gate reads (scripts/census.sh --aggregate <path>). A FAILED campaign has
#                     no census (forge writes a line per shrink replay): the file is renamed <name>.FAILED.tsv, named, and
#                     the gate refuses it.
#          OUT_DIR    where to write the log (default: <project>/.gauntlet/reports)
#          FORGE_FLAGS  extra flags for forge test (e.g. --offline)
#          ALLOW_SKIPS  1 to accept a skipped campaign;  ALLOW_SMALL_BUDGET  1 to accept a budget no larger than the default
# Exit:    forge's exit code; 2 when NOTHING WAS PROVEN (the profile does not exist, its invariant budget is not larger
#          than the everyday one, no invariant campaign ran - including a build or a setUp that failed before any could,
#          which is never reported as a counterexample - or one skipped itself, or the bench cannot hold the project).

set -uo pipefail

PROJECT="${1:-.}"
MATCH="${MATCH:---match-contract Invariant}"
USE_BENCH="${USE_BENCH:-1}"
FORGE_FLAGS="${FORGE_FLAGS:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/parse.sh
. "$HERE/lib/parse.sh" || { echo "fuzz-long: $HERE/lib/parse.sh is missing"; exit 2; }

SRC="$(cd "$PROJECT" && pwd)" || { echo "fuzz-long: cannot enter $PROJECT"; exit 1; }
OUT_DIR="${OUT_DIR:-$SRC/.gauntlet/reports}"
mkdir -p "$OUT_DIR"

RUN_IN="$SRC"
if [ "$USE_BENCH" = "1" ]; then
  # A project that imports from outside itself (`gauntlet-kit/=../src/`, `allow_paths = ["../src"]`) cannot compile in a
  # bench of itself alone: the bench has no parent to resolve `..` against. So the bench is made of the ancestor its
  # configuration reaches, and the campaign runs at the project's own place inside it. Found by a fresh reader: on the
  # v4 module this used to fail to compile, and the compile error was then reported as a counterexample.
  ups="$(cat "$SRC/foundry.toml" "$SRC/remappings.txt" 2> /dev/null | grep -v '^[[:space:]]*#' | grep -oE '(\.\./)+|\.\.["/]?$' \
    | awk '{ n = gsub(/\.\./, ""); if (n > m) m = n } END { print m + 0 }')"
  if [ "$ups" -gt 2 ]; then
    echo "fuzz-long: $SRC reaches $ups directories up (../ in foundry.toml or remappings.txt); a bench that deep is refused. Run with USE_BENCH=0, or bench it yourself (scripts/bench.sh). NOTHING PROVEN."
    exit 2
  fi
  BENCH_FROM="$SRC"; REL_IN=""
  for _ in $(seq 1 "$ups"); do REL_IN="$(basename "$BENCH_FROM")${REL_IN:+/$REL_IN}"; BENCH_FROM="$(dirname "$BENCH_FROM")"; done
  # one bench per PROJECT: two long campaigns sharing a bench delete each other's files
  bench_name="fuzz-long-$(basename "$SRC")-$(printf '%s' "$SRC" | sha256sum | cut -c1-8)"
  # the campaign's corpus/ and census/ live in the BENCH and must survive its refresh: without BENCH_KEEP the refresh's
  # `rsync --delete` removed both (the project has neither), and every long run with a bench started from an empty corpus.
  # A corpus the project has of its own is merged in, never replacing the bench's.
  keep="${REL_IN:+$REL_IN/}corpus ${REL_IN:+$REL_IN/}census"
  cdir="${FOUNDRY_INVARIANT_CORPUS_DIR:-}"; cdir="${cdir#./}"   # a corpus directory set elsewhere, relative, is kept too
  case "/$cdir/" in //* | */../* | */./* | /corpus/*) ;; *) keep="$keep ${REL_IN:+$REL_IN/}$cdir" ;; esac
  bench_out="$(BENCH_KEEP="${BENCH_KEEP:+$BENCH_KEEP }$keep" "$HERE/bench.sh" "$bench_name" "$BENCH_FROM")" || { printf '%s\n' "$bench_out" | tail -3; echo "fuzz-long: the bench could not be made. NOTHING PROVEN."; exit 2; }
  RUN_IN="$(printf '%s\n' "$bench_out" | tail -1)${REL_IN:+/$REL_IN}"
  [ -n "$REL_IN" ] && echo "fuzz-long: the project reaches $ups level(s) up, so the bench is of $BENCH_FROM and the campaign runs in <bench>/$REL_IN"
fi

export FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-long}"
[ -n "${RUNS:-}" ] && export FOUNDRY_INVARIANT_RUNS="$RUNS"
[ -n "${DEPTH:-}" ] && export FOUNDRY_INVARIANT_DEPTH="$DEPTH"

# one corpus per manager, for the reason given in battery.sh: a corpus recorded against one deployment layout, replayed
# against another, invents counterexamples
if [ -n "${V4_MANAGER:-}" ] && [ -z "${FOUNDRY_INVARIANT_CORPUS_DIR:-}" ]; then
  export FOUNDRY_INVARIANT_CORPUS_DIR="corpus/invariant-$V4_MANAGER"
fi

seed_flag=""
[ -n "${SEED:-}" ] && seed_flag="--fuzz-seed $SEED"

echo "profile=$FOUNDRY_PROFILE runs=${RUNS:-from profile} depth=${DEPTH:-from profile} in $RUN_IN"
cd "$RUN_IN" || exit 1

# forge falls back to the DEFAULT profile, with a warning, when the named one does not exist - and the default budget
# under the label "long" is worse than no run. Check before spending the time.
# The output is CAPTURED and then matched, never piped into `grep -q`: under `pipefail` grep closes the pipe at the first
# hit, forge dies of SIGPIPE, the pipeline is "false" and the check it guards never fires. It was written that way once.
# The everyday budget is read FIRST, because both refusals below print it, with a block to paste computed from it. A
# project on forge's defaults (no [invariant] section) runs 256 x 500 = 128 000 calls on every edit - as many as the
# kit's own `long` profile (1000 x 128) - and a refusal that only said "not larger" left a fresh reader to guess.
inv_of() { # inv_of <forge config output> <runs|depth>: that key of its [invariant] section, 0 when absent
  printf '%s\n' "$1" | awk -v key="$2" '/^\[invariant\]/ {f = 1; next} /^\[/ {f = 0} f && $1 == key {v = $3} END {print v + 0}'
}
default_cfg="$(env -u FOUNDRY_INVARIANT_RUNS -u FOUNDRY_INVARIANT_DEPTH FOUNDRY_PROFILE=default forge config 2>&1)"
default_runs="$(inv_of "$default_cfg" runs)"; default_depth="$(inv_of "$default_cfg" depth)"
default_budget=$((default_runs * default_depth))
suggest_block() { # the rule, the everyday budget, and a profile to paste: 4 x the everyday runs (at least 1000), the everyday depth
  local r=$((default_runs * 4))
  [ "$r" -lt 1000 ] && r=1000
  echo "           The rule: the long budget (runs x depth) must be LARGER than YOUR everyday one, which here is"
  echo "           $default_runs x $default_depth = $default_budget calls (the default profile's [invariant]; forge's own defaults are 256 x 500)."
  echo "           Put this in foundry.toml, in place of any [profile.$FOUNDRY_PROFILE.invariant] it has ($r x $default_depth = $((r * default_depth)) calls):"
  echo
  echo "[profile.$FOUNDRY_PROFILE.invariant]"
  echo "runs = $r"
  echo "depth = $default_depth"
  echo "fail_on_revert = true"
  echo "corpus_dir = \"corpus/long\""
  echo
}
cfg="$(forge config 2>&1)"
case "$cfg" in
  *"does not exist"*)
    echo "fuzz-long: profile '$FOUNDRY_PROFILE' does not exist in this project's foundry.toml. NOTHING PROVEN."
    suggest_block
    echo "           (Or set FOUNDRY_PROFILE to a profile you have.)"
    exit 2 ;;
esac

# A profile called "long" is not a long budget. `[profile.long.fuzz]` with no `[profile.long.invariant]` exists, warns
# about nothing, and runs the everyday campaign under this script's label. So the budget is READ, and compared with the
# default profile's: it has to be larger, or nothing was added to what the battery already does.
long_runs="$(inv_of "$cfg" runs)"; long_depth="$(inv_of "$cfg" depth)"
long_budget=$((long_runs * long_depth))
echo "invariant budget (runs x depth): $long_budget under '$FOUNDRY_PROFILE', $default_budget under the default profile"
if [ "$long_budget" -le "$default_budget" ] && [ "${ALLOW_SMALL_BUDGET:-0}" != "1" ]; then
  echo "fuzz-long: the budget of this run, $long_runs x $long_depth = $long_budget, is not larger than the everyday one. NOTHING PROVEN."
  suggest_block
  echo "           (RUNS / DEPTH, when set, override the profile: unset them. ALLOW_SMALL_BUDGET=1 to replay one seed on purpose.)"
  exit 2
fi

# the campaign's census: one line per run, written by HandlerBase.writeCensus if the suite calls it, added up below
mkdir -p census
export GAUNTLET_CENSUS="${GAUNTLET_CENSUS:-census/long.tsv}"
rm -f "$GAUNTLET_CENSUS"

# shellcheck disable=SC2086
forge test $FORGE_FLAGS $MATCH $seed_flag -vv 2>&1 | tee "$OUT_DIR/05-fuzz-long.txt"
rc=${PIPESTATUS[0]}

# a campaign that ran prints "(runs: N, calls: M, reverts: R)" per campaign (scripts/lib/parse.sh names the three shapes
# forge 1.8.1 prints it in). No such line, or zero calls, means the filter matched nothing: forge exits 0 on that too.
# Only a result line counts - a test that PRINTS such a text in its logs is not a campaign.
read -r campaigns calls smallest <<< "$(parse_invariant_runs "$OUT_DIR/05-fuzz-long.txt")"
# the pre-check above reads `forge config`; some forge versions only print the fallback warning when they RUN. Check again.
if grep -q "does not exist; falling back" "$OUT_DIR/05-fuzz-long.txt"; then
  echo
  echo "fuzz-long: forge fell back to the DEFAULT profile - '$FOUNDRY_PROFILE' does not exist here. What ran was the everyday"
  echo "           budget under the label 'long'. NOTHING PROVEN."
  exit 2
fi
echo
echo "invariant campaigns: $campaigns, fuzzed calls in total: $calls"
if [ "$rc" -ne 0 ] && [ -s "$GAUNTLET_CENSUS" ]; then
  # A FAILED campaign has NO census: forge calls afterInvariant() on every replay it makes while it shrinks a counterexample,
  # and each writes a line. Measured on a stranger's v4 hook: 199 510 "runs" and 59 778 "unexplained" for 272 real runs;
  # reproduced, 198 991 lines for 53. The table of that file used to be printed here, and its path offered to the gate.
  failed_census="${GAUNTLET_CENSUS%.tsv}.FAILED.tsv"
  mv -f "$GAUNTLET_CENSUS" "$failed_census"
  case "$failed_census" in /*) failed_abs="$failed_census" ;; *) failed_abs="$(pwd -P)/${failed_census#./}" ;; esac
  echo "fuzz-long: the campaign FAILED, so it has NO census. forge calls afterInvariant() on every replay it makes while it"
  echo "           shrinks a counterexample, and each one wrote a line: $(awk 'END { print NR }' "$failed_census") lines, not one per run."
  echo "           Kept for reading as $failed_abs - the gate (census.sh --aggregate) refuses it."
  echo "           Fix the failure, run again, and gate THAT campaign's census."
  echo "fuzz-long: the campaign FAILED - no census (renamed $failed_abs)" > "$OUT_DIR/06-census-long.txt"
elif [ -s "$GAUNTLET_CENSUS" ]; then
  # printed and kept, never a gate here: which actions are CORE is the project's call (scripts/census.sh, CORE=...).
  # CENSUS_TABLE_ONLY: the table without a gate verdict, which here would be "PASSED" over nothing judged. The log names
  # the suites that ran, whose persisted failures replayed first and wrote lines too (census.sh says how many)
  CORE="" CENSUS_TABLE_ONLY=1 CENSUS_FORGE_LOG="$OUT_DIR/05-fuzz-long.txt" "$HERE/census.sh" --aggregate "$GAUNTLET_CENSUS" | tee "$OUT_DIR/06-census-long.txt"
  # the path the gate reads, absolute and alone on its line (QUICKSTART: "the path fuzz-long.sh printed"). It is in the
  # bench when there is one, and it used to be named nowhere: a fresh reader had to find the bench directory and guess.
  case "$GAUNTLET_CENSUS" in /*) census_abs="$GAUNTLET_CENSUS" ;; *) census_abs="$(pwd -P)/${GAUNTLET_CENSUS#./}" ;; esac
  echo "census: $census_abs"
else
  echo "no census was written: the suite does not call writeCensus() from afterInvariant(), or foundry.toml lacks the"
  echo "fs_permissions line for ./census. What this campaign REACHED is unmeasured - the log above shows one run of it."
fi
if [ "$rc" -eq 0 ] && [ "$calls" = "0" ]; then
  echo "fuzz-long: NO INVARIANT CAMPAIGN RAN (MATCH='$MATCH' matched nothing?). NOTHING PROVEN."
  exit 2
fi
# forge failed AND no campaign ran: the build or a setUp died before any sequence was tried. That is not a
# counterexample, it is nothing - and it used to be printed as "LONG FUZZ FAILED. The counterexample and the seed are in".
if [ "$rc" -ne 0 ] && [ "$campaigns" = "0" ]; then
  echo "fuzz-long: forge exited $rc and NO invariant campaign ran: the build, a setUp, or a test that is not a campaign failed"
  echo "           first. NOTHING PROVEN about a long fuzz."
  echo "           first error: $(first_error_line "$OUT_DIR/05-fuzz-long.txt" || echo "(none recognised - read $OUT_DIR/05-fuzz-long.txt)")"
  exit 2
fi
# The budget was READ from the profile; this is what RAN. A test with its own inline configuration
# (`/// forge-config: long.invariant.runs = 1`) runs another number under the profile's label, and forge says nothing.
if [ "$rc" -eq 0 ] && [ "$smallest" -lt "$long_budget" ] && [ "${ALLOW_SMALL_BUDGET:-0}" != "1" ]; then
  echo "fuzz-long: a campaign RAN $smallest calls, and the budget of '$FOUNDRY_PROFILE' is $long_budget. An inline forge-config on"
  echo "           that test? NOTHING PROVEN for it. (ALLOW_SMALL_BUDGET=1 to accept.)"
  exit 2
fi
# the same rule as battery.sh: a campaign that SKIPPED itself (a fixture that is not there?) next to one that ran is not a pass
# "0" only from a summary that was READ: a line of another shape is refused below, never taken as no skips
if skip_summary="$(parse_test_summary "$OUT_DIR/05-fuzz-long.txt")"; then read -r _ _ skipped _ <<< "$skip_summary"; else skipped="unreadable"; fi
if [ "$rc" -eq 0 ] && [ "$skipped" = "unreadable" ]; then
  echo "fuzz-long: forge's test summary is missing or of a shape this kit cannot read, so the skips are unknown. NOTHING PROVEN."
  exit 2
fi
if [ "$rc" -eq 0 ] && [ "$skipped" != "0" ] && [ "${ALLOW_SKIPS:-0}" != "1" ]; then
  echo "fuzz-long: $skipped test(s) SKIPPED. A skipped campaign has tested nothing. NOTHING PROVEN for it. ALLOW_SKIPS=1 to accept."
  exit 2
fi
if [ "$rc" -ne 0 ]; then
  echo "LONG FUZZ FAILED. The counterexample and the seed are in $OUT_DIR/05-fuzz-long.txt."
  echo "Record the seed in the run log before you change anything, then replay it with SEED=<seed>."
else
  if [ "${ALLOW_SMALL_BUDGET:-0}" = "1" ] && { [ "$long_budget" -le "$default_budget" ] || [ "$smallest" -lt "$long_budget" ]; }; then
    echo "passed ON A BUDGET NO LARGER THAN THE EVERYDAY ONE (ALLOW_SMALL_BUDGET=1): a replay, not a long fuzz. Log: $OUT_DIR/05-fuzz-long.txt"
  else
    echo "long fuzz passed. Log: $OUT_DIR/05-fuzz-long.txt"
  fi
fi
exit "$rc"
