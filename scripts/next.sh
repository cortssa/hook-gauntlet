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
# finding is open), 3, 5, 8, 9, 9b, 10 (after a round, with no bytecode change since), 11b, 12, 16, 17, 18b.
#
# The rows are DATA (the ROWS table below): a new row of NEXT.md is one line here, not new parser code. The action a row
# prints is read from NEXT.md itself, as NEXT.md words it. And every run checks that the two name the same rows in the
# same order (the drift guard): a row added to NEXT.md with no line here, or the reverse, is a refusal.
#
# Two rows are not destinations, because NEXT.md says the route goes on after them:
#   row 2  (the ceiling is reached) is printed "in force", and every MODEL row below it (11b, 11, 12, 13, 13b, 15) is
#          then false: "no more model rounds ... the route CONTINUES without rounds";
#   row 14 (the loop is over) is printed "passed": its action is "Go to row 15".
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
# Output:  zero or more "in force: row 2 - ...", "passed: row 14 - ...", "needs judgement: row <id> - <question>" lines,
#          then "next: row <id> - <the action, as NEXT.md words it>" and "because: <the flags that made it true>".
# Exit:    0 the row given is the first true one; 1 no row is true: the table has a hole or a flag is stale (NEXT.md's
#          STOP rule); 2 REFUSED - a flag missing, of an unknown value, a malformed line, a bad --judge, or the table and
#          NEXT.md disagree: one line on stderr naming what; 3 a row above the one given needs judgement (named).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TABLE="$HERE/../doctrine/NEXT.md"

refuse() { echo "next: REFUSED - $*" >&2; exit 2; }

# ------------------------------------------------------------------------------------------------ the rows, as data
# id | kind | model round? | condition | the question, when the flags cannot decide the row ("-": they can)
#   kind: act (a destination) | limit (row 2: in force, model rows below it are off) | pass (row 14: go on)
#   condition: groups separated by " ; " (any group true), terms in a group separated by spaces (all true). A term is
#   <name>=<v>[,<v>...] (one of) | <name>!=<v> | <name>><n> (a number above n) | row:<id> (that row's condition) | -
#   (always). Names: the flags of STATE.md, and the parts parse_state below derives from them.
ROWS='
0   | act   | no  | phase=sketch | -
1   | act   | no  | open_findings.high>0 ; notes.pending=yes | does a high finding reproduce (open_findings high, or a provisional high on a pending: note) that the owner has not been told of?
2   | limit | no  | ceiling=reached | -
3   | act   | no  | waiting_on_owner!=none | does nothing below stand without the owner'"'"'s answer ({waiting_on_owner})? Answer false each row below that depends on it, and 3=false once none left does
4   | act   | no  | phase=0,1 | -
4b  | act   | no  | phase=2,3 | -
5   | act   | no  | - | has the fuzzer reported a violation of a promise that is not yet a deterministic test?
6   | act   | no  | bytecode_changed_since.last_battery=yes ; battery=never | -
6b  | act   | no  | battery=red | -
7   | act   | no  | bytecode_changed_since.last_long_fuzz=yes battery=green ; bytecode_changed_since.last_other_free_judges=yes battery=green | -
7b  | act   | no  | real_manager_battery=never,stale notes.real_manager=no | -
8   | act   | no  | any_round=yes | is there an ACCEPTED or FIXED finding (triaged in row 9) from outside the fuzzer with no rule for it yet (an invariant or action, or a unit test and a not fuzzable: note)?
9   | act   | no  | open_findings.total>0 | are there open findings from the last round with no answer, and is the owner there to answer?
9b  | act   | no  | open_findings.total>0 | do open findings FROM A ROUND wait on the owner'"'"'s triage while the owner is not available?
10  | act   | no  | any_round=yes bytecode_changed_since.last_audit_round=no | did only documents, comments, scripts or tests change since the last round, making claims about the code?
11b | act   | yes | - | was a model round STOPPED by the environment (the harness, the provider'"'"'s classifier) before delivering?
11  | act   | yes | last_audit_round=none battery=green | -
12  | act   | yes | last_audit_round!=none battery=green blackbox=never_run | did the spec'"'"'s promises stay unchanged in the last triage (no triage yet counts as unchanged)?
13  | act   | yes | last_audit_round!=none bytecode_changed_since.last_audit_round=yes battery=green | -
13b | act   | yes | last_audit_round.type=regression last_audit_round.high=0 last_audit_round.medium=0 ; last_audit_round!=none open_findings.reasoned_high_or_medium>0 | -
14  | pass  | no  | last_audit_round.type=discovery last_audit_round.high=0 last_audit_round.medium=0 open_findings.reasoned_high_or_medium=0 bytecode_changed_since.last_audit_round=no ; ceiling=reached open_findings.total=0 | -
15  | act   | yes | row:14 blackbox=stale,never_run | -
16  | act   | no  | row:14 blackbox=current,skipped_by_owner bytecode_changed_since.last_promotion=n/a,yes | does the owner want to freeze a release candidate?
17  | act   | no  | bytecode_changed_since.last_promotion=no | is a deployment runbook part of the dossier, not yet rehearsed?
18  | act   | no  | bytecode_changed_since.last_promotion=no | -
18b | act   | no  | row:14 bytecode_changed_since.last_promotion=n/a | light mode, and did the owner decline promotion in writing?
'

declare -a IDS=()
declare -A KIND=() MODEL=() COND=() ASK=()
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
while IFS='|' read -r c_id c_kind c_model c_cond c_ask; do
  c_id="$(trim "$c_id")"; [ -n "$c_id" ] || continue
  IDS+=("$c_id"); KIND[$c_id]="$(trim "$c_kind")"; MODEL[$c_id]="$(trim "$c_model")"
  COND[$c_id]="$(trim "$c_cond")"; ASK[$c_id]="$(trim "$c_ask")"
done <<< "$ROWS"

# ------------------------------------------------------------------------------------------------ NEXT.md's table
# table_rows <NEXT.md>: "id<TAB>action" per row of the table under "## The table", in order. A row whose cells cannot be
# read (not exactly four cells: a "|" inside one) is printed "BAD<TAB>id" - refused by the caller, never half-read.
table_rows() {
  LC_ALL=C awk '
    { sub(/\r$/, "") }
    /^## / { intable = ($0 ~ /^## The table/); next }
    intable && /^\| *[0-9]+b? *\|/ {
      line = $0; n = gsub(/[|]/, "|", line)
      split($0, c, /[|]/); id = c[2]; gsub(/^ +| +$/, "", id)
      if (n != 5) { print "BAD\t" id; next }
      act = c[4]; gsub(/^ +| +$/, "", act); print id "\t" act
    }' "$1"
}
declare -A ACTION=()
load_table() { # load_table <NEXT.md>: fills ACTION, and refuses when its rows and ROWS disagree (the drift guard)
  local f="$1" id act ours theirs="" x
  [ -f "$f" ] || refuse "no decision table at $f (doctrine/NEXT.md)."
  while IFS=$'\t' read -r id act; do
    [ "$id" = "BAD" ] && refuse "$f row $act: its cells cannot be read (a '|' inside a cell?)."
    [ -z "${ACTION[$id]+x}" ] || refuse "$f has row $id twice."
    ACTION[$id]="$act"; theirs="${theirs:+$theirs }$id"
  done < <(table_rows "$f")
  [ -n "$theirs" ] || refuse "$f has no rows under '## The table'."
  ours="${IDS[*]}"
  [ "$ours" = "$theirs" ] && return 0
  for x in $theirs; do [ -n "${KIND[$x]+x}" ] || refuse "drift: $f has row $x, and next.sh has no entry for it (add one to ROWS)."; done
  for x in $ours; do [ -n "${ACTION[$x]+x}" ] || refuse "drift: next.sh has an entry for row $x, and $f has no row $x."; done
  refuse "drift: $f and next.sh name the same rows in another order ($theirs / $ours)."
}

# ------------------------------------------------------------------------------------------------ STATE.md's flags
FLAGS="phase bytecode_changed_since battery blackbox open_findings last_audit_round last_other_round ceiling real_manager_battery waiting_on_owner location dossier notes"
declare -A RAW=() V=()

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
    elif [[ $line =~ ^[[:space:]] ]] && [ "$prev" = "notes" ]; then
      RAW[notes]="${RAW[notes]} $(trim "$line")"   # notes: may run on over indented lines
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
  enum blackbox never_run current stale skipped_by_owner
  pairs open_findings '^[0-9]+$' "a whole number" high medium low reasoned_high_or_medium
  local h="${V[open_findings.high]}" m="${V[open_findings.medium]}" l="${V[open_findings.low]}"
  V[open_findings.total]=$((10#$h + 10#$m + 10#$l))

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
  enum location .gauntlet/ root
  enum dossier none skeleton complete
  V[notes.pending]=no; V[notes.real_manager]=no
  case "${RAW[notes]}" in *"pending:"*) V[notes.pending]=yes ;; esac
  case "${RAW[notes]}" in *"real manager:"*) V[notes.real_manager]=yes ;; esac
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
models_off=0 pending=""
for id in "${IDS[@]}"; do
  [ "$models_off" = 1 ] && [ "${MODEL[$id]}" = yes ] && continue
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
  case "${KIND[$id]}" in
    limit) echo "in force: row $id - ${ACTION[$id]}"; echo "  because: $why"; models_off=1; continue ;;
    pass) echo "passed: row $id - ${ACTION[$id]}"; echo "  because: $why"; continue ;;
  esac
  echo "next: row $id - ${ACTION[$id]}"
  echo "because: ${why:-the row holds whatever the flags say}"
  [ -z "$JUDGED" ] || echo "judged: $JUDGED"
  if [ -n "$pending" ]; then
    echo "only if every row that needs judgement above is false (rows $pending): answer them with --judge <row>=true|false."
    exit 3
  fi
  exit 0
done
[ -z "$JUDGED" ] || echo "judged: $JUDGED"
if [ -n "$pending" ]; then
  echo "no row below them is true on the flags alone: if every row that needs judgement (rows $pending) is false, no row is true: the table has a hole or a flag is stale."
  exit 3
fi
echo "no row is true: the table has a hole or a flag is stale"
exit 1
