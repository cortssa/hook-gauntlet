#!/usr/bin/env bash
#
# init-state.sh - write a project's .gauntlet/ from the kit's state/ templates, the examples emptied, and record the
# hashes of the spec and of src/: both are the owner's.
#
# The problem it solves: the state convention was installed by hand - copy three example files, then empty them - and
# the walkers of the route did not: one walked the kit's example as its own state for two hours, one announced "write
# the state files" four times and wrote none. And the spec was nobody's to guard: a walker appended 35 "owner decisions"
# to the owner's SPEC.md before it had read the hook, three of them false on the code. So one command writes the three
# files a new project starts with, and records the spec's SHA-256, which scripts/next.sh compares on every run. And
# (v0.4.2) another walker "fixed" the hook it was auditing, in src/, when the harness refused its permission bits - a
# red recorded over the edited hook was a valid record: src/ is anchored too (scripts/lib/src-anchor.sh), and
# scripts/pending-red.sh and scripts/battery.sh compare it on every run.
#
# Usage:   scripts/init-state.sh <proj> [--spec <file>] [--src] [--by <name>]
#   <proj>          the project's directory
#   --spec <file>   the spec; a path relative to <proj> (or, when there is no such file there, to the current
#                   directory), or absolute - inside <proj> either way. Default: SPEC.md in <proj>
#   --src           on a project that has a STATE.md: re-record the anchor of src/ (signed, --by). A new project's
#                   src/ is recorded anyway: there --src changes nothing
#   --by <name>     the owner's SIGNATURE on a re-record (a non-empty string, no line break): the only way through the
#                   default refusal of `--spec` or `--src` on a project that already has a STATE.md. It is a signature,
#                   not a password - the kit cannot tell an owner from an agent at a shell; it records the name and
#                   says what it cannot know. Refused on a project with no STATE.md (a new project records both
#                   without it). `--by walker` (v0.5.3): the WALKER signs, the owner absent - accepted only when the
#                   STATE.md's notes carry an item `owner absent: <why>` (the record of the owner's absence,
#                   exactly `walker`, case-sensitive - `Walker`, `walker (owner absent)` and the like are refused,
#                   doctrine/NEXT.md's notes), else refused saying the owner is present by the record; the record then
#                   carries `by: walker (owner absent)` under its re-recorded line, and next.sh puts it in the dossier's
#                   section 8 as a divergence. The case it exists for: a hook handed over as code with no owner's spec
#                   (briefs/spec-template.md) - from phase 2 next.sh refuses a missing anchor, and the route's spec,
#                   .gauntlet/SPEC.md, is what the walker anchors (--spec .gauntlet/SPEC.md --by walker).
# Writes:  <proj>/.gauntlet/
#            STATE.md      a title for the project, the flag block with the starting values state/README.md lists
#                          (phase: 0, every bytecode_changed_since flag yes but last_promotion n/a, battery: never, ...,
#                          location: .gauntlet/) and the example's section headings - no example prose
#            DECISIONS.md  its title and its rules (what is written there, by whom), no entries
#            LOG.md        its title and its rules, no entries
#            .gitignore    state/.gitignore (the benches stay out of git)
#            spec.sha256   `<sha256>  <the spec's path relative to <proj>>` - read by scripts/next.sh, which refuses a
#                          spec whose hash differs, or that is gone. No spec found: it says so and records nothing.
#            src.sha256    `<sha256>  src/` - the anchor of src/, its file list and contents (scripts/lib/src-anchor.sh) -
#                          read by scripts/pending-red.sh and scripts/battery.sh, which refuse to run on a src/ that
#                          differs from it, or is gone. No src/, or one with no file in it yet (a hook still to be
#                          written): it says so and records nothing - the owner anchors it, signed, once the hook exists.
#          A project that HAS a STATE.md (<proj>/.gauntlet/STATE.md, or <proj>/STATE.md - location: root), run with
#          --spec but NOT --by, is REFUSED by default (D1b): the kit cannot tell whose hands changed the spec, so it
#          records nothing - the refusal names <proj>/.gauntlet/SPEC.md (where an agent writes the route's spec) and
#          --by. Run with --spec AND --by "<name>" it is the owner's SIGNED re-record of a spec they changed: only
#          spec.sha256 is written again (line 1 as it is, plus one line appended, `re-recorded <date> by "<name>"
#          <old8> -> <new8>`), and one line is appended to the LOG.md beside that STATE.md (.gauntlet/LOG.md, or the
#          root's with location: root; created if there is none), its own paragraph: `<date> spec re-recorded: <spec>
#          <old8> -> <new8>, signed --by "<name>" (init-state --spec --by: the kit cannot tell whose hands these were;
#          the owner reads this line, and the dossier carries it)` (`none` for no record before). next.sh repeats the
#          re-record, signed, under every answer. It says both on stdout. `--src --by "<name>"` is the same act for
#          src/: src.sha256's line 1 written again and `re-recorded <date> by "<name>" <old8> -> <new8>` appended (`none`
#          for no record before - how a project set up before v0.4.2 gets one), and `<date> src/ re-recorded: <old8> ->
#          <new8>, signed --by "<name>" (init-state --src --by: ...)` in that LOG.md; both flags in one call re-record
#          both, the spec first.
#          An owner's spec that lives at .gauntlet/SPEC.md itself (--spec .gauntlet/SPEC.md) leaves the route's spec no
#          place of its own; it is recorded as any other, and nothing new is written for the route (not refused).
#          A DECISIONS.md or LOG.md already in .gauntlet/ (append-only history) is kept, never overwritten.
#          The kit's example is not a project's state, and is REPLACED in this step (K52: next.sh's refusal of the
#          example sends here, and this refused it in its turn - two steps where the refusal promised one): a
#          .gauntlet/STATE.md that next.sh would refuse as the kit's example - by its marker, its title or its values,
#          the same test (scripts/lib/state-example.sh) - is overwritten, `replaced the kit's example STATE.md`, and so
#          is a DECISIONS.md or LOG.md in .gauntlet/ that is the example (`replaced the kit's example <file>`), unless a
#          STATE.md of the project's own is there: then the STATE wins, and it is refused as below.
#          Then it prints what it wrote and the next command: scripts/next.sh <proj>.
# Refuses (exit 2, nothing written):
#          - a project that has a STATE.md that is not the kit's example, without --spec (named; never overwritten) -
#            whatever is beside it; the kit's example at the project's root (location: root) is named as such: delete
#            it, then run this again (the new state goes to .gauntlet/, which next.sh <proj> reads first);
#          - --spec or --src on a project that has a STATE.md, without --by (the default: the kit records nothing it
#            cannot know); --src --by on a project with no file under src/;
#          - --by on a project with no STATE.md (a new project records its spec and src/ without the signature), --by
#            with no name (empty or a line break), or --by with neither --spec nor --src;
#          - a --spec file that does not exist, or that is outside <proj>; a <proj> that is not a directory.
# Exit:    0 written (or signed re-record); 2 refused, nothing written.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
T="$KIT/state"
refuse() { echo "init-state: REFUSED - $*" >&2; exit 2; }
usage="usage: scripts/init-state.sh <proj> [--spec <file>] [--src] [--by <name>]"

PROJ_ARG="" SPEC_ARG="" spec_given=0 BY_ARG="" by_given=0 src_given=0
while [ $# -gt 0 ]; do
  case "$1" in
    --spec) [ $# -ge 2 ] && [ -n "$2" ] || refuse "--spec has no file ($usage)."; SPEC_ARG="$2"; spec_given=1; shift 2 ;;
    --src) src_given=1; shift ;;
    --by) [ $# -ge 2 ] || refuse "--by has no name."; BY_ARG="$2"; by_given=1; shift 2 ;;
    -h | --help) echo "$usage"; exit 0 ;;
    -*) refuse "unknown argument '$1' ($usage)." ;;
    *) [ -z "$PROJ_ARG" ] || refuse "one project only (got '$PROJ_ARG' and '$1'; $usage)."; PROJ_ARG="$1"; shift ;;
  esac
done
[ "$by_given" != 1 ] || { [ -n "$BY_ARG" ] || refuse "--by has no name."; case "$BY_ARG" in *$'\n'*) refuse "--by has no name." ;; esac; }
[ -n "$PROJ_ARG" ] || refuse "no project given ($usage)."
[ -d "$PROJ_ARG" ] || refuse "$PROJ_ARG is not a directory: give the project's directory ($usage)."
PROJ="$(cd "$PROJ_ARG" && pwd)" || refuse "cannot enter $PROJ_ARG."
PROJ_REAL="$(cd "$PROJ" && pwd -P)" || refuse "cannot enter $PROJ."
G="$PROJ/.gauntlet"
for f in STATE.md DECISIONS.md LOG.md .gitignore; do [ -f "$T/$f" ] || refuse "the kit's template $T/$f is missing."; done

sha256_of() { if command -v sha256sum > /dev/null 2>&1; then sha256sum < "$1" | cut -d' ' -f1; else shasum -a 256 < "$1" | cut -d' ' -f1; fi; }
# the kit's example: next.sh's own test (marker, title, values), not a copy of it
# shellcheck source=lib/state-example.sh
. "$HERE/lib/state-example.sh" || refuse "$HERE/lib/state-example.sh is missing (the test of the kit's example, next.sh's)."
is_example_state() { is_kit_example "$1" 0 || example_by_values "$1" "$KIT" > /dev/null; }   # as next.sh reads a STATE.md
# owner_absent_noted <STATE.md>: 0 when its flag block's notes have an item `owner absent: <why>` - read at the START of a
# note item (a notes line, or a part after `;` or the middle dot, a list marker allowed), as next.sh reads a note
owner_absent_noted() {
  local blk line item innotes=0
  local -a items
  blk="$(flag_block "$1")" || return 1
  while IFS= read -r line; do
    if [[ $line =~ ^notes:(.*)$ ]]; then innotes=1; line="${BASH_REMATCH[1]}"
    elif [[ $line =~ ^[a-z_]+: ]]; then innotes=0; continue
    elif [ "$innotes" != 1 ]; then continue; fi
    IFS=';' read -ra items <<< "${line//$'\302\267'/;}"
    for item in ${items[@]+"${items[@]}"}; do
      item="${item#"${item%%[![:space:]]*}"}"
      if [[ $item =~ ^[-*+][[:space:]]+(.*)$ ]]; then item="${BASH_REMATCH[1]}"; fi
      [[ $item =~ ^owner\ absent:[[:space:]]*[^[:space:]] ]] && return 0
    done
  done <<< "$blk"
  return 1
}
# the anchor of src/, as pending-red.sh and battery.sh compute it (v0.4.2)
# shellcheck source=lib/src-anchor.sh
. "$HERE/lib/src-anchor.sh" || refuse "$HERE/lib/src-anchor.sh is missing (the anchor of src/)."

# ------------------------------------------------------------------------------------------------ the spec
# the spec, and its path relative to the project; refused when it is not a file inside the project
SPEC_FILE="" SPEC_REL=""
if [ "$spec_given" = 1 ]; then
  case "$SPEC_ARG" in
    /*) SPEC_FILE="$SPEC_ARG" ;;
    *) if [ -f "$PROJ/$SPEC_ARG" ]; then SPEC_FILE="$PROJ/$SPEC_ARG"; else SPEC_FILE="$SPEC_ARG"; fi ;;
  esac
  [ -f "$SPEC_FILE" ] || refuse "--spec $SPEC_ARG: no such file (in $PROJ, or from here)."
elif [ -f "$PROJ/SPEC.md" ]; then
  SPEC_FILE="$PROJ/SPEC.md"
fi
if [ -n "$SPEC_FILE" ]; then
  d="$(cd "$(dirname "$SPEC_FILE")" && pwd -P)" || refuse "cannot enter the directory of $SPEC_FILE."
  case "$d/" in
    "$PROJ_REAL"/*) SPEC_REL="${d#"$PROJ_REAL"}"; SPEC_REL="${SPEC_REL#/}"; SPEC_REL="${SPEC_REL:+$SPEC_REL/}$(basename "$SPEC_FILE")" ;;
    *) refuse "the spec $SPEC_FILE is outside the project $PROJ: the record names it relative to the project." ;;
  esac
  case "$SPEC_REL" in *$'\n'*) refuse "the spec's path has a line break in it." ;; esac
fi
record_spec() { # writes .gauntlet/spec.sha256; prints its line
  local h; h="$(sha256_of "$PROJ/$SPEC_REL")" || refuse "cannot read $PROJ/$SPEC_REL."
  mkdir -p "$G" || refuse "cannot create $G."
  printf '%s  %s\n' "$h" "$SPEC_REL" > "$G/spec.sha256.tmp" && mv "$G/spec.sha256.tmp" "$G/spec.sha256" || refuse "cannot write $G/spec.sha256."
  printf '%s  %s' "$h" "$SPEC_REL"
}
# src/ with a file in it (followed through symlinks, as the anchor reads it): a hook still to be written is not anchored
src_has_files() { [ -d "$PROJ/src" ] && [ -n "$(find -L "$PROJ/src" -type f -print -quit 2> /dev/null)" ]; }
record_src() { # writes .gauntlet/src.sha256; prints its line
  local h; h="$(src_anchor_hash "$PROJ")" || refuse "cannot read $PROJ/src."
  mkdir -p "$G" || refuse "cannot create $G."
  printf '%s  src/\n' "$h" > "$G/src.sha256.tmp" && mv "$G/src.sha256.tmp" "$G/src.sha256" || refuse "cannot write $G/src.sha256."
  printf '%s  src/' "$h"
}
NEXT_CMD="$KIT/scripts/next.sh $PROJ"

# ------------------------------------------------------------------------------------------------ a project with a STATE
# a .gauntlet/STATE.md that is the kit's example is no state: replaced below (EX_STATE); else the STATE.md there is, if any
HAS="" EX_STATE=0
if [ -e "$G/STATE.md" ]; then
  if [ -f "$G/STATE.md" ] && is_example_state "$G/STATE.md"; then EX_STATE=1; else HAS="$G/STATE.md"; fi
fi
[ -n "$HAS" ] || [ ! -e "$PROJ/STATE.md" ] || HAS="$PROJ/STATE.md"
if [ "$by_given" = 1 ] && [ -z "$HAS" ]; then
  refuse "--by is the re-record's signature (a project with a STATE.md and a recorded spec): a new project records its spec without it."
fi
if [ -n "$HAS" ]; then
  if [ "$by_given" = 1 ] && { [ "$spec_given" = 1 ] || [ "$src_given" = 1 ]; }; then   # the owner's SIGNED re-record: the hash, the signed line, and one line in the LOG.md beside the STATE.md - the spec, src/, or both (the spec first)
    LOGF="$(dirname "$HAS")/LOG.md"
    [ ! -e "$LOGF" ] || [ -f "$LOGF" ] || refuse "$LOGF is not a file: the re-record writes its line there."
    [ "$src_given" != 1 ] || src_has_files || refuse "--src: $PROJ/src has no file in it: there is nothing to anchor (the anchor is src/'s file list and contents)."
    # --by walker: the walker signs, the owner absent - only when the STATE.md records that absence (the header)
    BY_SHOWN="$BY_ARG"
    # the walker's word is exactly `walker`: any other spelling of it (Walker, " walker", "walker (owner absent)"), or a
    # name that claims the owner's absence, is neither the owner's name nor the walker's - refused, never taken as a name
    by_lc="${BY_ARG,,}"
    if [ "$BY_ARG" != walker ] && { [[ $by_lc =~ ^[[:space:]]*walker ]] || [[ $by_lc == *"owner absent"* ]]; }; then
      refuse "--by '$BY_ARG' is neither an owner's name nor the walker's word: the walker signs as --by walker, exactly (lower case, alone), and only with the note 'owner absent: <why>' in STATE.md's notes; the owner signs with their own name."
    fi
    if [ "$BY_ARG" = walker ]; then
      owner_absent_noted "$HAS" \
        || refuse "--by walker: the owner is present by the record - $HAS has no note 'owner absent: <why>' in its flag block's notes - and a walker never signs a re-record while the owner is there: the owner signs it (--by \"<their name>\"). With the owner absent, write that note first (doctrine/NEXT.md, the notes); the record then says by: walker (owner absent), and the dossier's section 8 carries it as a divergence."
      BY_SHOWN="walker (owner absent)"
    fi
    rerecord() { # rerecord <spec|src>: one signed re-record - the record's line 1, its re-recorded line, the LOG.md line
      local kind="$1" rec old old8 prior_rr line new8 entry what
      if [ "$kind" = spec ]; then rec="$G/spec.sha256"; what="the spec's hash"; else rec="$G/src.sha256"; what="the anchor of src/"; fi
      old="(none)"; [ -f "$rec" ] && old="$(sed -n '1{s/\r$//;p;}' "$rec")"
      old8="$(printf '%s' "$old" | LC_ALL=C sed -n 's/^\([0-9a-f]\{8\}\)[0-9a-f]\{56\}  .*/\1/p')"; [ -n "$old8" ] || old8=none
      prior_rr="$([ -f "$rec" ] && sed -n '2,${s/\r$//;/^re-recorded /p;/^by: walker (owner absent)$/p;}' "$rec")"   # earlier re-records are kept, a walker's signature line with its own
      if [ "$kind" = spec ]; then line="$(record_spec)" || exit 2; else line="$(record_src)" || exit 2; fi   # rewrites line 1 (the new hash and path)
      new8="${line:0:8}"
      # the record keeps line 1 (what next.sh, pending-red.sh and battery.sh parse) and gains one line per re-record,
      # appended, the earlier ones kept
      { [ -z "$prior_rr" ] || printf '%s\n' "$prior_rr"; printf 're-recorded %s by "%s" %s -> %s\n' "$(date +%F)" "$BY_SHOWN" "$old8" "$new8"
        [ "$BY_ARG" != walker ] || printf 'by: walker (owner absent)\n'; } >> "$rec" \
        || refuse "$what is re-recorded in $rec and the re-record line could not be appended to it."
      if [ "$kind" = spec ]; then
        entry="$(date +%F) spec re-recorded: $SPEC_REL $old8 -> $new8, signed --by \"$BY_SHOWN\" (init-state --spec --by: the kit cannot tell whose hands these were; the owner reads this line, and the dossier carries it)"
      else
        entry="$(date +%F) src/ re-recorded: $old8 -> $new8, signed --by \"$BY_SHOWN\" (init-state --src --by: the kit cannot tell whose hands these were; the owner reads this line, and the dossier carries it)"
      fi
      # its own paragraph, as scripts/round.sh appends: a blank line before it unless the file already ends in one
      if [ -s "$LOGF" ] && [ -n "$(tail -c 1 "$LOGF")" ]; then printf '\n' >> "$LOGF"; fi
      if [ -s "$LOGF" ] && [ -n "$(tail -n 1 "$LOGF")" ]; then printf '\n' >> "$LOGF"; fi
      printf '%s\n' "$entry" >> "$LOGF" || refuse "$what is re-recorded in $rec, and $LOGF could not be written: append this line to it by hand: $entry"
      echo "init-state: $rec was: $old"
      echo "init-state: $rec now: $line"
      echo "init-state: appended to $LOGF: $entry"
    }
    if [ "$spec_given" = 1 ] && [ "$src_given" = 1 ]; then w="the spec's hash, the anchor of src/ and two lines"
    elif [ "$spec_given" = 1 ]; then w="the spec's hash and one line"; else w="the anchor of src/ and one line"; fi
    echo "init-state: $HAS exists: nothing written but $w in LOG.md - a re-record signed --by \"$BY_SHOWN\"."
    [ "$spec_given" != 1 ] || rerecord spec
    [ "$src_given" != 1 ] || rerecord src
    echo "init-state: next: $NEXT_CMD"
    exit 0
  fi
  if [ "$spec_given" = 1 ]; then   # --spec on a project with a STATE.md, unsigned: REFUSED by default (D1b), nothing written
    old="(none)"; [ -f "$G/spec.sha256" ] && old="$(sed -n '1{s/\r$//;p;}' "$G/spec.sha256")"
    old8="$(printf '%s' "$old" | LC_ALL=C sed -n 's/^\([0-9a-f]\{8\}\)[0-9a-f]\{56\}  .*/\1/p')"; [ -n "$old8" ] || old8=none
    refuse "$HAS exists and the spec is recorded ($SPEC_ARG $old8): the kit cannot tell whose hands changed it, so it records nothing. An agent never re-records: undo the change, write what it assumed in DECISIONS.md (source: assumed, owner absent), and write the route's spec in $PROJ/.gauntlet/SPEC.md (AGENTS.md section 4). The owner, present, re-records a change of their own by signing it (--by; the header of scripts/init-state.sh says how) - the name is written in .gauntlet/spec.sha256 and LOG.md, and next.sh repeats it on every answer."
  fi
  if [ "$src_given" = 1 ]; then   # --src on a project with a STATE.md, unsigned: REFUSED by default, as --spec is, nothing written
    old="(none)"; [ -f "$G/src.sha256" ] && old="$(sed -n '1{s/\r$//;p;}' "$G/src.sha256")"
    old8="$(printf '%s' "$old" | LC_ALL=C sed -n 's/^\([0-9a-f]\{8\}\)[0-9a-f]\{56\}  .*/\1/p')"; [ -n "$old8" ] || old8=none
    refuse "$HAS exists and src/ is the owner's code (anchor: $old8): the kit cannot tell whose hands changed it, so it records nothing. An agent never re-records: undo the change and write what it assumed in DECISIONS.md (source: assumed, owner absent) - a finding's fix is the owner's decision, shown on a copy (scripts/mutate.sh), never in src/. The owner, present, re-records a change of their own by signing it (--by; the header of scripts/init-state.sh says how) - the name is written in .gauntlet/src.sha256 and LOG.md."
  fi
  if [ "$by_given" = 1 ]; then   # --by with neither --spec nor --src on a project with a STATE.md: nothing to re-record
    refuse "--by signs a re-record of the spec or of src/: give --spec <the spec> or --src too ($usage)."
  fi
  if [ -f "$HAS" ] && is_example_state "$HAS"; then   # at the project's root (location: root): only .gauntlet/ is replaced
    refuse "$HAS exists, and it is the kit's example (state/STATE.md, copied) at the project's root: init-state replaces an example in .gauntlet/ only and never overwrites a STATE.md at the root - delete it (and a DECISIONS.md or LOG.md beside it that is the example too), then run this again."
  fi
  refuse "$HAS exists: init-state writes a NEW project's state and never overwrites one. To re-record a spec, or src/, the owner changed, the owner signs it (--by; the header of scripts/init-state.sh says how)."
fi
# a DECISIONS.md or LOG.md in .gauntlet/ that is the kit's example (as next.sh reads one: its marker as a whole line,
# or its title): replaced below, like the STATE.md beside it; one of the project's own is kept
EX_DECISIONS=0 EX_LOG=0
if [ -f "$G/DECISIONS.md" ] && is_kit_example "$G/DECISIONS.md" 1; then EX_DECISIONS=1; fi
if [ -f "$G/LOG.md" ] && is_kit_example "$G/LOG.md" 1; then EX_LOG=1; fi

# ------------------------------------------------------------------------------------------------ the three files
NAME="$(basename "$PROJ_REAL")"
TODAY="$(date +%F)"
mkdir -p "$G" || refuse "cannot create $G."
W="$(mktemp -d "$G/.init-state.XXXXXX")" || refuse "cannot write in $G."
trap 'rm -rf "$W"' EXIT

# STATE.md: the flag block is state/README.md's starting values (the first fenced block there with a phase: line); the
# headings are the example's (its "## " lines); nothing else of the example
block="$(LC_ALL=C awk '{ sub(/\r$/, "") } /^```/ { if (inb && has) { found = 1; exit } inb = !inb; n = 0; has = 0; next }
  inb { buf[++n] = $0; if ($0 ~ /^phase:/) has = 1 } END { if (!found) exit 1; for (i = 1; i <= n; i++) print buf[i] }' "$T/README.md")" \
  || refuse "the kit's $T/README.md has no block of starting values (a fenced block with a phase: line)."
heads="$(LC_ALL=C sed -n 's/\r$//; /^## /p' "$T/STATE.md")"
{
  echo "# STATE - $NAME"
  echo
  echo "*Written by \`scripts/init-state.sh\` on $TODAY: a new project's starting values (\`state/README.md\`). Rewrite it in"
  echo "place as the route moves: the flag block is what \`scripts/next.sh\` reads (\`doctrine/NEXT.md\`).*"
  echo
  echo '```'
  printf '%s\n' "$block"
  echo '```'
  while IFS= read -r h; do [ -n "$h" ] || continue; echo; echo "$h"; done <<< "$heads"
} > "$W/STATE.md"

# DECISIONS.md and LOG.md: the template's title (for this project), its rules down to the first `---` line; no marker,
# no entries
intro() { # intro <template> <title word>
  LC_ALL=C awk -v title="# $2 - $NAME" -v marker="$EXAMPLE_MARKER" '{ sub(/\r$/, "") }
    NR == 1 { print title; next }
    $0 == marker { skip = 1; next }
    skip && /^$/ { skip = 0; next }
    { skip = 0; print }
    /^---$/ { done = 1; exit }
    END { exit done ? 0 : 1 }' "$1"
}
intro "$T/DECISIONS.md" DECISIONS > "$W/DECISIONS.md" || refuse "the kit's $T/DECISIONS.md has no '---' line after its rules."
intro "$T/LOG.md" LOG > "$W/LOG.md" || refuse "the kit's $T/LOG.md has no '---' line after its rules."
is_example_state "$W/STATE.md" && refuse "the STATE.md written from the kit's template is still the example (a bug in init-state.sh)."
for f in DECISIONS.md LOG.md; do
  is_kit_example "$W/$f" 1 && refuse "the $f written from the kit's template is still the example (a bug in init-state.sh)."
done

mv "$W/STATE.md" "$G/STATE.md" || refuse "cannot write $G/STATE.md."
if [ "$EX_STATE" = 1 ]; then w="replaced the kit's example STATE.md - wrote"; else w="wrote"; fi
echo "init-state: $w $G/STATE.md (phase 0: the starting values of state/README.md, the flag block next.sh reads)"
for f in DECISIONS.md LOG.md; do
  if [ "$f" = DECISIONS.md ]; then ex="$EX_DECISIONS"; else ex="$EX_LOG"; fi
  if [ "$ex" != 1 ] && [ -e "$G/$f" ]; then echo "init-state: kept $G/$f (the project's own; append-only, never overwritten)"; continue; fi
  if [ "$ex" = 1 ]; then w="replaced the kit's example $f - wrote"; else w="wrote"; fi
  mv "$W/$f" "$G/$f" || refuse "cannot write $G/$f."; echo "init-state: $w $G/$f (its title and its rules, no entries)"
done
if [ -e "$G/.gitignore" ]; then echo "init-state: kept $G/.gitignore"
else cp "$T/.gitignore" "$G/.gitignore" || refuse "cannot write $G/.gitignore."; echo "init-state: wrote $G/.gitignore (the benches stay out of git)"; fi

if [ -n "$SPEC_REL" ]; then
  line="$(record_spec)" || exit 2
  echo "init-state: recorded the spec: $G/spec.sha256 = $line"
  echo "init-state: the spec is the owner's: next.sh refuses it changed or gone. The route's spec - phase 1 - is"
  echo "            $PROJ/.gauntlet/SPEC.md; an assumption goes in DECISIONS.md (source: assumed, owner absent), never"
  echo "            into $SPEC_REL."
else
  echo "init-state: no spec found ($PROJ/SPEC.md does not exist; --spec <file> names another): nothing recorded - next.sh"
  echo "            cannot tell a spec changed under the route's hands until one is - the owner's act, signed (--spec --by; the header of scripts/init-state.sh says how)."
fi
if src_has_files; then
  line="$(record_src)" || exit 2
  echo "init-state: recorded src/: $G/src.sha256 = $line"
  echo "init-state: src/ is the owner's code: pending-red.sh and battery.sh refuse to run on it changed or gone. A finding's"
  echo "            fix is the owner's decision (doctrine/NEXT.md row 6b), shown on a copy (scripts/mutate.sh), never in src/."
else
  echo "init-state: no file under $PROJ/src: nothing anchored - the hook is still to be written. Once it exists, the anchor is"
  echo "            the owner's act, signed (--src --by; the header of scripts/init-state.sh says how)."
fi
echo "init-state: next: $NEXT_CMD"
