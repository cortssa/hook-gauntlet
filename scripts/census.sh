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
# Usage:   scripts/census.sh [project-dir]          run the invariant campaigns, then print the census
#          scripts/census.sh --aggregate <file>     add up a census file that already exists (fuzz-long.sh does this)
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
#          OUT_DIR      where the report goes        (default: <project>/.gauntlet/reports)
# Exit:    0 printed (and every CORE / REACH name met the floor); 1 a name is below the floor or in no suite at all, or a
#          run met an unexplained revert; 2 NOTHING MEASURED - no census line was written (the suite does not call
#          writeCensus from afterInvariant, or foundry.toml lacks fs_permissions for ./census), or MIN_PCT is not a
#          number from 1 to 100; otherwise forge's exit code when the campaign itself failed.

set -uo pipefail

MIN_PCT="${MIN_PCT:-25}"
# a floor that is not a number counts as 0 inside awk, and a floor of 0 passes an action that never worked once
case "$MIN_PCT" in '' | *[!0-9]*) echo "census: MIN_PCT must be a whole number from 1 to 100 (got '$MIN_PCT'). NOTHING MEASURED."; exit 2 ;; esac
if [ "$MIN_PCT" -lt 1 ] || [ "$MIN_PCT" -gt 100 ]; then echo "census: MIN_PCT must be from 1 to 100 (got $MIN_PCT). NOTHING MEASURED."; exit 2; fi

aggregate() { # aggregate <file>
  [ -s "$1" ] || return 2
  CORE="${CORE:-}" REACH="${REACH:-}" MIN_PCT="$MIN_PCT" awk -F '\t' '
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
        if (surprised[label] + 0 > 0) bad = 1
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
            bad = 1
          }
        }
        if (!found) { printf "CORE action \"%s\" is not in the census at all: it never ran.\n", name; bad = 1 }
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
            bad = 1
          }
        }
        if (!found) { printf "REACH boundary \"%s\" is not in the census at all: no run of any suite reached it.\n", name; bad = 1 }
      }
      exit bad
    }' "$1"
}

if [ "${1:-}" = "--aggregate" ]; then
  [ -n "${2:-}" ] || { echo "usage: census.sh --aggregate <file>"; exit 2; }
  aggregate "$2"; rc=$?
  [ "$rc" -eq 2 ] && echo "census: $2 is empty or missing. NOTHING MEASURED."
  exit "$rc"
fi

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

# shellcheck disable=SC2086
forge test $FORGE_FLAGS $MATCH > "$OUT_DIR/06-census-run.txt" 2>&1
rc_forge=$?
if [ "$rc_forge" -ne 0 ]; then
  echo "census: the campaign itself FAILED (rc=$rc_forge). The end of its log:"; tail -n 12 "$OUT_DIR/06-census-run.txt" | sed "s/^/    | /"
fi

aggregate "$GAUNTLET_CENSUS" | tee "$OUT_DIR/06-census.txt"
rc=${PIPESTATUS[0]}
if [ "$rc" -eq 2 ]; then
  echo "census: no census line was written. Call handler.writeCensus(\"<name>\") from afterInvariant() and give foundry.toml"
  echo "        fs_permissions = [{ access = \"read-write\", path = \"./census\" }]. NOTHING MEASURED."
  exit 2
fi
[ "$rc_forge" -ne 0 ] && exit "$rc_forge"
exit "$rc"
