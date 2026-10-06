#!/usr/bin/env bash
#
# gen-manifest.sh - the kit's MANIFEST: the SHA-256 of every file the kit ships, so that a file in the kit that is not the kit's is seen.
#
# The problem it solves: an agent whose terminal had drifted into the vendored kit (a `cd` into its examples) wrote a
# test file there, and nothing in the kit noticed - measured once, 2026-10-01. The kit is not to be changed by a project
# that uses it; a list of what it shipped is what makes a file that is not on the list visible. `scripts/doctor.sh`
# prints `kit: N files not in MANIFEST: <first three>` from it, and `scripts/next.sh` a note under its answer.
#
# What it lists: every file of the kit - in a git checkout of the kit (the kit's root is the checkout's), what git
# tracks plus what `git add` would add (not ignored); otherwise every file on disk - EXCEPT `MANIFEST` itself, `.git`,
# and every `lib/` (but `scripts/lib/`, the scripts' own library: source), `cache/`, `out/`, `corpus/`, `census/`,
# `broadcast/` and `.gauntlet/` directory anywhere: dependencies, builds, and what the kit's own runs write (the
# selftest, the batteries; the selftest's marker is in `.gauntlet/`) - THE EXCLUSIONS below, the same in doctor.sh and
# next.sh. A file the kit tracks under one of them (the two backtest fixtures under foundry-kit/v4/.gauntlet/) is not
# listed either: what is under those directories is never the MANIFEST's.
# Format:  `sha256sum`'s - `<hash>  <path from the kit's root>` - one line per file, sorted by path (bytewise).
#
# Usage:   scripts/gen-manifest.sh [--check]
#   --check   write nothing; compare MANIFEST with what this would write and name each difference: a file not listed, a
#             listed file that is not there, a hash that differs. Outside a git checkout a file on disk that MANIFEST
#             does not list cannot be told from one the operator added: it is named as a note and does not fail the
#             check (the kit cannot know whether it was meant; doctor.sh says it too)
# Output:  `gen-manifest: wrote MANIFEST - <n> files (<git checkout | not a git checkout: every file on disk>)`, or with
#          --check `gen-manifest: MANIFEST is current - <n> files listed (...)` (and the notes, indented), or
#          `gen-manifest: MANIFEST is stale - <k> difference(s) (...):` then one indented line per difference - `not
#          listed: <path>`, `listed, not there: <path>`, `hash differs: <path>` (the first 20) - and the command that
#          rewrites it.
# Exit:    0 written / current; 1 --check: stale, or no MANIFEST; 2 REFUSED - bad arguments, no sha256 tool.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
M="$KIT/MANIFEST"

# THE EXCLUSIONS - one rule, in the same words in scripts/gen-manifest.sh, scripts/doctor.sh and scripts/next.sh (the
# selftest holds these lines equal in the three): MANIFEST itself; `.git`, file or directory, at any depth; and every
# directory named in KIT_SKIP_DIRS, anywhere under the kit - dependencies (lib/, but scripts/lib/: the scripts' own
# library, source), builds (cache/, out/) and what the kit's own runs write (corpus/, census/, broadcast/, .gauntlet/,
# where the selftest's marker is). The kit's .gitignore names the same directories.
KIT_SKIP_DIRS="lib cache out corpus census broadcast .gauntlet"

refuse() { echo "gen-manifest: REFUSED - $*"; exit 2; }

MODE="write"
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check; shift ;;
    *) refuse "unknown argument '$1' (scripts/gen-manifest.sh [--check])." ;;
  esac
done
if command -v sha256sum > /dev/null 2>&1; then SHA=(sha256sum); elif command -v shasum > /dev/null 2>&1; then SHA=(shasum -a 256); else
  refuse "no sha256sum and no shasum on the PATH."; fi

TMPD="$(mktemp -d)" || refuse "no temporary directory."
trap 'rm -rf "$TMPD"' EXIT

# ---------------------------------------------------------------------------- the files
GIT=0
if command -v git > /dev/null 2>&1 && top="$(git -C "$KIT" rev-parse --show-toplevel 2> /dev/null)" && [ -n "$top" ] \
  && [ "$(cd "$top" && pwd -P)" = "$(cd "$KIT" && pwd -P)" ]; then
  GIT=1
  git -C "$KIT" ls-files -z --cached --others --exclude-standard > "$TMPD/list0" || refuse "git ls-files failed in $KIT."
  tr '\0' '\n' < "$TMPD/list0" > "$TMPD/raw"
else
  kit_prune=(); for d in $KIT_SKIP_DIRS; do [ ${#kit_prune[@]} = 0 ] || kit_prune+=(-o); kit_prune+=(-name "$d"); done
  (cd "$KIT" && find . \( -name .git -o \( -type d \( "${kit_prune[@]}" \) ! -path ./scripts/lib \) \) -prune \
    -o \( -type f -o -type l \) -print) | sed 's#^\./##' > "$TMPD/raw"
fi
# the exclusions, whichever listed them (git lists what it tracks under them too)
LC_ALL=C awk -v skip="$KIT_SKIP_DIRS" '
  BEGIN { k = split(skip, s, " "); for (i = 1; i <= k; i++) dir[s[i]] = 1 }
  $0 == "" || $0 == "MANIFEST" { next }
  { n = split($0, p, "/")
    for (i = 1; i <= n; i++) {
      if (p[i] == ".git") next
      if (i < n && (p[i] in dir) && !(i == 2 && p[1] == "scripts" && p[i] == "lib")) next
    }
    print }' "$TMPD/raw" | LC_ALL=C sort -u > "$TMPD/list"
: > "$TMPD/gone"
while IFS= read -r f; do
  if [ -f "$KIT/$f" ]; then printf '%s\n' "$f"; else printf '%s\n' "$f" >> "$TMPD/gone"; fi   # tracked, deleted on disk
done < "$TMPD/list" > "$TMPD/files"
n="$(awk 'END { print NR }' "$TMPD/files")"
# the hashes, in sha256sum's format whatever the tool printed (`<hash> *<path>` on some systems)
(cd "$KIT" && while IFS= read -r f; do "${SHA[@]}" "$f"; done < "$TMPD/files") \
  | sed -E 's/^\\?([0-9a-f]{64}) [ *]/\1  /' > "$TMPD/new" || refuse "hashing failed."
[ "$(awk 'END { print NR }' "$TMPD/new")" = "$n" ] || refuse "hashed $(awk 'END { print NR }' "$TMPD/new") of $n files."
if [ "$GIT" = 1 ]; then how="git checkout: what git tracks and would add"; else how="not a git checkout: every file on disk"; fi

if [ "$MODE" = write ]; then
  cp "$TMPD/new" "$M.tmp" && mv "$M.tmp" "$M" || refuse "cannot write $M."
  echo "gen-manifest: wrote MANIFEST - $n files ($how)"
  if [ -s "$TMPD/gone" ]; then sed 's/^/gen-manifest: note - tracked by git, not on disk (not listed): /' "$TMPD/gone"; fi
  exit 0
fi

# ---------------------------------------------------------------------------- --check
[ -f "$M" ] || { echo "gen-manifest: no MANIFEST at $KIT - scripts/gen-manifest.sh writes it"; exit 1; }
tr -d '\r' < "$M" > "$TMPD/old"
LC_ALL=C awk -v git="$GIT" -v notes="$TMPD/notes" '
  function path(s) { return substr(s, 67) }
  NR == FNR { o[path($0)] = substr($0, 1, 64); next }
  { p = path($0); h = substr($0, 1, 64); seen[p] = 1
    if (!(p in o)) { if (git) print "not listed: " p; else print "not listed: " p > notes }
    else if (o[p] != h) print "hash differs: " p }
  END { for (p in o) if (!(p in seen)) print "listed, not there: " p }
' "$TMPD/old" "$TMPD/new" | LC_ALL=C sort > "$TMPD/diff"
k="$(awk 'END { print NR }' "$TMPD/diff")"
if [ "$k" = 0 ]; then
  echo "gen-manifest: MANIFEST is current - $(awk 'END { print NR }' "$TMPD/old") files listed ($how)"
  if [ -s "$TMPD/notes" ]; then
    echo "gen-manifest: note - $(awk 'END { print NR }' "$TMPD/notes") file(s) on disk that MANIFEST does not list (not a git checkout: they may be the operator's; the kit is not to be changed):"
    LC_ALL=C sort "$TMPD/notes" | head -n 20 | sed 's/^/  /'
  fi
  exit 0
fi
echo "gen-manifest: MANIFEST is stale - $k difference(s) ($how):"
head -n 20 "$TMPD/diff" | sed 's/^/  /'
[ "$k" -le 20 ] || echo "  ... and $((k - 20)) more"
echo "gen-manifest: rewrite it from the kit as it is meant to ship: scripts/gen-manifest.sh"
exit 1
