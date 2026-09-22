#!/usr/bin/env bash
#
# release-guard.sh - the published copy must be identical to the tree you test, AND must still match the
# hashes it published.
#
# The problem it solves, in two halves, because one half alone is not enough:
#
#  * A diff between the working tree and the published copy catches the drift where only one of them was
#    edited. It does NOT catch the drift where both were edited together, which is exactly what a runbook
#    that says "fix it in both places" produces.
#  * A manifest of hashes catches that second case. It is only worth anything if every file has a line: a
#    file added to both trees without a hash slips past a hash check that only walks the manifest.
#
# So this checks both directions: every published file has a manifest line, every manifest line names a file
# that is there, and every hash matches what is on disk.
#
# It is READ ONLY. It never writes into the published copy, not even to refresh a hash, because a guard that
# can fix what it finds is not a guard.
#
# Usage:   scripts/release-guard.sh <work-dir> <published-dir> [manifest]
#          manifest defaults to <published-dir>/MANIFEST.sha256
#          a manifest line is "<64 hex>  <filename>", the format sha256sum prints
# Env:     GUARD_EXCLUDE  extra diff/inventory exclusions, space separated glob patterns
#                         (default: "*.md MANIFEST.sha256")
# Exit:    0 identical and every hash matches
#          1 the trees diverged
#          2 the manifest is incomplete, has extra lines, or is unreadable
#          3 a hash does not match the file on disk
#          4 usage

set -uo pipefail

WORK="${1:-}"
PUB="${2:-}"
if [ -z "$WORK" ] || [ -z "$PUB" ]; then
  echo "usage: release-guard.sh <work-dir> <published-dir> [manifest]"
  exit 4
fi
MANIFEST="${3:-$PUB/MANIFEST.sha256}"
GUARD_EXCLUDE="${GUARD_EXCLUDE:-*.md MANIFEST.sha256}"

[ -d "$WORK" ] || { echo "release-guard: $WORK is not a directory"; exit 4; }
[ -d "$PUB" ] || { echo "release-guard: $PUB is not a directory"; exit 4; }

if command -v sha256sum > /dev/null 2>&1; then
  hash_of() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum > /dev/null 2>&1; then
  hash_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  echo "release-guard: no sha256sum and no shasum on PATH"
  exit 4
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- half one: the trees are the same
# the patterns are kept in arrays and quoted: an unquoted "*.md" would be expanded by the shell against
# whatever directory happened to be current, which is a guard that changes meaning with the weather.
diff_args=()
set -f   # patterns such as *.md must not be expanded against whatever directory this happens to run from
for pat in $GUARD_EXCLUDE; do diff_args+=("--exclude=$pat"); done
set +f
if ! diff -r ${diff_args[@]+"${diff_args[@]}"} "$WORK" "$PUB" > "$TMP/tree.diff" 2>&1; then
  echo "PUBLISHED COPY DIVERGED ($PUB is not $WORK):"
  cat "$TMP/tree.diff"
  exit 1
fi

# ---------------------------------------------------------------- half two: the manifest is complete
[ -f "$MANIFEST" ] || { echo "MANIFEST MISSING: $MANIFEST"; exit 2; }

grep -Eo '^[0-9a-f]{64}  [^ ]+$' "$MANIFEST" > "$TMP/lines" || true
lines=$(wc -l < "$TMP/lines" | tr -d ' ')
if [ "$lines" -eq 0 ]; then
  echo "MANIFEST UNREADABLE: no line in $MANIFEST has the form '<64 hex>  <filename>'"
  exit 2
fi

cut -c67- "$TMP/lines" | sort > "$TMP/listed"
if [ "$(sort -u "$TMP/listed" | wc -l | tr -d ' ')" != "$lines" ]; then
  echo "MANIFEST HAS DUPLICATE ENTRIES:"
  sort "$TMP/listed" | uniq -d
  exit 2
fi

find_args=()
set -f
for pat in $GUARD_EXCLUDE; do find_args+=(! -name "$pat"); done
set +f
(cd "$PUB" && find . -type f ${find_args[@]+"${find_args[@]}"} | sed 's|^\./||' | sort) > "$TMP/present"

if ! diff "$TMP/present" "$TMP/listed" > "$TMP/inventory.diff" 2>&1; then
  echo "MANIFEST DOES NOT COVER THE PUBLISHED COPY (< is on disk and unlisted, > is listed and missing):"
  cat "$TMP/inventory.diff"
  exit 2
fi

# ---------------------------------------------------------------- half three: the hashes still match
bad=0
while read -r want name; do
  have=$(hash_of "$PUB/$name" 2>/dev/null)
  if [ "$have" != "$want" ]; then
    echo "HASH MISMATCH: $name (published $want, on disk ${have:-unreadable})"
    bad=1
  fi
done < "$TMP/lines"

if [ "$bad" = 1 ]; then
  echo "THE PUBLISHED COPY DOES NOT MATCH ITS OWN MANIFEST (both trees may have been edited together)."
  exit 3
fi

echo "release guard: $PUB is identical to $WORK and matches all $lines published hashes."
