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
#          USE_BENCH  1 to run in a bench copy (default: 1)
#          OUT_DIR    where to write the log (default: <project>/.gauntlet/reports)
#          FORGE_FLAGS  extra flags for forge test (e.g. --offline)
#          ALLOW_SKIPS  1 to accept a skipped campaign;  ALLOW_SMALL_BUDGET  1 to accept a budget no larger than the default
# Exit:    forge's exit code; 2 when NOTHING WAS PROVEN (the profile does not exist, its invariant budget is not larger
#          than the everyday one, no invariant campaign ran, or one skipped itself).

set -uo pipefail

PROJECT="${1:-.}"
MATCH="${MATCH:---match-contract Invariant}"
USE_BENCH="${USE_BENCH:-1}"
FORGE_FLAGS="${FORGE_FLAGS:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"

SRC="$(cd "$PROJECT" && pwd)" || { echo "fuzz-long: cannot enter $PROJECT"; exit 1; }
OUT_DIR="${OUT_DIR:-$SRC/.gauntlet/reports}"
mkdir -p "$OUT_DIR"

RUN_IN="$SRC"
if [ "$USE_BENCH" = "1" ]; then
  # one bench per PROJECT: two long campaigns sharing a bench delete each other's files
  bench_name="fuzz-long-$(basename "$SRC")-$(printf '%s' "$SRC" | sha256sum | cut -c1-8)"
  RUN_IN="$("$HERE/bench.sh" "$bench_name" "$SRC" | tail -1)" || exit 1
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
cfg="$(forge config 2>&1)"
case "$cfg" in
  *"does not exist"*)
    echo "fuzz-long: profile '$FOUNDRY_PROFILE' does not exist in this project's foundry.toml. Add [profile.$FOUNDRY_PROFILE.invariant]"
    echo "           (runs, depth, fail_on_revert = true) or set FOUNDRY_PROFILE. NOTHING PROVEN."
    exit 2 ;;
esac

# A profile called "long" is not a long budget. `[profile.long.fuzz]` with no `[profile.long.invariant]` exists, warns
# about nothing, and runs the everyday campaign under this script's label. So the budget is READ, and compared with the
# default profile's: it has to be larger, or nothing was added to what the battery already does.
budget_of() { printf '%s\n' "$1" | awk '/^\[invariant\]/ {f = 1; next} /^\[/ {f = 0} f && $1 == "runs" {r = $3} f && $1 == "depth" {d = $3} END {print (r + 0) * (d + 0)}'; }
long_budget="$(budget_of "$cfg")"
default_budget="$(budget_of "$(env -u FOUNDRY_INVARIANT_RUNS -u FOUNDRY_INVARIANT_DEPTH FOUNDRY_PROFILE=default forge config 2>&1)")"
echo "invariant budget (runs x depth): $long_budget under '$FOUNDRY_PROFILE', $default_budget under the default profile"
if [ "$long_budget" -le "$default_budget" ] && [ "${ALLOW_SMALL_BUDGET:-0}" != "1" ]; then
  echo "fuzz-long: the budget of this run is not larger than the everyday one. Is [profile.$FOUNDRY_PROFILE.invariant] missing, or"
  echo "           did RUNS / DEPTH shrink it? NOTHING PROVEN. (ALLOW_SMALL_BUDGET=1 to replay one seed on purpose.)"
  exit 2
fi

# the campaign's census: one line per run, written by HandlerBase.writeCensus if the suite calls it, added up below
mkdir -p census
export GAUNTLET_CENSUS="${GAUNTLET_CENSUS:-census/long.tsv}"
rm -f "$GAUNTLET_CENSUS"

# shellcheck disable=SC2086
forge test $FORGE_FLAGS $MATCH $seed_flag -vv 2>&1 | tee "$OUT_DIR/05-fuzz-long.txt"
rc=${PIPESTATUS[0]}

# a campaign that ran prints "(runs: N, calls: M, reverts: R)" per invariant. No such line, or zero calls, means the
# filter matched nothing: forge exits 0 on that too.
# Whole lines, de-duplicated: forge prints a FAILING invariant twice (in its suite, and again under "Failing tests:").
lines="$(grep -E '\(runs: [0-9]+, calls: [0-9]+' "$OUT_DIR/05-fuzz-long.txt" | sort -u)"
calls="$(printf '%s\n' "$lines" | grep -oE 'calls: [0-9]+' | awk '{s+=$2} END {print s+0}')"
campaigns="$(printf '%s\n' "$lines" | grep -cE 'calls: [0-9]+')"
smallest="$(printf '%s\n' "$lines" | grep -oE 'calls: [0-9]+' | awk 'NR == 1 || $2 < m {m = $2} END {print m+0}')"
# the pre-check above reads `forge config`; some forge versions only print the fallback warning when they RUN. Check again.
if grep -q "does not exist; falling back" "$OUT_DIR/05-fuzz-long.txt"; then
  echo
  echo "fuzz-long: forge fell back to the DEFAULT profile - '$FOUNDRY_PROFILE' does not exist here. What ran was the everyday"
  echo "           budget under the label 'long'. NOTHING PROVEN."
  exit 2
fi
echo
echo "invariant campaigns: $campaigns, fuzzed calls in total: $calls"
if [ -s "$GAUNTLET_CENSUS" ]; then
  # printed and kept, never a gate here: which actions are CORE is the project's call (scripts/census.sh, CORE=...)
  CORE="" "$HERE/census.sh" --aggregate "$GAUNTLET_CENSUS" | tee "$OUT_DIR/06-census.txt"
else
  echo "no census was written: the suite does not call writeCensus() from afterInvariant(), or foundry.toml lacks the"
  echo "fs_permissions line for ./census. What this campaign REACHED is unmeasured - the log above shows one run of it."
fi
if [ "$rc" -eq 0 ] && [ "$calls" = "0" ]; then
  echo "fuzz-long: NO INVARIANT CAMPAIGN RAN (MATCH='$MATCH' matched nothing?). NOTHING PROVEN."
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
skipped="$(grep -E 'Ran [0-9]+ test suites? .*: [0-9]+ tests? passed' "$OUT_DIR/05-fuzz-long.txt" | tail -1 | sed -E 's/.* ([0-9]+) skipped.*/\1/')"
if [ "$rc" -eq 0 ] && [ "${skipped:-0}" != "0" ] && [ "${ALLOW_SKIPS:-0}" != "1" ]; then
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
