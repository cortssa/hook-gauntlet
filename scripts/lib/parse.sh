# shellcheck shell=bash
#
# parse.sh - every piece of forge's (and the ledger's) TEXT that a script in this kit reads, read in one place.
#
# The problem it solves: a gate that reads a number out of a log is exactly as good as the line it matched. The first
# versions of these parsers lived inline in each script, as one `grep | sed` apiece, and each had a shape it misread in
# silence: a `sed` that does not match leaves the WHOLE line behind, and the gate then compares a sentence with "0"; a
# column read by position reads the wrong column the day forge reorders its table; a ledger field that is not a number
# is added up as 0 by awk. So every function here either returns the numbers it was asked for, or refuses (non-zero
# exit, nothing on stdout). A shape it does not recognise is a refusal, never a zero.
#
# Tested against real forge 1.8.1 output and near-miss shapes in scripts/test/fixtures/ (scripts/selftest.sh, section
# "parse.sh"). Source it:  . "$HERE/lib/parse.sh"

# forge colours its output on a terminal, and a log written on Windows has CR line ends: neither is part of the text
_parse_clean() {
  local esc
  esc="$(printf '\033')"
  sed -e 's/\r$//' -e "s/${esc}\[[0-9;]*m//g" "$1"
}

# parse_test_summary <log>
#   forge's closing line, e.g.
#     Ran 3 test suites in 1.23s (3.45s CPU time): 10 tests passed, 1 failed, 2 skipped (13 total tests)
#   prints "passed failed skipped total". Only a line that STARTS with "Ran " counts (a test's own console output is
#   indented, and a test can print anything), the last one wins, and the four numbers must add up.
#   exit 1: no summary line at all (no test ran, a filter matched nothing, the build failed)
#   exit 2: a summary line that is not of this shape, or whose numbers do not add up - REFUSED, not read
parse_test_summary() {
  local line out
  [ -r "$1" ] || return 1
  line="$(_parse_clean "$1" | grep -E '^Ran [0-9]+ test suites? ' | tail -n 1)"
  [ -n "$line" ] || return 1
  out="$(printf '%s\n' "$line" | sed -nE \
    's/^Ran [0-9]+ test suites? in [^:]*: ([0-9]+) tests? passed, ([0-9]+) failed, ([0-9]+) skipped \(([0-9]+) total tests?\)[[:space:]]*$/\1 \2 \3 \4/p')"
  [ -n "$out" ] || return 2
  printf '%s\n' "$out" | awk '$1 + $2 + $3 == $4 { print; ok = 1 } END { exit ok ? 0 : 2 }'
}

# parse_invariant_runs <log>
#   the line that closes a campaign. forge 1.8.1 prints it in three shapes, all read here (fixtures: forge-invariant-*):
#     [PASS] invariant_x() (runs: 64, calls: 4096, reverts: 12)          one invariant in its contract
#      ToyVaultInvariants invariants (runs: 64, calls: 4096, reverts: 0)   several: one campaign, one line, ONE space in
#      invariant_red() (runs: 1, calls: 1, reverts: 0)                     a failing one, after its call sequence
#   prints "campaigns calls smallest": how many campaigns ran, the calls they made in total, and the fewest calls any
#   one of them made. The whole line must be of one of those shapes: a test's console output is printed indented by two
#   spaces under "Logs:", and a test can print "(runs: 1, calls: 5, reverts: 0)" - that is not a campaign (an earlier,
#   unanchored version of this parser counted it, and a 5-call "campaign" failed a long fuzz for a budget it never had).
#   forge prints a failing invariant twice (in its suite and under "Failing tests:"), so whole lines are de-duplicated -
#   which also merges two campaigns with the same name and the same three numbers, a limit stated. No campaign at all
#   prints "0 0 0" and exits 0: the caller decides whether that is a refusal.
parse_invariant_runs() {
  [ -r "$1" ] || return 1
  _parse_clean "$1" \
    | { grep -E '^(\[(PASS|FAIL)(: .*)?\] | )[A-Za-z_$][A-Za-z0-9_$]*(\(\)| invariants) \(runs: [0-9]+, calls: [0-9]+, reverts: [0-9]+\)[[:space:]]*$' || true; } \
    | sort -u \
    | sed -E 's/.*\(runs: [0-9]+, calls: ([0-9]+), reverts: [0-9]+\)[[:space:]]*$/\1/' \
    | awk '{ n++; s += $1; if (n == 1 || $1 < m) m = $1 } END { print n + 0, s + 0, m + 0 }'
}

# parse_suites_by_dir <log>
#   forge's "Ran 5 tests for test/sim/GasMeter.t.sol:GasMeterScenario" lines, counted per directory of the test file:
#   prints e.g. "test=6 test/examples=2 test/sim=12" (sorted), or nothing when no suite ran. So a log says by NAME which
#   parts of a project's tests ran - a whole directory that silently stopped compiling into the run shows as missing.
parse_suites_by_dir() {
  [ -r "$1" ] || return 1
  _parse_clean "$1" | sed -nE 's/^Ran [0-9]+ tests? for (.*)\/[^/:]+:[A-Za-z0-9_$]+[[:space:]]*$/\1/p' \
    | sort | uniq -c | awk '{ printf "%s%s=%s", sep, $2, $1; sep = " " } END { if (NR) print "" }'
}

# parse_sizes <raw output of forge build --sizes>
#   forge's table, e.g.
#     | Contract | Runtime Size (B) | Initcode Size (B) | Runtime Margin (B) | Initcode Margin (B) |
#     | ToyVault | 2,431            | 2,606             | 22,145             | 46,546              |
#   prints "name runtime_bytes" per contract. The column is found BY ITS HEADER ("Runtime Size"), never by position,
#   and the header must name "Contract" first: a table without that header, or rows before it, are not read.
#   exit 2: no header, or a header with no Runtime Size column, or not a single row read
parse_sizes() {
  [ -r "$1" ] || return 2
  _parse_clean "$1" | awk -F'|' '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    !col && NF >= 4 && trim($2) == "Contract" {
      for (i = 3; i < NF; i++) if (trim($i) ~ /^Runtime Size/) col = i
      if (!col) { bad_header = 1; exit }
      next
    }
    col && NF >= col + 1 {
      name = trim($2); size = $col; gsub(/[ ,\t]/, "", size)
      if (name == "" || name == "Contract" || size !~ /^[0-9]+$/) next
      print name, size; rows++
    }
    END { exit (col && rows && !bad_header) ? 0 : 2 }'
}

# parse_sizes_both <raw output of forge build --sizes>
#   the same table, both sizes: prints "name runtime_bytes initcode_bytes" per contract. Both columns are found by their
#   headers ("Runtime Size", "Initcode Size"); the phase-2 gate needs both margins (AGENTS.md), so a table that lacks
#   either column is refused, never read as "initcode 0".
#   exit 2: no header, a header without both columns, or not a single row read
parse_sizes_both() {
  [ -r "$1" ] || return 2
  _parse_clean "$1" | awk -F'|' '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    !rc && NF >= 4 && trim($2) == "Contract" {
      for (i = 3; i < NF; i++) { h = trim($i); if (h ~ /^Runtime Size/) rc = i; if (h ~ /^Initcode Size/) ic = i }
      if (!rc || !ic) { bad_header = 1; exit }
      next
    }
    rc && NF >= (rc > ic ? rc : ic) + 1 {
      name = trim($2); r = $rc; c = $ic; gsub(/[ ,\t]/, "", r); gsub(/[ ,\t]/, "", c)
      if (name == "" || name == "Contract" || r !~ /^[0-9]+$/ || c !~ /^[0-9]+$/) next
      print name, r, c; rows++
    }
    END { exit (rc && ic && rows && !bad_header) ? 0 : 2 }'
}

# first_error_line <build or test log>
#   the line that says WHY a build or a setUp failed, for a message that has one line to spend: solc's first
#   `<Kind>Error (<code>): ...`, else a setUp failure (`[FAIL: setup failed: ...]` or `[FAIL: ...] setUp()`), else
#   forge's own `Error: ...`. Searched for, never taken from the end: solc's errors and warnings arrive in one listing
#   whose order depends on which compiler run finished first (the v4 module has two, because of the manager's IR
#   profile), so the end of a failed build can be nothing but warnings - which is what a fresh reader was shown.
#   Fixtures: scripts/test/fixtures/build-*.txt.
#   exit 1: none of those in the log
first_error_line() {
  local txt l
  [ -r "$1" ] || return 1
  txt="$(_parse_clean "$1")"
  l="$(grep -m 1 -E '^[A-Za-z]*Error \([0-9]+\):' <<< "$txt")"
  [ -n "$l" ] || l="$(grep -m 1 -E '^\[FAIL: setup failed|^\[FAIL.*\] setUp\(\)' <<< "$txt")"
  [ -n "$l" ] || l="$(grep -m 1 -E '^Error:|^error(\[|:)' <<< "$txt")"
  [ -n "$l" ] || return 1
  printf '%s
' "${l:0:300}"
}

# The simulation ledger (SimLedger.line): tab separated, 13, 15 or 16 fields, label and agent then numbers.
#   label agent decided executed refused in out quoted shortfall worst windfall gas pnl [gasCost pnlNet [atQuote]]
# A well-formed line has at least 13 fields and every field from the 3rd to the 16th that is present is an integer
# (pnl and pnlNet may be negative). Anything else is MALFORMED: counted and named by the report, never added up (awk
# reads "12a" as 12 and "" or "-" as 0, and a mean over those is a mean of a typo).
_SIM_LINE_OK='function sim_ok(   i, last) { if (NF < 13) return 0; last = NF < 16 ? NF : 16
  for (i = 3; i <= last; i++) if ($i !~ /^-?[0-9]+$/) return 0; return 1 }'

# sim_ledger_filter <file>   prints the well-formed lines (CR stripped)
sim_ledger_filter() {
  _parse_clean "$1" | awk -F '\t' "$_SIM_LINE_OK"' sim_ok() { print }'
}

# sim_ledger_malformed <file>   prints how many lines are malformed (empty lines included: the ledger writes none)
sim_ledger_malformed() {
  _parse_clean "$1" | awk -F '\t' "$_SIM_LINE_OK"' !sim_ok() { n++ } END { print n + 0 }'
}

# is_evm_address <string>   exactly "0x" and 40 hex digits, nothing before or after (a newline included)
is_evm_address() {
  [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]
}

# is_git_sha <string>   a full commit hash: exactly 40 lower-case hex digits (a branch, a tag or a short sha is not a pin)
is_git_sha() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}
