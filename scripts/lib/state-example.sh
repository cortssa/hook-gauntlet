# shellcheck shell=bash
#
# state-example.sh - is this state file still the kit's example (state/STATE.md, DECISIONS.md, LOG.md, copied)? The one
# test, read by scripts/next.sh (which refuses such a file before it reads a row) and by scripts/init-state.sh (which
# replaces it with an empty one in the same step - K52: next.sh's refusal sent the walker to init-state.sh, which
# refused the example in its turn: two steps where the refusal promised one).
#
# The problem it solves: a STATE.md that is still the example is not a state, and no row is read from it (K40: next.sh
# answered "row 13 - a REGRESSION round ... r05" on the example BlockCapHook, twice, and the walker gave up on next.sh).
# Known by its marker line, or by the example hook's name in the title (the first "# " line); the DECISIONS.md and
# LOG.md beside it likewise. In STATE.md the marker counts anywhere; in DECISIONS.md and LOG.md only as a whole line
# (K48: an honest LOG.md that quoted the line it had deleted was refused, with no way out but editing an append-only
# file - V40). And STATE.md by its values (K48: the example with its marker deleted, as the line itself says, and
# retitled, as QUICKSTART 5 says, answered "row 13 - a REGRESSION round" again - V40): a flag block that shares three
# or more non-generic lines with the kit's own state/STATE.md is the example. The lines are compared with the spacing
# collapsed on both sides - each trimmed, its runs of spaces and tabs one space (K49: the example re-aligned, one space
# after each colon, the same values, walked to row 13 again - V41) - and the shared lines are the example's own,
# whatever the spacing of the copy. A flag line written `key:value`, no space after its first colon, is read as
# `key: value` on both sides (v0.4.1, D7: `ceiling:8 model rounds ...` and the like walked as a state - K49's gap).
# The generic flags (phase, battery, blackbox, dossier, rehearsal, real_manager_battery, location) are left out: a new
# project's can match the example's by chance.
#
# Source it:  . "$HERE/lib/state-example.sh"   (needs awk and grep; bash 4)
#   flag_block <STATE.md>                 the flag block's lines (the first fenced block with a phase: line); exit 1
#                                         when there is none
#   is_kit_example <file> <whole>         0 when the file is the kit's example by its marker or its title; <whole> 1:
#                                         the marker counts only as a whole line (DECISIONS.md, LOG.md), else anywhere
#   example_by_values <STATE.md> <kit>    0 when its flag block shares three or more non-generic lines with
#                                         <kit>/state/STATE.md's, and then prints those lines as the example has them

EXAMPLE_MARKER='*Example file. The project is fictional. Delete this and start yours.*'
EXAMPLE_NONGENERIC='^(last_audit_round|last_other_round|open_findings|ceiling|waiting_on_owner|notes|bytecode_changed_since):'

flag_block() { # flag_block <STATE.md>: the flag block's lines (the first fenced block with a phase: line); exit 1 when none
  LC_ALL=C awk '
    { sub(/\r$/, "") }
    /^```/ { if (inb && has) { found = 1; exit } inb = !inb; n = 0; has = 0; next }
    inb { buf[++n] = $0; if ($0 ~ /^phase:/) has = 1 }
    END { if (!found) exit 1; for (i = 1; i <= n; i++) print buf[i] }' "$1"
}

is_kit_example() { # is_kit_example <file> <1: the marker counts only as a whole line>: 0 when it is the kit's example
  LC_ALL=C awk -v whole="$2" -v marker="$EXAMPLE_MARKER" '{ sub(/\r$/, "") }
    whole != 1 && index($0, "Example file. The project is fictional.") { found = 1; exit }
    whole == 1 && $0 == marker { found = 1; exit }
    !titled && /^# / { titled = 1; if ($0 ~ /BlockCapHook/) { found = 1; exit } }
    END { exit found ? 0 : 1 }' "$1"
}

_example_values() { # _example_values <STATE.md> <kit>: the example's own lines for the flag block's non-generic lines
  # that are the kit's example's once the spacing is collapsed (each trimmed, runs of spaces and tabs one space), in its order
  local ex="$2/state/STATE.md" mine theirs
  [ -f "$ex" ] || return 0
  theirs="$(flag_block "$ex" | grep -E "$EXAMPLE_NONGENERIC")" || return 0
  mine="$(flag_block "$1" | grep -E "$EXAMPLE_NONGENERIC")" || return 0
  LC_ALL=C awk 'function sq(s) { gsub(/[ \t]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s); if (s ~ /^[a-z_]+:[^ ]/) sub(/:/, ": ", s); return s }
    NR == FNR { k = sq($0); if (!(k in ex)) ex[k] = $0; next }
    { k = sq($0) } (k in ex) && !seen[k]++ { print ex[k] }' <(printf '%s\n' "$theirs") - <<< "$mine"
}

example_by_values() { # example_by_values <STATE.md> <kit>: 0, printing the shared lines, when three or more are shared
  local same
  same="$(_example_values "$1" "$2")"
  [ "$(grep -c . <<< "$same")" -ge 3 ] || return 1
  printf '%s\n' "$same"
}
