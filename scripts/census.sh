#!/usr/bin/env bash
#
# census.sh - what did the fuzz campaign actually DO, added up over every run?
#
# The problem it solves: a stateful campaign is 64 runs (or 1000), and forge prints the logs of ONE of them. The
# block of numbers on the screen after `forge test -vv` describes some 64 calls out of 4 096, and it has been seen to
# say "withdrawsOk 0" over a campaign with more than a hundred successful withdrawals - and the opposite mistake is
# just as available. A gate that says "every core action succeeded in the campaign" cannot be answered from that block.
#
# So the handler writes one line per run (HandlerBase.writeCensus, called from afterInvariant), and this script adds
# them up. The question it answers, per action: IN HOW MANY RUNS did it succeed at least once? A run in which the
# action that matters never succeeded tested an empty contract, however green it was.
#
# Usage:   scripts/census.sh [project-dir]          run the invariant campaigns, then print the census - a smoke check of
#                                                   the everyday campaign; the report is <OUT_DIR>/06-census.txt
#          scripts/census.sh --aggregate <file> [project-dir]
#                                                   THE GATE: judge a census file that already exists (the long campaign's
#                                                   <bench>/census/long.tsv, the path fuzz-long.sh prints). It writes the
#                                                   table and the verdict to <OUT_DIR>/06-census-gate.txt, says where, and
#                                                   prints the verdict as its LAST line: "census gate: PASSED - ..." or
#                                                   "census gate: FAILED - <what>". OUT_DIR is resolved as in run mode, against
#                                                   the project given - or, with none, the directory it runs from (which is not
#                                                   the bench the file is in: the line that says where it wrote says so too)
# Env:     MATCH        forge filter                 (default: --match-contract Invariant)
#          FORGE_FLAGS  extra flags for forge test   (e.g. --offline)
#          CORE         action names, space separated, that MUST have succeeded in at least MIN_PCT per cent of the runs
#          REACH        boundary names, SEMICOLON separated (they contain spaces), that MUST have been reached in at least
#                       MIN_PCT per cent of the runs - e.g. REACH="fee at the cap". The boundary a hook's main promise is
#                       about can vanish from a campaign without any action failing; this is the gate that notices.
#                       Both are judged PER SUITE (per label): a name that is dead in one suite is not rescued by the same
#                       name in another. A suite that does not have the name at all is not judged on it.
#          MIN_PCT      the floor for CORE and REACH, a whole number from 1 to 100  (default: 25). The floor is a decision of the PROJECT, written in its
#                       spec: it says how much of the campaign you are willing to see wasted on runs that never did the
#                       thing. The default is deliberately low because a campaign's reach is a sample - the kit's own vault
#                       example measured between 42 and 80 per cent on sixteen campaigns of the same tree - and a gate that
#                       sits inside the noise is a gate that fails by luck. Set yours below your measured range, not in it.
#          OUT_DIR      where the report goes        (default: <project>/.gauntlet/reports; a relative one is under <project>)
#          CENSUS_TABLE_ONLY  1: --aggregate prints the table and nothing else - no gate record, no verdict line. For a
#                       caller that judges nothing (fuzz-long.sh prints the long campaign's table with no CORE, and a
#                       "PASSED - 0 CORE actions" under it would read as a gate that was never run).
#          CENSUS_FORGE_LOG  --aggregate: forge's log of the campaign, when there is one (fuzz-long.sh passes it). Only the
#                       persisted failures of suites named in it are counted in the `runs:` line below.
# Counts:  a run writes one line, and forge adds lines that are not runs. A GREEN campaign of N runs has N + 1 lines plus one
#          per persisted failure of a suite that ran (forge replays them first; foundry-kit/README.md, the census): when
#          <failure_persist_dir>/failures holds any, a line under the table says how many - `runs: <n> (cache/invariant/failures
#          holds <k> persisted failures of <suites>: they replay first and count)`. A FAILED campaign has NO census: forge
#          writes a line per shrink replay (199 510 lines for 272 runs, measured). Run mode renames its file runs.FAILED.tsv
#          and prints no table; fuzz-long.sh renames long.tsv long.FAILED.tsv; --aggregate refuses any *.FAILED.tsv in one
#          line, exit 2.
# Exit:    0 printed (and every CORE / REACH name met the floor); 1 a name is below the floor or in no suite at all, or a
#          run met an unexplained revert; 2 NOTHING MEASURED - no census line was written (the suite does not call
#          writeCensus from afterInvariant, or foundry.toml lacks fs_permissions for ./census), or MIN_PCT is not a
#          number from 1 to 100; otherwise forge's exit code when the campaign itself failed.
#          The gate (--aggregate) exits the same way (0, 1 or 2); its last line says which, and why.

set -uo pipefail

MIN_PCT="${MIN_PCT:-25}"
# a floor that is not a number counts as 0 inside awk, and a floor of 0 passes an action that never worked once
# (refused below, once the mode is known: the gate records the refusal as its verdict)
floor_error=""
case "$MIN_PCT" in
  '' | *[!0-9]*) floor_error="MIN_PCT must be a whole number from 1 to 100 (got '$MIN_PCT')." ;;
  *) if [ "$MIN_PCT" -lt 1 ] || [ "$MIN_PCT" -gt 100 ]; then floor_error="MIN_PCT must be from 1 to 100 (got $MIN_PCT)."; fi ;;
esac

aggregate() { # aggregate <file>
  [ -s "$1" ] || return 2
  CORE="${CORE:-}" REACH="${REACH:-}" MIN_PCT="$MIN_PCT" GATE_WHY="${GATE_WHY:-}" awk -F '\t' -v sq="'" -v unrestricted="handler unrestricted: bookkeeping selectors were fuzzed" '
    # the gate verdict: every reason it failed, one per line, into the file GATE_WHY names (the gate joins them)
    function why(s) { if (ENVIRON["GATE_WHY"] != "") print s > (ENVIRON["GATE_WHY"]) }
    {
      sub(/\r$/, "")
      label = $1
      if (!(label in runs)) labels[++nl] = label
      runs[label]++
      for (i = 2; i <= NF; i++) {
        f = $i
        if (f ~ /^U=/) { if (substr(f, 3) + 0 > 0) surprised[label]++ }
        else if (f ~ /^A:/ && match(f, /=[0-9]+\/[0-9]+$/)) {
          name = substr(f, 3, RSTART - 3); split(substr(f, RSTART + 1), p, "/")
          k = label SUBSEP name
          if (!(k in aCalls)) { aOrder[label, ++aN[label]] = name }
          aCalls[k] += p[1]; aSucc[k] += p[2]; if (p[2] + 0 > 0) aRunsOk[k]++
        }
        else if (f ~ /^B:/ && match(f, /=[0-9]+$/)) {
          name = substr(f, 3, RSTART - 3)
          k = label SUBSEP name
          if (!(k in bTotal)) { bOrder[label, ++bN[label]] = name }
          bTotal[k] += substr(f, RSTART + 1); bRuns[k]++
        }
        else ignored++
      }
    }
    END {
      bad = 0
      for (li = 1; li <= nl; li++) {
        label = labels[li]; n = runs[label]
        printf "== campaign census: %s - %d runs ==\n", label, n
        printf "runs in which the handler met an UNEXPLAINED revert: %d\n", surprised[label] + 0
        if (surprised[label] + 0 > 0) { bad = 1; why(sprintf("%d run(s) of %s met an UNEXPLAINED revert", surprised[label], label)) }
        printf "%-28s %10s %10s %18s %18s\n", "action", "calls", "successes", "runs with >= 1 ok", "runs with ZERO ok"
        for (j = 1; j <= aN[label]; j++) {
          name = aOrder[label, j]; k = label SUBSEP name
          printf "%-28s %10d %10d %18d %18d\n", name, aCalls[k], aSucc[k], aRunsOk[k] + 0, n - (aRunsOk[k] + 0)
        }
        printf "%-72s %12s %10s\n", "boundary", "runs reached", "times"
        for (j = 1; j <= bN[label]; j++) {
          name = bOrder[label, j]; k = label SUBSEP name
          printf "%-72s %12d %10d\n", substr(name, 1, 72), bRuns[k], bTotal[k]
        }
        print ""
      }
      # a handler with no targetSelector: HandlerBase.writeCensus counted the calls the fuzzer made to it (spent
      # there, not on your actions) and wrote this boundary. Printed, never a gate: the census itself is still clean.
      for (li = 1; li <= nl; li++) if ((labels[li] SUBSEP unrestricted) in bTotal) flagged = 1
      if (flagged) print "the fuzzer reached HandlerBase" sq "s own functions: restrict the handler with targetSelector (doctrine/INVARIANTS.md)"
      if (ignored > 0) printf "NOTE: %d field(s) ignored - not U=, A:<name>=<calls>/<successes> or B:<name>=<count>. A tab inside a name?\n", ignored
      floor = ENVIRON["MIN_PCT"] + 0
      # PER SUITE: judged in every label that has the name, failed if ANY of them is below the floor
      nc = split(ENVIRON["CORE"], core, " ")
      for (c = 1; c <= nc; c++) {
        name = core[c]; found = 0
        for (li = 1; li <= nl; li++) {
          label = labels[li]; k = label SUBSEP name
          if (!(k in aCalls)) continue
          found = 1; pct = 100 * (aRunsOk[k] + 0) / runs[label]
          if (pct < floor) {
            printf "CORE action \"%s\" succeeded in only %d of %d runs of %s (%.0f%%, floor %d%%): most runs did not test it.\n", name, aRunsOk[k] + 0, runs[label], label, pct, floor
            bad = 1; why(sprintf("CORE \"%s\" succeeded in %d of %d runs of %s (%.0f%%), below the %d%% floor", name, aRunsOk[k] + 0, runs[label], label, pct, floor))
          }
        }
        if (!found) { printf "CORE action \"%s\" is not in the census at all: it never ran.\n", name; bad = 1; why(sprintf("CORE \"%s\" is in no suite: it never ran", name)) }
      }
      nr = split(ENVIRON["REACH"], reach, ";")
      for (c = 1; c <= nr; c++) {
        name = reach[c]; found = 0
        if (name == "") continue
        for (li = 1; li <= nl; li++) {
          label = labels[li]; k = label SUBSEP name
          if (!(k in bTotal)) continue
          found = 1; pct = 100 * bRuns[k] / runs[label]
          if (pct < floor) {
            printf "REACH boundary \"%s\" was reached in only %d of %d runs of %s (%.0f%%, floor %d%%).\n", name, bRuns[k], runs[label], label, pct, floor
            bad = 1; why(sprintf("REACH \"%s\" reached in %d of %d runs of %s (%.0f%%), below the %d%% floor", name, bRuns[k], runs[label], label, pct, floor))
          }
        }
        if (!found) { printf "REACH boundary \"%s\" is not in the census at all: no run of any suite reached it.\n", name; bad = 1; why(sprintf("REACH \"%s\" is in no suite: no run reached it", name)) }
      }
      exit bad
    }' "$1"
}

# A persisted failure (forge's <failure_persist_dir>/failures/<suite>/) is replayed FIRST on every later run of its suite,
# and afterInvariant writes a line for the replay like for a run: measured (forge 1.8.1, a stranger's v4 hook), 1 011 lines
# for 1 000 runs with ten persisted failures - N + 1 + one per persisted failure. forge's census line carries nothing that
# tells the replay from a run, so the count is SAID, under the table, never corrected.
# persisted_note <root> <census file> [<forge log>]: the root is where forge ran; with a log, only suites that ran count
persisted_note() {
  local root="$1" tsv="$2" log="${3:-}" pdir abs d s c k=0 names="" n
  pdir="${FOUNDRY_INVARIANT_FAILURE_PERSIST_DIR:-}"
  if [ -z "$pdir" ] && [ -f "$root/foundry.toml" ] && command -v forge > /dev/null 2>&1; then
    pdir="$(cd "$root" && forge config 2> /dev/null | awk '/^\[invariant\]/ {f = 1; next} /^\[/ {f = 0} f && $1 == "failure_persist_dir" {v = $3} END {gsub(/"/, "", v); print v}')"
  fi
  pdir="${pdir:-cache/invariant}"; pdir="${pdir#./}"
  case "$pdir" in /*) abs="$pdir" ;; *) abs="$root/$pdir" ;; esac
  [ -d "$abs/failures" ] || return 0
  for d in "$abs/failures"/*/; do
    [ -d "$d" ] || continue
    s="$(basename "$d")"
    # forge prints "Ran <n> tests for <path>:<Suite>" for every suite it ran
    if [ -n "$log" ] && ! grep -aqE "^Ran [0-9]+ tests? for .*:$s\$" "$log"; then continue; fi
    c="$(find "$d" -type f | wc -l | tr -d ' ')"
    [ "$c" -gt 0 ] || continue
    k=$((k + c)); names="${names:+$names, }$s"
  done
  [ "$k" -gt 0 ] || return 0
  n="$(awk 'END { print NR }' "$tsv")"
  echo "runs: $n ($pdir/failures holds $k persisted failures of $names: they replay first and count)"
}

# where forge ran, for a census file given to --aggregate: the parent of its census/ directory (census/long.tsv, where
# fuzz-long.sh writes it), or else the project given, or else here
census_root() { # census_root <file> [project-dir]
  local dir
  dir="$(cd "$(dirname "$1")" 2> /dev/null && pwd -P)" || { (cd "${2:-.}" && pwd -P); return; }
  if [ "$(basename "$dir")" = "census" ]; then dirname "$dir"; else (cd "${2:-.}" 2> /dev/null && pwd -P); fi
}

# A FAILED campaign has no census. forge calls afterInvariant() on every replay it makes while it SHRINKS a counterexample,
# and each writes a line like a run: measured (forge 1.8.1, a stranger's v4 hook), 199 510 lines and 59 778 "unexplained"
# for 272 runs; reproduced, 198 991 lines for 53. fuzz-long.sh and the run mode below rename such a file *.FAILED.tsv.
failed_census() { case "$(basename "$1")" in *.FAILED.tsv | *.FAILED) return 0 ;; *) return 1 ;; esac; }
FAILED_WHY="is the census of a FAILED campaign: forge wrote a line per shrink replay, not per run. NOTHING MEASURED - fix the failure, and gate a green campaign's census"

if [ "${1:-}" = "--aggregate" ] && [ "${CENSUS_TABLE_ONLY:-0}" = "1" ]; then
  [ -n "${2:-}" ] || { echo "usage: census.sh --aggregate <file> [project-dir]"; exit 2; }
  [ -z "$floor_error" ] || { echo "census: $floor_error NOTHING MEASURED."; exit 2; }
  if failed_census "$2"; then echo "census: $2 $FAILED_WHY."; exit 2; fi
  aggregate "$2"; rc=$?
  [ "$rc" -eq 2 ] && echo "census: $2 is empty or missing. NOTHING MEASURED."
  [ "$rc" -ne 2 ] && persisted_note "$(census_root "$2" "${3:-}")" "$2" "${CENSUS_FORGE_LOG:-}"
  exit "$rc"
fi

# THE GATE. It used to write no file and print no verdict on a pass (rc 0 only): a fresh reader could not tell a gate that
# passed from one that printed a table, and the dossier had nothing to cite. Now it leaves a record, and says the verdict
# last. The exit code is what it always was.
if [ "${1:-}" = "--aggregate" ]; then
  [ -n "${2:-}" ] || { echo "usage: census.sh --aggregate <file> [project-dir]"; echo "census gate: FAILED - no census file given"; exit 2; }
  if failed_census "$2"; then echo "census gate: FAILED - $2 $FAILED_WHY"; exit 2; fi
  TSV="$2"; GPROJECT="${3:-.}"
  proj_abs="$(cd "$GPROJECT" 2> /dev/null && pwd -P)" || { echo "census gate: FAILED - cannot enter the project $GPROJECT"; exit 2; }
  gate_out="${OUT_DIR:-.gauntlet/reports}"; case "$gate_out" in /*) ;; *) gate_out="$proj_abs/$gate_out" ;; esac
  mkdir -p "$gate_out" || { echo "census gate: FAILED - cannot create $gate_out"; exit 2; }
  record="$gate_out/06-census-gate.txt"
  tsv_dir="$(cd "$(dirname "$TSV")" 2> /dev/null && pwd -P)"
  tsv_abs="${tsv_dir:+$tsv_dir/}$(basename "$TSV")"
  printf 'census gate over %s: CORE="%s" REACH="%s" MIN_PCT=%s (%s)\n\n' "$tsv_abs" "${CORE:-}" "${REACH:-}" "$MIN_PCT" \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$record" || { echo "census gate: FAILED - cannot write $record"; exit 2; }
  if [ -n "$floor_error" ]; then
    echo "census: $floor_error NOTHING MEASURED." | tee -a "$record"; rc=2
    verdict="FAILED - $floor_error NOTHING MEASURED."
  else
    GATE_WHY="$(mktemp)" || { echo "census gate: FAILED - mktemp"; exit 2; }
    GATE_WHY="$GATE_WHY" aggregate "$TSV" | tee -a "$record"; rc=${PIPESTATUS[0]}
    [ "$rc" -ne 2 ] && persisted_note "$(census_root "$TSV" "${3:-}")" "$TSV" "${CENSUS_FORGE_LOG:-}" | tee -a "$record"
    if [ "$rc" -eq 0 ]; then
      n_core="$(printf '%s\n' "${CORE:-}" | wc -w | tr -d ' ')"
      n_reach="$(printf '%s\n' "${REACH:-}" | tr ';' '\n' | grep -c .)"
      if [ "$n_core" -eq 0 ] && [ "$n_reach" -eq 0 ]; then
        # nothing was judged but unexplained reverts: a gate with no floor is not a pass (Fable, after K9)
        verdict="NOTHING JUDGED - CORE and REACH are both empty; only unexplained reverts were checked. Name the actions and boundaries that matter (doctrine/JUDGES.md row 4)"
        rc=2
      else
        verdict="PASSED - $n_core CORE actions and $n_reach REACH boundaries at or above $MIN_PCT%"
      fi
    elif [ "$rc" -eq 2 ]; then
      echo "census: $TSV is empty or missing. NOTHING MEASURED." | tee -a "$record"
      verdict="FAILED - NOTHING MEASURED: $TSV is empty or missing"
    else
      reasons="$(awk 'NR > 1 { printf "; " } { printf "%s", $0 }' "$GATE_WHY")"
      verdict="FAILED - ${reasons:-rc $rc, read the table above}"
    fi
    rm -f "$GATE_WHY"
  fi
  echo "census gate: $verdict" >> "$record"
  if [ -z "${3:-}" ] && [ -n "$tsv_dir" ] && case "$tsv_dir/" in "$proj_abs"/*) false ;; *) true ;; esac; then
    echo "census gate: record written to $record (the census is in $tsv_dir; give the project as the third argument to write it there)"
  else
    echo "census gate: record written to $record"
  fi
  echo "census gate: $verdict"
  exit "$rc"
fi

[ -z "$floor_error" ] || { echo "census: $floor_error NOTHING MEASURED."; exit 2; }
PROJECT="${1:-.}"
MATCH="${MATCH:---match-contract Invariant}"
FORGE_FLAGS="${FORGE_FLAGS:-}"
cd "$PROJECT" || { echo "census: cannot enter $PROJECT"; exit 2; }
OUT_DIR="${OUT_DIR:-.gauntlet/reports}"
mkdir -p "$OUT_DIR" census
# one corpus per manager, for the reason given in battery.sh: this script runs the same campaigns, and a corpus recorded
# against one deployment layout, replayed against another, invents a counterexample - and PERSISTS it in cache/invariant,
# from where it goes on to poison the battery that did everything right
if [ -n "${V4_MANAGER:-}" ] && [ -z "${FOUNDRY_INVARIANT_CORPUS_DIR:-}" ]; then
  export FOUNDRY_INVARIANT_CORPUS_DIR="corpus/invariant-$V4_MANAGER"
fi
export GAUNTLET_CENSUS="census/runs.tsv"
rm -f "$GAUNTLET_CENSUS"

# the moment the campaign started: forge's records of the failures THIS run persisted are the ones newer than it
started_at="$OUT_DIR/.census-started"; : > "$started_at"

# shellcheck disable=SC2086
forge test $FORGE_FLAGS $MATCH > "$OUT_DIR/06-census-run.txt" 2>&1
rc_forge=$?
if [ "$rc_forge" -ne 0 ]; then
  echo "census: the campaign itself FAILED (rc=$rc_forge). The end of its log:"; tail -n 12 "$OUT_DIR/06-census-run.txt" | sed "s/^/    | /"
  # a red campaign has no census: its file holds a line per shrink replay (see failed_census). Renamed, never tabled.
  if [ -s "$GAUNTLET_CENSUS" ]; then
    failed_file="${GAUNTLET_CENSUS%.tsv}.FAILED.tsv"
    mv -f "$GAUNTLET_CENSUS" "$failed_file"
    echo "census: the campaign FAILED, so it has NO census: forge calls afterInvariant() on every replay it makes while it"
    echo "        shrinks a counterexample, and each wrote a line ($(awk 'END { print NR }' "$failed_file") lines, not one per run). Kept for"
    echo "        reading as $(pwd -P)/${failed_file#./}; the gate refuses it. Fix the failure first."
    echo "census: the campaign FAILED - no census (renamed $failed_file)" > "$OUT_DIR/06-census.txt"
    exit "$rc_forge"
  fi
fi

aggregate "$GAUNTLET_CENSUS" | tee "$OUT_DIR/06-census.txt"
rc=${PIPESTATUS[0]}
[ "$rc" -ne 2 ] && persisted_note "$(pwd -P)" "$GAUNTLET_CENSUS" "$OUT_DIR/06-census-run.txt" | tee -a "$OUT_DIR/06-census.txt"
if [ "$rc" -eq 2 ]; then
  echo "census: no census line was written. Call handler.writeCensus(\"<name>\") from afterInvariant() and give foundry.toml"
  echo "        fs_permissions = [{ access = \"read-write\", path = \"./census\" }]. NOTHING MEASURED."
  # A campaign that failed on its ENVIRONMENT (the write refused, or census/ missing) is still a failure to forge: it
  # persists the sequence under <failure_persist_dir>/failures/<suite>/ and replays it FIRST on every later run, saying
  # nothing (measured, forge 1.8.1: after the config was fixed the replay passed, silently, and every census from then on
  # had one run more than a fresh one - 258 lines against 257 on 256 runs). Named here, never deleted by this script:
  # forge's record carries no reason (measured: `call_sequence`, `settings`, `assertion_failure` and nothing else), so
  # nothing in it proves the sequence is the environment error and not a counterexample replayed from an earlier run.
  if [ "$rc_forge" -ne 0 ] && grep -aq '^\[FAIL: vm\.writeLine' "$OUT_DIR/06-census-run.txt"; then
    persist="$(forge config 2> /dev/null | awk '/^\[invariant\]/ {f = 1; next} /^\[/ {f = 0} f && $1 == "failure_persist_dir" {v = $3} END {gsub(/"/, "", v); print v}')"
    persist="${persist:-cache/invariant}"; case "$persist" in /*) ;; *) persist="$(pwd -P)/$persist" ;; esac
    # the FILES this run wrote (a suite's directory keeps its old time when a record inside it is rewritten), by suite
    recorded="$(find "$persist/failures" -type f -newer "$started_at" 2> /dev/null | sed "s#^\($persist/failures/[^/]*\)/.*#\1#" | sort -u)"
    if [ -n "$recorded" ]; then
      echo "        forge PERSISTED that environment failure and will replay it first on the next run, silently. After fixing"
      echo "        the config, delete its record:"
      printf '%s\n' "$recorded" | while IFS= read -r d; do echo "          rm -rf $d"; done
    fi
  fi
  exit 2
fi
[ "$rc_forge" -ne 0 ] && exit "$rc_forge"
exit "$rc"
