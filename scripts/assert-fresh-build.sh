#!/usr/bin/env bash
#
# assert-fresh-build.sh - fail if the compiled artifacts are older than the sources.
#
# The problem it solves: the stale `out/`. A guard that compares SOURCES can be perfectly green while the
# thing you are about to measure, deploy or hand to an auditor was compiled from an older tree. It happens
# most easily at exactly the wrong moment: a dry run, a size check before a promotion, a benchmark. The
# failure is silent and the output looks right, which is why it needs its own check with its own exit code.
#
# What it compares, and why not the obvious thing: forge decides what to recompile from CONTENT, not from
# timestamps, so a source that was touched but not changed leaves the artifacts untouched too. Comparing
# sources against artifact timestamps alone therefore cries wolf after any rsync, and a gate that cries wolf
# gets switched off. The reference point is instead the newest of the artifacts and the compiler cache, which
# forge rewrites on every build: if a source is newer than that, no build has been run since it changed.
#
# Usage:   scripts/assert-fresh-build.sh [project-dir]
# Env:     SRC_DIRS   space separated (default: "src test script"). It does NOT read `src =` / `test =` from
#                     foundry.toml, does not look inside lib/, and does not follow remappings: a project with
#                     `src = "contracts"`, or one that imports ../something, must name those directories here,
#                     or this check says FRESH over stale artifacts.
#          OUT_DIR    artifact directory (default: out)
#          CACHE_FILE build marker (default: cache/solidity-files-cache.json)
#          EXTRA_SRC  extra files to include (default: "foundry.toml remappings.txt")
# Exit:    0 the build is at least as new as every source
#          1 STALE: at least one source changed after the last build
#          2 there are no artifacts at all (nothing has been built)

set -uo pipefail

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

newest_artifact=""
while IFS= read -r f; do
  if [ -z "$newest_artifact" ] || [ "$f" -nt "$newest_artifact" ]; then newest_artifact="$f"; fi
done < <(find "$OUT_DIR" -type f -name '*.json' 2>/dev/null)

if [ -z "$newest_artifact" ]; then
  echo "NO ARTIFACTS: $OUT_DIR holds no .json artifacts. Run forge build."
  exit 2
fi

build_marker="$newest_artifact"
if [ -f "$CACHE_FILE" ] && [ "$CACHE_FILE" -nt "$build_marker" ]; then build_marker="$CACHE_FILE"; fi

newest_source=""
present_dirs=""
for d in $SRC_DIRS; do
  [ -d "$d" ] && present_dirs="$present_dirs $d"
done

if [ -n "$present_dirs" ]; then
  # shellcheck disable=SC2086   # $present_dirs is a space-separated list on purpose
  while IFS= read -r f; do
    if [ -z "$newest_source" ] || [ "$f" -nt "$newest_source" ]; then newest_source="$f"; fi
  done < <(find $present_dirs -type f -name '*.sol' 2>/dev/null)
fi

for f in $EXTRA_SRC; do
  [ -f "$f" ] || continue
  if [ -z "$newest_source" ] || [ "$f" -nt "$newest_source" ]; then newest_source="$f"; fi
done

if [ -z "$newest_source" ]; then
  echo "NO SOURCES found in:$present_dirs $EXTRA_SRC"
  exit 2
fi

echo "newest source: $newest_source"
echo "build marker:  $build_marker"

if [ "$newest_source" -nt "$build_marker" ]; then
  echo "STALE BUILD: $newest_source changed after the last build. Run forge build before trusting anything"
  echo "measured from $OUT_DIR."
  exit 1
fi

echo "FRESH: the build is at least as new as every source."
