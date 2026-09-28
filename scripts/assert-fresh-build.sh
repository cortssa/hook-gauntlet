#!/usr/bin/env bash
#
# assert-fresh-build.sh - fail if the compiled artifacts are not what the sources and the settings as they are now produce.
#
# The problem it solves: the stale `out/`. A guard that compares SOURCES can be perfectly green while the
# thing you are about to measure, deploy or hand to an auditor was compiled from an older tree. It happens
# most easily at exactly the wrong moment: a dry run, a size check before a promotion, a benchmark. The
# failure is silent and the output looks right, which is why it needs its own check with its own exit code.
#
# Who decides: FORGE. This check runs `forge build --offline` (plus FORGE_FLAGS, in the profile FOUNDRY_PROFILE selects:
# the battery's) and reads forge's own answer. `No files changed, compilation skipped` - every artifact is what the
# sources and the settings produce - is FRESH. A compilation is STALE: the artifacts you were about to measure were older
# than the sources or the settings. A build that fails decides nothing. So THIS CHECK BUILDS: when the artifacts were
# stale it rewrites out/ and cache/, and says so - they are current afterwards, but whatever was measured from them before
# was not. Why forge and not a comparison of our own: forge knows everything that changes the bytecode, and a comparison
# only knows what it was told about. The version before this one compared each source's content hash with forge's cache,
# and forge's cache does not record foundry.toml: an optimizer, evm_version or via_ir changed with no source touched
# changes the bytecode (measured, forge 1.8.1: a toy's runtime went from 690 to 388 bytes with the optimizer on, and
# forge recompiled) and that check said FRESH. forge also sees remappings, imports outside SRC_DIRS, `skip =` patterns,
# and an artifact deleted from out/. The first version of all compared file TIMES, and went red about one run in ten on
# sources that had just been copied (new mtime, same bytes); forge decides by content, so a copy is FRESH here too.
# What it costs when nothing changed: one no-op `forge build` plus the hashing - measured 2026-09-24, forge 1.8.1, WSL,
# right after the battery's own build: the whole check 0.19-0.21 s on the kit's root project (the no-op build alone
# 0.12-0.13 s), 0.30-0.32 s on the v4 module (0.22 s), 0.16 s on a one-contract toy (0.09 s).
#
# EVIDENCE, printed before the verdict and never deciding it: each source under SRC_DIRS hashed the way forge hashes it
# (XXH3-64 of the text with CR LF folded to LF, scripts/lib/forge-cache-check.py, checked against forge 1.8.1's own
# cache) and compared with the content forge recorded for it in its cache - so a STALE names the file that differed, or
# says no source did (then the settings, the compiler, a missing artifact or a file outside SRC_DIRS changed). The
# evidence is read BEFORE the build, which rewrites the cache. File times are printed as evidence too.
#
# Usage:   scripts/assert-fresh-build.sh [project-dir]
# Env:     FORGE_FLAGS  the flags the artifacts were built with (the battery passes its own). `--offline` is added if it
#                     is not there (the check never downloads a compiler: a solc that is not installed decides nothing).
#                     `--force` is refused: it always compiles, so its answer means nothing.
#                     A line break in it is refused (scripts/lib/forge-env.sh, forge_flags_one_line): exit 2.
#          FOUNDRY_PROFILE  as forge reads it: the check builds the profile you measured. A profile with its own `out`
#                     needs OUT_DIR set to it (its `cache_path` is read, below).
#          OUT_DIR    artifact directory (default: out). No .json in it: nothing was built - exit 2, nothing built here.
#          CACHE_FILE forge's cache (default: <cache_path>/solidity-files-cache.json, cache_path as `forge config` gives it
#                     here, under the profile in force; `cache` when it cannot say). Missing: exit 2, nothing built here.
#                     It was cache/ always, and a project with its own cache_path failed the battery's freshness on
#                     every run with "NO CACHE" (V25, 2026-09-27).
#          SRC_DIRS   evidence only: where the sources to hash are (default: "src test script").
#          EXTRA_SRC  evidence only: other files whose time is compared with the cache's (default: "foundry.toml
#                     remappings.txt"; forge's cache does not record their content, forge's build sees them).
#          HASH_PYTHON  evidence only: the Python 3 to hash with (default: python3, then python). None: no evidence,
#                     and the verdict is forge's as always.
# A CACHE WRITTEN AT ANOTHER PATH (the project copied with its out/ and cache/, or moved) is not asked: there forge's
# answer is not true. Its incremental build recompiles a changed source without the test files that derive from it,
# which it recorded by absolute path (scripts/lib/forge-env.sh, forge_cache_elsewhere), says "No files changed" after,
# and the tests run the old code - measured, 2026-09-27: this check said FRESH (rc 0 in the battery) over artifacts that
# ran a planted mutant's ORIGINAL. So the record is removed, everything is built from nothing, and the verdict is STALE:
# nothing measured from the copied artifacts can be vouched for.
# A SOURCE CHANGED WHERE FORGE'S INCREMENTAL BUILD DOES NOT FOLLOW IT is not asked either, nor a build with no record of
# what it read: forge 1.8.1 links tests to sources dynamically and, after a change that keeps a source's interface,
# recompiles the source and not the tests - wrong for a file outside src/ (the root kit under the v4 module, a remapped or
# linked directory, lib/) and for src/ reached through a symlink or a remapping; then it says "No files changed" and the
# tests run the old code (measured, K27: FRESH here, BATTERY PASSED, over a planted mutant). The kit's record of what the
# last build it trusted read (scripts/lib/forge-env.sh, forge_sources_stale) decides: built from nothing, STALE, recorded.
# Every build this check makes and that succeeds is recorded. With NO record (a build forge made alone) forge's answer
# decides, as it always has, and an evidence line says a change outside src/ is not seen: the battery records first.
#
# Exit:    0 FRESH: forge compiled nothing
#          1 STALE: forge compiled - the artifacts were older than the sources or the settings; they are rebuilt now.
#            Or the cache was written at another path: rebuilt from nothing, and what was measured before is not vouched for
#          2 nothing can be decided: no artifacts or no cache (never built), no forge, --force, a build that failed
#            (its error is printed), an answer from forge this check does not know, a line break in FORGE_FLAGS, or
#            none of sha256sum, shasum, openssl to hash what the build read with

set -uo pipefail

# resolved BEFORE the cd below, which would break a relative $0
HERE="$(cd "$(dirname "$0")" && pwd)"
CHECKER="$HERE/lib/forge-cache-check.py"
# shellcheck source=lib/parse.sh
. "$HERE/lib/parse.sh" || { echo "assert-fresh-build: $HERE/lib/parse.sh is missing. Nothing decided."; exit 2; }
# shellcheck source=lib/forge-env.sh
. "$HERE/lib/forge-env.sh" || { echo "assert-fresh-build: $HERE/lib/forge-env.sh is missing. Nothing decided."; exit 2; }

PROJECT="${1:-.}"
cd "$PROJECT" || { echo "assert-fresh-build: cannot enter $PROJECT"; exit 2; }

SRC_DIRS="${SRC_DIRS:-src test script}"
OUT_DIR="${OUT_DIR:-out}"
EXTRA_SRC="${EXTRA_SRC:-foundry.toml remappings.txt}"
FORGE_FLAGS="${FORGE_FLAGS:-}"
forge_flags_one_line assert-fresh-build || exit 2
# forge's record where forge keeps it here (scripts/lib/forge-env.sh: `forge config`'s cache_path, `cache` without forge)
CACHE_FILE="${CACHE_FILE:-$(_forge_cache_file)}"

# ---- never built: nothing to judge, and nothing is built here (building it is the battery's job, not a verdict)
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
if ! command -v forge > /dev/null 2>&1; then
  echo "CANNOT CHECK: no forge on the PATH, and the verdict is forge's. Nothing decided."
  exit 2
fi
case " $FORGE_FLAGS " in
  *" --force "*) echo "CANNOT CHECK: FORGE_FLAGS has --force, which compiles every time: forge's answer would mean nothing. Nothing decided."; exit 2 ;;
esac

# ---- the evidence, read before the build (the build rewrites the cache)
n_changed=-1   # -1: no evidence
evidence() {
  local PY="" c d f present_dirs="" sources=() extras=() res rc verdict path ev h_disk h_cache n_newer=0 newer_same=""
  for c in ${HASH_PYTHON:-python3 python}; do
    if "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)' > /dev/null 2>&1; then PY="$c"; break; fi
  done
  if [ -z "$PY" ]; then echo "evidence: none - no Python 3 to hash the sources with (tried: ${HASH_PYTHON:-python3 python}; HASH_PYTHON)."; return; fi
  [ -f "$CHECKER" ] || { echo "evidence: none - $CHECKER is missing."; return; }
  for d in $SRC_DIRS; do [ -d "$d" ] && present_dirs="$present_dirs $d"; done
  if [ -n "$present_dirs" ]; then
    # shellcheck disable=SC2086   # $present_dirs is a space-separated list on purpose
    while IFS= read -r f; do sources+=("$f"); done < <(find $present_dirs -type f -name '*.sol' 2> /dev/null | sort)
  fi
  [ "${#sources[@]}" -gt 0 ] || { echo "evidence: none - no .sol file in:${present_dirs:- (none of: $SRC_DIRS)} (SRC_DIRS)."; return; }
  for f in $EXTRA_SRC; do [ -f "$f" ] && extras+=("$f"); done
  is_extra() { local e; for e in ${extras[@]+"${extras[@]}"}; do [ "$e" = "$1" ] && return 0; done; return 1; }
  res="$("$PY" "$CHECKER" "$CACHE_FILE" "${sources[@]}" ${extras[@]+"${extras[@]}"})"
  rc=$?
  if [ "$rc" -eq 3 ]; then
    echo "evidence: none - $CACHE_FILE has no per-source contentHash this check can read (another forge's shape?): $(printf '%s\n' "$res" | tr '\t' ' ' | head -1)"; return
  elif [ "$rc" -ne 0 ]; then
    echo "evidence: none - the hash helper failed (rc=$rc)."; return
  fi
  echo "evidence: cache $CACHE_FILE, mtime $(stat -c '%.9Y' "$CACHE_FILE" 2> /dev/null || echo '?')"
  n_changed=0
  while IFS=$'\t' read -r verdict path ev h_disk h_cache; do
    [ -n "$verdict" ] || continue
    h_cache="${h_cache%$'\r'}"; ev="${ev%$'\r'}"
    case "$verdict" in
      SAME)
        if ! is_extra "$path" && [ "$path" -nt "$CACHE_FILE" ]; then n_newer=$((n_newer + 1)); [ "$n_newer" -le 3 ] && newer_same="$newer_same $path"; fi ;;
      CHANGED)
        n_changed=$((n_changed + 1))
        echo "evidence: $path changed after the last build: its content hash is $h_disk, forge compiled $h_cache ($ev)" ;;
      ABSENT)
        if is_extra "$path"; then
          if [ "$path" -nt "$CACHE_FILE" ]; then
            echo "evidence: $path is newer than the cache (forge's cache does not record its content; forge's build below sees what it changes)"
          fi
        else
          n_changed=$((n_changed + 1))
          echo "evidence: $path is not in the cache: forge has never compiled it (a new source, or one forge does not build) ($ev)"
        fi ;;
      *) echo "evidence: the hash helper printed a line this check does not know ($verdict); the rest is not read."; n_changed=-1; return ;;
    esac
  done <<< "$res"
  [ "$n_newer" -gt 0 ] && echo "evidence: $n_newer source(s) are newer than the cache with the same content (copied or touched: not a change):$newer_same$([ "$n_newer" -gt 3 ] && echo ' ...')"
  echo "evidence: ${#sources[@]} sources under$present_dirs compared by content with what forge recorded: $n_changed changed or never built"
}
evidence

offline="--offline"
case " $FORGE_FLAGS " in *" --offline "*) offline="" ;; esac
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
cmd="forge build $offline $(forge_flags_shown "$FORGE_FLAGS")"

# ---- nothing to hash what a build read with (scripts/lib/forge-env.sh, sha256_of): the record below can be neither
# read nor written, and this check is not made without it
if ! _sha256_tool; then echo "CANNOT CHECK: $FORGE_SHA256_MISSING. Nothing decided."; exit 2; fi

# ---- a cache written at another path: forge's answer is not asked (see the header); built from nothing, STALE
if elsewhere="$(forge_cache_elsewhere "$CACHE_FILE")"; then
  echo "evidence: forge's cache records $elsewhere, which is not under $(pwd -P): it was written at another path"
  if ! rm -f -- "$CACHE_FILE" 2> /dev/null || [ -e "$CACHE_FILE" ]; then
    echo "CANNOT CHECK: $CACHE_FILE cannot be removed, and forge's incremental answer is not true for a cache written elsewhere. Nothing decided."; exit 2
  fi
  echo "decision: $(echo "$cmd" | tr -s ' ' | sed 's/ $//') with its record $CACHE_FILE removed, so from nothing (forge's 'No files changed' is not true for a cache written at another path)"
  # shellcheck disable=SC2086   # FORGE_FLAGS is a list of flags on purpose, as in battery.sh
  forge build $offline $FORGE_FLAGS > "$LOG" 2>&1
  brc=$?
  if [ "$brc" -ne 0 ]; then
    echo "CANNOT CHECK: forge build failed (rc=$brc) building from nothing:"
    if err="$(first_error_line "$LOG")"; then echo "  $err"; else tail -n 5 "$LOG" | sed 's/^/  | /'; fi
    echo "Nothing decided. Fix the build; $OUT_DIR holds whatever the other path's build left."
    exit 2
  fi
  forge_sources_record "$CACHE_FILE"
  echo "STALE BUILD: the artifacts in $OUT_DIR came with a cache written at another path, where forge leaves tests running the old code after a change; they are rebuilt from nothing now ($(grep -E 'Compiling [0-9]+ files? with ' "$LOG" | sed -e 's/^\[[^]]*\] //' | paste -sd ';' - | sed 's/;/; /g'))."
  echo "  Anything measured from them before this run was measured on artifacts this check cannot vouch for: measure it again."
  exit 1
fi

# ---- a source changed that forge's incremental build does not follow, or no record of what the last build read (the
# header): forge's answer is not asked either - "No files changed" after such a change is what forge says while the
# tests run the old code. Built from nothing, recorded, STALE
# (standalone, with no record - a build forge made alone - forge's answer decides as it always has, and a line says what
# that leaves unseen; the battery records what its build read before it calls this check)
forge_sources_stale "$CACHE_FILE" --no-record-ok; rc_src=$?
[ "$rc_src" -ne 2 ] || { echo "CANNOT CHECK: $FORGE_SOURCES_WHY. Nothing decided."; exit 2; }
if [ "$rc_src" -eq 0 ]; then
  echo "evidence: $FORGE_SOURCES_WHY"
  if ! rm -f -- "$CACHE_FILE" 2> /dev/null || [ -e "$CACHE_FILE" ]; then
    echo "CANNOT CHECK: $CACHE_FILE cannot be removed, and forge's incremental answer is not true here. Nothing decided."; exit 2
  fi
  echo "decision: $(echo "$cmd" | tr -s ' ' | sed 's/ $//') with its record $CACHE_FILE removed, so from nothing (forge's 'No files changed' is not true after such a change)"
  # shellcheck disable=SC2086   # FORGE_FLAGS is a list of flags on purpose, as in battery.sh
  forge build $offline $FORGE_FLAGS > "$LOG" 2>&1
  brc=$?
  if [ "$brc" -ne 0 ]; then
    echo "CANNOT CHECK: forge build failed (rc=$brc) building from nothing:"
    if err="$(first_error_line "$LOG")"; then echo "  $err"; else tail -n 5 "$LOG" | sed 's/^/  | /'; fi
    echo "Nothing decided. Fix the build; $OUT_DIR holds whatever the last build left."
    exit 2
  fi
  forge_sources_record "$CACHE_FILE"
  echo "STALE BUILD: what the last build read cannot be vouched for here (above); the artifacts in $OUT_DIR are rebuilt from nothing now ($(grep -E 'Compiling [0-9]+ files? with ' "$LOG" | sed -e 's/^\[[^]]*\] //' | paste -sd ';' - | sed 's/;/; /g'))."
  echo "  Anything measured from them before this run was measured on artifacts this check cannot vouch for: measure it again."
  exit 1
fi

# ---- the verdict: forge's
[ -z "$FORGE_SOURCES_NOTE" ] || echo "evidence: $FORGE_SOURCES_NOTE"
sources_pre="$(forge_sources_snapshot "$CACHE_FILE")"
echo "decision: $(echo "$cmd" | tr -s ' ' | sed 's/ $//') (forge decides; when it compiles, it rewrites $OUT_DIR and the cache)"
# shellcheck disable=SC2086   # FORGE_FLAGS is a list of flags on purpose, as in battery.sh
forge build $offline $FORGE_FLAGS > "$LOG" 2>&1
brc=$?
if [ "$brc" -ne 0 ]; then
  echo "CANNOT CHECK: forge build failed (rc=$brc), so it cannot say whether the artifacts were current:"
  if err="$(first_error_line "$LOG")"; then echo "  $err"; else tail -n 5 "$LOG" | sed 's/^/  | /'; fi
  echo "Nothing decided. Fix the build; the artifacts in $OUT_DIR are whatever the last good build left."
  exit 2
fi
# recorded only when a record was compared above: with none, this build may be one forge made over a change it does not
# follow, and recording it would bless it
[ -n "$FORGE_SOURCES_NOTE" ] || forge_sources_record "$CACHE_FILE" "$sources_pre"
answer="$(parse_build_verdict "$LOG")"
case "$answer" in
  skipped)
    if [ "$n_changed" -gt 0 ]; then
      echo "note: the evidence names $n_changed source(s) and forge compiled nothing; forge's answer is the verdict (a file under SRC_DIRS that forge does not build?)."
    fi
    echo "FRESH: forge compiled nothing - every artifact in $OUT_DIR is what the sources and settings as they are now produce."
    exit 0 ;;
  compiled)
    echo "STALE BUILD: forge compiled ($(grep -E 'Compiling [0-9]+ files? with ' "$LOG" | sed -e 's/^\[[^]]*\] //' | paste -sd ';' - | sed 's/;/; /g')): the artifacts in $OUT_DIR were older than the sources or the settings."
    if [ "$n_changed" -eq 0 ]; then
      echo "  not a source: every source's content is the one forge had compiled, so what changed is the settings (foundry.toml, remappings), the compiler, an artifact missing from $OUT_DIR, or a file outside SRC_DIRS."
    fi
    echo "  They are rebuilt now. Anything measured from them before this run was measured on stale artifacts: measure it again."
    exit 1 ;;
  *)
    echo "CANNOT CHECK: forge build answered neither 'No files changed, compilation skipped' nor 'Compiling <n> files' (another forge version?):"
    grep -v '^\s*$' "$LOG" | head -n 5 | sed 's/^/  | /'
    echo "Nothing decided."
    exit 2 ;;
esac
