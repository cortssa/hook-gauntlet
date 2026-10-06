# shellcheck shell=bash
#
# threats.sh - the independent threat model against the walker's own list, by id: read in one place, by
# scripts/threat-diff.sh (which writes the report and prints the STATE.md line) and by scripts/next.sh (which refuses
# phase 3's close while an independent threat is left unanswered, and a `threat_model:` flag the files do not bear out).
#
# The problem it solves: the walker of the route writes the spec, the threat list, the invariants and the tests, so every
# one of them carries the same blind spots - the threat it never thought of has no row, no invariant and no test, and
# nothing in the route can see the gap. A fresh agent that sees only the owner's spec, the hook's public interface and
# the economic model writes its own list (briefs/threat-model.md); this compares the two by id, and an independent
# threat the walker's list does not match must be turned into an invariant or refused in writing - never dropped.
# Nothing here reads free text (the kit's rule since v0.5: every new input is a file with ids and one-line forms):
#
#   <proj>/.gauntlet/THREATS-independent.md   the fresh agent's, copied in unchanged:
#       model: <the model that wrote it, as specific as you can be>          (once, at column 0)
#       received: <what it was given>                                        (once, at column 0)
#       T-<n>: <who acts> / <what is lost, and by whom> / <the call sequence>  (one line per threat, at column 0)
#   <proj>/.gauntlet/THREATS.md               the walker's, written in phase 2, its matching lines filled after:
#       W-<n>: <who acts> / <what is lost, and by whom> / <the call sequence>
#       from: <where it came from: doctrine/HOOK-ATTACKS.md class <#>, or the spec's section and row>
#       matches: T-<n>[, T-<n>...]     or     new          (one of the two: `new` = no independent threat is this one)
#     a threat's block is its W- line and the lines right under it; a blank line or a heading ends it
#   DECISIONS.md (beside STATE.md)            a refusal is a heading of the form, and only of it
#       ## <id> · <YYYY-MM-DD> · threat T-<n>[, T-<n>...] refused: <why, in one line>
#     an id (a letter and a digit at least), a real date, ` · ` (a middle dot between spaces) before `threat`. A heading
#     that refuses an id in any other shape - no id, no date, a date that is not one, hyphens for the dots - is not a
#     refusal: the threat stays unmatched, and the diff names that line and what is wrong with it
#   a test file under test/ or pending/       an invariant made of an independent threat names it on a line of its own,
#       /// @custom:threat T-<n>[, T-<n>...]   right above the test function, in a .sol file that has a test or invariant
#     function. solc reads every `///` line as NatSpec and accepts no tag of a project's own but @custom:<name>:
#     `/// @threat` above a function does not build ("Documentation tag @threat not valid for functions"), and is refused
#
# An id is T-<n> (the independent list) or W-<n> (the walker's), <n> from 1, no leading zero. Each fact has one line, and
# a line that starts like one of them and is not of its form is REFUSED with its line number - never skipped: a threat
# line with fewer than three fields (` / ` between them) or a placeholder field (`?`, `TBD`, `...`, `<who>`), an id twice,
# a walker's id in the independent list or the reverse, a matching line in another shape or outside a threat's block,
# a block with no `from:` or no matching line, an id named that the independent list does not have, `@custom:threat` in
# any other shape, `@threat` at all, a tag in a file with no test. A refusal heading whose reason is a placeholder, or
# that is not of the form above, is not a refusal (said).
#
# Each independent threat is, in this order: MATCHED (a W- block names it in `matches:`), NEW (no walker's threat
# matches it - it is new to the route - and a test names it: an invariant now), REFUSED (neither, and DECISIONS.md
# refuses it in the form above), or UNMATCHED. The STATE.md line counts the first three:
#   threat_model: diffed (<n> matched, <m> new, <k> refused)
# and is given only when none is UNMATCHED. The walker's `new` blocks (threats only the walker has) are counted in the
# report, not in the line. The report keeps both lists' full sha256 (`sha256 .gauntlet/THREATS.md: <hex>`, and the
# independent list's): the lists are frozen after the diff, and scripts/next.sh refuses a `diffed` line whose lists are
# no longer the files the report hashed - the diff is run again, and its line written again.
#
# Source it:  . "$HERE/lib/threats.sh"   (needs awk, find, sha256sum or shasum; bash 4)
#   threats_diff <proj> <DECISIONS.md, or "" for none>
#     sets TD_STATE   not_yet (a file missing) | bad (a file not of its form) | unmatched | diffed
#          TD_WHY     one line: what is missing, the first line refused, or the unmatched threats with what each lacks
#          TD_N TD_M TD_K   matched, new, refused;  TD_U the unmatched;  TD_T the independent threats;  TD_W the walker's;
#          TD_WOWN    the walker's `new` blocks;  TD_MODEL TD_RECEIVED;  TD_LINE the STATE.md line (diffed only)
#          TD_IND_SHA TD_WAL_SHA   the two lists' sha256, 8 hex;  TD_IND_SHA256 TD_WAL_SHA256   the same, in full
#          TD_REPORT  one line per independent threat, then one per walker's own threat (the report's body)
#     returns 0 diffed, 1 not_yet or unmatched, 2 bad

td_sha256() { if command -v sha256sum > /dev/null 2>&1; then sha256sum < "$1" | cut -d' ' -f1; else shasum -a 256 < "$1" | cut -d' ' -f1; fi; }

# the shared part of the two lists' awk: trim, a placeholder field, a threat line's three fields
_TD_AWK_LIB='
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function placeholder(s,   l) { l = tolower(s)
  return (l ~ /^(\?+|-+|\.\.\.+|tbd|tba|todo|n\/a|none|xxx)$/ || s ~ /^<[^>]*>$/ || index(s, "{{") > 0) }
function err(m) { gsub(/\t/, " ", m); print "ERR\t" FNR "\t" m; bad = 1; exit }
# fields <the text after "X-n:"> <id>: sets WHO LOST SEQ, or err
function fields(r, id,   i) {
  r = trim(r); gsub(/\t/, " ", r)
  i = index(r, " / "); if (!i) err(id " has fewer than three fields: <who acts> / <what is lost> / <the call sequence>, \" / \" between them")
  WHO = trim(substr(r, 1, i - 1)); r = substr(r, i + 3)
  i = index(r, " / "); if (!i) err(id " has fewer than three fields: <who acts> / <what is lost> / <the call sequence>, \" / \" between them")
  LOST = trim(substr(r, 1, i - 1)); SEQ = trim(substr(r, i + 3))
  if (WHO == "" || placeholder(WHO)) err(id ": who acts is empty or a placeholder (\"" WHO "\")")
  if (LOST == "" || placeholder(LOST)) err(id ": what is lost is empty or a placeholder (\"" LOST "\")")
  if (SEQ == "" || placeholder(SEQ)) err(id ": the call sequence is empty or a placeholder (\"" SEQ "\")")
}
# a line that STARTS like a threat id (after list markers, a heading, emphasis) - of the form or not
function idlike(s) { return (s ~ /^[ \t>#*+_`-]*[TtWw]-?[0-9]+([^0-9A-Za-z]|$)/) }
'

_td_read_independent() { # <file>: MODEL/RECEIVED/T records, or one ERR
  LC_ALL=C awk "$_TD_AWK_LIB"'
    { sub(/\r$/, "") }
    /^model:/ { if (model++) err("model: is given twice"); v = trim(substr($0, 7)); if (v == "" || placeholder(v)) err("model: is empty or a placeholder: the model that wrote this list, as specific as you can be")
      gsub(/\t/, " ", v); print "MODEL\t" FNR "\t" v; next }
    /^received:/ { if (recv++) err("received: is given twice"); v = trim(substr($0, 10)); if (v == "" || placeholder(v)) err("received: is empty or a placeholder: what this agent was given (the owner'"'"'s spec, the interface, the economic model)")
      gsub(/\t/, " ", v); print "RECEIVED\t" FNR "\t" v; next }
    /^T-[1-9][0-9]*:([ \t]|$)/ { id = substr($0, 1, index($0, ":") - 1)
      if (id in seen) err(id " is given twice (lines " seen[id] " and " FNR ")"); seen[id] = FNR
      fields(substr($0, length(id) + 2), id); n++
      print "T\t" FNR "\t" id "\t" WHO "\t" LOST "\t" SEQ; next }
    /^W-[1-9][0-9]*:/ { err("a walker'"'"'s id (" substr($0, 1, index($0, ":") - 1) ") in the independent list: the independent agent never sees the walker'"'"'s list, and its own ids are T-<n>") }
    idlike($0) { err("this line starts with a threat id and is not a threat line - T-<n>: <who acts> / <what is lost> / <the call sequence>, at column 0, <n> from 1 with no leading zero: \"" substr($0, 1, 80) "\"") }
    END { if (bad) exit; if (!model) { FNR = 0; err("there is no model: line (the model that wrote this list)") }
      if (!recv) { FNR = 0; err("there is no received: line (what this agent was given)") }
      if (!n) { FNR = 0; err("there is no threat line (T-<n>: <who acts> / <what is lost> / <the call sequence>)") } }' "$1"
}

_td_read_walker() { # <file>: W records "W line id who lost seq from match" (match: new, or T-a,T-b), or one ERR
  LC_ALL=C awk "$_TD_AWK_LIB"'
    function close_block() { if (!inb) return
      if (from == "") { FNR = bline; err(bid " has no from: line (doctrine/HOOK-ATTACKS.md class <#>, or the spec'"'"'s section and row)") }
      if (mat == "") { FNR = bline; err(bid " has no matching line: matches: T-<n>[, T-<n>...] or new, right under it (filled once THREATS-independent.md is in)") }
      print "W\t" bline "\t" bid "\t" bwho "\t" blost "\t" bseq "\t" from "\t" mat; inb = 0 }
    { sub(/\r$/, ""); l = $0; sub(/^[ \t]*([-*+][ \t]+)?/, "", l) }
    /^[ \t]*$/ || /^#/ { close_block(); next }
    /^W-[1-9][0-9]*:([ \t]|$)/ { close_block(); id = substr($0, 1, index($0, ":") - 1)
      if (id in seen) err(id " is given twice (lines " seen[id] " and " FNR ")"); seen[id] = FNR
      fields(substr($0, length(id) + 2), id); n++
      inb = 1; bid = id; bline = FNR; bwho = WHO; blost = LOST; bseq = SEQ; from = ""; mat = ""; next }
    /^T-[1-9][0-9]*:/ { err("an independent id (" substr($0, 1, index($0, ":") - 1) ") in the walker'"'"'s list: the walker'"'"'s ids are W-<n>; an independent threat is named in a matches: line") }
    l ~ /^from:/ { if (!inb) err("from: outside a threat'"'"'s block (a W- line and the lines right under it; a blank line ends it)")
      if (from != "") err(bid " has two from: lines"); from = trim(substr(l, 6)); gsub(/\t/, " ", from)
      if (from == "" || placeholder(from)) err(bid ": from: is empty or a placeholder"); next }
    l ~ /^matches:/ { if (!inb) err("matches: outside a threat'"'"'s block (a W- line and the lines right under it; a blank line ends it)")
      if (mat != "") err(bid " has two matching lines"); v = trim(substr(l, 9))
      if (v !~ /^T-[1-9][0-9]*([ \t]*,[ \t]*T-[1-9][0-9]*)*([ \t]+[(][^()]*[)])?$/) err(bid ": \"" l "\" is not matches: T-<n>[, T-<n>...] (an optional comment in parentheses after)")
      sub(/[ \t]+[(].*$/, "", v); gsub(/[ \t]/, "", v); mat = v; next }
    l ~ /^new([ \t]+[(][^()]*[)])?[ \t]*$/ { if (!inb) err("new outside a threat'"'"'s block (a W- line and the lines right under it; a blank line ends it)")
      if (mat != "") err(bid " has two matching lines"); mat = "new"; next }
    inb && l ~ /^(matches|match|matched|new)([^A-Za-z]|$)/ { err("\"" l "\" is not a matching line: matches: T-<n>[, T-<n>...] or new") }
    idlike($0) { err("this line starts with a threat id and is not a threat line - W-<n>: <who acts> / <what is lost> / <the call sequence>, at column 0, <n> from 1 with no leading zero: \"" substr($0, 1, 80) "\"") }
    inb { err(bid "'"'"'s block has a line that is none of from:, matches: T-<n> or new: \"" substr(l, 1, 80) "\" (a blank line ends a threat'"'"'s block)") }
    END { if (bad) exit; close_block(); if (!n) { FNR = 0; err("there is no threat line (W-<n>: <who acts> / <what is lost> / <the call sequence>)") } }' "$1"
}

_td_read_decisions() { # <DECISIONS.md>: REF "REF line id reason" per id refused; HINT "HINT line id what" for a near miss
  LC_ALL=C awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function realdate(d,   y, m, dd, ml) {
      if (d !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) return 0
      y = substr(d, 1, 4) + 0; m = substr(d, 6, 2) + 0; dd = substr(d, 9, 2) + 0
      if (m < 1 || m > 12 || dd < 1) return 0
      ml = (m == 2) ? ((y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ? 29 : 28) : ((m == 4 || m == 6 || m == 9 || m == 11) ? 30 : 31)
      return dd <= ml }
    # what keeps <the text between ## and "threat"> from being "<id> · <YYYY-MM-DD> ·" - "" when nothing does
    function notform(p,   f, id, d) {
      p = trim(p)
      if (p == "") return "there is no id and no date before '"'"'threat'"'"'"
      if (index(p, "·") == 0) return "the separators are not '"'"' · '"'"' (a middle dot between spaces)"
      if (p !~ /^[^ \t·]+[ \t]+·[ \t]+[^ \t·]+[ \t]+·$/) return "not <id> · <YYYY-MM-DD> before '"'"'threat'"'"'"
      split(p, f, /[ \t]+·[ \t]*/); id = f[1]; d = f[2]
      if (id !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ || id !~ /[A-Za-z]/ || id !~ /[0-9]/) return "'"'"'" id "'"'"' is not an id: a letter and a digit at least, D-4"
      if (!realdate(d)) return "'"'"'" d "'"'"' is not a real date (YYYY-MM-DD)"
      return "" }
    { sub(/\r$/, "") }
    /^##[ \t]/ && match($0, /[ \t]threat[ \t]+T-[1-9][0-9]*([ \t]*,[ \t]*T-[1-9][0-9]*)*[ \t]+refused:/) {
      pre = substr($0, 3, RSTART - 3)
      head = substr($0, RSTART, RLENGTH); why = trim(substr($0, RSTART + RLENGTH)); gsub(/\t/, " ", why)
      sub(/^[ \t]threat[ \t]+/, "", head); sub(/[ \t]+refused:$/, "", head); gsub(/[ \t]/, "", head)
      k = split(head, ids, ","); l = tolower(why); nf = notform(pre)
      ph = (why == "" || l ~ /^(\?+|-+|\.\.\.+|tbd|tba|todo|n\/a|none|xxx)$/ || why ~ /^<[^>]*>$/ || index(why, "{{") > 0)
      for (i = 1; i <= k; i++) {
        if (nf != "") print "HINT\t" FNR "\t" ids[i] "\tline " FNR " refuses it in another form than ## <id> · <YYYY-MM-DD> · threat T-<n> refused: <why> (" nf "), and is not read as a refusal"
        else if (ph) print "HINT\t" FNR "\t" ids[i] "\tits refusal on line " FNR " gives no reason (\"" why "\")"
        else print "REF\t" FNR "\t" ids[i] "\t" why }
      next }
    tolower($0) ~ /threat/ { s = $0
      while (match(s, /T-[1-9][0-9]*/)) { print "HINT\t" FNR "\t" substr(s, RSTART, RLENGTH) "\tline " FNR " names it, not in the form ## <id> · <date> · threat T-<n> refused: <why>"; s = substr(s, RSTART + RLENGTH) } }' "$1"
}

_td_read_tags() { # <proj>: TAG "TAG file:line id" per id a test names; or one ERR "ERR file:line what"
  local proj="$1" d
  local -a dirs=()
  for d in test pending; do [ -d "$proj/$d" ] && dirs+=("$d"); done
  [ ${#dirs[@]} -gt 0 ] || return 0
  ( cd "$proj" && find -L "${dirs[@]}" -name '*.sol' -type f -print0 2> /dev/null | LC_ALL=C sort -z ) | while IFS= read -r -d '' f; do
      grep -qE '@(custom:)?threat' "$proj/$f" 2> /dev/null || continue
      LC_ALL=C awk -v f="$f" '
        { sub(/\r$/, "") }
        /function[ \t]+(test|invariant)[A-Za-z0-9_]*[ \t]*\(/ { hastest = 1 }
        index($0, "@threat") {
          if ($0 ~ /^[ \t]*\/\/\/[ \t]*@threat([ \t]|$)/) print "ERR\t" f ":" FNR "\t/// @threat does not compile (solc: \"Documentation tag @threat not valid for functions\" - a tag of your own is @custom:<name>): write /// @custom:threat T-<n>[, T-<n>...]"
          else print "ERR\t" f ":" FNR "\t@threat is not the tag: write /// @custom:threat T-<n>[, T-<n>...], on a line of its own right above the test function"
          bad = 1; exit }
        index($0, "@custom:threat") {
          if ($0 !~ /^[ \t]*\/\/\/[ \t]*@custom:threat([ \t]|$)/) { print "ERR\t" f ":" FNR "\t@custom:threat is not on a line of its own of the form /// @custom:threat T-<n>[, T-<n>...]"; bad = 1; exit }
          s = $0; sub(/^[ \t]*\/\/\/[ \t]*@custom:threat/, "", s); k = split(s, w, /[ \t,]+/); got = 0
          for (i = 1; i <= k; i++) { if (w[i] == "") continue; if (w[i] !~ /^T-[1-9][0-9]*$/) break; tags[++nt] = w[i] "\t" f ":" FNR; got++ }
          if (!got) { print "ERR\t" f ":" FNR "\t/// @custom:threat names no id (T-<n>, n from 1)"; bad = 1; exit } }
        END { if (bad) exit
          if (nt && !hastest) { print "ERR\t" f "\tnames a threat (/// @custom:threat) and has no test or invariant function: the tag goes right above the test that turns the threat into an invariant"; exit }
          for (i = 1; i <= nt; i++) { split(tags[i], p, "\t"); print "TAG\t" p[2] "\t" p[1] } }' "$proj/$f"
    done
}

# shellcheck disable=SC2034   # the TD_* globals are read by the scripts that source this (threat-diff.sh, next.sh)
threats_diff() {
  local proj="$1" dec="$2" ind wal kind ln id a b c d e f
  local -a t_order=() w_order=()
  local -A t_txt=() w_txt=() w_from=() w_mat=() matched_by=() tag=() ref=() ref_why=() hint=()
  ind="$proj/.gauntlet/THREATS-independent.md"; wal="$proj/.gauntlet/THREATS.md"
  TD_STATE="" TD_WHY="" TD_N=0 TD_M=0 TD_K=0 TD_U=0 TD_T=0 TD_W=0 TD_WOWN=0 TD_MODEL="" TD_RECEIVED="" TD_LINE="" TD_REPORT=""
  TD_IND_SHA="" TD_WAL_SHA="" TD_IND_SHA256="" TD_WAL_SHA256=""
  if [ ! -f "$ind" ]; then
    TD_STATE=not_yet; TD_WHY="there is no .gauntlet/THREATS-independent.md - a fresh agent writes it from briefs/threat-model.md (the owner's spec, the hook's public interface and the economic model, nothing of the route's)"; return 1
  fi
  if [ ! -f "$wal" ]; then
    TD_STATE=not_yet; TD_WHY="there is no .gauntlet/THREATS.md - the walker's own list, written in phase 2 from doctrine/HOOK-ATTACKS.md and the spec (briefs/threat-model.md)"; return 1
  fi
  TD_IND_SHA256="$(td_sha256 "$ind")"; TD_WAL_SHA256="$(td_sha256 "$wal")"; TD_IND_SHA="${TD_IND_SHA256:0:8}"; TD_WAL_SHA="${TD_WAL_SHA256:0:8}"
  while IFS=$'\t' read -r kind ln a b c d; do
    case "$kind" in
      ERR) TD_STATE=bad; TD_WHY=".gauntlet/THREATS-independent.md${ln:+ line $ln}: $a"; [ "$ln" != 0 ] || TD_WHY=".gauntlet/THREATS-independent.md: $a"; return 2 ;;
      MODEL) TD_MODEL="$a" ;;
      RECEIVED) TD_RECEIVED="$a" ;;
      T) t_order+=("$a"); t_txt[$a]="$b / $c / $d" ;;
    esac
  done < <(_td_read_independent "$ind")
  while IFS=$'\t' read -r kind ln id a b c d e; do
    case "$kind" in
      ERR) TD_STATE=bad; TD_WHY=".gauntlet/THREATS.md${ln:+ line $ln}: $id"; [ "$ln" != 0 ] || TD_WHY=".gauntlet/THREATS.md: $id"; return 2 ;;
      W) w_order+=("$id"); w_txt[$id]="$a / $b / $c"; w_from[$id]="$d"; w_mat[$id]="$e" ;;
    esac
  done < <(_td_read_walker "$wal")
  TD_T=${#t_order[@]}; TD_W=${#w_order[@]}
  for id in "${w_order[@]}"; do
    if [ "${w_mat[$id]}" = new ]; then TD_WOWN=$((TD_WOWN + 1)); continue; fi
    for f in ${w_mat[$id]//,/ }; do
      [ -n "${t_txt[$f]+x}" ] || { TD_STATE=bad; TD_WHY=".gauntlet/THREATS.md: $id matches $f, and THREATS-independent.md has no $f"; return 2; }
      matched_by[$f]="${matched_by[$f]:+${matched_by[$f]}, }$id"
    done
  done
  while IFS=$'\t' read -r kind ln id; do
    case "$kind" in
      ERR) TD_STATE=bad; TD_WHY="$ln: $id"; return 2 ;;
      TAG) [ -n "${t_txt[$id]+x}" ] || { TD_STATE=bad; TD_WHY="$ln names $id (/// @custom:threat), and THREATS-independent.md has no $id"; return 2; }
        [ -n "${tag[$id]+x}" ] || tag[$id]="$ln" ;;
    esac
  done < <(_td_read_tags "$proj")
  if [ -n "$dec" ] && [ -f "$dec" ]; then
    while IFS=$'\t' read -r kind ln id a; do
      case "$kind" in
        REF) [ -n "${t_txt[$id]+x}" ] || { TD_STATE=bad; TD_WHY="$(basename "$dec") line $ln refuses $id, and THREATS-independent.md has no $id"; return 2; }
          [ -n "${ref[$id]+x}" ] || { ref[$id]="$ln"; ref_why[$id]="$a"; } ;;
        HINT) [ -n "${hint[$id]+x}" ] || hint[$id]="$a" ;;
      esac
    done < <(_td_read_decisions "$dec")
  fi
  local un="" decn
  decn="$(basename "${dec:-DECISIONS.md}")"
  for id in "${t_order[@]}"; do
    if [ -n "${matched_by[$id]+x}" ]; then TD_N=$((TD_N + 1)); TD_REPORT+="$id  matched by ${matched_by[$id]}  | ${t_txt[$id]}"$'\n'
    elif [ -n "${tag[$id]+x}" ]; then TD_M=$((TD_M + 1)); TD_REPORT+="$id  new - an invariant: ${tag[$id]}  | ${t_txt[$id]}"$'\n'
    elif [ -n "${ref[$id]+x}" ]; then TD_K=$((TD_K + 1)); TD_REPORT+="$id  refused - $decn line ${ref[$id]}: ${ref_why[$id]}  | ${t_txt[$id]}"$'\n'
    else TD_U=$((TD_U + 1)); TD_REPORT+="$id  UNMATCHED  | ${t_txt[$id]}"$'\n'
      un="${un:+$un; }$id (${t_txt[$id]})${hint[$id]:+ - $decn: ${hint[$id]}}"; fi
  done
  for id in "${w_order[@]}"; do
    [ "${w_mat[$id]}" = new ] && TD_REPORT+="$id  the walker's own (new)  | ${w_txt[$id]}  (from: ${w_from[$id]})"$'\n'
  done
  if [ "$TD_U" -gt 0 ]; then
    TD_STATE=unmatched
    TD_WHY="$TD_U of $TD_T independent threats neither matched by the walker's list (matches: in .gauntlet/THREATS.md), turned into an invariant (/// @custom:threat T-<n> in a test) nor refused in DECISIONS.md (## <id> · <date> · threat T-<n> refused: <why>): $un"
    return 1
  fi
  TD_STATE=diffed; TD_LINE="threat_model: diffed ($TD_N matched, $TD_M new, $TD_K refused)"
  return 0
}
