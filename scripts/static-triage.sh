#!/usr/bin/env bash
#
# static-triage.sh - the static analysers this machine has, run on the project's src/, into one report to triage.
#
# The problem it solves: row 1 of doctrine/JUDGES.md (a basic mistake a machine would catch) was a sentence - "Slither if
# the owner allowed the install; otherwise forge lint" - and each agent ran its own command, read its own subset and
# wrote what it remembered. Here it is one command: what is installed runs, in a fixed order, on src/ only, and the
# output is kept whole with a count beside it. It installs nothing and fetches nothing: a missing tool is said, never
# fetched (an install is the owner's to allow: briefs/owner-interview.md, question 17b).
#
# Usage:   scripts/static-triage.sh <proj>
# Env:     OUT_DIR  where the report goes (default: <proj>/.gauntlet/reports; a relative one is under <proj>). Inside a
#                   project with no .gauntlet/ it refuses before running or writing anything, exit 2 - unless it is a
#                   bench or the kit's own (scripts/lib/owner-tree.sh)
#          FOUNDRY_PROFILE  the profile forge runs (allowed, and named). Every other FOUNDRY_*, FORGE_*, DAPP_ name is
#                   removed, as the battery removes them (scripts/lib/forge-env.sh); a `.env` that sets one is refused.
# The tools, in this order, each on <proj>/src/ (never the kit's sources, never lib/, test/ or script/):
#   1. Slither, when `slither` is on the PATH: `slither . --include-paths '^<proj, resolved>/src/[^/]' --checklist
#      --fail-none --skip-clean`; with the project's own slither.config.json (or slither.conf.json), `slither .
#      --checklist --fail-none --skip-clean` and its filters are the project's. Not `--filter-paths lib`: Slither matches
#      that regex against each result's ABSOLUTE path and drops a result when ANY of its elements matches - measured
#      (Slither 0.11.6, 2026-10-06): 0 results of 43 for a project under a directory named `library`, and one result of 43
#      lost to an element in lib/ (`src/libraries/` would go the same way). The counts are read from the checklist's
#      Summary (` - [<detector>](#...) (<n> results) (<Impact>)`) and must add up to Slither's own last line (`<n>
#      result(s) found`): when they do not, or either is missing, the output is kept and said "not read" - never
#      guessed. Slither builds the project itself (`forge build --force`): it rebuilds out/ and - measured - deletes
#      forge's two persisted-failure directories, the counterexamples a later `forge test` replays first: the invariant
#      one and the fuzz one. This script reads them from the project's `forge config --json`
#      (`invariant.failure_persist_dir`, `fuzz.failure_persist_dir`; `cache/invariant` and `cache/fuzz` when forge does
#      not say), keeps each that exists aside, and puts it back as it was - and says so, in its output and in the
#      report's note.
#      One outside the project is not kept (this script writes only in the project and OUT_DIR) - measured, Slither's
#      build deletes it too: the note says so.
#   2. Aderyn, when `aderyn` is on the PATH: `aderyn . --output <a temporary file>.md --skip-update-check` (its report
#      is copied into this one; nothing is left in the project). Counted from its "Issue Summary" table (`| High | n |`,
#      `| Low | n |`) against its `## H-<n>:` / `## L-<n>:` headings. That shape is ASSUMED - no Aderyn was on the
#      machines this was written on, and only a fake one has run it (the selftest): a report of another shape is kept
#      and said "not read".
#   3. `forge lint src`, always (forge's own linter: it does not compile; a path overrides the project's `[lint] ignore`,
#      so all of src/ is linted). Counted by level and rule (`<level>[<rule>]:` lines), and by forge's own severity: one
#      more `forge lint src --severity <s>` per severity (high, med, low, info, gas, code-size), each about a second -
#      that flag overrides the project's `[lint] severity`, so the sum can differ from the plain run's count, and the
#      report says so when it does (measured on the root kit, forge 1.8.1: 49 lints, and without code-size the sum was 45).
# Output:  .gauntlet/reports/05-static.txt (OUT_DIR): a header (each tool and its version, or "not installed"), then each
#          tool's findings as it printed them, then the counts by impact / severity. On stdout: one line per tool, the
#          line for STATE.md's `notes:` - `static triage: <tools>` (this script prints it; it does not edit STATE.md):
#            static triage: slither <v>, forge lint                         (and `aderyn <v>, ` when it ran)
#            static triage: forge lint only, Slither not installed
#            static triage: forge lint only - the owner declined the install (no analyser here, and the LAST answer to
#                           question 17b in the project's DECISIONS.md - .gauntlet/DECISIONS.md, else DECISIONS.md at its
#                           root - is the heading `## <id> · <date> · Q17b static analyzers: no`; the form is
#                           briefs/owner-interview.md's. Nothing else is read from it: what runs is what is installed)
#            a tool that failed or was not read is named after the tools, with "see 05-static.txt"
#          and, last, that the findings are the agent's to triage, like any finding.
# Exit:    0 forge lint ran (whatever Slither and Aderyn did: the report says); 1 forge is not on the PATH, or forge lint
#          failed (the report is still written, with its output); 2 nothing run, nothing written: no <proj>, no src/ or no
#          .sol file under it, OUT_DIR refused, a `.env` that sets a forge variable, bad arguments.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/forge-env.sh
. "$HERE/lib/forge-env.sh" || { echo "static-triage: $HERE/lib/forge-env.sh is missing"; exit 2; }
# shellcheck source=lib/owner-tree.sh
. "$HERE/lib/owner-tree.sh" || { echo "static-triage: $HERE/lib/owner-tree.sh is missing"; exit 2; }

refuse() { echo "static-triage: REFUSED - $*"; echo "static-triage: nothing run, nothing written."; exit 2; }
[ "$#" -eq 1 ] || refuse "usage: scripts/static-triage.sh <proj> (one argument, the project's directory)."
case "$1" in -*) refuse "usage: scripts/static-triage.sh <proj> - '$1' is not a directory." ;; esac
forge_env_clean static-triage "FOUNDRY_PROFILE" "$0" "$@"

PROJ="$1"
[ -d "$PROJ" ] || refuse "$PROJ is not a directory."
cd "$PROJ" || refuse "cannot enter $PROJ."
PROJ_REAL="$(pwd -P)"
[ -d src ] || refuse "$PROJ_REAL has no src/: the static triage reads the project's own sources there, and nothing else (a project whose sources live elsewhere: its own analyser run, said in the dossier)."
[ -n "$(find -L src -name '*.sol' -type f -print -quit 2> /dev/null)" ] || refuse "$PROJ_REAL/src has no .sol file: nothing to analyse."
OUT_DIR="${OUT_DIR:-.gauntlet/reports}"
report_dir_allowed static-triage "$PROJ_REAL" "$OUT_DIR" || { echo "static-triage: nothing run, nothing written."; exit 2; }
forge_dotenv_check static-triage "$PROJ_REAL" || { echo "static-triage: nothing run, nothing written."; exit 2; }

ver_of() { local re='([0-9]+\.[0-9]+(\.[0-9]+)?)'; if [[ $1 =~ $re ]]; then echo "${BASH_REMATCH[1]}"; fi; }
TMPD="$(mktemp -d)" || { echo "static-triage: no temporary directory"; exit 1; }
# forge's persisted-failure directories, kept aside around Slither's build: KEEP_DIR[i] (as forge config gives it, under
# the project) and its copy KEEP_COPY[i]; KEEP_PENDING=1 while a copy is not yet put back
KEEP_DIR=() KEEP_COPY=() KEEP_PENDING=""
keep_restore() { # keep_restore <i>: KEEP_DIR[i] back as KEEP_COPY[i] holds it
  local d="$PROJ_REAL/${KEEP_DIR[$1]}"
  rm -rf "$d"; mkdir -p "$(dirname "$d")" && cp -a "${KEEP_COPY[$1]}" "$d"
}
cleanup() {
  # a run cut short between Slither's build and the restore: what it deleted is put back
  local i
  if [ -n "$KEEP_PENDING" ]; then
    for i in "${!KEEP_DIR[@]}"; do [ -d "$PROJ_REAL/${KEEP_DIR[$i]}" ] || keep_restore "$i"; done
  fi
  rm -rf "$TMPD"
}
trap cleanup EXIT

if ! command -v forge > /dev/null 2>&1; then
  echo "static-triage: forge is not on the PATH: forge lint, the one judge this script always runs, cannot run (scripts/doctor.sh)."
  echo "static-triage: FAILED - nothing analysed"
  exit 1
fi
FORGE_V="$(ver_of "$(forge --version 2> /dev/null | head -n 1)")"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ------------------------------------------------------------------------------------------------ 1. Slither
SL_STATE="not installed" SL_V="" SL_CMD="" SL_COUNT="" SL_WHY=""
if command -v slither > /dev/null 2>&1; then
  SL_V="$(ver_of "$(slither --version 2> /dev/null | head -n 1)")"; SL_V="${SL_V:-unknown}"
  sl_cfg=""
  for c in slither.config.json slither.conf.json; do [ -f "$c" ] && { sl_cfg="$c"; break; }; done
  if [ -n "$sl_cfg" ]; then
    sl_args=(. --checklist --fail-none --skip-clean)
    SL_CMD="slither . --checklist --fail-none --skip-clean   (the project's $sl_cfg: its own filters)"
  else
    # the project's resolved path as a Python regex, then src/ and one more character: Slither strips a trailing '/' or
    # '.' from the pattern (slither_core.py, _relative_path_format), and a bare `src` would also take src2/
    esc="$(printf '%s' "$PROJ_REAL" | sed 's/[][\.^$*+?(){}|]/\\&/g')"
    sl_args=(. --include-paths "^$esc/src/[^/]" --checklist --fail-none --skip-clean)
    SL_CMD="slither . --include-paths '^$esc/src/[^/]' --checklist --fail-none --skip-clean"
  fi
  # the persisted-failure directories, as the project's forge config gives them (pretty-printed JSON: a section's keys
  # at four spaces), or forge's defaults
  pf_cfg="$(forge config --json 2> /dev/null)"; pf_rc=$?
  pf_of() { # pf_of <fuzz|invariant>: that section's failure_persist_dir as forge prints it, empty when absent or null
    printf '%s\n' "$pf_cfg" | LC_ALL=C awk -v sec="$1" '
      $0 ~ "^  \"" sec "\": [{]" { f = 1; next }
      f && /^  [}]/ { exit }
      f && /^    "failure_persist_dir": "/ { v = $0; sub(/^    "failure_persist_dir": "/, "", v); sub(/",?$/, "", v); print v; exit }'
  }
  persist_note=()
  [ "$pf_rc" -eq 0 ] || persist_note+=("forge config --json failed (rc $pf_rc): forge's defaults cache/invariant and cache/fuzz are the ones kept")
  for sec in invariant fuzz; do
    d=""; [ "$pf_rc" -ne 0 ] || d="$(pf_of "$sec")"
    [ -n "$d" ] || d="cache/$sec"
    d="${d%/}"; case "$d" in "$PROJ_REAL"/*) d="${d#"$PROJ_REAL"/}" ;; esac
    [ -e "$d" ] || continue
    case "$d" in
      /*) persist_note+=("$d/ ($sec.failure_persist_dir) is outside the project: not kept - Slither's build deletes it"); continue ;;
      *\\* | *//* | ..|../*|*/..|*/../* | .|./*|*/.|*/./*) persist_note+=("$d/ ($sec.failure_persist_dir) is not a plain path under the project: not kept - Slither's build deletes it"); continue ;;
    esac
    [ -d "$d" ] || continue
    dup=""; for k in "${KEEP_DIR[@]}"; do [ "$k" != "$d" ] || dup=1; done
    [ -z "$dup" ] || continue
    KEEP_COPY+=("$TMPD/kept-${#KEEP_DIR[@]}"); KEEP_DIR+=("$d")
    cp -a "$d" "${KEEP_COPY[${#KEEP_COPY[@]}-1]}"
  done
  KEEP_PENDING=1
  echo "static-triage: slither $SL_V - running (it builds the project with forge, from nothing: seconds on a small project, minutes on a large one)"
  slither "${sl_args[@]}" > "$TMPD/slither.out" 2> "$TMPD/slither.err"; sl_rc=$?
  for i in "${!KEEP_DIR[@]}"; do
    if [ ! -d "${KEEP_DIR[$i]}" ] || ! diff -r "${KEEP_COPY[$i]}" "${KEEP_DIR[$i]}" > /dev/null 2>&1; then
      keep_restore "$i" && persist_note+=("${KEEP_DIR[$i]}/ was changed or deleted by Slither's build, and is put back as it was")
    else
      persist_note+=("${KEEP_DIR[$i]}/ as it was")
    fi
  done
  KEEP_PENDING=""
  sl_total="$(grep -oE '[0-9]+ result\(s\) found' "$TMPD/slither.err" "$TMPD/slither.out" 2> /dev/null | tail -n 1 | sed -E 's/^[^:]*://; s/ .*//')"
  # the checklist's Summary: ` - [<detector>](#<anchor>) (<n> results) (<Impact>)`
  sl_sum="$(LC_ALL=C awk '
    /^ - \[[A-Za-z0-9_.-]+\]\(#[^)]*\) \([0-9]+ results?\) \((High|Medium|Low|Informational|Optimization)\)$/ {
      match($0, /\([0-9]+ results?\)/); n = substr($0, RSTART + 1, RLENGTH - 2); sub(/ .*$/, "", n)
      imp = $0; sub(/\)$/, "", imp); sub(/^.*\(/, "", imp)
      c[imp] += n; t += n; rows++
    }
    END { printf "%d %d %d %d %d %d %d\n", rows + 0, t + 0, c["High"] + 0, c["Medium"] + 0, c["Low"] + 0, c["Informational"] + 0, c["Optimization"] + 0 }' "$TMPD/slither.out")"
  read -r sl_rows sl_t sl_h sl_m sl_l sl_i sl_o <<< "$sl_sum"
  if [ "$sl_rc" -ne 0 ]; then
    SL_STATE="failed"; SL_WHY="slither exited $sl_rc (with --fail-none, findings alone do not make it fail: a build or a parse that did not succeed - its last lines are below)"
  elif [ -z "$sl_total" ]; then
    SL_STATE="not read"; SL_WHY="its output has no '<n> result(s) found' line: not of a shape this script reads (another Slither version?) - kept below, not counted"
  elif [ "$sl_t" != "$sl_total" ]; then
    SL_STATE="not read"; SL_WHY="its checklist's Summary adds up to $sl_t ($sl_rows rows) and its own last line says $sl_total result(s): not counted - kept below"
  else
    SL_STATE="ran"
    SL_COUNT="$sl_total findings - High $sl_h, Medium $sl_m, Low $sl_l, Informational $sl_i, Optimization $sl_o"
  fi
  echo "static-triage: slither $SL_V - $SL_STATE${SL_COUNT:+: $SL_COUNT}${SL_WHY:+ ($SL_WHY)}"
  for n in "${persist_note[@]}"; do echo "static-triage: $n"; done
else
  echo "static-triage: slither - not installed (not fetched: an install is the owner's to allow)"
fi

# ------------------------------------------------------------------------------------------------ 2. Aderyn
AD_STATE="not installed" AD_V="" AD_CMD="" AD_COUNT="" AD_WHY=""
if command -v aderyn > /dev/null 2>&1; then
  AD_V="$(ver_of "$(aderyn --version 2> /dev/null | head -n 1)")"; AD_V="${AD_V:-unknown}"
  AD_CMD="aderyn . --output <a temporary file>.md --skip-update-check"
  echo "static-triage: aderyn $AD_V - running"
  aderyn . --output "$TMPD/aderyn.md" --skip-update-check > "$TMPD/aderyn.log" 2>&1; ad_rc=$?
  if [ "$ad_rc" -ne 0 ]; then
    AD_STATE="failed"; AD_WHY="aderyn exited $ad_rc - its last lines are below"
  elif [ ! -s "$TMPD/aderyn.md" ]; then
    AD_STATE="not read"; AD_WHY="it wrote no report where it was asked to - its own lines are below"
  else
    ad_sum="$(LC_ALL=C awk '
      { sub(/\r$/, "") }
      /^\| *(High|Medium|Low) *\| *[0-9]+ *\|$/ { s = $0; gsub(/[| ]+/, " ", s); split(s, f, " "); tab[f[1]] = f[2]; seen++ }
      /^## H-[0-9]+:/ { h++ } /^## M-[0-9]+:/ { m++ } /^## L-[0-9]+:/ { l++ }
      END { printf "%d %s %s %s %d %d %d\n", seen + 0, (("High" in tab) ? tab["High"] : "-"), (("Medium" in tab) ? tab["Medium"] : "-"), (("Low" in tab) ? tab["Low"] : "-"), h + 0, m + 0, l + 0 }' "$TMPD/aderyn.md")"
    read -r ad_seen ad_th ad_tm ad_tl ad_h ad_m ad_l <<< "$ad_sum"
    ad_th="${ad_th/-/0}"; ad_tm="${ad_tm/-/0}"; ad_tl="${ad_tl/-/0}"
    if [ "$ad_seen" -eq 0 ]; then
      AD_STATE="not read"; AD_WHY="its report has no Issue Summary rows ('| High | n |', '| Low | n |'): not of the shape this script reads - kept below, not counted"
    elif [ "$ad_th" != "$ad_h" ] || [ "$ad_tm" != "$ad_m" ] || [ "$ad_tl" != "$ad_l" ]; then
      AD_STATE="not read"; AD_WHY="its Issue Summary (High $ad_th, Medium $ad_tm, Low $ad_tl) does not match its headings (H- $ad_h, M- $ad_m, L- $ad_l): not counted - kept below"
    else
      AD_STATE="ran"; AD_COUNT="$((ad_h + ad_m + ad_l)) issues - High $ad_h, Medium $ad_m, Low $ad_l"
    fi
  fi
  echo "static-triage: aderyn $AD_V - $AD_STATE${AD_COUNT:+: $AD_COUNT}${AD_WHY:+ ($AD_WHY)}"
else
  echo "static-triage: aderyn - not installed (not fetched: an install is the owner's to allow)"
fi

# ------------------------------------------------------------------------------------------------ 3. forge lint, always
LINT_STATE="ran" LINT_COUNT="" LINT_WHY="" LINT_SEV=""
forge lint src > "$TMPD/lint.txt" 2>&1; lint_rc=$?
lint_diag() { LC_ALL=C grep -E '^[a-z]+\[[A-Za-z0-9_.-]+\]: ' "$1"; }
if [ "$lint_rc" -ne 0 ]; then
  LINT_STATE="failed"; LINT_WHY="forge lint exited $lint_rc - its output is below"
else
  lint_n="$(lint_diag "$TMPD/lint.txt" | awk 'END { print NR }')"
  lint_lv="$(lint_diag "$TMPD/lint.txt" | sed -E 's/\[.*//' | sort | uniq -c | awk '{ printf "%s%s %s", (n++ ? ", " : ""), $2, $1 }')"
  LINT_COUNT="$lint_n lints${lint_lv:+ - $lint_lv}"
  sev_sum=0; sev_bad=""
  for s in high med low info gas code-size; do
    if forge lint src --severity "$s" > "$TMPD/lint-$s.txt" 2>&1; then
      k="$(lint_diag "$TMPD/lint-$s.txt" | awk 'END { print NR }')"; sev_sum=$((sev_sum + k))
      LINT_SEV="${LINT_SEV:+$LINT_SEV, }$s $k"
    else
      sev_bad="${sev_bad:+$sev_bad, }$s"
    fi
  done
  if [ -n "$sev_bad" ]; then LINT_SEV="${LINT_SEV:+$LINT_SEV; }not counted for: $sev_bad (forge lint --severity failed)"
  elif [ "$sev_sum" -ne "$lint_n" ]; then LINT_SEV="$LINT_SEV (sum $sev_sum, the plain run $lint_n: --severity overrides the project's [lint] severity)"; fi
fi
echo "static-triage: forge lint (forge ${FORGE_V:-unknown}) - $LINT_STATE${LINT_COUNT:+: $LINT_COUNT}${LINT_WHY:+ ($LINT_WHY)}"

# ------------------------------------------------------------------------------------------------ the line for STATE.md
declined=""
for d in .gauntlet/DECISIONS.md DECISIONS.md; do
  [ -f "$d" ] || continue
  a="$(LC_ALL=C sed -nE 's/\r$//; s/^##[[:space:]].*[Qq]17b static analy[sz]ers:[[:space:]]*(yes|no|already installed)[[:space:]]*$/\1/p' "$d" | tail -n 1)"
  [ "$a" = no ] && declined="$d"
  break
done
tools=""; notes=""
case "$SL_STATE" in ran) tools="slither $SL_V" ;; "not installed") ;; *) notes="slither $SL_V $SL_STATE" ;; esac
case "$AD_STATE" in ran) tools="${tools:+$tools, }aderyn $AD_V" ;; "not installed") ;; *) notes="${notes:+$notes, }aderyn $AD_V $AD_STATE" ;; esac
if [ "$LINT_STATE" != ran ]; then notes="${notes:+$notes, }forge lint failed"; fi
if [ -n "$tools" ]; then
  STATE_LINE="static triage: $tools, forge lint"
  [ "$SL_STATE" != "not installed" ] || STATE_LINE="$STATE_LINE (Slither not installed)"
elif [ -n "$declined" ]; then
  STATE_LINE="static triage: forge lint only - the owner declined the install"
elif [ "$SL_STATE" = "not installed" ]; then
  STATE_LINE="static triage: forge lint only, Slither not installed"
else
  STATE_LINE="static triage: forge lint only"
fi
[ -z "$notes" ] || STATE_LINE="$STATE_LINE - $notes: see 05-static.txt"

# ------------------------------------------------------------------------------------------------ the report
REPORT_NAME="05-static.txt"
tool_head() { # tool_head <name> <state> <version>
  case "$2" in "not installed") echo "not installed" ;; *) echo "$1 $3 - $2" ;; esac
}
{
  echo "# static triage of $PROJ_REAL/src - scripts/static-triage.sh, $NOW"
  echo "# slither:    $(tool_head slither "$SL_STATE" "$SL_V")"
  echo "# aderyn:     $(tool_head aderyn "$AD_STATE" "$AD_V")"
  echo "# forge lint: forge ${FORGE_V:-unknown} - $LINT_STATE"
  echo "# Each finding below is a candidate for the agent to triage, not a verdict: doctrine/JUDGES.md, \"The static-analysis"
  echo "# triage (row 1)\" - a verdict per finding or per homogeneous group, in .gauntlet/STATIC-TRIAGE.md."
  echo
  echo "== slither =="
  if [ "$SL_STATE" = "not installed" ]; then echo "not installed (not fetched: an install is the owner's to allow)"; else
    echo "command: $SL_CMD"
    [ -z "$SL_WHY" ] || echo "NOT COUNTED: $SL_WHY"
    for n in "${persist_note[@]}"; do echo "note: $n (forge's persisted failures: Slither's build deletes them)"; done
    echo "-- its checklist (stdout):"; cat "$TMPD/slither.out"
    if [ "$SL_STATE" = ran ]; then echo "-- its last line (stderr):"; grep -E 'result\(s\) found' "$TMPD/slither.err" | tail -n 1
    else echo "-- the last 40 lines of its stderr:"; tail -n 40 "$TMPD/slither.err"; fi
  fi
  echo
  echo "== aderyn =="
  if [ "$AD_STATE" = "not installed" ]; then echo "not installed (not fetched: an install is the owner's to allow)"; else
    echo "command: $AD_CMD"
    [ -z "$AD_WHY" ] || echo "NOT COUNTED: $AD_WHY"
    if [ -s "$TMPD/aderyn.md" ]; then echo "-- its report:"; cat "$TMPD/aderyn.md"; fi
    if [ "$AD_STATE" != ran ]; then echo "-- the last 40 lines it printed:"; tail -n 40 "$TMPD/aderyn.log"; fi
  fi
  echo
  echo "== forge lint (forge ${FORGE_V:-unknown}) =="
  echo "command: forge lint src   (then forge lint src --severity <s>, for the count by severity only)"
  [ -z "$LINT_WHY" ] || echo "FAILED: $LINT_WHY"
  cat "$TMPD/lint.txt"
  echo
  echo "== counts =="
  if [ "$SL_STATE" = ran ]; then echo "slither $SL_V: $SL_COUNT"; elif [ "$SL_STATE" = "not installed" ]; then echo "slither: not installed"
  else echo "slither $SL_V: $SL_STATE - not counted"; fi
  if [ "$AD_STATE" = ran ]; then echo "aderyn $AD_V: $AD_COUNT"; elif [ "$AD_STATE" = "not installed" ]; then echo "aderyn: not installed"
  else echo "aderyn $AD_V: $AD_STATE - not counted"; fi
  if [ "$LINT_STATE" = ran ]; then
    echo "forge lint: $LINT_COUNT"
    echo "forge lint by severity: ${LINT_SEV:-none counted}"
    lint_diag "$TMPD/lint.txt" | sed -E 's/\]: .*/]/' | sort | uniq -c | sort -rn | awk '{ printf "  %s x%s\n", $2, $1 }'
  else echo "forge lint: failed - not counted"; fi
  echo "$STATE_LINE"
} > "$TMPD/report.txt"
mkdir -p "$OUT_DIR" && mv -f "$TMPD/report.txt" "$OUT_DIR/$REPORT_NAME" \
  || { echo "static-triage: the report could not be written to $OUT_DIR/$REPORT_NAME"; exit 1; }

echo "static-triage: report in $OUT_DIR/$REPORT_NAME"
echo "static-triage: the line for STATE.md notes: (this script does not edit STATE.md):"
echo "$STATE_LINE"
if [ "$LINT_STATE" != ran ]; then
  echo "static-triage: FAILED - forge lint did not run clean (its output is in the report)"
  exit 1
fi
echo "static-triage: the findings are yours to triage, not verdicts - each one goes to pending/ (a bug: its test, doctrine/NEXT.md row 6b) or DECISIONS.md (by design, accepted, a false positive) like any finding, with its verdict in .gauntlet/STATIC-TRIAGE.md (doctrine/JUDGES.md, row 1)"
exit 0
