#!/usr/bin/env bash
#
# size.sh - the runtime AND initcode size of each contract, their margins to the 24,576-byte (EIP-170) and 49,152-byte
# (EIP-3860) limits, and the change in runtime size since a baseline.
#
# The problem it solves: a hook is one contract that cannot be split across a proxy without changing what it is,
# so it lives close to the EIP-170 limit, and every fix costs bytes. "It should still fit" is an inference. The
# number has to be read before the decision, not discovered after it, and a fix that leaves no room for the next
# fix is a finding in its own right. The initcode counts too: a hook is deployed by CREATE2 from initcode that carries
# its constructor arguments, and the phase-2 gate (AGENTS.md) asks for both margins. This script used to print only
# the runtime one.
#
# Usage:   scripts/size.sh [project-dir] [ContractName ...]      (no names = every contract forge reports; a name also
#          takes that contract's other builds, `<Name>.<profile>` - the `.manager` build of a v4 hook, QUICKSTART 7b)
# Env:     BASELINE    a file written by an earlier run; prints the delta per contract
#          MIN_MARGIN  fail if any listed contract has fewer bytes of RUNTIME margin than this   (default: 0)
#          MIN_INIT_MARGIN  the same for the INITCODE margin                                 (default: 0)
#          LABEL       name of the output file                                           (default: sizes)
#          OUT_DIR     where it goes                                                     (default: <project>/.gauntlet/reports;
#                      a relative one is under <project>). Inside a project with no .gauntlet/ (someone else's tree,
#                      doctrine/RETROFIT.md) it refuses before writing anything, exit 2 - unless it is a bench or the kit's
#                      own (scripts/lib/owner-tree.sh)
#          FORGE_FLAGS extra flags for forge (a line break in it is refused, exit 2: scripts/lib/forge-env.sh)
# Output:  lines of "name runtime_bytes runtime_margin initcode_bytes initcode_margin", also saved to $OUT_DIR/$LABEL.txt
#          (usable as a BASELINE; a baseline of the older three-column form is read too). A source forge compiled under two
#          paths (a relative path out of the project and the absolute one) is ONE row, and the run says how many it merged.
# Exit:    0 ok, 1 a margin is below MIN_MARGIN or MIN_INIT_MARGIN, 2 no sizes could be read (a table without BOTH size
#          columns measures nothing), or a line break in FORGE_FLAGS, or OUT_DIR refused (above)

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/parse.sh
. "$HERE/lib/parse.sh" || { echo "size: $HERE/lib/parse.sh is missing"; exit 2; }
# shellcheck source=lib/forge-env.sh
. "$HERE/lib/forge-env.sh" || { echo "size: $HERE/lib/forge-env.sh is missing"; exit 2; }
# shellcheck source=lib/owner-tree.sh
. "$HERE/lib/owner-tree.sh" || { echo "size: $HERE/lib/owner-tree.sh is missing"; exit 2; }

PROJECT="${1:-.}"
[ "$#" -gt 0 ] && shift
cd "$PROJECT" || { echo "size: cannot enter $PROJECT"; exit 2; }

MIN_MARGIN="${MIN_MARGIN:-0}"
MIN_INIT_MARGIN="${MIN_INIT_MARGIN:-0}"
LABEL="${LABEL:-sizes}"
OUT_DIR="${OUT_DIR:-.gauntlet/reports}"
FORGE_FLAGS="${FORGE_FLAGS:-}"
forge_flags_one_line size || exit 2
BASELINE="${BASELINE:-}"
LIMIT=24576
INIT_LIMIT=49152
# never into a tree without the kit's convention (V26b: `size.sh <proj> <Name>` made <proj>/.gauntlet/reports in one)
report_dir_allowed size "$(pwd -P)" "$OUT_DIR" || { echo "size: nothing measured."; exit 2; }
mkdir -p "$OUT_DIR"
RAW="$OUT_DIR/$LABEL.raw.txt"
OUT="$OUT_DIR/$LABEL.txt"

# the baseline is read BEFORE this run writes anything: with the default LABEL the two are the same file, and the
# delta used to come out as 0 after a fix that had cost bytes
BASE_COPY=""
if [ -n "$BASELINE" ] && [ -f "$BASELINE" ]; then
  BASE_COPY="$(mktemp)"; cp "$BASELINE" "$BASE_COPY"; trap 'rm -f "$BASE_COPY"' EXIT
fi

# shellcheck disable=SC2086
forge build $FORGE_FLAGS --sizes > "$RAW" 2>&1
rc_build=$?

# forge prints a table: | Contract | Runtime Size (B) | Initcode Size (B) | Runtime Margin (B) | Initcode Margin (B) |
# Both size columns are found BY THEIR HEADERS (scripts/lib/parse.sh, parse_sizes_both), never by position: a table
# without that header, or with a column renamed or missing, measures nothing. The margins are recomputed here.
# A source compiled under TWO paths - a project that reaches the kit by `../` (the kit vendored beside it, FR16) gets some
# of the kit's and v4-core's files under the relative path and the absolute one - is one contract that forge lists twice,
# as `<name> (<path>)` (parse.sh: one word, `<name>@<path>`). Listed once here: the two paths are resolved from the project
# (textually: `..` against the directory, no link followed) and a row whose name and resolved file an earlier row
# already had is dropped, counted, and said. A name left with one file is printed plain; two DIFFERENT files of one
# name keep their `@<path>`.
parse_sizes_both "$RAW" | awk -v dir="$(pwd -P)" -v note="$OUT.merged" '
  function norm(p,  n, i, a, k, out, parts) {
    gsub(/%20/, " ", p); if (p !~ /^\//) p = dir "/" p
    n = split(p, a, "/"); k = 0
    for (i = 1; i <= n; i++) { if (a[i] == "" || a[i] == ".") continue; if (a[i] == "..") { if (k > 0) k--; continue } parts[++k] = a[i] }
    out = ""; for (i = 1; i <= k; i++) out = out "/" parts[i]; return out
  }
  { base = $1; key = $1; at = index($1, "@"); if (at) { base = substr($1, 1, at - 1); key = base "@" norm(substr($1, at + 1)) }
    if (key in seen) { merged++; next }
    seen[key] = 1; files[base]++; n++; b[n] = base; row[n] = $0 }
  END {
    for (i = 1; i <= n; i++) { split(row[i], f, " "); name = (files[b[i]] == 1) ? b[i] : f[1]; print name, f[2], f[3] }
    if (merged) print merged > note
  }' | awk -v limit="$LIMIT" -v ilimit="$INIT_LIMIT" '{ print $1, $2, limit - $2, $3, ilimit - $3 }' > "$OUT.all"
if [ -s "$OUT.merged" ]; then
  echo "size: $(cat "$OUT.merged") row(s) of forge's table were a source compiled under two paths (a relative path out of the project and the absolute one): listed once"
fi
rm -f "$OUT.merged"

if [ ! -s "$OUT.all" ]; then
  echo "size: could not read any size from forge's output (rc=$rc_build): no table headed 'Contract | ... Runtime Size ..."
  echo "      Initcode Size', or no row under it. See $RAW. NOTHING MEASURED."
  rm -f "$OUT.all"
  exit 2
fi

if [ "$#" -gt 0 ]; then
  : > "$OUT"
  # a name also takes that contract's other builds, `<name>.<profile>`: a hook compiled next to the PoolManager's IR
  # restriction (QUICKSTART 7b) has `<Hook>.manager`, the build the tests deploy and the one the kit says to cite - it
  # used to be left out of sizes.txt whenever the hook was named
  for want in "$@"; do
    if ! awk -v w="$want" '$1 == w || index($1, w ".") == 1 { print; found = 1 } END { exit found ? 0 : 1 }' "$OUT.all" >> "$OUT"; then
      echo "size: contract $want is not in forge's output. NOTHING MEASURED for it."; rm -f "$OUT.all"; exit 2
    fi
  done
else
  cp "$OUT.all" "$OUT"
fi
rm -f "$OUT.all"

fail=0
printf '%-32s %10s %10s %10s %10s %10s\n' contract runtime margin initcode init_margin delta
while read -r name size margin isize imargin; do
  delta="-"
  if [ -n "$BASE_COPY" ]; then
    was="$(awk -v w="$name" '$1 == w { print $2 }' "$BASE_COPY")"
    [ -n "$was" ] && delta="$((size - was))"
    [ "$delta" != "-" ] && [ "$delta" -gt 0 ] && delta="+$delta"
  fi
  flag=""
  if [ "$margin" -lt "$MIN_MARGIN" ]; then flag="  <-- runtime below MIN_MARGIN=$MIN_MARGIN"; fail=1; fi
  if [ "$imargin" -lt "$MIN_INIT_MARGIN" ]; then flag="$flag  <-- initcode below MIN_INIT_MARGIN=$MIN_INIT_MARGIN"; fail=1; fi
  printf '%-32s %10s %10s %10s %10s %10s%s\n' "$name" "$size" "$margin" "$isize" "$imargin" "$delta" "$flag"
done < "$OUT"
echo "saved to $OUT"

[ -n "$BASELINE" ] && [ ! -f "$BASELINE" ] && echo "size: BASELINE $BASELINE does not exist; no delta shown"
exit "$fail"
