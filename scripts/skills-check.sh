#!/usr/bin/env bash
#
# skills-check.sh - the skills in skills/ are exactly what scripts/gen-skills.sh writes from the doctrine today.
#
# The problem it solves: a skill is a copy of doctrine, read before the doctrine, and a copy that drifts is read as the
# rule. The skills are generated (scripts/gen-skills.sh) so that they cannot drift by construction - which holds only if
# something regenerates them and looks. This script does, and checks what the generator cannot see for itself:
#   1. drift: gen-skills.sh writes the skills into a temporary directory, and each <name>/SKILL.md there is compared
#      with skills/<name>/SKILL.md, byte for byte; a skill on one side only is named too (skills/README.md is not a
#      skill). A hand edit, or a doctrine edit nobody regenerated after, is red here. A generator refusal (a NEXT.md row
#      no skill owns, AGENTS.md's markers broken) is red, with its line;
#   2. pointers: every `{{KIT}}/<path>` in a skill names a file or a directory of the kit;
#   3. the six rules: the block between `<!-- invariants:begin -->` and `<!-- invariants:end -->` in each skill is
#      AGENTS.md's block, markers included, byte for byte;
#   4. size: tokens printed per skill (bytes/4); a skill above 8000 bytes is red - a skill is read whole, before any
#      doctrine, and a long one is read around (the fork's 12-14k skills were read with sed, past their first half);
#   5. the frontmatter a harness reads: `name:` is the directory, `description:` present and at most 1024 characters.
# The thin-skills design and the drift guard are Pedro Santana's idea (his fork's skills-check.sh checked a copied
# constitution; here there is none to copy).
#
# Usage:   scripts/skills-check.sh [--skills DIR]
#   --skills DIR  the directory that holds the skill folders (default: the kit's skills/); pointers are resolved
#                 against the kit this script is in
# Output:  one "skills-check: <file>: <what>" line per problem (the run goes on), one "tokens <name>: <n> (<bytes> bytes)"
#          line per skill, then "SKILLS CHECK PASSED: <n> skills, as generated; <k> pointers resolve; the six rules are
#          AGENTS.md's; none above 8000 bytes." or "SKILLS CHECK FAILED: <n> problem(s)."
# Exit:    0 passed; 1 problem(s); 2 REFUSED - bad arguments, no skills directory, no gen-skills.sh: one line on stderr.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
SKILLS="$KIT/skills"
MAX_BYTES=8000

refuse() { echo "skills-check: REFUSED - $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --skills) [ $# -ge 2 ] || refuse "--skills has no value."; SKILLS="$2"; shift 2 ;;
    *) refuse "unknown argument '$1'." ;;
  esac
done
[ -d "$SKILLS" ] || refuse "no skills directory at $SKILLS."
SKILLS="$(cd "$SKILLS" && pwd)"
[ -f "$HERE/gen-skills.sh" ] || refuse "no gen-skills.sh beside this script."

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
problems=0 npointers=0 nskills=0
prob() { echo "skills-check: $1: $2"; problems=$((problems + 1)); }
rel() { case "$1" in "$KIT"/*) printf '%s' "${1#"$KIT"/}" ;; *) printf '%s' "$1" ;; esac; }

# markers <file>: "nb ne lb le" - how many invariants:begin / :end lines, and the line of the first of each
markers() {
  LC_ALL=C awk '
    /^<!-- invariants:begin -->[ \t\r]*$/ { nb++; if (nb == 1) lb = NR }
    /^<!-- invariants:end -->[ \t\r]*$/   { ne++; if (ne == 1) le = NR }
    END { printf "%d %d %d %d\n", nb + 0, ne + 0, lb + 0, le + 0 }' "$1"
}

# ---- 1. drift: regenerate, compare
GEN="$TMPD/gen"
if bash "$HERE/gen-skills.sh" --out "$GEN" > "$TMPD/gen.log" 2>&1; then
  for g in "$GEN"/*/SKILL.md; do
    [ -f "$g" ] || continue
    n="$(basename "$(dirname "$g")")"; f="$SKILLS/$n/SKILL.md"
    if [ ! -f "$f" ]; then prob "$(rel "$SKILLS")/$n/SKILL.md" "missing: gen-skills.sh writes it (run scripts/gen-skills.sh)"
    elif ! cmp -s "$g" "$f"; then
      prob "$(rel "$f")" "differs from what gen-skills.sh writes from the doctrine today (a hand edit, or doctrine changed and nobody regenerated): first difference at line $(cmp "$g" "$f" 2> /dev/null | sed -n 's/.* line \([0-9]*\).*/\1/p')"
    fi
  done
  for d in "$SKILLS"/*/; do
    [ -d "$d" ] || continue
    n="$(basename "$d")"
    [ -f "$GEN/$n/SKILL.md" ] || prob "$(rel "$SKILLS")/$n" "is not a skill gen-skills.sh writes (a hand-made or a renamed skill)"
  done
else
  prob "scripts/gen-skills.sh" "refused to regenerate the skills: $(tail -n 1 "$TMPD/gen.log")"
fi

# ---- 2-5, per skill in the directory
read -r a_nb a_ne a_lb a_le <<< "$(markers "$KIT/AGENTS.md")"
if [ "$a_nb" = 1 ] && [ "$a_ne" = 1 ] && [ "$a_lb" -lt "$a_le" ]; then
  sed -n "${a_lb},${a_le}p" "$KIT/AGENTS.md" > "$TMPD/rules"
else
  prob "AGENTS.md" "has $a_nb invariants:begin and $a_ne invariants:end line(s): exactly one of each, begin first"
  : > "$TMPD/rules"
fi
for d in "$SKILLS"/*/; do
  [ -d "$d" ] || continue
  n="$(basename "$d")"; f="$d/SKILL.md"; fr="$(rel "$SKILLS")/$n/SKILL.md"
  [ -f "$f" ] || { prob "$fr" "does not exist"; continue; }
  nskills=$((nskills + 1))

  # 5. frontmatter
  if [ "$(sed -n 1p "$f")" != "---" ]; then prob "$fr" "does not start with a '---' frontmatter line"
  else
    close="$(awk 'NR > 1 && /^---$/ { print NR; exit }' "$f")"
    if [ -z "$close" ]; then prob "$fr" "its frontmatter has no closing '---'"
    else
      nm="$(sed -n "2,${close}p" "$f" | sed -n 's/^name: //p' | head -n 1)"
      ds="$(sed -n "2,${close}p" "$f" | sed -n 's/^description: //p' | head -n 1)"
      [ "$nm" = "$n" ] || prob "$fr" "its name: is '$nm', not its directory '$n'"
      if [ -z "$ds" ]; then prob "$fr" "has no description:"
      elif [ "${#ds}" -gt 1024 ]; then prob "$fr" "its description is ${#ds} characters, over 1024"; fi
    fi
  fi

  # 3. the six rules
  read -r s_nb s_ne s_lb s_le <<< "$(markers "$f")"
  if [ "$s_nb" != 1 ] || [ "$s_ne" != 1 ] || [ "$s_lb" -ge "$s_le" ]; then
    prob "$fr" "has $s_nb invariants:begin and $s_ne invariants:end line(s): exactly one of each, begin first"
  elif ! sed -n "${s_lb},${s_le}p" "$f" | cmp -s - "$TMPD/rules"; then
    prob "$fr" "its six rules are not AGENTS.md's block between the invariants markers, byte for byte"
  fi

  # 2. pointers
  while IFS= read -r p; do
    npointers=$((npointers + 1))
    [ -e "$KIT/$p" ] || prob "$fr" "points at '{{KIT}}/$p', which is not in the kit"
  done < <(grep -oE '\{\{KIT\}\}/[A-Za-z0-9._/-]*[A-Za-z0-9_/-]' "$f" | sed 's|^{{KIT}}/||' | sort -u)

  # 4. size
  b="$(wc -c < "$f" | tr -d ' ')"
  echo "tokens $n: $((b / 4)) ($b bytes)"
  [ "$b" -le "$MAX_BYTES" ] || prob "$fr" "is $b bytes, over $MAX_BYTES: a skill is read whole, before any doctrine - cut what it quotes (gen-skills.sh, SKILLS), not the doctrine"
done
[ "$nskills" -gt 0 ] || prob "$(rel "$SKILLS")" "holds no skill"

if [ "$problems" -gt 0 ]; then
  echo "SKILLS CHECK FAILED: $problems problem(s)."
  exit 1
fi
echo "SKILLS CHECK PASSED: $nskills skills, as generated; $npointers pointers resolve; the six rules are AGENTS.md's; none above $MAX_BYTES bytes."
