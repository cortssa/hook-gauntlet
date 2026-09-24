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
#          FOUNDRY_PROFILE  as forge reads it: the check builds the profile you measured. A profile with its own `out` /
#                     `cache_path` needs OUT_DIR and CACHE_FILE set to them.
#          OUT_DIR    artifact directory (default: out). No .json in it: nothing was built - exit 2, nothing built here.
#          CACHE_FILE forge's cache (default: cache/solidity-files-cache.json). Missing: exit 2, nothing built here.
#          SRC_DIRS   evidence only: where the sources to hash are (default: "src test script").
#          EXTRA_SRC  evidence only: other files whose time is compared with the cache's (default: "foundry.toml
#                     remappings.txt"; forge's cache does not record their content, forge's build sees them).
#          HASH_PYTHON  evidence only: the Python 3 to hash with (default: python3, then python). None: no evidence,
#                     and the verdict is forge's as always.
# Exit:    0 FRESH: forge compiled nothing
#          1 STALE: forge compiled - the artifacts were older than the sources or the settings; they are rebuilt now
#          2 nothing can be decided: no artifacts or no cache (never built), no forge, --force, a build that failed
#            (its error is printed), or an answer from forge this check does not know

set -uo pipefail

# resolved BEFORE the cd below, which would break a relative $0
HERE="$(cd "$(dirname "$0")" && pwd)"
CHECKER="$HERE/lib/forge-cache-check.py"
# shellcheck source=lib/parse.sh
. "$HERE/lib/parse.sh" || { echo "assert-fresh-build: $HERE/lib/parse.sh is missing. Nothing decided."; exit 2; }

PROJECT="${1:-.}"
cd "$PROJECT" || { echo "assert-fresh-build: cannot enter $PROJECT"; exit 2; }

SRC_DIRS="${SRC_DIRS:-src test script}"
OUT_DIR="${OUT_DIR:-out}"
CACHE_FILE="${CACHE_FILE:-cache/solidity-files-cache.json}"
EXTRA_SRC="${EXTRA_SRC:-foundry.toml remappings.txt}"
FORGE_FLAGS="${FORGE_FLAGS:-}"

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

# ---- the verdict: forge's
offline="--offline"
case " $FORGE_FLAGS " in *" --offline "*) offline="" ;; esac
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
cmd="forge build $offline $FORGE_FLAGS"
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
