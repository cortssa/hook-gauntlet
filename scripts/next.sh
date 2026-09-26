#!/usr/bin/env bash
#
# next.sh - read STATE.md's flag block and name the row of doctrine/NEXT.md that comes next.
#
# The problem it solves: NEXT.md calls its table computable, and every agent walked its rows by hand. A mistyped enum
# (`battery: gren`) went unnoticed and was read as whatever the reader guessed; a flag left out was read as its default;
# and a gap in the table was only ever found by a reviewer. So the flags are parsed here, each one checked, and a block
# that is not of NEXT.md's shape is REFUSED before any row is read. Then the rows are evaluated top to bottom.
#
# What the flags cannot decide is not guessed. A row whose condition needs something STATE.md does not carry (a fuzzer's
# report, what the owner wants, whether the spec's promises changed) is printed as "needs judgement: row <id> - <the
# question>", and the evaluation goes on to the first row the flags alone make true, printed as the answer ONLY IF every
# row needing judgement above it is false (exit 3). The agent answers with --judge, and the answers are echoed in the
# output, so the judgement is on the record, not in anyone's head. Rows that need judgement: 1 (when a high or a pending
# finding is open), 3, 5, 8, 9 and 9b (a finding open, once round 1 has run or the ceiling is reached), 10 (after a
# round, with no bytecode change since), 11b, 12, 16, 18b.
#
# The rows are DATA (the ROWS table below): a new row of NEXT.md is one line here, not new parser code. The action a row
# prints is read from NEXT.md itself, as NEXT.md words it. And every run checks the two against each other (the drift
# guard): the same rows - every row under NEXT.md's "## The table", whatever the form of its id (12, 12b, 12a) - in the
# same order, and each row's condition cell the text its entry here was written from (the entry keeps a hash of the
# cell, whitespace normalised; --check-table prints the new one). A row added to NEXT.md with no line here, the reverse,
# another order, or a condition reworded without its entry being re-read, is a refusal naming the row. And inside the
# table every non-blank line must be a row ("|" at column 0, four cells): an indented row, a row without its leading "|"
# (Markdown shows both in the table) or a line of prose there is a refusal naming the line - no row can hide.
#
# NEXT.md says, and this script does:
#   - rows 2 and 14 are GATES, not stops. A gate that is true is printed "in force", the rows it names are off wherever
#     they stand, and the reading goes on: row 2 (the ceiling is reached) turns off every model row - 11, 11b (a retry
#     is a model round), 12, 13, 13b, 15; row 14 (the loop is over) turns off 11, 12, 13, 13b - not 11b: a stopped
#     round, the closing black-box included, still gets its one retry - and the next row that can apply is 15;
#   - at the ceiling the black-box is a model round like any other, so it does not run: with row 2 in force, rows 16 and
#     18b also take `blackbox: never_run` or `stale` (the dossier then says "black-box: not run - ceiling reached");
#   - rehearsal (row 17) is the `rehearsal:` flag: promoted and `not yet` is 17; promoted and `n/a` or `done` is 18;
#   - row 7b is off while `waiting_on_owner` names `RPC_URL` or `chain` (an item that contains `RPC_URL`, or the word
#     `chain`, anywhere in it): its action waits on the owner, so row 3 skips it;
#   - rows 12 and 16 are off while 7b is owed (`real_manager_battery` `never` or `stale` - the chain is known - and no
#     `real manager:` note); when 7b is silenced by the wait and no other row stands, row 3 is given, as NEXT.md's row 3
#     says: it stops and says what is waiting (an answer 3=false does not make the rows the wait turned off stand);
#   - rows 9 and 9b count every open finding, from any round - a phase-3 `pending:` one too, once round 1 has run; before
#     round 1 (`last_audit_round: none`) they are off, pending findings ride into round 1 - unless the ceiling is reached
#     (row 2: round 1 will not run, every open finding goes to 9 or 9b);
#   - `blackbox: stopped (<round id>)` (a black-box round stopped twice, row 11b): rows 12 and 15 do not fire on it, rows
#     16 and 18b take it;
#   - a note is read by its name only at the START of a note item (a note line, or a part of one after the middle dot
#     or ";"): `pending: <id>` for row 1, `real manager:` for row 7b;
#   - rows 13b and 14 count a finding against "closed with 0 high and 0 medium" only while it is OPEN in `open_findings`
#     (one accepted by the owner, refused in writing or handed to the human audit by name does not): the terms are
#     `open_findings.high=0 open_findings.medium=0`, not the round's own counts;
#   - row 18b is either mode: the owner declined promotion in writing (light mode by default) - a judgement.
# Readings of NEXT.md this script makes, each from NEXT.md's own words: `phase` advances only when a phase's gate is met,
# so rows 4 and 4b are `phase` 0-1 and 2-3; "promoted" is `last_promotion=no` (`yes` = changed since, no longer promoted;
# `n/a` = never promoted); "the loop is over" (rows 15-18b) is row 14's condition; a finding from outside the fuzzer
# (row 8) comes from a round, so row 8 is false before any round has run.
#
# Usage:   scripts/next.sh [STATE.md] [--judge <row>=true|false[,<row>=true|false...]]... [--table <NEXT.md>]
#          scripts/next.sh --check-table [<NEXT.md>]     the drift guard alone
#   STATE.md defaults to .gauntlet/STATE.md, then ./STATE.md. --table defaults to the kit's doctrine/NEXT.md.
#   --judge answers a row that needs judgement: `true` makes it true (it is then given, if it is the first), `false`
#   passes it. Row 3 (waiting on the owner): answer each row below that depends on the owner's answer `false`, and 3
#   itself `false` once nothing left depends on it - or `true` when nothing below stands, and stop.
# Output:  zero or more "in force: row <2|14> - ..." and "needs judgement: row <id> - <question>" lines,
#          then "next: row <id> - <the action, as NEXT.md words it>" and "because: <the flags that made it true>".
# Exit:    0 the row given is the first true one; 1 no row is true: the table has a hole or a flag is stale (NEXT.md's
#          STOP rule); 2 REFUSED - a flag missing, of an unknown value, a malformed line, a bad --judge, or the table and
#          NEXT.md disagree: one line on stderr naming what; 3 a row above the one given needs judgement (named).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TABLE="$HERE/../doctrine/NEXT.md"

refuse() { echo "next: REFUSED - $*" >&2; exit 2; }

# ------------------------------------------------------------------------------------------------ the rows, as data
# id | NEXT.md hash | kind | turns off | condition | the question, when the flags cannot decide the row ("-": they can)
#   NEXT.md hash: of the row's condition cell in NEXT.md (whitespace normalised; cksum's CRC, 8 hex digits) as it read
#   when this entry was written. When the cell changes, the drift guard refuses and --check-table prints the new hash:
#   re-read the row, make the entry say what it now says, then paste the hash - never the hash alone.
#   kind: act (a destination) | gate (rows 2 and 14: when its condition is true it is printed "in force", the rows in
#   "turns off" are false wherever they stand - above it or below - and the reading goes on). A gate needs no judgement.
#   condition: groups separated by " ; " (any group true), terms in a group separated by spaces (all true). A term is
#   <name>=<v>[,<v>...] (one of) | <name>!=<v> | <name>><n> (a number above n) | row:<id> (that row's condition) | -
#   (always). Names: the flags of STATE.md, and the parts parse_state below derives from them.
ROWS='
0   | 8591339f | act  | -                   | phase=sketch | -
1   | 1b0ac5fe | act  | -                   | open_findings.high>0 ; notes.pending=yes | does a high finding reproduce (open_findings high, or a provisional high on a pending: note) that the owner has not been told of?
2   | 64c00456 | gate | 11,11b,12,13,13b,15 | ceiling=reached | -
3   | 8949c656 | act  | -                   | waiting_on_owner!=none | does nothing below stand without the owner'"'"'s answer ({waiting_on_owner})? Answer false each row below that depends on it, and 3=false once none left does
4   | a019d2cf | act  | -                   | phase=0,1 | -
4b  | 2473e53b | act  | -                   | phase=2,3 | -
5   | 2a2d739a | act  | -                   | - | has the fuzzer reported a violation of a promise that is not yet a deterministic test?
6   | cebb3ad7 | act  | -                   | bytecode_changed_since.last_battery=yes ; battery=never | -
6b  | 021321a6 | act  | -                   | battery=red | -
7   | c644f4bc | act  | -                   | bytecode_changed_since.last_long_fuzz=yes battery=green ; bytecode_changed_since.last_other_free_judges=yes battery=green | -
7b  | cd03dc26 | act  | -                   | real_manager.owed=yes waiting_on_owner.real_manager=no | -
8   | c328f377 | act  | -                   | any_round=yes | is there an ACCEPTED or FIXED finding (triaged in row 9) from outside the fuzzer with no rule for it yet (an invariant or action, or a unit test and a not fuzzable: note)?
9   | 5608652c | act  | -                   | last_audit_round!=none open_findings.total>0 ; ceiling=reached open_findings.total>0 | is a finding from any round still open (not fixed, refused in writing, accepted by the owner with a number, or handed to the human audit by name - one triaged fix at the cause whose fix is not written yet is still open; a phase-3 pending: finding is one too, now that round 1 has run or the ceiling is reached), and is the owner there to answer, or is it already triaged fix at the cause?
9b  | 9ccc797e | act  | -                   | last_audit_round!=none open_findings.total>0 ; ceiling=reached open_findings.total>0 | do open findings from any round (a phase-3 pending: finding too, now that round 1 has run or the ceiling is reached) wait on the owner'"'"'s triage while the owner is not available?
10  | 75485129 | act  | -                   | any_round=yes bytecode_changed_since.last_audit_round=no | did only documents, comments, scripts or tests change since the last round, making claims about the code?
11b | 39b95289 | act  | -                   | - | was a model round STOPPED by the environment (the harness, the provider'"'"'s classifier) before delivering, and not yet retried - or stopped again, and not yet recorded (notes: round <id> stopped; a black-box round also blackbox: stopped (<id>))?
11  | 29326122 | act  | -                   | last_audit_round=none battery=green | -
12  | dd66e624 | act  | -                   | last_audit_round!=none battery=green blackbox=never_run real_manager.owed=no | did the spec'"'"'s promises stay unchanged in the last triage (no triage yet counts as unchanged)?
13  | 78bc1c8a | act  | -                   | last_audit_round!=none bytecode_changed_since.last_audit_round=yes battery=green | -
13b | 76200526 | act  | -                   | last_audit_round.type=regression open_findings.high=0 open_findings.medium=0 ; last_audit_round!=none open_findings.reasoned_high_or_medium>0 | -
14  | b21af050 | gate | 11,12,13,13b        | last_audit_round.type=discovery open_findings.high=0 open_findings.medium=0 open_findings.reasoned_high_or_medium=0 bytecode_changed_since.last_audit_round=no ; ceiling=reached open_findings.total=0 | -
15  | d7de1684 | act  | -                   | row:14 blackbox=stale,never_run | -
16  | 3d8c630f | act  | -                   | row:14 blackbox=current,skipped_by_owner,stopped bytecode_changed_since.last_promotion=n/a,yes real_manager.owed=no ; row:2 row:14 blackbox=never_run,stale bytecode_changed_since.last_promotion=n/a,yes real_manager.owed=no | does the owner want to freeze a release candidate?
17  | 496e473f | act  | -                   | bytecode_changed_since.last_promotion=no rehearsal=not_yet | -
18  | da261889 | act  | -                   | bytecode_changed_since.last_promotion=no rehearsal=n/a,done | -
18b | c2bb2b6a | act  | -                   | row:14 blackbox=current,skipped_by_owner,stopped ; row:2 row:14 blackbox=never_run,stale | did the owner decline promotion in writing (light mode by default, COST.md; full mode by the owner'"'"'s own written decision)?
'

declare -a IDS=()
declare -A HASH=() KIND=() OFFS=() COND=() ASK=()
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
while IFS='|' read -r c_id c_hash c_kind c_off c_cond c_ask; do
  c_id="$(trim "$c_id")"; [ -n "$c_id" ] || continue
  IDS+=("$c_id"); HASH[$c_id]="$(trim "$c_hash")"; KIND[$c_id]="$(trim "$c_kind")"; OFFS[$c_id]="$(trim "$c_off")"
  COND[$c_id]="$(trim "$c_cond")"; ASK[$c_id]="$(trim "$c_ask")"
done <<< "$ROWS"
for c_id in "${IDS[@]}"; do   # the row data's own shape: a bug here is refused, never half-read
  [[ ${HASH[$c_id]} =~ ^[0-9a-f]{8}$ ]] || refuse "next.sh's row data: row $c_id has no NEXT.md hash of 8 hex digits (a bug in ROWS)."
  case "${KIND[$c_id]}:${OFFS[$c_id]}" in
    act:-) ;;
    gate:-) refuse "next.sh's row data: gate $c_id turns no row off (a bug in ROWS)." ;;
    gate:*) [ "${ASK[$c_id]}" = "-" ] || refuse "next.sh's row data: gate $c_id needs judgement; a gate must not (a bug in ROWS)."
      for c_x in ${OFFS[$c_id]//,/ }; do
        [ -n "${KIND[$c_x]+x}" ] || refuse "next.sh's row data: gate $c_id turns off row $c_x, which it does not have (a bug in ROWS)."
      done ;;
    *) refuse "next.sh's row data: row $c_id is '${KIND[$c_id]}' turning off '${OFFS[$c_id]}' (a bug in ROWS)." ;;
  esac
done

# ------------------------------------------------------------------------------------------------ NEXT.md's table
# table_rows <NEXT.md>: "id US action US condition" (US: the unit separator, \037) per row of the table under "## The
# table", in order - every row, whatever the form of its id; the condition with its whitespace normalised. The table
# runs from the first line under the heading that starts with "|" to the first blank line, and inside it EVERY line must
# be a row: "|" at column 0 and four cells. One that is not (indented, no leading "|" - Markdown shows both in the
# table -, a line of prose, a "|" inside a cell, no id) is printed "BAD US <line number> US <the line>": refused, never
# half-read, never skipped. A "|" line under the heading after the table has ended is read as a row too.
table_rows() {
  LC_ALL=C awk '
    { sub(/\r$/, "") }
    /^## / { intable = ($0 ~ /^## The table/); started = 0; ended = 0; next }
    !intable { next }
    !started && /^\|/ { started = 1 }
    !started { next }
    !ended && /^[ \t]*$/ { ended = 1; next }
    ended && !/^\|/ { next }
    {
      line = $0; n = gsub(/[|]/, "|", line)
      if ($0 ~ /^\|[-:| ]+$/ && n == 5) next
      split($0, c, /[|]/); id = c[2]; gsub(/^[ \t]+|[ \t]+$/, "", id)
      if ($0 !~ /^\|/ || n != 5 || id == "" || id ~ /[ \t]/) { print "BAD\037" NR "\037" $0; next }
      if (id == "#") next
      act = c[4]; gsub(/^[ \t]+|[ \t]+$/, "", act)
      cond = c[3]; gsub(/[ \t]+/, " ", cond); gsub(/^ | $/, "", cond)
      print id "\037" act "\037" cond
    }' "$1"
}
cell_hash() { local c; c="$(printf '%s' "$1" | cksum)"; printf '%08x' "${c%%[[:space:]]*}"; }   # POSIX cksum: the same CRC everywhere
declare -A ACTION=() CELL=()
load_table() { # load_table <NEXT.md>: fills ACTION, and refuses when its rows and ROWS disagree (the drift guard)
  local f="$1" id act cond ours theirs="" x changed=""
  [ -f "$f" ] || refuse "no decision table at $f (doctrine/NEXT.md)."
  while IFS=$'\037' read -r id act cond; do
    [ "$id" = "BAD" ] && refuse "$f line $act is inside the table but is not a row of it (a '|' at column 0 and four cells, an id; a '|' inside a cell?): '$cond'."
    [ -z "${ACTION[$id]+x}" ] || refuse "$f has row $id twice."
    ACTION[$id]="$act"; CELL[$id]="$(cell_hash "$cond")"; theirs="${theirs:+$theirs }$id"
  done < <(table_rows "$f")
  [ -n "$theirs" ] || refuse "$f has no rows under '## The table'."
  ours="${IDS[*]}"
  if [ "$ours" != "$theirs" ]; then
    for x in $theirs; do [ -n "${KIND[$x]+x}" ] || refuse "drift: $f has row $x, and next.sh has no entry for it (add one to ROWS)."; done
    for x in $ours; do [ -n "${ACTION[$x]+x}" ] || refuse "drift: next.sh has an entry for row $x, and $f has no row $x."; done
    refuse "drift: $f and next.sh name the same rows in another order ($theirs / $ours)."
  fi
  for x in $ours; do
    [ "${HASH[$x]}" = "${CELL[$x]}" ] && continue
    changed="${changed:+$changed, }$x"
    if [ "$check_only" = 1 ]; then
      echo "row $x: its condition in $f is not the text next.sh's entry was written from - re-read the row, make its ROWS entry say the same, then paste its new hash ${CELL[$x]} over ${HASH[$x]}"
    fi
  done
  [ -z "$changed" ] || refuse "drift: the condition of row $changed in $f changed since next.sh's entry was written from it (ROWS keeps a hash of each cell; scripts/next.sh --check-table prints the new one, to paste once the entry says the same)."
}

# ------------------------------------------------------------------------------------------------ STATE.md's flags
FLAGS="phase bytecode_changed_since battery blackbox open_findings last_audit_round last_other_round ceiling real_manager_battery waiting_on_owner location dossier rehearsal notes"
declare -A RAW=() V=()
declare -a NOTE_LINES=()

# enum <flag> <allowed...>: the value's first word is one of them, and anything after it is a comment in parentheses
enum() {
  local f="$1" v first rest; shift
  v="${RAW[$f]}"; first="${v%%[[:space:]]*}"; rest="$(trim "${v#"$first"}")"
  case " $* " in *" $first "*) ;; *) refuse "$f: '$first' is not one of: $*." ;; esac
  case "$rest" in "" | "("*) ;; *) refuse "$f: after '$first' only a comment in parentheses may follow (got '$rest')." ;; esac
  V[$f]="$first"
}
# pairs <flag> <value regex> <what a value is> <key...>: every key exactly once as key=value, then optionally a comment
# in parentheses
pairs() {
  local f="$1" re="$2" what="$3" w k val; shift 3
  local -a words
  local -A seen=()
  read -ra words <<< "${RAW[$f]}"
  for w in "${words[@]}"; do
    case "$w" in "("*) break ;; esac
    k="${w%%=*}"; val="${w#*=}"
    case "$w" in *=*) ;; *) refuse "$f: '$w' is not key=value (keys: $*)." ;; esac
    case " $* " in *" $k "*) ;; *) refuse "$f: '$k' is not one of its keys: $*." ;; esac
    [ -z "${seen[$k]+x}" ] || refuse "$f: $k= is given twice."
    [[ $val =~ $re ]] || refuse "$f: $k='$val' is not $what."
    seen[$k]=1; V[$f.$k]="$val"
  done
  for k in "$@"; do [ -n "${seen[$k]+x}" ] || refuse "$f: $k= is missing."; done
}

parse_state() {
  local st="$1" block line n=0 name val prev=""
  block="$(LC_ALL=C awk '
    { sub(/\r$/, "") }
    /^```/ { if (inb && has) { found = 1; exit } inb = !inb; n = 0; has = 0; next }
    inb { buf[++n] = $0; if ($0 ~ /^phase:/) has = 1 }
    END { if (!found) exit 1; for (i = 1; i <= n; i++) print buf[i] }' "$st")" \
    || refuse "$st has no flag block (a fenced block with a 'phase:' line, doctrine/NEXT.md)."
  while IFS= read -r line; do
    n=$((n + 1))
    [ -n "$(trim "$line")" ] || continue
    if [[ $line =~ ^([a-z_]+):(.*)$ ]]; then
      name="${BASH_REMATCH[1]}"; val="$(trim "${BASH_REMATCH[2]}")"
      case " $FLAGS " in *" $name "*) ;; *) refuse "unknown flag '$name' (line $n of the flag block; the flags: $FLAGS)." ;; esac
      [ -z "${RAW[$name]+x}" ] || refuse "flag '$name' appears twice in the flag block."
      RAW[$name]="$val"; prev="$name"
      [ "$name" != notes ] || [ -z "$val" ] || NOTE_LINES+=("$val")
    elif [[ $line =~ ^[[:space:]] ]] && [ "$prev" = "notes" ]; then
      RAW[notes]="${RAW[notes]} $(trim "$line")"   # notes: may run on over indented lines, each a note line
      NOTE_LINES+=("$(trim "$line")")
    else
      refuse "line $n of the flag block is not 'name: value': '$line'."
    fi
  done <<< "$block"
  for name in $FLAGS; do
    [ -n "${RAW[$name]+x}" ] || refuse "flag '$name' is missing from the flag block (doctrine/NEXT.md lists the flags)."
    [ "$name" = "notes" ] || [ -n "${RAW[$name]}" ] || refuse "flag '$name' has no value."
  done

  enum phase sketch 0 1 2 3 4 5 6 7 8
  pairs bytecode_changed_since '^(yes|no|n/a)$' "yes or no (n/a: last_promotion only)" \
    last_battery last_long_fuzz last_other_free_judges last_audit_round last_promotion
  for name in last_battery last_long_fuzz last_other_free_judges last_audit_round; do
    [ "${V[bytecode_changed_since.$name]}" != "n/a" ] || refuse "bytecode_changed_since: $name='n/a' is not yes or no (n/a: last_promotion only)."
  done
  enum battery never green red
  val="${RAW[blackbox]}"   # stopped (<round id>): a black-box round the environment stopped twice (row 11b)
  if [[ $val =~ ^stopped([^A-Za-z0-9_]|$) ]]; then
    local re_stop='^stopped[[:space:]]+[(][A-Za-z0-9][A-Za-z0-9._-]*([,;[:space:]][^()]*)?[)]$'
    [[ $val =~ $re_stop ]] \
      || refuse "blackbox: '$val' is not stopped (<round id>): the id of the black-box round stopped twice (row 11b), in parentheses."
    V[blackbox]=stopped
  else
    enum blackbox never_run current stale skipped_by_owner stopped
  fi
  pairs open_findings '^[0-9]+$' "a whole number" high medium low reasoned_high_or_medium
  local h="${V[open_findings.high]}" m="${V[open_findings.medium]}" l="${V[open_findings.low]}" r="${V[open_findings.reasoned_high_or_medium]}"
  V[open_findings.total]=$((10#$h + 10#$m + 10#$l))
  [ $((10#$r)) -le $((10#$h + 10#$m)) ] \
    || refuse "open_findings: reasoned_high_or_medium=$r is more than high+medium open ($((10#$h + 10#$m))): a REASONED finding is one of them."

  local re_type='^[A-Za-z0-9._-]+,?[[:space:]]+([a-z-]+)(,|[[:space:]]|$)'
  local re_audit='^([A-Za-z0-9._-]+),?[[:space:]]+([a-z-]+),?[[:space:]]+([0-9]+)H[[:space:]]+([0-9]+)M[[:space:]]+([0-9]+)L([[:space:]].*)?$'
  val="${RAW[last_audit_round]}"
  if [[ $val =~ $re_type ]] && [ "$val" != none ]; then
    case "${BASH_REMATCH[1]}" in discovery | regression) ;;
      *) refuse "last_audit_round: '${BASH_REMATCH[1]}' is not discovery or regression (black-box and verifier rounds go in last_other_round)." ;; esac
  fi
  if [[ $val =~ ^none([[:space:]]+\(.*)?$ ]]; then
    V[last_audit_round]=none; V[last_audit_round.type]=none; V[last_audit_round.high]=0; V[last_audit_round.medium]=0
  elif [[ $val =~ $re_audit ]]; then
    V[last_audit_round]="${BASH_REMATCH[1]}"; V[last_audit_round.type]="${BASH_REMATCH[2]}"
    V[last_audit_round.high]="${BASH_REMATCH[3]}"; V[last_audit_round.medium]="${BASH_REMATCH[4]}"
  else
    refuse "last_audit_round: '$val' is neither 'none' nor '<id> discovery|regression <n>H <n>M <n>L' (e.g. r06 regression 0H 1M 3L)."
  fi
  local re_other='^([A-Za-z0-9._-]+),?[[:space:]]+([a-z-]+)(,|[[:space:]]|$)'
  val="${RAW[last_other_round]}"
  if [[ $val =~ ^none([[:space:]]+\(.*)?$ ]]; then V[last_other_round]=none
  elif [[ $val =~ $re_other ]]; then
    case "${BASH_REMATCH[2]}" in black-box | verifier) V[last_other_round]="${BASH_REMATCH[1]}" ;;
      *) refuse "last_other_round: '${BASH_REMATCH[2]}' is not black-box or verifier (discovery and regression rounds go in last_audit_round)." ;; esac
  else
    refuse "last_other_round: '$val' is neither 'none' nor '<id> black-box|verifier <result>'."
  fi
  V[any_round]=no
  if [ "${V[last_audit_round]}" != none ] || [ "${V[last_other_round]}" != none ]; then V[any_round]=yes; fi

  local re_ceil='^([0-9]+)[^;]*;[[:space:]]*([0-9]+)[[:space:]]+used'
  val="${RAW[ceiling]}"
  if [[ $val =~ ^not\ agreed ]]; then V[ceiling]=not_agreed
  elif [[ $val =~ ^undecided ]]; then V[ceiling]=undecided
  elif [[ $val =~ $re_ceil ]]; then
    if [ "${BASH_REMATCH[2]}" -ge "${BASH_REMATCH[1]}" ]; then V[ceiling]=reached; else V[ceiling]=open; fi
    CEIL_SHOW="${BASH_REMATCH[2]} of ${BASH_REMATCH[1]} used"
  else
    refuse "flag 'ceiling': '$val' is none of 'not agreed ...', 'undecided ...', '<N> model rounds ...; <M> used'."
  fi

  enum real_manager_battery n/a never stale current
  val="${RAW[waiting_on_owner]}"
  if [[ $val =~ ^none([[:space:]]+\(.*)?$ ]]; then V[waiting_on_owner]=none; else V[waiting_on_owner]="$val"; fi
  # row 7b's own question waits on the owner when an item of waiting_on_owner (items: separated by ";" or the middle dot
  # NEXT.md uses) names RPC_URL or chain: contains RPC_URL, or the word chain (any case), anywhere in the item
  local item; local -a items=()
  V[waiting_on_owner.real_manager]=no
  if [ "${V[waiting_on_owner]}" != none ]; then
    IFS=';' read -ra items <<< "${val//$'\302\267'/;}"
    for item in "${items[@]}"; do
      case "$item" in *RPC_URL*) V[waiting_on_owner.real_manager]=yes ;; esac
      [[ ${item,,} =~ (^|[^a-z0-9_])chain([^a-z0-9_]|$) ]] && V[waiting_on_owner.real_manager]=yes
    done
  fi
  enum location .gauntlet/ root
  enum dossier none skeleton complete
  local re_na='^n/a([[:space:]]+[(].*[)])?$' re_ny='^not yet([[:space:]]+[(].*[)])?$'
  local re_done='^done[[:space:]]+[(]([0-9]{4})-([0-9]{2})-([0-9]{2})[)]$'
  val="${RAW[rehearsal]}"
  if [[ $val =~ $re_na ]]; then V[rehearsal]=n/a
  elif [[ $val =~ $re_ny ]]; then V[rehearsal]=not_yet
  elif [[ $val =~ $re_done ]] && real_date "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"; then V[rehearsal]="done"
  else refuse "rehearsal: '$val' is not one of: n/a (no runbook) | not yet | done (YYYY-MM-DD), a real date."; fi
  # a note is read by its name only at the START of a note item: a note line (the value of notes:, or an indented line
  # under it), or a part of one after the middle dot or ";" - never where the words merely appear
  V[notes.pending]=no; V[notes.real_manager]=no
  for line in "${NOTE_LINES[@]}"; do
    IFS=';' read -ra items <<< "${line//$'\302\267'/;}"
    for item in "${items[@]}"; do
      item="$(trim "$item")"
      [[ $item =~ ^pending:[[:space:]]+[A-Za-z0-9][A-Za-z0-9._-]*([[:space:]]|$) ]] && V[notes.pending]=yes   # row 1
      [[ $item =~ ^real\ manager: ]] && V[notes.real_manager]=yes                                            # row 7b
    done
  done
  # row 7b is owed (and rows 12 and 16 wait on it): the chain is known, the real-manager battery never ran or is stale,
  # and no real manager: note says what replaced it
  V[real_manager.owed]=no
  case "${V[real_manager_battery]}" in never | stale) [ "${V[notes.real_manager]}" = yes ] || V[real_manager.owed]=yes ;; esac
}
real_date() { # real_date <YYYY> <MM> <DD>: 0 when it is a day of the calendar
  local y=$((10#$1)) mo=$((10#$2)) d=$((10#$3)) last=31
  [ "$mo" -ge 1 ] && [ "$mo" -le 12 ] || return 1
  case "$mo" in
    4 | 6 | 9 | 11) last=30 ;;
    2) last=28; if [ $((y % 4)) = 0 ] && { [ $((y % 100)) != 0 ] || [ $((y % 400)) = 0 ]; }; then last=29; fi ;;
  esac
  [ "$d" -ge 1 ] && [ "$d" -le "$last" ]
}

# ------------------------------------------------------------------------------------------------ evaluating a row
CEIL_SHOW=""
show() { # show <name>: name=value, as the because: line prints it
  if [ "$1" = ceiling ] && [ -n "$CEIL_SHOW" ]; then printf 'ceiling=%s (%s)' "${V[ceiling]}" "$CEIL_SHOW"
  else printf '%s=%s' "$1" "${V[$1]}"; fi
}
have() { [ -n "${V[$1]+x}" ] || refuse "next.sh's row data names '$1', which is not a flag it reads (a bug in ROWS)."; }
TERM_SHOW="" COND_WHY=""
term_true() {
  local t="$1" k v
  case "$t" in
    row:*)
      k="${t#row:}"; [ -n "${COND[$k]+x}" ] || refuse "next.sh's row data names row $k, which it does not have."
      cond_true "${COND[$k]}" || return 1
      TERM_SHOW="row $k [$COND_WHY]" ;;
    *'!='*) k="${t%%!=*}"; v="${t#*!=}"; have "$k"; TERM_SHOW="$(show "$k")"; [ "${V[$k]}" != "$v" ] ;;
    *'>'*) k="${t%%>*}"; v="${t#*>}"; have "$k"; TERM_SHOW="$(show "$k")"; [ "${V[$k]}" -gt "$v" ] ;;
    *=*) k="${t%%=*}"; v="${t#*=}"; have "$k"; TERM_SHOW="$(show "$k")"
      case ",$v," in *",${V[$k]},"*) return 0 ;; *) return 1 ;; esac ;;
    *) refuse "next.sh's row data has a term it cannot read: '$t' (a bug in ROWS)." ;;
  esac
}
cond_true() { # cond_true <condition>: 0 when one group holds; COND_WHY is that group's terms with their values
  local cond="$1" group t why ok
  local -a groups terms
  if [ "$cond" = "-" ]; then COND_WHY=""; return 0; fi
  IFS=';' read -ra groups <<< "$cond"
  for group in "${groups[@]}"; do
    read -ra terms <<< "$group"; ok=1; why=""
    for t in "${terms[@]}"; do
      if term_true "$t"; then why="${why:+$why }$TERM_SHOW"; else ok=0; break; fi
    done
    if [ "$ok" = 1 ]; then COND_WHY="$why"; return 0; fi
  done
  return 1
}

# ------------------------------------------------------------------------------------------------ arguments
STATE="" JUDGED="" check_only=0
declare -A JUDGE=()
while [ $# -gt 0 ]; do
  case "$1" in
    --check-table) check_only=1; [ $# -ge 2 ] && { TABLE="$2"; shift; }; shift ;;
    --table) [ $# -ge 2 ] || refuse "--table has no value."; TABLE="$2"; shift 2 ;;
    --judge) [ $# -ge 2 ] || refuse "--judge has no value (<row>=true|false[,...])."; JUDGED="${JUDGED:+$JUDGED,}$2"; shift 2 ;;
    -*) refuse "unknown argument '$1'." ;;
    *) [ -z "$STATE" ] || refuse "one STATE.md only (got '$STATE' and '$1')."; STATE="$1"; shift ;;
  esac
done

load_table "$TABLE"
if [ "$check_only" = 1 ]; then echo "next: next.sh's rows and $TABLE agree: ${#IDS[@]} rows, ${IDS[*]}."; exit 0; fi

IFS=',' read -ra answers <<< "$JUDGED"
for a in "${answers[@]}"; do
  k="${a%%=*}"; v="${a#*=}"
  case "$a" in *=*) ;; *) refuse "--judge '$a' is not <row>=true|false." ;; esac
  [ -n "${KIND[$k]+x}" ] || refuse "--judge $a: NEXT.md has no row $k."
  [ "${ASK[$k]}" != "-" ] || refuse "--judge $a: row $k is decided by the flags, not by judgement."
  case "$v" in true | false) ;; *) refuse "--judge $a: the answer is true or false." ;; esac
  [ -z "${JUDGE[$k]+x}" ] || refuse "--judge: row $k is answered twice."
  JUDGE[$k]="$v"
done

if [ -z "$STATE" ]; then
  for c in .gauntlet/STATE.md STATE.md; do [ -f "$c" ] && { STATE="$c"; break; }; done
  [ -n "$STATE" ] || refuse "no STATE.md given, and none at .gauntlet/STATE.md or ./STATE.md."
fi
[ -f "$STATE" ] || refuse "$STATE does not exist."
parse_state "$STATE"

# ------------------------------------------------------------------------------------------------ the table, top to bottom
# The gates first (NEXT.md: a gate that is true turns its rows off wherever they stand - row 14's are above it), then
# the rows in order, a row turned off by a gate in force being false.
declare -A OFF=()
for id in "${IDS[@]}"; do
  [ "${KIND[$id]}" = gate ] || continue
  cond_true "${COND[$id]}" || continue
  for x in ${OFFS[$id]//,/ }; do OFF[$x]="$id"; done
done
pending=""
for id in "${IDS[@]}"; do
  [ -z "${OFF[$id]+x}" ] || continue
  cond_true "${COND[$id]}" || continue
  why="$COND_WHY"
  if [ "${ASK[$id]}" != "-" ]; then
    q="${ASK[$id]//\{waiting_on_owner\}/${V[waiting_on_owner]}}"
    case "${JUDGE[$id]:-}" in
      false) continue ;;
      true) why="${why:+$why; }judged true: $q" ;;
      *) echo "needs judgement: row $id - $q"; pending="${pending:+$pending,}$id"; continue ;;
    esac
  fi
  if [ "${KIND[$id]}" = gate ]; then echo "in force: row $id - ${ACTION[$id]}"; echo "  because: $why"; continue; fi
  echo "next: row $id - ${ACTION[$id]}"
  echo "because: ${why:-the row holds whatever the flags say}"
  [ -z "$JUDGED" ] || echo "judged: $JUDGED"
  if [ -n "$pending" ]; then
    echo "only if every row that needs judgement above is false (rows $pending): answer them with --judge <row>=true|false."
    exit 3
  fi
  exit 0
done
# NEXT.md row 3: "take the first [row] that does not [depend on the answer]; if none, stop and say what is waiting". When
# the wait is what turned 7b off (and 12 and 16 wait on 7b) and nothing else stands, that is row 3 - not a hole.
if [ -z "$pending" ] && [ -z "${OFF[3]+x}" ] && [ "${V[waiting_on_owner]}" != none ] \
  && [ "${V[waiting_on_owner.real_manager]}" = yes ] && [ "${V[real_manager.owed]}" = yes ]; then
  echo "next: row 3 - ${ACTION[3]}"
  echo "because: waiting_on_owner=${V[waiting_on_owner]}: row 7b waits on that answer (it names RPC_URL or chain), rows 12 and 16 wait on 7b (real_manager_battery=${V[real_manager_battery]}), and no other row below stands - stop and say what is waiting"
  [ -z "$JUDGED" ] || echo "judged: $JUDGED"
  exit 0
fi
[ -z "$JUDGED" ] || echo "judged: $JUDGED"
if [ -n "$pending" ]; then
  echo "no row below them is true on the flags alone: if every row that needs judgement (rows $pending) is false, no row is true: the table has a hole or a flag is stale."
  exit 3
fi
echo "no row is true: the table has a hole or a flag is stale"
exit 1
