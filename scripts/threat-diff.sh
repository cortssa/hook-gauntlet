#!/usr/bin/env bash
#
# threat-diff.sh - the independent threat model against the walker's own list, by id, before phase 3 closes.
#
# The problem it solves: everything the route writes before round 1 - the spec's hostile-actor table, the threat list,
# the invariants, the tests - comes from one reader, and a threat that reader never thought of has no row, no invariant
# and no test: no judge of the route can see what nobody wrote down. So before phase 3 closes, a fresh agent that sees
# only the owner's spec, the hook's public interface and the economic model writes its own numbered list
# (briefs/threat-model.md), and this script compares it with the walker's, by the ids the walker's matching lines name.
# An independent threat the walker's list does not match must become an invariant or be refused in writing; while one
# is neither, phase 3 does not close (scripts/next.sh refuses `phase:` 4 or higher, doctrine/NEXT.md row 4b).
#
# Usage:   scripts/threat-diff.sh <proj>
# Reads:   <proj>/.gauntlet/THREATS-independent.md   the fresh agent's list (model:, received:, T-<n>: lines)
#          <proj>/.gauntlet/THREATS.md               the walker's (W-<n>: lines, each with from: and matches: T-<n> | new)
#          the DECISIONS.md beside STATE.md (.gauntlet/'s, or the root's with location: root)   refusals, one heading each:
#                                                    ## <id> · <date> · threat T-<n> refused: <why>
#          the .sol files under <proj>/test/ and <proj>/pending/        invariants: /// @custom:threat T-<n>, on a line
#                                                    of its own right above the test function (solc builds no other tag)
#          The forms, and the order each independent threat is read in (matched, new - an invariant -, refused,
#          unmatched): scripts/lib/threats.sh, briefs/threat-model.md. Nothing else is read, and no free text is parsed.
# Output:  <proj>/.gauntlet/reports/06-threats.txt, when both lists read: the verdict, the two files' sha256 in full
#          (`sha256 .gauntlet/THREATS-independent.md: <hex>`, `sha256 .gauntlet/THREATS.md: <hex>` - the lists are frozen
#          after the diff: scripts/next.sh refuses a `diffed` line whose lists are no longer these files), the model
#          that wrote the independent list and what it received, one line per independent threat with its status, one
#          per walker's own threat (`new` in THREATS.md), and the line for STATE.md. On stdout, the counts and then:
#            threat_model: diffed (<n> matched, <m> new, <k> refused)      every independent threat answered (exit 0)
#            threat-diff: REFUSED - <u> of <t> independent threats neither matched ... : T-3 (...); T-7 (...)  (exit 1),
#              and that the line for STATE.md stays `threat_model: not yet`
#            threat_model: not yet - <the file missing, and who writes it>   (exit 1, nothing written)
#          This script does not edit STATE.md: the agent writes the line it prints.
# Exit:    0 diffed; 1 not diffed - a list missing, or an independent threat unanswered (each named); 2 REFUSED, nothing
#          written: no <proj>, bad arguments, or a file not of its form (the file, its line and what is wrong).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/threats.sh
. "$HERE/lib/threats.sh" || { echo "threat-diff: $HERE/lib/threats.sh is missing"; exit 2; }

refuse() { echo "threat-diff: REFUSED - $*"; echo "threat-diff: nothing written."; exit 2; }
[ "$#" -eq 1 ] || refuse "usage: scripts/threat-diff.sh <proj> (one argument, the project's directory)."
case "$1" in -*) refuse "usage: scripts/threat-diff.sh <proj> - '$1' is not a directory." ;; esac
[ -d "$1" ] || refuse "$1 is not a directory (the project: the directory with .gauntlet/ in it)."
PROJ="$(cd "$1" && pwd)" || refuse "cannot enter $1."

# the DECISIONS.md beside STATE.md, as scripts/next.sh reads it (no STATE.md yet: .gauntlet/'s, else the root's)
if [ -f "$PROJ/.gauntlet/STATE.md" ]; then DEC="$PROJ/.gauntlet/DECISIONS.md"
elif [ -f "$PROJ/STATE.md" ]; then DEC="$PROJ/DECISIONS.md"
elif [ -f "$PROJ/.gauntlet/DECISIONS.md" ]; then DEC="$PROJ/.gauntlet/DECISIONS.md"
else DEC="$PROJ/DECISIONS.md"; fi
[ -f "$DEC" ] || DEC=""

threats_diff "$PROJ" "$DEC"; rc=$?
case "$TD_STATE" in
  not_yet) echo "threat_model: not yet - $TD_WHY"; exit 1 ;;
  bad) refuse "$TD_WHY" ;;
esac

REP_DIR="$PROJ/.gauntlet/reports"; REP="$REP_DIR/06-threats.txt"
mkdir -p "$REP_DIR" || refuse "cannot create $REP_DIR."
if [ "$TD_STATE" = diffed ]; then VERDICT="threat-diff: diffed - every independent threat is matched, an invariant, or refused in writing"
else VERDICT="threat-diff: REFUSED - $TD_WHY"; fi
{
  echo "$VERDICT"
  echo "date: $(date +%F)"
  echo "independent: .gauntlet/THREATS-independent.md (sha256 $TD_IND_SHA...) - $TD_T threats; model: $TD_MODEL; received: $TD_RECEIVED"
  echo "walker: .gauntlet/THREATS.md (sha256 $TD_WAL_SHA...) - $TD_W threats, $TD_WOWN of them the walker's own (new: no independent threat matches)"
  echo "sha256 .gauntlet/THREATS-independent.md: $TD_IND_SHA256"
  echo "sha256 .gauntlet/THREATS.md: $TD_WAL_SHA256"
  if [ -n "$DEC" ]; then echo "refusals read from: ${DEC#"$PROJ/"}"; else echo "refusals read from: no DECISIONS.md"; fi
  echo "counts: $TD_N matched, $TD_M new (not in the walker's list, now an invariant), $TD_K refused, $TD_U unmatched - of $TD_T"
  echo
  printf '%s' "$TD_REPORT"
  echo
  if [ "$TD_STATE" = diffed ]; then echo "the line for STATE.md: $TD_LINE"
  else echo "the line for STATE.md stays: threat_model: not yet"; fi
} > "$REP" || refuse "cannot write $REP."

echo "threat-diff: $TD_T independent threats ($TD_IND_SHA, model: $TD_MODEL), $TD_W of the walker's ($TD_WAL_SHA; $TD_WOWN its own)"
echo "threat-diff: $TD_N matched, $TD_M new (now an invariant), $TD_K refused, $TD_U unmatched - report: .gauntlet/reports/06-threats.txt"
if [ "$TD_STATE" = diffed ]; then
  echo "$TD_LINE"
  exit 0
fi
echo "threat-diff: REFUSED - $TD_WHY"
echo "threat-diff: the line for STATE.md stays 'threat_model: not yet' - phase 3 does not close (doctrine/NEXT.md row 4b)"
exit "$rc"
