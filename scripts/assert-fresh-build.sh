#!/usr/bin/env bash
#
# assert-fresh-build.sh - fail if the compiled artifacts were not built from the sources as they are now.
#
# The problem it solves: the stale `out/`. A guard that compares SOURCES can be perfectly green while the
# thing you are about to measure, deploy or hand to an auditor was compiled from an older tree. It happens
# most easily at exactly the wrong moment: a dry run, a size check before a promotion, a benchmark. The
# failure is silent and the output looks right, which is why it needs its own check with its own exit code.
#
# What it compares: CONTENT, the way forge itself does. forge records in its cache (cache/solidity-files-cache.json),
# per source, the `contentHash` of the text it compiled (with CR LF folded to LF: a CRLF checkout is the same text), and
# recompiles a source when that hash changes - not when its modification time does. This check hashes every source under
# SRC_DIRS the same way (XXH3-64, scripts/lib/forge-cache-check.py, checked against forge 1.8.1's own cache, line ends
# included) and says STALE when a hash differs from the cache's, or
# a source is not in the cache at all. Timestamps are printed as EVIDENCE and never decide: the first version of this
# check compared times ("forge rewrites the cache on every build, so a source newer than the cache was not built"), and
# it went red about one run in ten on sources that had just been copied (new mtime, same bytes) - and it would have said
# FRESH over an edit dated before the build.
#
# Usage:   scripts/assert-fresh-build.sh [project-dir]
# Env:     SRC_DIRS   space separated (default: "src test script"). It does NOT read `src =` / `test =` from
#                     foundry.toml, does not look inside lib/, and does not follow remappings: a project with
#                     `src = "contracts"`, or one that imports ../something, must name those directories here,
#                     or this check says FRESH over stale artifacts. A .sol file under SRC_DIRS that forge does
#                     not compile (a `skip =` pattern, a directory forge is not told about) is not in the cache and
#                     reads STALE on every run: narrow SRC_DIRS.
#          OUT_DIR    artifact directory (default: out)
#          CACHE_FILE forge's cache (default: cache/solidity-files-cache.json)
#          EXTRA_SRC  other files to compare (default: "foundry.toml remappings.txt"). forge's cache does NOT record
#                     foundry.toml or remappings.txt, so their content is NOT checked: one that is newer than the
#                     cache is reported in a note, never as a verdict. A change to the config that was not rebuilt
#                     is therefore NOT caught here. An EXTRA_SRC file the cache does record is compared like a source.
#          HASH_PYTHON  the Python 3 to hash with (default: python3, then python). None -> exit 2, nothing decided.
# Limits:  only the sources are compared with the cache; that every artifact the cache names is still in OUT_DIR is
#          not checked (OUT_DIR must hold at least one .json). A cache written by a forge whose hash is not XXH3-64
#          makes every source read STALE (it fails closed); one of another shape (no contentHash) exits 2.
# Exit:    0 FRESH: every source's content is the content forge compiled
#          1 STALE: at least one source changed, or was never built, after the last build
#          2 nothing can be decided: no artifacts, no cache, a cache of another shape, or no Python 3

set -uo pipefail

# resolved BEFORE the cd below, which would break a relative $0
HERE="$(cd "$(dirname "$0")" && pwd)"
CHECKER="$HERE/lib/forge-cache-check.py"

PROJECT="${1:-.}"
cd "$PROJECT" || { echo "assert-fresh-build: cannot enter $PROJECT"; exit 2; }

SRC_DIRS="${SRC_DIRS:-src test script}"
OUT_DIR="${OUT_DIR:-out}"
CACHE_FILE="${CACHE_FILE:-cache/solidity-files-cache.json}"
EXTRA_SRC="${EXTRA_SRC:-foundry.toml remappings.txt}"

if [ ! -d "$OUT_DIR" ]; then
  echo "NO ARTIFACTS: $OUT_DIR does not exist. Run forge build."
  exit 2
fi
if [ -z "$(find "$OUT_DIR" -type f -name '*.json' -print -quit 2> /dev/null)" ]; then
  echo "NO ARTIFACTS: $OUT_DIR holds no .json artifacts. Run forge build."
  exit 2
fi
if [ ! -f "$CACHE_FILE" ]; then
  echo "NO CACHE: $CACHE_FILE does not exist, so there is no record of what forge compiled. Run forge build."
  exit 2
fi
[ -f "$CHECKER" ] || { echo "CANNOT CHECK: $CHECKER is missing. Nothing decided."; exit 2; }

PY=""
for c in ${HASH_PYTHON:-python3 python}; do
  if "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)' > /dev/null 2>&1; then PY="$c"; break; fi
done
if [ -z "$PY" ]; then
  echo "CANNOT CHECK: no Python 3 to hash the sources with (tried: ${HASH_PYTHON:-python3 python}; set HASH_PYTHON). Nothing decided."
  exit 2
fi

present_dirs=""
for d in $SRC_DIRS; do
  [ -d "$d" ] && present_dirs="$present_dirs $d"
done
sources=()
if [ -n "$present_dirs" ]; then
  # shellcheck disable=SC2086   # $present_dirs is a space-separated list on purpose
  while IFS= read -r f; do sources+=("$f"); done < <(find $present_dirs -type f -name '*.sol' 2> /dev/null | sort)
fi
if [ "${#sources[@]}" -eq 0 ]; then
  echo "NO SOURCES: no .sol file in:${present_dirs:- (none of: $SRC_DIRS)}"
  exit 2
fi
extras=()
for f in $EXTRA_SRC; do [ -f "$f" ] && extras+=("$f"); done

res="$("$PY" "$CHECKER" "$CACHE_FILE" "${sources[@]}" ${extras[@]+"${extras[@]}"})"
rc=$?
if [ "$rc" -eq 3 ]; then
  echo "CANNOT CHECK: $CACHE_FILE is not a cache this check can read (no per-source contentHash: another forge's shape?)."
  echo "  $(printf '%s\n' "$res" | tr '\t' ' ' | head -1)"
  echo "Nothing decided."
  exit 2
elif [ "$rc" -ne 0 ]; then
  echo "CANNOT CHECK: the hash helper failed (rc=$rc). Nothing decided."
  exit 2
fi

is_extra() { local e; for e in ${extras[@]+"${extras[@]}"}; do [ "$e" = "$1" ] && return 0; done; return 1; }

echo "cache:   $CACHE_FILE ($(stat -c '%.9Y' "$CACHE_FILE" 2> /dev/null || echo '?') mtime, evidence only)"
echo "sources: ${#sources[@]} under$present_dirs, compared by content with what forge recorded"

stale=0; same=0; newer_same=""; n_newer=0; notes=""
while IFS=$'\t' read -r verdict path evidence h_disk h_cache; do
  [ -n "$verdict" ] || continue
  h_cache="${h_cache%$'\r'}"; evidence="${evidence%$'\r'}"
  case "$verdict" in
    SAME)
      same=$((same + 1))
      if [ "$path" -nt "$CACHE_FILE" ]; then n_newer=$((n_newer + 1)); [ "$n_newer" -le 3 ] && newer_same="$newer_same $path"; fi ;;
    CHANGED)
      stale=$((stale + 1))
      echo "STALE BUILD: $path changed after the last build: its content hash is $h_disk, forge compiled $h_cache."
      echo "  evidence: $evidence" ;;
    ABSENT)
      if is_extra "$path"; then
        [ "$path" -nt "$CACHE_FILE" ] && notes="${notes}note: $path is newer than the cache; forge's cache does not record its content, so a change to it is NOT checked here - rebuild if you changed it."$'\n'
      else
        stale=$((stale + 1))
        echo "STALE BUILD: $path is not in the cache: forge has never compiled it (a new source, or one forge does not build?)."
        echo "  evidence: $evidence"
      fi ;;
    *) echo "CANNOT CHECK: the hash helper printed a line this check does not know: $verdict. Nothing decided."; exit 2 ;;
  esac
done <<< "$res"

if [ "$n_newer" -gt 0 ]; then
  echo "note: $n_newer source(s) are newer than the cache with the same content (copied or touched: not a change):$newer_same$([ "$n_newer" -gt 3 ] && echo ' ...')"
fi
printf '%s' "$notes"

if [ "$stale" -gt 0 ]; then
  echo "STALE BUILD: $stale source(s) are not what forge compiled. Run forge build before trusting anything measured from $OUT_DIR."
  exit 1
fi
echo "FRESH: every source's content is the content forge compiled ($same sources)."
