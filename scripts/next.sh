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
# output, so the judgement is on the record, not in anyone's head. Rows that need judgement: 1 (a high open that the
# flags do not show recorded to tell), 5, 8, 9 and 9b (a finding open, once round 1 has run or the ceiling is reached; 9b
# only while the dossier does not name them yet), 10 (after a round, with no bytecode change since), 11b, 12, 16, 18b.
# Not row 3: the flags decide it (below).
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
#   - row 7b is off while `waiting_on_owner` asks the owner for the endpoint or the chain: an item that contains `RPC_URL`,
#     or that IS the chain question (`chain`, or starting with the WORD `chain`, `target chain` or `which chain`, any case;
#     `chain-id`, `chain_id`, `chains` are other words) - `off-chain`, `cross-chain` or the word inside another question
#     do not count: its action waits on the owner, so row 3 skips it;
#   - rows 12 and 16 are off while 7b is owed (`real_manager_battery` `never` or `stale` - the chain is known - and no
#     `real manager:` note); when 7b is silenced by the wait and no other row stands, that is row 3's pause, as NEXT.md's
#     row 3 says: it stops and says what is waiting (no answer makes the rows the wait turned off stand: row 3 is not
#     answered);
#   - rows 9 and 9b count every open finding, from any round - a phase-3 `pending:` one too, once round 1 has run; before
#     round 1 (`last_audit_round: none`) they are off, pending findings ride into round 1 - unless the ceiling is reached
#     (row 2: round 1 will not run, every open finding goes to 9 or 9b);
#   - `blackbox: stopped (<round id>)` (a black-box round stopped twice, row 11b): rows 12 and 15 do not fire on it, rows
#     16 and 18b take it;
#   - row 1 goes quiet only by the flags' record of the owner absent, BY ID (K28): open_findings names the open highs,
#     `high=N (<ids>)` - the parentheses exactly when N > 0, one id per high, each once (case aside), ids between commas
#     or spaces; a count without its ids, ids with N = 0, a count that is not the number of ids, a placeholder (none,
#     TBD, nobody, n/a, ?), a word between the ids, or a word that is not an id - an id has a letter and a digit (F-1,
#     r01-A1; `all`, `TBA`, `pending`, `1`, `None.` are not: V28, the same non-id on both sides quieted the row) - is
#     refused. The row is quiet when EVERY one of those ids is among the ids of the items `high <id>[, <id>...] - to
#     tell` of waiting_on_owner (compared case-insensitively, the same rules for the ids there); an id recorded there
#     that is not an open high is refused (a recorded high is no longer open: remove it - V26b: `high all`, `high 1`, a
#     medium's id, one high spelled twice quieted the row by their number alone). Then the row is false, and the
#     because: line of whatever is given names those ids - a quiet row 1 always leaves a trace. Otherwise, with a high
#     open, it is a question naming the highs not recorded (the owner present: answered 1=false once told); a `told:`
#     note is not read. A provisional high from phase 3 counts in open_findings high like any other (NEXT.md row 6b);
#   - row 9b is quiet once the dossier names the open findings: `dossier: skeleton (<K> open, ...)` with K the number
#     open (high + medium + low; informational findings are not counted) decides it false by the flags, unasked; `none`,
#     or a skeleton naming another number (stale), keeps it standing, and the owner's presence is what is asked.
#     `dossier: complete` with a finding open is refused: a dossier with an open finding is a skeleton (K28, NEXT.md's
#     `dossier:` flag);
#   - row 3 ends the route with the owner absent: when waiting_on_owner is not `none` and no row below stands on the flags
#     and none is left to judge, the answer is `next: STOP - paused, waiting on the owner: <items>` (exit 0) - decided
#     by the flags, never asked, and never answered: `--judge 3=...` is REFUSED (V26b: `3=true` gave that STOP over row
#     6 and row 9b, which the flags made true - the answer to row 3 could hide the rows below; an answer refused hides
#     nothing, where one ignored would still stand on the record as judged). A row below that waits on the owner's
#     answer is skipped the way the table skips it: a row that needs judgement is answered false, row 7b is off by the
#     flags. While rows still need judgement (above or below row 3), the pause is not given: exit 3, the questions, and
#     one line, `if every answer is false: STOP - paused, waiting on the owner: <items>`;
#   - a note is read by its name only at the START of a note item (a note line, or a part of one after the middle dot
#     or ";", a Markdown list marker `- ` / `* ` / `+ ` before it allowed): `real manager:` for row 7b;
#   - the ceiling the OPERATOR set in full mode with the owner absent (`<N> model rounds, set by the operator (owner
#     absent); <M> used`) is a ceiling like the owner's: row 2 fires on it; "operator" in any other shape or case is refused;
#   - rows 13b and 14 count a finding against "closed with 0 high and 0 medium" only while it is OPEN in `open_findings`
#     (one accepted by the owner, refused in writing or handed to the human audit by name does not): the terms are
#     `open_findings.high=0 open_findings.medium=0`, not the round's own counts;
#   - row 18b is either mode: the owner declined promotion in writing (light mode by default) - a judgement;
#   - row 10 does not count the route's whole workspace (everything under .gauntlet/ - STATE.md, DECISIONS.md, LOG.md,
#     SPEC.md, the dossier, briefs/, reports/, rounds/, bench/, backtests/, ... - or those same files at the root with
#     location: root; an owner's own SPEC.md, README or NatSpec outside it still counts): its question says so - a
#     walker of the route found the row true at the letter over the skeleton it had just written, and answered it false
#     to reach the pause (K31); the benches and the tests written in them were still outside the words (V31, K31b).
# And two checks before any row (K31, K31b), neither of them a flag of STATE.md:
#   - the kit is proven on this machine: scripts/selftest.sh, ending PASSED, leaves <kit>/.gauntlet/selftest-passed with
#     the SHA-256 of the kit's scripts, a hash of the machine's identity and forge's version (scripts/lib/kit-proof.sh).
#     Absent, with one of the three missing, or written for other scripts, on another machine or with another forge,
#     this prints ONE line, `next: FIRST - prove the kit on this machine: <kit>/scripts/selftest.sh (then run next.sh
#     again) - <which>` (the scripts / the machine / forge), and exits 0 - nothing else, no row. --check-table does not
#     look;
#   - a test in pending/ that STATE.md does not name is refused: the project is the STATE.md's directory (its parent
#     when that directory is .gauntlet/), and each .sol file below its pending/ (subdirectories and hidden files too:
#     row 6b's profile compiles and runs them all) needs a note `pending: <id> ...`, the id its name without .t.sol or
#     .sol, and each id of such a note (`pending: F-4, F-5 - ...` names two) its file (NEXT.md row 6b); no pending/,
#     nothing is checked.
# Readings of NEXT.md this script makes, each from NEXT.md's own words: `phase` advances only when a phase's gate is met,
# so rows 4 and 4b are `phase` 0-1 and 2-3; "promoted" is `last_promotion=no` (`yes` = changed since, no longer promoted;
# `n/a` = never promoted); "the loop is over" (rows 15-18b) is row 14's condition; a finding from outside the fuzzer
# (row 8) comes from a round, so row 8 is false before any round has run.
#
# Usage:   scripts/next.sh [STATE.md] [--judge <row>=true|false[,<row>=true|false...]]... [--table <NEXT.md>]
#          scripts/next.sh --check-table [<NEXT.md>]     the drift guard alone
#   STATE.md defaults to .gauntlet/STATE.md, then ./STATE.md. --table defaults to the kit's doctrine/NEXT.md.
#   Before any row: the kit's selftest marker (above); without it, or not for these scripts, this machine and this
#   forge, the one line `next: FIRST - ...` and exit 0.
#   --judge answers a row that needs judgement: `true` makes it true (it is then given, if it is the first), `false`
#   passes it. Row 3 (waiting on the owner) is not one: `--judge 3=...` is refused - answer `false` each row below that
#   depends on the owner's answer; when nothing below stands and nothing is left to judge, the pause is given.
# Output:  zero or more "in force: row <2|14> - ..." and "needs judgement: row <id> - <question>" lines,
#          then "next: row <id> - <the action, as NEXT.md words it>" and "because: <the flags that made it true>" -
#          or, the owner absent, nothing below row 3 standing and nothing left to judge, "next: STOP - paused, waiting on
#          the owner: <items>" (STOP, not "row": a caller that walks the rows stops here, and runs this again when the
#          owner has answered) - or, with rows still to judge and nothing below standing on the flags, the questions and
#          "if every answer is false: STOP - paused, waiting on the owner: <items>" (exit 3: answer them, run it again).
# Env:     NEXT_SELFTEST=1  the selftest's own cases: the marker is not checked, and the first line on stderr says so
#          every time it is set (a user never sets it; any other value is refused)
# Exit:    0 the row given is the first true one, or the pause, or FIRST (the kit not proven here); 1 no row is true and
#          nothing waits on the owner: the table has a hole or a flag is stale (NEXT.md's STOP rule); 2 REFUSED - a flag
#          missing, of an unknown value, a malformed line, a bad --judge, a pending/ test and the notes disagreeing, or the
#          table and NEXT.md disagree: one line on stderr naming what; 3 a row above the one given needs judgement
#          (named), or rows still need judgement before the pause can be given.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TABLE="$HERE/../doctrine/NEXT.md"

refuse() { echo "next: REFUSED - $*" >&2; exit 2; }

KIT="$(cd "$HERE/.." && pwd)"
# the selftest's own cases run without the marker - said on one line every time, never silently (K31)
case "${NEXT_SELFTEST-}" in
  "") ;;
  1) echo "next: NEXT_SELFTEST=1 - the kit's selftest marker is NOT checked (the selftest's own cases set this; a user never does)" >&2 ;;
  *) refuse "NEXT_SELFTEST='${NEXT_SELFTEST}' is not 1: it is set by the kit's selftest for its own cases only - unset it." ;;
esac

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
0   | 8d05b8e0 | act  | -                   | phase=sketch | -
1   | 7b9700dd | act  | -                   | open_findings.high_not_recorded>0 | does a high finding reproduce (open_findings high: {highs_not_recorded} not recorded to tell) that the owner has not been told of? The owner present: false once they have been told (a told: note is not read); absent: record every open high in waiting_on_owner as high <id>[, <id>...] - to tell, and the flags quiet this row
2   | 64c00456 | gate | 11,11b,12,13,13b,15 | ceiling=reached | -
3   | 8949c656 | act  | -                   | waiting_on_owner!=none | -
4   | a019d2cf | act  | -                   | phase=0,1 | -
4b  | 2473e53b | act  | -                   | phase=2,3 | -
5   | 2a2d739a | act  | -                   | - | has the fuzzer reported a violation of a promise that is not yet a deterministic test?
6   | cebb3ad7 | act  | -                   | bytecode_changed_since.last_battery=yes ; battery=never | -
6b  | 021321a6 | act  | -                   | battery=red | -
7   | c644f4bc | act  | -                   | bytecode_changed_since.last_long_fuzz=yes battery=green ; bytecode_changed_since.last_other_free_judges=yes battery=green | -
7b  | 4135edaa | act  | -                   | real_manager.owed=yes waiting_on_owner.real_manager=no | -
8   | c328f377 | act  | -                   | any_round=yes | is there an ACCEPTED or FIXED finding (triaged in row 9) from outside the fuzzer with no rule for it yet (an invariant or action, or a unit test and a not fuzzable: note)?
9   | 6d5b5f55 | act  | -                   | last_audit_round!=none open_findings.total>0 ; ceiling=reached open_findings.total>0 | is a finding from any round still open (not fixed, refused in writing, accepted by the owner with a number, or handed to the human audit by name - one triaged fix at the cause whose fix is not written yet is still open; a phase-3 pending: finding is one too, now that round 1 has run or the ceiling is reached), and is the owner there to answer, or is it already triaged fix at the cause?
9b  | 3fac6ddc | act  | -                   | last_audit_round!=none open_findings.total>0 dossier.lists_open=no ; ceiling=reached open_findings.total>0 dossier.lists_open=no | open findings from any round (a phase-3 pending: finding too, now that round 1 has run or the ceiling is reached) wait on the owner'"'"'s triage, and the dossier does not name them yet ({dossier_names}): is the owner unavailable to triage them now (an exercise, or away)?
10  | 335ae40f | act  | -                   | any_round=yes bytecode_changed_since.last_audit_round=no | did only documents, comments, scripts or tests change since the last round, making claims about the code? The route'"'"'s whole workspace does not count - everything under .gauntlet/ (STATE.md, DECISIONS.md, LOG.md, the route'"'"'s SPEC.md, the dossier, STATIC-TRIAGE.md, briefs/, reports/, rounds/, the benches in bench/ and the tests written in them, backtests/, the triage notes), or with location: root those same files and directories at the root; an owner'"'"'s own SPEC.md, README or NatSpec outside that workspace still counts. A skeleton written since the last round does not make this row true
11b | 39b95289 | act  | -                   | - | was a model round STOPPED by the environment (the harness, the provider'"'"'s classifier) before delivering, and not yet retried - or stopped again, and not yet recorded (notes: round <id> stopped; a black-box round also blackbox: stopped (<id>))?
11  | 29326122 | act  | -                   | last_audit_round=none battery=green | -
12  | 9f085660 | act  | -                   | last_audit_round!=none battery=green blackbox=never_run real_manager.owed=no | did the spec'"'"'s promises stay unchanged in the last triage (no triage yet counts as unchanged)?
13  | 78bc1c8a | act  | -                   | last_audit_round!=none bytecode_changed_since.last_audit_round=yes battery=green | -
13b | 4e8baa1f | act  | -                   | last_audit_round.type=regression open_findings.high=0 open_findings.medium=0 ; last_audit_round!=none open_findings.reasoned_high_or_medium>0 | -
14  | 89e14495 | gate | 11,12,13,13b        | last_audit_round.type=discovery open_findings.high=0 open_findings.medium=0 open_findings.reasoned_high_or_medium=0 bytecode_changed_since.last_audit_round=no ; ceiling=reached open_findings.total=0 | -
15  | d7de1684 | act  | -                   | row:14 blackbox=stale,never_run | -
16  | f4763e2e | act  | -                   | row:14 blackbox=current,skipped_by_owner,stopped bytecode_changed_since.last_promotion=n/a,yes real_manager.owed=no ; row:2 row:14 blackbox=never_run,stale bytecode_changed_since.last_promotion=n/a,yes real_manager.owed=no | does the owner want to freeze a release candidate?
17  | 496e473f | act  | -                   | bytecode_changed_since.last_promotion=no rehearsal=not_yet | -
18  | da261889 | act  | -                   | bytecode_changed_since.last_promotion=no rehearsal=n/a,done | -
18b | 41757769 | act  | -                   | row:14 blackbox=current,skipped_by_owner,stopped ; row:2 row:14 blackbox=never_run,stale | did the owner decline promotion in writing (light mode by default, COST.md; full mode by the owner'"'"'s own written decision)?
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
declare -A RAW=() V=() RECORDED=() SHOW_NOTE=() OPEN_HIGH=()
declare -a RECORDED_ORDER=() OPEN_HIGH_ORDER=()
ROW1_QUIET="" HIGHS_NOT_RECORDED=""
declare -a NOTE_LINES=()

# finding_id <where> <id> <the form expected>: one finding id, or refused - a placeholder, a word between ids, anything
# that is not one id (open_findings' high=N (<ids>) and waiting_on_owner's high <id>[, <id>...] - to tell alike)
finding_id() {
  local where="$1" id="$2" form="$3"
  case "${id,,}" in
    none | tbd | nobody | n/a | '?') refuse "$where, '$id' is a placeholder, not a finding id ($form: the ids of the open highs)." ;;
    and | or | '&' | plus) refuse "$where, '$id' is a word, not a finding id (ids between commas or spaces: $form)." ;;
  esac
  [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || refuse "$where, '$id' is not one finding id ($form)."
  # an id is an id: a letter and a digit at least (F-1, P-02, r01-A1, R01-3). The same non-id written on both sides -
  # `high=1 (all)` and `high all - to tell`, `TBA`, `pending`, the count `1`, `None.` - quieted row 1 (V28)
  [[ $id =~ [A-Za-z] && $id =~ [0-9] ]] \
    || refuse "$where, '$id' is not an id: an id has at least one letter and one digit (F-1, r01-A1; $form)."
}

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
  # open_findings names the open highs (NEXT.md, K28): `high=N (<ids>)`, the parentheses right after high=N - the first
  # high= key, before any "(" (a comment after the keys may say anything) - exactly when N > 0. They are taken out here,
  # checked, and the rest is read as key=value pairs like any other
  local id key hid_given=0 hid_raw="" hid_show
  local -a ids=()
  local re_hid='^([^(]*[[:space:]]|)high=([0-9]+)[[:space:]]*[(]([^()]*)[)]'
  val="${RAW[open_findings]}"
  if [[ $val =~ $re_hid ]]; then
    hid_given=1; hid_raw="$(trim "${BASH_REMATCH[3]}")"
    RAW[open_findings]="${BASH_REMATCH[1]}high=${BASH_REMATCH[2]}${val:${#BASH_REMATCH[0]}}"
  fi
  pairs open_findings '^[0-9]+$' "a whole number" high medium low reasoned_high_or_medium
  local h="${V[open_findings.high]}" m="${V[open_findings.medium]}" l="${V[open_findings.low]}" r="${V[open_findings.reasoned_high_or_medium]}"
  V[open_findings.total]=$((10#$h + 10#$m + 10#$l))
  hid_show="high=$((10#$h))"
  if [ "$hid_given" = 1 ]; then
    hid_show="high=$((10#$h)) ($hid_raw)"
    [ $((10#$h)) -gt 0 ] \
      || refuse "open_findings: high=0 with ids in parentheses ($hid_raw): the parentheses name the open highs, none when high is 0 (high=N (<ids>), NEXT.md)."
    read -ra ids <<< "${hid_raw//,/ }"
    for id in ${ids[@]+"${ids[@]}"}; do
      finding_id "open_findings: in '$hid_show'" "$id" "high=N (<ids>)"
      key="${id,,}"
      [ -z "${OPEN_HIGH[$key]+x}" ] \
        || refuse "open_findings: in '$hid_show', '$id' is named twice ('${OPEN_HIGH[$key]}' and '$id', case aside): each open high once."
      OPEN_HIGH[$key]="$id"; OPEN_HIGH_ORDER+=("$id")
    done
    key="ids"; [ "${#ids[@]}" != 1 ] || key="id"
    [ "${#ids[@]}" -eq $((10#$h)) ] \
      || refuse "open_findings: high=$((10#$h)) names ${#ids[@]} $key ($hid_raw): one id per open high (high=N (<ids>), NEXT.md)."
  elif [ $((10#$h)) -gt 0 ]; then
    refuse "open_findings: high=$((10#$h)) names no ids: the ids of the open highs go in parentheses right after it, high=$((10#$h)) (<ids>) (NEXT.md)."
  fi
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
  # the ceiling the OPERATOR set, the owner absent in full mode (NEXT.md row 3, COST.md 1): one fixed form, read strictly -
  # a line that says "operator" in any other shape, or in any other case, is refused, never read as the owner's
  local re_op='^([0-9]+) model rounds?, set by the operator \(owner absent\);[[:space:]]*([0-9]+)[[:space:]]+used([[:space:]]+[(][^()]*[)])?$'
  val="${RAW[ceiling]}"
  if [[ $val =~ ^not\ agreed ]]; then V[ceiling]=not_agreed
  elif [[ $val =~ ^undecided ]]; then V[ceiling]=undecided
  elif [[ ${val,,} == *operator* ]]; then   # in ANY case: `set by the Operator` passed as the owner's ceiling (V24)
    [[ $val =~ $re_op ]] || refuse "flag 'ceiling': '$val' is not the operator's form, '<N> model rounds, set by the operator (owner absent); <M> used'."
    if [ "${BASH_REMATCH[2]}" -ge "${BASH_REMATCH[1]}" ]; then V[ceiling]=reached; else V[ceiling]=open; fi
    CEIL_SHOW="${BASH_REMATCH[2]} of ${BASH_REMATCH[1]} used, set by the operator (owner absent)"
  elif [[ $val =~ $re_ceil ]]; then
    if [ "${BASH_REMATCH[2]}" -ge "${BASH_REMATCH[1]}" ]; then V[ceiling]=reached; else V[ceiling]=open; fi
    CEIL_SHOW="${BASH_REMATCH[2]} of ${BASH_REMATCH[1]} used"
  else
    refuse "flag 'ceiling': '$val' is none of 'not agreed ...', 'undecided ...', '<N> model rounds ...; <M> used', '<N> model rounds, set by the operator (owner absent); <M> used'."
  fi

  enum real_manager_battery n/a never stale current
  val="${RAW[waiting_on_owner]}"
  if [[ $val =~ ^none([[:space:]]+\(.*)?$ ]]; then V[waiting_on_owner]=none; else V[waiting_on_owner]="$val"; fi
  # row 7b's own question waits on the owner when an item of waiting_on_owner (items: separated by ";" or the middle dot
  # NEXT.md uses) contains RPC_URL, or IS the chain question: the item is `chain`, or starts with `chain`, `target chain`
  # or `which chain` (any case) as a word. The word anywhere else - `off-chain keeper address`, `triage of F-2
  # (cross-chain replay)`, `severity of F-7 (it depends on the chain)` - asks the owner something else, and 7b, a
  # local judge, does not wait on it (a verifier's G03 and G12)
  local item; local -a items=()
  V[waiting_on_owner.real_manager]=no
  # row 1 with the owner absent: the highs recorded to tell are the items `high <id>[, <id>...] - to tell` (both real walks
  # wrote several ids in one item, between commas or between spaces). Each id once, compared case-insensitively; a
  # placeholder, a word between the ids, or an item that says "to tell" in any other shape is refused - never counted,
  # never ignored
  local re_tell='^high[[:space:]]+(.*[^[:space:]])[[:space:]]+-[[:space:]]+to[[:space:]]+tell([[:space:]]|$)'
  local re_tell_empty='^high[[:space:]]+-[[:space:]]+to[[:space:]]+tell([[:space:]]|$)'
  if [ "${V[waiting_on_owner]}" != none ]; then
    IFS=';' read -ra items <<< "${val//$'\302\267'/;}"
    for item in "${items[@]}"; do
      case "$item" in *RPC_URL*) V[waiting_on_owner.real_manager]=yes ;; esac
      item="$(trim "$item")"
      [[ ${item,,} =~ ^(target[[:space:]]+|which[[:space:]]+)?chain([^a-z0-9_-]|$) ]] && V[waiting_on_owner.real_manager]=yes
      if [[ $item =~ $re_tell_empty ]]; then
        refuse "waiting_on_owner: '$item' names no finding id (high <id>[, <id>...] - to tell)."
      elif [[ $item =~ $re_tell ]]; then
        read -ra ids <<< "${BASH_REMATCH[1]//,/ }"
        [ "${#ids[@]}" -gt 0 ] || refuse "waiting_on_owner: '$item' names no finding id (high <id>[, <id>...] - to tell)."
        for id in "${ids[@]}"; do
          finding_id "waiting_on_owner: in '$item'" "$id" "high <id>[, <id>...] - to tell"
          key="${id,,}"
          [ -n "${RECORDED[$key]+x}" ] && continue
          RECORDED[$key]="$id"; RECORDED_ORDER+=("$id")
        done
      elif [[ ${item,,} == *"to tell"* ]]; then
        refuse "waiting_on_owner: '$item' is not 'high <id>[, <id>...] - to tell' (NEXT.md row 1: the ids of the open highs, then ' - to tell')."
      fi
    done
  fi
  enum location .gauntlet/ root
  # the skeleton says how many open findings it names (row 9b reads it): skeleton (<K> open, <N> judges not done)
  val="${RAW[dossier]}"
  if [[ $val =~ ^skeleton([^A-Za-z0-9_]|$) ]]; then
    local re_skel='^skeleton[[:space:]]+[(]([0-9]+)[[:space:]]+open([,;[:space:]][^()]*)?[)]$'
    [[ $val =~ $re_skel ]] \
      || refuse "dossier: '$val' is not skeleton (<K> open, <N> judges not done): row 9b reads K, the number of open findings the skeleton names."
    V[dossier]=skeleton; V[dossier.open]=$((10#${BASH_REMATCH[1]}))
  else
    enum dossier none skeleton complete
  fi
  # a complete dossier has no finding open (NEXT.md's dossier: flag): one next to an open finding is a skeleton, refused
  # (K28: it quieted row 9b, and the route paused on a "complete" dossier with findings still open)
  [ "${V[dossier]}" != complete ] || [ "${V[open_findings.total]}" -eq 0 ] \
    || refuse "dossier: complete, and open_findings has ${V[open_findings.total]} open (high + medium + low): a dossier with an open finding is a skeleton - dossier: skeleton (<K> open, <N> judges not done)."
  # row 9b is done once the dossier names what is open: a skeleton naming exactly the number open (a complete dossier has
  # none open)
  V[dossier.lists_open]=no
  case "${V[dossier]}" in
    complete) V[dossier.lists_open]=yes ;;
    skeleton) [ "${V[dossier.open]}" -ne "${V[open_findings.total]}" ] || V[dossier.lists_open]=yes
      SHOW_NOTE[dossier.lists_open]="the skeleton names ${V[dossier.open]}, open_findings has ${V[open_findings.total]} open" ;;
    none) SHOW_NOTE[dossier.lists_open]="dossier: none" ;;
  esac
  local re_na='^n/a([[:space:]]+[(].*[)])?$' re_ny='^not yet([[:space:]]+[(].*[)])?$'
  local re_done='^done[[:space:]]+[(]([0-9]{4})-([0-9]{2})-([0-9]{2})[)]$'
  val="${RAW[rehearsal]}"
  if [[ $val =~ $re_na ]]; then V[rehearsal]=n/a
  elif [[ $val =~ $re_ny ]]; then V[rehearsal]=not_yet
  elif [[ $val =~ $re_done ]] && real_date "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"; then V[rehearsal]="done"
  else refuse "rehearsal: '$val' is not one of: n/a (no runbook) | not yet | done (YYYY-MM-DD), a real date."; fi
  # a note is read by its name only at the START of a note item: a note line (the value of notes:, or an indented line
  # under it), or a part of one after the middle dot or ";" - never where the words merely appear
  V[notes.real_manager]=no
  for line in "${NOTE_LINES[@]}"; do
    IFS=';' read -ra items <<< "${line//$'\302\267'/;}"
    for item in "${items[@]}"; do
      item="$(trim "$item")"
      # a note written as a Markdown list item (`- real manager: ...`) is read like a plain one
      if [[ $item =~ ^[-*+][[:space:]]+(.*)$ ]]; then item="${BASH_REMATCH[1]}"; fi
      [[ $item =~ ^real\ manager: ]] && V[notes.real_manager]=yes                                            # row 7b
    done
  done
  # row 1, by id (K28): quiet by the flags only when EVERY open high named in open_findings is recorded to tell. An id
  # recorded to tell that is not an open high is a stale entry (a high fixed or re-triaged since) or not a high at all
  # (V26b: `high all`, `high 1`, a medium's id, one high spelled twice quieted the row by their number): refused, so that
  # it is read and removed - never counted. One open high not recorded: the row is a question naming it. A told: note
  # is not read (V26: a told: of a closed high, or told: none, quieted it with nothing on the record).
  for id in ${RECORDED_ORDER[@]+"${RECORDED_ORDER[@]}"}; do
    [ -n "${OPEN_HIGH[${id,,}]+x}" ] \
      || refuse "waiting_on_owner: '$id' is recorded to tell (high <id>[, <id>...] - to tell), and it is not an open high in open_findings ($hid_show): a recorded high is no longer open: remove it."
  done
  local rec_n=0 rec_ids="" nrec_n=0
  for id in ${OPEN_HIGH_ORDER[@]+"${OPEN_HIGH_ORDER[@]}"}; do
    if [ -n "${RECORDED[${id,,}]+x}" ]; then rec_n=$((rec_n + 1)); rec_ids="${rec_ids:+$rec_ids, }$id"
    else nrec_n=$((nrec_n + 1)); HIGHS_NOT_RECORDED="${HIGHS_NOT_RECORDED:+$HIGHS_NOT_RECORDED, }$id"; fi
  done
  V[open_findings.high_not_recorded]=$nrec_n
  SHOW_NOTE[open_findings.high_not_recorded]="$hid_show, recorded to tell in waiting_on_owner: ${rec_ids:-none}; not recorded: ${HIGHS_NOT_RECORDED:-none}"
  if [ $((10#$h)) -gt 0 ] && [ "$nrec_n" -eq 0 ]; then
    if [ "$rec_n" -eq 1 ]; then ROW1_QUIET="row 1 is quiet: the 1 high open is recorded to tell in waiting_on_owner ($rec_ids)"
    else ROW1_QUIET="row 1 is quiet: the $rec_n highs open are recorded to tell in waiting_on_owner ($rec_ids)"; fi
  fi
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
show() { # show <name>: name=value, as the because: line prints it (with what it was derived from, for a derived one)
  if [ "$1" = ceiling ] && [ -n "$CEIL_SHOW" ]; then printf 'ceiling=%s (%s)' "${V[ceiling]}" "$CEIL_SHOW"
  elif [ -n "${SHOW_NOTE[$1]:-}" ]; then printf '%s=%s (%s)' "$1" "${V[$1]}" "${SHOW_NOTE[$1]}"
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

# before any row: the kit's own tools proven on this machine, for these scripts and this forge (K31, K31b). Not for
# --check-table, which reads no STATE.md
if [ "$check_only" != 1 ] && [ "${NEXT_SELFTEST-}" != 1 ]; then
  [ -f "$HERE/lib/kit-proof.sh" ] || refuse "$HERE/lib/kit-proof.sh is missing (the kit's own check that its selftest passed here)."
  # shellcheck source=lib/kit-proof.sh
  . "$HERE/lib/kit-proof.sh"
  if ! kit_why="$(kit_proof_check "$KIT")"; then
    echo "next: FIRST - prove the kit on this machine: $KIT/scripts/selftest.sh (then run next.sh again) - $kit_why"
    exit 0
  fi
fi
load_table "$TABLE"
if [ "$check_only" = 1 ]; then echo "next: next.sh's rows and $TABLE agree: ${#IDS[@]} rows, ${IDS[*]}."; exit 0; fi

IFS=',' read -ra answers <<< "$JUDGED"
for a in "${answers[@]}"; do
  k="${a%%=*}"; v="${a#*=}"
  case "$a" in *=*) ;; *) refuse "--judge '$a' is not <row>=true|false." ;; esac
  [ -n "${KIND[$k]+x}" ] || refuse "--judge $a: NEXT.md has no row $k."
  # row 3: its answer used to be read, and 3=true gave the pause over rows the flags made true below it (V26b)
  [ "$k" != 3 ] || refuse "--judge $a: row 3 is decided by the flags: waiting_on_owner and the rows below. Answer false each row below that waits on the owner's answer; with none standing and none left to judge, the pause is given."
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

# ------------------------------------------------------------------------------------------------ pending/ and the notes
# NEXT.md row 6b: a phase-3 test that shows the code breaking a promise, the owner absent, goes to pending/<id>.t.sol,
# OUTSIDE test/, so that the battery is honestly green - and the finding goes into open_findings and a note `pending:
# <id> - <promise>, owner undecided`. A test moved there and never written down is a red test hidden from the battery
# and from the route alike. So, before any row (K31): the project is the STATE.md's directory, or its parent when that
# directory is .gauntlet/; with a pending/ there, every file row 6b's profile would run needs its note and every id of a
# pending: note its file (ids compared case aside, as everywhere here). No pending/, nothing is checked. A note is read
# by its name at the START of a note item, like real manager: above.
# What the profile runs (`[profile.pending] test = "pending"`, forge 1.8.1, measured - K31b): every .sol file below
# pending/, in subdirectories, without .t, hidden (.F-5.t.sol) or in a hidden directory - so each is read here, its id
# the file's name without .t.sol or .sol (and without a leading dot). pending/ is matched case-sensitively, as forge
# matches it. A note may name several ids: `pending: F-4, F-5 - ...` (commas, `and`, `&` or spaces between them; the
# list ends at the first word that is not an id - at least one letter and one digit - such as the ` - ` before the
# promise), and each needs its file.
pending_ids() { # pending_ids <the text after pending:>: its ids, one per line; exit 1 when the first word is not an id
  local rest="$1" tok first=1 re_comma='^[[:space:]]*,[[:space:]]*((and|[&])[[:space:]]+)?(.*)$' re_amp='^[[:space:]]*[&][[:space:]]*(.*)$'
  while :; do
    rest="${rest#"${rest%%[![:space:]]*}"}"
    tok=""
    if [[ $rest =~ ^([A-Za-z0-9][A-Za-z0-9._-]*)(.*)$ ]]; then tok="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"; fi
    while [[ $tok =~ ^(.+)[._-]$ ]]; do tok="${BASH_REMATCH[1]}"; done   # `pending: F-1. ...`
    if ! [[ $tok =~ [A-Za-z] && $tok =~ [0-9] ]]; then [ "$first" = 1 ] && return 1; return 0; fi
    printf '%s\n' "$tok"; first=0
    if [[ $rest =~ $re_comma ]]; then rest="${BASH_REMATCH[3]}"
    elif [[ $rest =~ $re_amp ]]; then rest="${BASH_REMATCH[1]}"
    elif [[ $rest =~ ^[[:space:]]+and[[:space:]]+(.*)$ ]]; then rest="${BASH_REMATCH[1]}"
    elif [[ $rest =~ ^[[:space:]]+(.*)$ ]]; then rest="${BASH_REMATCH[1]}"
    else return 0; fi
  done
}
check_pending() {
  local st_dir proj f id ids key line item re_pend='^pending:(.*)$'
  local -a items=() order=()
  local -A note=() file=()
  st_dir="$(cd "$(dirname "$1")" && pwd)" || refuse "cannot read the directory of $1."
  if [ "$(basename "$st_dir")" = ".gauntlet" ]; then proj="$(dirname "$st_dir")"; else proj="$st_dir"; fi
  [ -d "$proj/pending" ] || return 0
  for line in ${NOTE_LINES[@]+"${NOTE_LINES[@]}"}; do
    IFS=';' read -ra items <<< "${line//$'\302\267'/;}"
    for item in ${items[@]+"${items[@]}"}; do
      item="$(trim "$item")"
      if [[ $item =~ ^[-*+][[:space:]]+(.*)$ ]]; then item="${BASH_REMATCH[1]}"; fi
      [[ $item =~ $re_pend ]] || continue
      ids="$(pending_ids "${BASH_REMATCH[1]}")" \
        || refuse "notes: a pending: note names no id ('$item'): pending: <id>[, <id>...] - <promise>, owner undecided - NEXT.md row 6b."
      while IFS= read -r id; do
        [ -n "${note[${id,,}]+x}" ] || order+=("${id,,}")
        note[${id,,}]="$id"
      done <<< "$ids"
    done
  done
  while IFS= read -r -d '' f; do
    id="$(basename "$f")"; id="${id%.sol}"; id="${id%.t}"; while [ "${id#.}" != "$id" ]; do id="${id#.}"; done
    file[${id,,}]="$id"
    [ -n "${note[${id,,}]+x}" ] \
      || refuse "$f is a test in pending/, and STATE.md's notes have no 'pending: $id ...' for it: write it in STATE.md notes and in open_findings before anything else - NEXT.md row 6b."
  done < <(find -L "$proj/pending" -name '*.sol' -type f -print0 2> /dev/null | LC_ALL=C sort -z)
  for key in ${order[@]+"${order[@]}"}; do
    [ -n "${file[$key]+x}" ] \
      || refuse "STATE.md's notes name 'pending: ${note[$key]}', and $proj/pending/${note[$key]}.t.sol does not exist (nor any ${note[$key]}.sol below pending/): a pending finding's test is pending/<id>.t.sol - put it there, or, if the finding is closed, take the note out and the finding out of open_findings - NEXT.md row 6b."
  done
}
check_pending "$STATE"

# ------------------------------------------------------------------------------------------------ the table, top to bottom
# The gates first (NEXT.md: a gate that is true turns its rows off wherever they stand - row 14's are above it), then
# the rows in order, a row turned off by a gate in force being false.
declare -A OFF=()
for id in "${IDS[@]}"; do
  [ "${KIND[$id]}" = gate ] || continue
  cond_true "${COND[$id]}" || continue
  for x in ${OFFS[$id]//,/ }; do OFF[$x]="$id"; done
done
# The lines before the answer - gates in force, rows that need judgement - are kept in order and printed with it.
declare -a SAID=()
pending=""
said() { local x; for x in ${SAID[@]+"${SAID[@]}"}; do printf '%s\n' "$x"; done; }   # the lines kept so far, in order
# because <why>: the because: line of what is given - with the trace of a row 1 the flags quieted (the ids that did)
because() { local w="$1"; [ -z "$ROW1_QUIET" ] || w="${w:+$w; }$ROW1_QUIET"; echo "because: ${w:-the row holds whatever the flags say}"; }
# paused <why>: NEXT.md row 3, "if none, stop and say what is waiting" - the end of the route with the owner absent (after
# row 9b's skeleton, typically). A distinct first word, STOP, so that a caller walking the rows can tell it from one.
# Given ONLY when it is true: while a row still needs judgement nothing is given - the questions, and one line saying
# what an all-false answer gives (V26: "next: STOP" and "no row below row 3 stands" were printed while rows 5, 8, 9,
# 10 - or the black-box, below the ceiling - were still to judge).
paused() {
  said
  if [ -n "$pending" ]; then
    [ -z "$JUDGED" ] || echo "judged: $JUDGED"
    echo "if every answer is false: STOP - paused, waiting on the owner: ${V[waiting_on_owner]}"
    exit 3
  fi
  echo "next: STOP - paused, waiting on the owner: ${V[waiting_on_owner]}"
  because "$1"
  [ -z "$JUDGED" ] || echo "judged: $JUDGED"
  exit 0
}
for id in "${IDS[@]}"; do
  [ -z "${OFF[$id]+x}" ] || continue
  cond_true "${COND[$id]}" || continue
  why="$COND_WHY"
  if [ "${ASK[$id]}" != "-" ]; then
    q="${ASK[$id]//\{waiting_on_owner\}/${V[waiting_on_owner]}}"; q="${q//\{highs_not_recorded\}/$HIGHS_NOT_RECORDED}"
    q="${q//\{dossier_names\}/${SHOW_NOTE[dossier.lists_open]:-dossier: ${V[dossier]}}}"
    case "${JUDGE[$id]:-}" in
      false) continue ;;
      true) why="${why:+$why; }judged true: $q" ;;
      *) SAID+=("needs judgement: row $id - $q"); pending="${pending:+$pending,}$id"; continue ;;
    esac
  fi
  if [ "${KIND[$id]}" = gate ]; then SAID+=("in force: row $id - ${ACTION[$id]}" "  because: $why"); continue; fi
  # row 3 true: its action - the pause - is taken only when no row below stands (after the loop), never here: the rows
  # below are read on, and the first that stands is given (V26b: taken here on 3=true, the pause hid rows 6 and 9b)
  [ "$id" != 3 ] || continue
  said
  echo "next: row $id - ${ACTION[$id]}"
  because "$why"
  [ -z "$JUDGED" ] || echo "judged: $JUDGED"
  if [ -n "$pending" ]; then
    echo "only if every row that needs judgement above is false (rows $pending): answer them with --judge <row>=true|false."
    exit 3
  fi
  exit 0
done
# No row below stands on the flags. With the owner absent that is row 3's end, not a hole: "take the first [row] that
# does not [depend on the answer]; if none, stop and say what is waiting" (NEXT.md) - decided by the flags (row 3 is
# never answered), and given only once no row is left to judge (paused). The because line says what stood last: the
# skeleton that names the open findings (row 9b done), and the wait that turned 7b off (and 12 and 16 with it).
if [ "${V[waiting_on_owner]}" != none ]; then
  why="waiting_on_owner=${V[waiting_on_owner]}, and no row below row 3 stands"
  if [ "${V[open_findings.total]}" -gt 0 ] && [ "${V[dossier.lists_open]}" = yes ]; then
    why="$why; the dossier names the ${V[open_findings.total]} open finding(s) (dossier=${V[dossier]}: row 9b is done)"
  fi
  if [ "${V[waiting_on_owner.real_manager]}" = yes ] && [ "${V[real_manager.owed]}" = yes ]; then
    why="$why; row 7b waits on that answer (an item names RPC_URL or is the chain question), rows 12 and 16 wait on 7b (real_manager_battery=${V[real_manager_battery]})"
  fi
  paused "$why - stop and say what is waiting; run this again when the owner has answered"
fi
said
[ -z "$JUDGED" ] || echo "judged: $JUDGED"
if [ -n "$pending" ]; then
  echo "no row below them is true on the flags alone: if every row that needs judgement (rows $pending) is false, no row is true: the table has a hole or a flag is stale."
  exit 3
fi
echo "no row is true: the table has a hole or a flag is stale"
exit 1
