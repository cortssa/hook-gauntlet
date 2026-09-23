#!/usr/bin/env bash
#
# round.sh - write the ROUND line of a round into LOG.md, validated; and read the ROUND lines back as JSON.
#
# The problem it solves: the ROUND line (state/README.md) is the only record of what the rounds cost and found, and
# `grep '^ROUND ' LOG.md` is the history. A line typed by hand drifts: a type that is not on the list, "1-2" where a
# count goes, a date that is "last Tuesday", a field left out so every field after it moves one place. Nobody notices
# until somebody reads the history, and then it is too late to know what was meant. So the line is written from NAMED
# arguments, each one checked, and a malformed one is refused before anything is written.
#
# There is no second file. The JSON is a VIEW, derived from the ROUND lines on demand (`--json`), never stored: a
# fourth state file was tried once, nothing read it, and it was cut (state/README.md, "The ROUND line").
#
# Usage:   scripts/round.sh <LOG.md> --id r05 --phase 4 --type regression --model "vendor-a/large" --bench "~/hg-a05" \
#            --dates 2026-03-09..2026-03-12 --high 0 --medium 1 --low 4 --info 7 --reasoned 0 --gate pass \
#            [--tokens 230k] [--minutes 95] [--files-read 41] [--tests-written 6] --report reports/r05.md [--conf 0.7]
#          scripts/round.sh --json <LOG.md>      one JSON object per ROUND line, in file order, on stdout
# Args:    --id          the round's id: letters, digits, . _ - (r05, v2, bb1); refused if LOG.md already has it
#          --phase       0 to 8 (doctrine/NEXT.md)
#          --type        one of: interview spec battery discovery regression black-box verifier executor promotion
#                        rehearsal handoff simulation
#          --model       as specific as you can be ("Opus 5.5 (1M context)"); --bench, --report: a path
#          --dates       YYYY-MM-DD, or YYYY-MM-DD..YYYY-MM-DD with the end not before the start. Real calendar dates only
#          --high --medium --low --info   the findings AS THE ROUND CLASSIFIED THEM, whole numbers, all four required
#          --reasoned    the REASONED high/medium, counted apart (state/README.md), a whole number, required
#          --gate        pass | fail  (a round that died on a rate limit is `fail`, and it still gets its line)
#          --tokens (a whole number, or with k / M: 230k), --minutes, --files-read, --tests-written: the cost and the
#                        effort. OPTIONAL, because what you cannot measure you leave out - never guess it
#          --conf        OPTIONAL raw_confidence, 0 to 1: what the round's author would bet on its own verdict. Recorded;
#                        no policy reads it today
#          --dry-run     print the line, write nothing
# Text fields may not contain "|" (the separator) or control characters.
# Exit:    0 written (or printed); 2 REFUSED - a malformed or missing argument, a duplicate id, or no LOG.md: nothing was
#          written. --json: 0 every ROUND line read; 1 a ROUND line is not of the shape this script writes (named on
#          stderr, not printed - the others are); 2 no such file.

set -uo pipefail

TYPES="interview spec battery discovery regression black-box verifier executor promotion rehearsal handoff simulation"

refuse() { echo "round: $* NOTHING WRITTEN." >&2; exit 2; }

# ------------------------------------------------------------------------------------------------ --json: the view
if [ "${1:-}" = "--json" ]; then
  [ -f "${2:-}" ] || { echo "round: --json needs an existing LOG.md (got '${2:-}')." >&2; exit 2; }
  # the same shape as the writer below, read back field by field; a line that does not fit is named, never guessed at
  LC_ALL=C awk -v types=" $TYPES " '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return "\"" s "\"" }
    function num(s) { return (s == "") ? "null" : s }
    function tok(s,   n) { if (s == "") return "null"; n = s; if (n ~ /k$/) { sub(/k$/, "", n); return n * 1000 }
                           if (n ~ /M$/) { sub(/M$/, "", n); return n * 1000000 } return n + 0 }
    function bad(why) { printf "round: line %d is not a ROUND line of the fixed shape (%s): %s\n", NR, why, $0 > "/dev/stderr"; nbad++ }
    /^ROUND / {
      sub(/\r$/, "")
      n = split(substr($0, 7), f, / \| /)
      if (n != 10 && n != 11) { bad(n " fields, not 10 or 11"); next }
      id = f[1]
      if (f[2] !~ /^phase [0-8]$/) { bad("phase"); next }
      phase = substr(f[2], 7)
      if (index(types, " " f[3] " ") == 0) { bad("type"); next }
      model = f[4]
      if (f[5] !~ /^bench .+/) { bad("bench"); next }
      bench = substr(f[5], 7)
      if (f[6] ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) { d0 = f[6]; d1 = f[6] }
      else if (f[6] ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\.\.[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) { d0 = substr(f[6], 1, 10); d1 = substr(f[6], 13) }
      else { bad("dates"); next }
      if (f[7] !~ /^[0-9]+H [0-9]+M [0-9]+L [0-9]+I reasoned [0-9]+$/) { bad("findings"); next }
      split(f[7], g, / /); H = g[1]; M = g[2]; L = g[3]; I = g[4]; sub(/H/, "", H); sub(/M/, "", M); sub(/L/, "", L); sub(/I/, "", I)
      if (f[8] !~ /^gate (pass|fail)$/) { bad("gate"); next }
      gate = substr(f[8], 6)
      c = f[9]; t = ""; mi = ""; fr = ""; tw = ""
      if (c != "cost not measured") {
        m = split(c, parts, /, /)
        for (j = 1; j <= m; j++) {
          p = parts[j]
          if (p ~ /^[0-9]+[kM]? tokens$/) { sub(/ tokens$/, "", p); t = p }
          else if (p ~ /^[0-9]+ min$/) { sub(/ min$/, "", p); mi = p }
          else if (p ~ /^[0-9]+ files read$/) { sub(/ files read$/, "", p); fr = p }
          else if (p ~ /^[0-9]+ tests written$/) { sub(/ tests written$/, "", p); tw = p }
          else { t = "?"; break }
        }
        if (t == "?") { bad("cost"); next }
      }
      report = f[10]
      conf = "null"
      if (n == 11) { if (f[11] !~ /^conf (0(\.[0-9]+)?|1(\.0+)?)$/) { bad("conf"); next } conf = substr(f[11], 6) }
      printf "{\"id\":%s,\"phase\":%d,\"type\":%s,\"model\":%s,\"bench\":%s,\"dates\":{\"start\":%s,\"end\":%s},", esc(id), phase, esc(f[3]), esc(model), esc(bench), esc(d0), esc(d1)
      printf "\"findings\":{\"high\":%d,\"medium\":%d,\"low\":%d,\"info\":%d,\"reasoned_high_medium\":%d},\"gate\":%s,", H, M, L, I, g[6], esc(gate)
      printf "\"cost\":{\"tokens\":%s,\"minutes\":%s,\"files_read\":%s,\"tests_written\":%s},\"report\":%s,\"raw_confidence\":%s}\n", tok(t), num(mi), num(fr), num(tw), esc(report), conf
    }
    END { exit nbad ? 1 : 0 }
  ' "$2"
  exit $?
fi

# ------------------------------------------------------------------------------------------------ the writer
LOG="${1:-}"; shift || true
case "$LOG" in "" | --*) refuse "the first argument is the LOG.md to append to (or --json <LOG.md>).";; esac
[ -f "$LOG" ] || refuse "$LOG does not exist. The state convention installs LOG.md first (state/README.md); this script does not create it."

id="" phase="" type="" model="" bench="" dates="" high="" medium="" low="" info="" reasoned="" gate=""
tokens="" minutes="" files_read="" tests_written="" report="" conf="" dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift; continue ;;
    --id | --phase | --type | --model | --bench | --dates | --high | --medium | --low | --info | --reasoned | --gate | \
      --tokens | --minutes | --files-read | --tests-written | --report | --conf)
      [ $# -ge 2 ] || refuse "$1 has no value."
      case "$1" in
        --id) id="$2" ;; --phase) phase="$2" ;; --type) type="$2" ;; --model) model="$2" ;; --bench) bench="$2" ;;
        --dates) dates="$2" ;; --high) high="$2" ;; --medium) medium="$2" ;; --low) low="$2" ;; --info) info="$2" ;;
        --reasoned) reasoned="$2" ;; --gate) gate="$2" ;; --tokens) tokens="$2" ;; --minutes) minutes="$2" ;;
        --files-read) files_read="$2" ;; --tests-written) tests_written="$2" ;; --report) report="$2" ;; --conf) conf="$2" ;;
      esac
      shift 2 ;;
    *) refuse "unknown argument '$1'." ;;
  esac
done

is_count() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; }
text_ok() { # a field of the line: not empty, no separator, no control character (a newline would split the line)
  [ -n "$2" ] || refuse "--$1 is required."
  case "$2" in *"|"*) refuse "--$1 contains '|', the field separator: '$2'." ;; esac
  # grep reads lines, so it never sees a newline: that one is looked for by name
  case "$2" in *$'\n'*) refuse "--$1 contains a newline." ;; esac
  if printf '%s' "$2" | LC_ALL=C grep -q '[[:cntrl:]]'; then refuse "--$1 contains a control character (a tab, a CR?)."; fi
  case "$2" in " "* | *" ") refuse "--$1 starts or ends with a space: '$2'." ;; esac
}
iso_day() { # a real calendar day, YYYY-MM-DD
  local y m d max
  printf '%s' "$1" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || return 1
  y=$((10#${1:0:4})); m=$((10#${1:5:2})); d=$((10#${1:8:2}))
  case "$m" in 1 | 3 | 5 | 7 | 8 | 10 | 12) max=31 ;; 4 | 6 | 9 | 11) max=30 ;;
    2) if [ $((y % 4)) -eq 0 ] && { [ $((y % 100)) -ne 0 ] || [ $((y % 400)) -eq 0 ]; }; then max=29; else max=28; fi ;;
    *) return 1 ;; esac
  [ "$d" -ge 1 ] && [ "$d" -le "$max" ]
}

text_ok id "$id"
printf '%s' "$id" | grep -Eq '^[A-Za-z0-9._-]+$' || refuse "--id is letters, digits, '.', '_' and '-' only (got '$id')."
case "$phase" in [0-8]) ;; *) refuse "--phase is a whole number from 0 to 8 (got '$phase')." ;; esac
case " $TYPES " in *" $type "*) [ -n "$type" ] || refuse "--type is required." ;;
  *) refuse "--type '$type' is not on the fixed list: $TYPES." ;; esac
text_ok model "$model"; text_ok bench "$bench"; text_ok report "$report"
case "$dates" in
  *..*) d0="${dates%%..*}"; d1="${dates#*..}"
        if ! iso_day "$d0" || ! iso_day "$d1"; then refuse "--dates must be YYYY-MM-DD..YYYY-MM-DD, real days, both in full (got '$dates')."; fi
        if [ "$d1" \< "$d0" ]; then refuse "--dates ends before it starts ('$dates')."; fi ;;
  *) iso_day "$dates" || refuse "--dates must be YYYY-MM-DD or YYYY-MM-DD..YYYY-MM-DD, a real day (got '$dates')." ;;
esac
for pair in "high:$high" "medium:$medium" "low:$low" "info:$info" "reasoned:$reasoned"; do
  is_count "${pair#*:}" || refuse "--${pair%%:*} is a whole number of findings, required (got '${pair#*:}')."
done
case "$gate" in pass | fail) ;; *) refuse "--gate is pass or fail (got '$gate')." ;; esac
if [ -n "$tokens" ]; then printf '%s' "$tokens" | grep -Eq '^[0-9]+[kM]?$' || refuse "--tokens is a whole number, optionally with k or M (got '$tokens')."; fi
for pair in "minutes:$minutes" "files-read:$files_read" "tests-written:$tests_written"; do
  [ -z "${pair#*:}" ] || is_count "${pair#*:}" || refuse "--${pair%%:*} is a whole number when given (got '${pair#*:}')."
done
if [ -n "$conf" ]; then printf '%s' "$conf" | grep -Eq '^(0(\.[0-9]+)?|1(\.0+)?)$' || refuse "--conf is a number from 0 to 1, e.g. 0.7 (got '$conf')."; fi
if grep -Eq "^ROUND $(printf '%s' "$id" | sed 's/[.]/\\./g') \|" "$LOG"; then refuse "$LOG already has a ROUND line for '$id'."; fi

cost=""
add() { cost="${cost:+$cost, }$1"; }
[ -n "$tokens" ] && add "$tokens tokens"; [ -n "$minutes" ] && add "$minutes min"
[ -n "$files_read" ] && add "$files_read files read"; [ -n "$tests_written" ] && add "$tests_written tests written"
[ -n "$cost" ] || cost="cost not measured"
line="ROUND $id | phase $phase | $type | $model | bench $bench | $dates | ${high}H ${medium}M ${low}L ${info}I reasoned $reasoned | gate $gate | $cost | $report${conf:+ | conf $conf}"

if [ "$dry" = "1" ]; then printf '%s\n' "$line"; exit 0; fi
# its own paragraph: a blank line before it unless the file already ends in one
if [ -s "$LOG" ] && [ -n "$(tail -c 1 "$LOG")" ]; then printf '\n' >> "$LOG"; fi
if [ -s "$LOG" ] && [ -n "$(tail -n 1 "$LOG")" ]; then printf '\n' >> "$LOG"; fi
printf '%s\n' "$line" >> "$LOG" || { echo "round: could not write to $LOG." >&2; exit 2; }
printf '%s\n' "$line"
echo "round: appended to $LOG. Write the entry's body under it (state/README.md)."
