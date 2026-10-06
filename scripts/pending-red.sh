#!/usr/bin/env bash
#
# pending-red.sh - see a test in pending/ FAIL on src/ as it stands, and leave the record scripts/next.sh reads.
#
# The problem it solves: a finding's test in pending/ (NEXT.md row 6b) is evidence only once it has been seen red on the
# code it accuses (EVIDENCE.md section 2), and "seen red" was a sentence in DECISIONS.md. A walker of the route
# (the local-model walk, judged 2026-09-30) cited five red tests in pending/ that never existed; the one that did exist did not compile, and mended it
# PASSED on the planted code - it asserted the bug, not the promise. So the red is measured here and written down as a
# file: for each test file, `FOUNDRY_PROFILE=pending forge test --match-path pending/<file> -vv` from the project, and
# the record <proj>/.gauntlet/pending-red/<file>.<key> (scripts/lib/pending-record.sh: the key is the SHA-256 of the
# file list and contents of src/, test/, pending/, foundry.toml and remappings.txt) is written ONLY when the file
# compiled, at least one of its tests FAILED, and no failure is setUp()'s. Every other outcome is refused, and no
# record is left for that file:
#   - it does not compile (or another file the pending profile compiles does not: forge builds them all), or no test
#     of it ran: `pending/<file> does not compile` / `no test ran`;
#   - every test in it PASSES on the code: `pending/<file> passes on the code: it is not a finding's test (EVIDENCE.md
#     section 2)` - a finding's test fails on the code it accuses (its control, a test of its own in the same file,
#     passes: one red test is enough);
#   - setUp() failed: the harness broke, not the code (the local-model walk's judge: 17 failures, every one the bench's
#     own) - except the v4 harness refusing a hook's permission bits (`V4Harness: ... permission bit ...`): its whole
#     line is printed, and that refusal IS a finding (doctrine/EVIDENCE.md section 2, "while a permission-bits finding
#     is open"): its own test sets `_skipPermissionCheck = true` in setUp and holds the deployed hook to the check in a
#     test of its own, `_checkHookPermissions(address(hook));` - that test's failure is the harness's line, and its red
#     is recorded like any other (and, once recorded, a line says the next steps in their order: the flag and its
#     header in the suites, then the battery);
#   - a directory below pending/ named *.sol: not a test file.
# Every run builds from NOTHING, in a build directory of its own (<proj>/.gauntlet/pending-red-build/: forge's
# --cache-path and --out there, emptied at the start of each run, and again whenever the key changes between two
# files). K48: forge's
# incremental build ran a helper in test/ as it was BEFORE an edit, both ways - a test the edit made green kept its red,
# one it made red "passed" (V40). The battery's guard (scripts/lib/forge-env.sh, forge_cache_rehome: its record of what
# the build read) is not reused: the pending profile shares forge's cache with the battery, and that record, written by
# the battery, leaves test/ out. Nor `forge test --force`: it deletes cache/fuzz and cache/invariant, the failures the
# battery's fuzzer persisted (measured, forge 1.8.1). A build from nothing costs a full compile per run (the v4 module's
# PoolManager included). The project's cache/fuzz, cache/invariant, cache/solidity-files-cache.json and out/ are not
# touched (measured, K48 and V41). What forge does write there is cache/test-failures - the tests that failed, here the
# pending ones, replacing the battery's last list - which nothing in the kit reads: `--rerun` is never used.
# Before a run the old records of that file are removed: the verdict is the last run's. The key is taken before and
# after the run; a file edited while it ran is refused. The record's first line is `pending-red: red <file> key=<key>
# <date>`, then the failing tests, the counts, and the last 20 lines of forge's output; the whole log of the run is
# <proj>/.gauntlet/pending-red/<file>.log.
# src/ is the owner's (v0.4.2): with a record of its anchor, <proj>/.gauntlet/src.sha256 (scripts/init-state.sh;
# scripts/lib/src-anchor.sh), every run first says whether src/ is as recorded, and refuses before anything runs - exit
# 2, no record written or removed - when it differs or is gone (a red recorded over an edited hook is no finding's red:
# a walker "fixed" its hook's permission bits in src/, and its records were made on that). No record: one line says how
# one is made, and the run goes on. Each record names the anchor it was made on (`anchor: src/ ...`), and a record whose
# failures include the v4 harness's permission-bits refusal - a test that held the hook to the check - carries that
# line too, `permission-bits: <the FAIL line>`: what scripts/battery.sh reads for a suite under test/ that sets
# `_skipPermissionCheck` (doctrine/EVIDENCE.md section 2). The `anchor:` line carries the hash of src/ the run saw, and
# the `keyed:` line each part of the key hashed alone: a reader names the part that changed since, and a permission-bits
# record stays current while src/ and its own file are as recorded (scripts/lib/pending-record.sh, v0.4.2).
# What it does not do: judge WHY the test is red (a wrong assertion is red too - EVIDENCE.md section 2's
# MUTATION-TESTED is that judgement), nor stale a record when a library or the compiler changes (not in the key).
#
# Usage:   scripts/pending-red.sh <proj> [pending/<file>]     no file: every .sol below <proj>/pending
#   <proj> is the project: the directory that holds pending/ and foundry.toml, whose foundry.toml has the pending
#   profile of NEXT.md row 6b (`[profile.pending]` with `test = "pending"`). The file may be given as pending/<file>,
#   <file> (below pending/) or a path to it.
# Env:     none read. Every variable forge would read (FOUNDRY_*, FORGE_*, DAPP_*) is removed and named
#          (scripts/lib/forge-env.sh); FOUNDRY_PROFILE=pending is set here. A .env in the project that sets one is
#          refused, and so is a filter in ~/.foundry/foundry.toml.
# Exit:    0 every file named is red on the code, its record written; 2 one is not (the lines above say which and why),
#          or nothing could be run: no project, no pending/, no [profile.pending], no such file, no forge, src/ not as
#          its anchor records it.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/parse.sh
. "$HERE/lib/parse.sh" || { echo "pending-red: $HERE/lib/parse.sh is missing"; exit 2; }
# shellcheck source=lib/forge-env.sh
. "$HERE/lib/forge-env.sh" || { echo "pending-red: $HERE/lib/forge-env.sh is missing"; exit 2; }
# shellcheck source=lib/pending-record.sh
. "$HERE/lib/pending-record.sh" || { echo "pending-red: $HERE/lib/pending-record.sh is missing"; exit 2; }
# shellcheck source=lib/src-anchor.sh
. "$HERE/lib/src-anchor.sh" || { echo "pending-red: $HERE/lib/src-anchor.sh is missing"; exit 2; }
forge_env_clean pending-red "" "$0" "$@"

no() { echo "pending-red: $*"; exit 2; }
[ $# -ge 1 ] && [ $# -le 2 ] || no "usage: scripts/pending-red.sh <proj> [pending/<file>]"
PROJ="$(cd "$1" 2> /dev/null && pwd -P)" || no "no project at '$1'."
[ -d "$PROJ/pending" ] || no "$PROJ has no pending/ (NEXT.md row 6b: a finding's test goes to pending/<id>.t.sol)."
[ -f "$PROJ/foundry.toml" ] || no "$PROJ has no foundry.toml."
{ [ -d "$PROJ/.gauntlet" ] || [ -f "$PROJ/STATE.md" ]; } \
  || no "$PROJ has neither .gauntlet/ nor STATE.md: not a project of the route (state/README.md) - nothing written."
grep -qE '^[[:space:]]*\[profile\.pending\][[:space:]]*(#.*)?$' "$PROJ/foundry.toml" \
  || no "$PROJ/foundry.toml has no [profile.pending] (with test = \"pending\"): NEXT.md row 6b - add it, then run this again."
command -v forge > /dev/null 2>&1 || no "no forge on the PATH."

declare -a FILES=()
if [ $# -eq 2 ]; then
  f="$2"
  case "$f" in
    /*) case "$f" in "$PROJ"/pending/*) f="${f#"$PROJ"/}" ;; *) f="$(cd "$(dirname "$f")" 2> /dev/null && pwd -P)/$(basename "$f")"; f="${f#"$PROJ"/}" ;; esac ;;
    pending/*) ;;
    ./pending/*) f="${f#./}" ;;
    *) f="pending/$f" ;;
  esac
  case "$f" in pending/*.sol) ;; *) no "'$2' is not a .sol file below $PROJ/pending." ;; esac
  [ ! -d "$PROJ/$f" ] || no "$f is a directory: a test in pending/ is a file (NEXT.md row 6b) - nothing run."
  [ -f "$PROJ/$f" ] || no "$PROJ/$f does not exist."
  FILES=("$f")
else
  # a directory named *.sol below pending/ is not a test: refused as the cited-file check refuses one (K48)
  d_bad="$(pending_sol_dirs "$PROJ")"
  [ -z "$d_bad" ] || no "$(head -1 <<< "$d_bad") is a directory: a test in pending/ is a file (NEXT.md row 6b) - nothing run."
  while IFS= read -r f; do FILES+=("$f"); done < <(pending_files "$PROJ")
  [ "${#FILES[@]}" -gt 0 ] || no "$PROJ/pending has no .sol file."
fi

# src/ against its anchor (v0.4.2): said on every run; changed or gone, refused before anything runs or is written
src_anchor_check pending-red "$PROJ"; sa_rc=$?
[ -z "$SRC_ANCHOR_LINE" ] || echo "$SRC_ANCHOR_LINE"
[ "$sa_rc" -eq 0 ] || exit 2

cd "$PROJ" || no "cannot enter $PROJ."
forge_dotenv_check pending-red "$PROJ" || no "nothing run."
export FOUNDRY_PROFILE=pending
forge_global_config pending-red
[ -z "$FORGE_GLOBAL_NARROW" ] \
  || no "$FORGE_GLOBAL_FILE narrows the tests forge runs here ($FORGE_GLOBAL_NARROW): take that key out of it - nothing run."
FV="$(forge --version 2> /dev/null | head -1)"
RD="$(pending_record_dir "$PROJ")"
mkdir -p "$RD" || no "cannot write $RD."
# the build from nothing (K48, above): forge's cache and artifacts of this script's own, never the project's
BD="$PROJ/.gauntlet/pending-red-build"

bad=0 bk=""
for f in "${FILES[@]}"; do
  sub="${f#pending/}"
  mkdir -p "$RD/$(dirname "$sub")"
  # the verdict is this run's: the records of any earlier run of this file go first
  find "$RD/$(dirname "$sub")" -maxdepth 1 -type f -name "$(basename "$sub").*" ! -name "$(basename "$sub").log" -exec rm -f {} + 2> /dev/null
  k0="$(pending_record_key "$PROJ" "$f")"
  log="$RD/$sub.log"
  if [ "$k0" != "$bk" ]; then
    rm -rf "$BD" 2> /dev/null; [ ! -e "$BD" ] || no "cannot empty $BD (the build from nothing) - nothing run."
    bk="$k0"
  fi
  forge test --cache-path "$BD/cache" --out "$BD/out" --match-path "$f" -vv > "$log" 2>&1
  rc=$?
  k1="$(pending_record_key "$PROJ" "$f")"
  keyed="$(pending_record_keyed "$PROJ" "$f")"; src_now="$(pending_key_part "$PROJ" src)"
  if [ "$k0" != "$k1" ]; then echo "pending-red: $f, or a file of $PENDING_KEY_SAYS, changed while it ran - no record; run it again."; bad=1; bk=""; continue; fi
  sum="$(parse_test_summary "$log")"; src=$?
  if [ "$src" -eq 2 ]; then echo "pending-red: $f - forge's summary line is not of a shape this script reads (log: $log) - no record."; bad=1; continue; fi
  if [ "$src" -ne 0 ]; then
    first="$(first_error_line "$log")"
    if grep -qE 'Compiler run failed|^Error \([0-9]+\)|^[A-Za-z]*Error \([0-9]+\):' <(_parse_clean "$log"); then
      echo "pending-red: $f does not compile (forge rc $rc): ${first:-see $log} - no record. A test that does not compile has not been seen red; if the error is in another file below pending/, that file stops this one too (forge builds them all)."
    else
      echo "pending-red: $f - no test ran (forge rc $rc): ${first:-see $log} - no record."
    fi
    bad=1; continue
  fi
  read -r n_pass n_fail n_skip n_total <<< "$sum"
  setup_fail="$(_parse_clean "$log" | grep -E '^\[FAIL[^]]*\] setUp\(\)|^\[FAIL: setup failed' | head -1)"
  if [ -n "$setup_fail" ]; then
    case "$setup_fail" in
      *V4Harness:*"permission bit"*)
        # the harness refused the deploy: the hook implements a callback its address has no bit for (K46) - a finding
        echo "pending-red: $f - setUp() failed: $setup_fail - no record."
        echo "pending-red: the harness refused the deploy: that IS the finding - its test sets _skipPermissionCheck = true in setUp and holds the hook to the check in a test of its own, _checkHookPermissions(address(hook)); - that test's failure is this line, recorded red like any other (doctrine/EVIDENCE.md section 2, \"while a permission-bits finding is open\")" ;;
      *) echo "pending-red: $f - setUp() failed: the harness broke, not the code under test: ${setup_fail:0:200} - no record." ;;
    esac
    bad=1; continue
  fi
  if [ "$n_total" -eq 0 ]; then echo "pending-red: $f - no test ran ($n_total tests) - no record."; bad=1; continue; fi
  if [ "$n_fail" -eq 0 ]; then
    echo "pending-red: $f passes on the code: it is not a finding's test (EVIDENCE.md section 2) - $n_pass passed, $n_skip skipped; no record."
    bad=1; continue
  fi
  failed="$(_parse_clean "$log" | sed -nE 's/^\[FAIL[^]]*\] ([A-Za-z_$][A-Za-z0-9_$]*\(\)).*/\1/p' | awk '!seen[$0]++' | paste -sd ',' - | sed 's/,/, /g')"
  first="$(_parse_clean "$log" | grep -m 1 -E '^\[FAIL' | cut -c1-300)"
  # the v4 harness's permission-bits refusal as a test's failure (setUp's is refused above): the record says so, and
  # scripts/battery.sh reads it for a suite that sets _skipPermissionCheck (doctrine/EVIDENCE.md section 2)
  bits="$(_parse_clean "$log" | grep -m 1 -E '^\[FAIL: V4Harness: .* implemented but (its|their) permission bits? (is|are) not set' | cut -c1-400)"
  rec="$RD/$sub.$k1"
  {
    pending_record_head "$f" "$k1"   # the line next.sh reads: `pending-red: red <file> key=<key> <date>`
    echo "failed: $failed"
    echo "result: $n_pass passed, $n_fail failed, $n_skip skipped ($n_total total)"
    echo "first failure: $first"
    echo "anchor: src/ $SRC_ANCHOR_SHORT - src/ sha256 $src_now"
    [ -z "$bits" ] || echo "permission-bits: $bits"
    echo "$keyed"
    echo "# written by scripts/pending-red.sh, read by scripts/next.sh and scripts/battery.sh; the key: sha256 of the file list and contents of $PENDING_KEY_SAYS, each part hashed alone on the keyed: line (scripts/lib/pending-record.sh)"
    [ -z "$bits" ] || echo "# a permission-bits record: it stays current while src/ (the anchor: line's sha256) and $f (the keyed: line's file) are as recorded - an edit elsewhere in test/ or pending/ does not stale it"
    echo "# forge: $FV; profile pending; built from nothing in $BD; the whole log: $log"
    echo "# the last 20 lines of forge's output:"
    _parse_clean "$log" | tail -n 20
  } > "$rec.tmp" && mv "$rec.tmp" "$rec" || { echo "pending-red: cannot write $rec."; bad=1; continue; }
  echo "pending-red: $f is RED on the code as it stands - $n_fail failed ($failed), $n_pass passed; record: $rec"
  if [ -n "$bits" ]; then
    bid="${sub##*/}"; bid="${bid%.sol}"; bid="${bid%.t}"; while [ "${bid#.}" != "$bid" ]; do bid="${bid#.}"; done
    echo "pending-red: $f fails on the harness's permission-bits line: the finding is OPEN AND RECORDED. Now put _skipPermissionCheck = true and the header line '// _skipPermissionCheck: $bid open' in the suites that deploy the hook, then run the battery ($HERE/battery.sh $PROJ): this record stays current while src/ and $f are as recorded (doctrine/EVIDENCE.md section 2)"
  fi
done
if [ "$bad" -ne 0 ]; then echo "pending-red: NOT every file is red on the code - see the lines above."; exit 2; fi
echo "pending-red: every file checked is red on the code as it stands (${#FILES[@]}); next.sh reads the records."
exit 0
