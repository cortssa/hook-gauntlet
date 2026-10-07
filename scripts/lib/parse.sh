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

# parse_campaign_seconds <log>
#   how long forge took for the suites that ran an invariant campaign - what scripts/fuzz-long.sh scales into the cost of
#   the long one (K32). A suite is the block from "Ran N test(s) for <file>:<Contract>" to its
#     Suite result: ok. 3 passed; 0 failed; 0 skipped; finished in 1.20s (1.20s CPU time)
#   and it counts when a line inside it closes a campaign (parse_invariant_runs's shapes). Its time as forge prints it:
#   1.20s, 812.34ms, 339.10µs. Prints "suites seconds" (two decimals): the counted suites' times ADDED - forge runs suites
#   side by side, so on a machine with cores to spare the campaigns take less: an upper bound, as a cost said in advance
#   should be. exit 1: no suite with a campaign (no log, a filter, no invariant); exit 2: such a suite with no time of a
#   shape read here - refused, never read as 0.
parse_campaign_seconds() {
  [ -r "$1" ] || return 1
  _parse_clean "$1" | awk '
    /^Ran [0-9]+ tests? for / { in_s = 1; camp = 0; next }
    in_s && /^(\[(PASS|FAIL)(: .*)?\] | )[A-Za-z_$][A-Za-z0-9_$]*(\(\)| invariants) \(runs: [0-9]+, calls: [0-9]+, reverts: [0-9]+\)[ \t]*$/ { camp = 1 }
    in_s && /^Suite result: / {
      in_s = 0
      if (!camp) next
      if (!match($0, /finished in [0-9]+(\.[0-9]+)?(s|ms|µs|μs|us|ns) /)) { bad = 1; next }
      t = substr($0, RSTART + 12, RLENGTH - 13); v = t; sub(/[^0-9.]+$/, "", v); u = substr(t, length(v) + 1)
      total += v * (u == "s" ? 1 : u == "ms" ? 0.001 : u == "ns" ? 0.000000001 : 0.000001); n++
    }
    END { if (bad) exit 2; if (!n) exit 1; printf "%d %.2f\n", n, total }'
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
#   The name is ONE word. forge names a contract `<name> (<path>)` when two sources give it that name - a project that
#   reaches the kit by `../` has some of the kit's sources compiled under the relative AND the absolute path (FR16) - and
#   that is printed `<name>@<path>` (a space in the path as %20): with the space, every reader downstream took the path
#   for the size (scripts/size.sh wrote "runtime 24576" over it).
#   exit 2: no header, or a header with no Runtime Size column, or not a single row read
_SIZES_TOKEN='function token(n,  p) { if (match(n, / \(.*\)$/)) { p = substr(n, RSTART + 2, RLENGTH - 3); gsub(/ /, "%20", p); n = substr(n, 1, RSTART - 1) "@" p } return n }'
parse_sizes() {
  [ -r "$1" ] || return 2
  _parse_clean "$1" | awk -F'|' "$_SIZES_TOKEN"'
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    !col && NF >= 4 && trim($2) == "Contract" {
      for (i = 3; i < NF; i++) if (trim($i) ~ /^Runtime Size/) col = i
      if (!col) { bad_header = 1; exit }
      next
    }
    col && NF >= col + 1 {
      name = token(trim($2)); size = $col; gsub(/[ ,\t]/, "", size)
      if (name == "" || name == "Contract" || size !~ /^[0-9]+$/) next
      print name, size; rows++
    }
    END { exit (col && rows && !bad_header) ? 0 : 2 }'
}

# parse_sizes_both <raw output of forge build --sizes>
#   the same table, both sizes: prints "name runtime_bytes initcode_bytes" per contract. Both columns are found by their
#   headers ("Runtime Size", "Initcode Size"); the phase-2 gate needs both margins (AGENTS.md), so a table that lacks
#   either column is refused, never read as "initcode 0". The name is one word, as in parse_sizes (`<name>@<path>`).
#   exit 2: no header, a header without both columns, or not a single row read
parse_sizes_both() {
  [ -r "$1" ] || return 2
  _parse_clean "$1" | awk -F'|' "$_SIZES_TOKEN"'
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    !rc && NF >= 4 && trim($2) == "Contract" {
      for (i = 3; i < NF; i++) { h = trim($i); if (h ~ /^Runtime Size/) rc = i; if (h ~ /^Initcode Size/) ic = i }
      if (!rc || !ic) { bad_header = 1; exit }
      next
    }
    rc && NF >= (rc > ic ? rc : ic) + 1 {
      name = token(trim($2)); r = $rc; c = $ic; gsub(/[ ,\t]/, "", r); gsub(/[ ,\t]/, "", c)
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

# parse_build_verdict <log of a `forge build` that exited 0>
#   whether forge COMPILED anything. forge 1.8.1 prints `No files changed, compilation skipped` when every artifact is
#   what the sources and the settings as they are now produce, and `Compiling <n> files with Solc <version>` once per
#   compiler run when it compiled (on a terminal the line starts with a spinner, `[...] Compiling ...`). Prints
#   "compiled" or "skipped". A log with both (two compiler runs, one of them skipped) is "compiled": something was
#   rebuilt. Fixtures: scripts/test/fixtures/build-real-noop.txt, build-real-compiled.txt, build-nm-neither.txt.
#   exit 1: neither line - another forge's wording, or not a build log: REFUSED, never read as "skipped"
parse_build_verdict() {
  local txt
  [ -r "$1" ] || return 1
  txt="$(_parse_clean "$1")"
  if grep -Eq '^(\[[^]]*\] )?Compiling [0-9]+ files? with ' <<< "$txt"; then echo compiled; return 0; fi
  if grep -Eq '^(\[[^]]*\] )?No files changed, compilation skipped$' <<< "$txt"; then echo skipped; return 0; fi
  return 1
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

# any_revert_shapes <a test's .sol file>   (K32c, V32b: scripts/mutate.sh's WARNING on a finding's test)
#   the ways the file accepts ANY revert, one word a line, each once, in this order: `bare-expectRevert` (a
#   vm.expectRevert() with no error in it), `call-asserted-false` (a low-level .call / .delegatecall / .staticcall whose
#   success flag is asserted false - assertFalse(ok), assertTrue(!ok), assertEq(ok, false), require(!ok) - and whose
#   returned data is not captured, or never read again), `catch-not-compared` (a try/catch whose catch names no error, or
#   never reads the one it names under an assert, a require or a comparison; a catch that fails the test - fail(),
#   revert - accepts nothing and is not one). CODE is read, not comments or strings: `//` and `/* */` are taken out first,
#   and a string literal is blanked to its quotes (a URL in one included), so a comment or an assertion's message that
#   cites the rule is not a hit (V32b: Q-1's NatSpec was; V32c: Q-5's message was).
#   A heuristic that knows these few shapes only, stated: its silence is not evidence. The file is read as one text, not
#   test by test; a comparison made in a helper it does not see counts as none, and a name read anywhere in the file
#   counts as read. Known and not chased (V32c): a flag asserted false in a helper under another name (`_mustFail(ok)`),
#   `if (ok) fail();`, `assertTrue(ok == false)`, a catch that asserts only `err.length > 0` - all silent.
#   EVIDENCE.md section 2, condition 3.
#   exit 1: the file cannot be read. Nothing printed: none found.
any_revert_shapes() {
  [ -r "$1" ] && [ -f "$1" ] || return 1
  awk '
    function isid(ch) { return ch ~ /[A-Za-z0-9_$]/ }
    function words(s, w,   n, p, b, a) { # how many times the identifier w stands alone in s
      n = 0
      while ((p = index(s, w)) > 0) {
        b = p > 1 ? substr(s, p - 1, 1) : " "; a = substr(s, p + length(w), 1)
        if (!isid(b) && !isid(a)) n++
        s = substr(s, p + length(w))
      }
      return n
    }
    function closing(s, p, o, c,   d, ch) { # s has o at p: where its matching c is, 0 if nowhere
      d = 0
      for (; p <= length(s); p++) {
        ch = substr(s, p, 1)
        if (ch == o) d++; else if (ch == c && --d == 0) return p
      }
      return 0
    }
    function asserted_false(s, f) {
      return s ~ ("assertFalse *\\( *" f " *[,)]") || s ~ ("assertTrue *\\( *! *" f " *[,)]") \
        || s ~ ("assertEq *\\( *" f " *, *false *[,)]") || s ~ ("assertEq *\\( *false *, *" f " *[,)]") \
        || s ~ ("require *\\( *! *" f " *[,)]")
    }
    { # comments out, strings blanked to their quotes (K32d, V32c: a message citing the rule was read as code):
      # st 0 code, 2 inside /* */, 3 inside a double-quoted string, 4 a single-quoted one
      out = ""; n = length($0)
      for (i = 1; i <= n; i++) {
        ch = substr($0, i, 1); two = substr($0, i, 2)
        if (st == 2) { if (two == "*/") { st = 0; i++; out = out " " } continue }
        if (st >= 3) {
          if (ch == "\\") i++
          else if ((st == 3 && ch == "\"") || (st == 4 && ch == "\047")) { st = 0; out = out ch }
          continue
        }
        if (two == "//") break
        if (two == "/*") { st = 2; i++; continue }
        if (ch == "\"") st = 3; else if (ch == "\047") st = 4
        out = out ch
      }
      if (st >= 3) st = 0
      code = code " " out
    }
    END {
      gsub(/[\t\r]/, " ", code)
      bare = code ~ /(^|[^A-Za-z0-9_$])expectRevert *\( *\)/
      rest = code
      while (match(rest, /\( *(bool +)?[A-Za-z_][A-Za-z0-9_]* *, *((bytes +memory +)?[A-Za-z_][A-Za-z0-9_]*)? *\) *= *[^;]*\.(call|delegatecall|staticcall) *[({]/)) {
        m = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
        split(substr(m, 2, index(m, ")") - 2), part, ",")
        f = part[1]; gsub(/^ +| +$/, "", f); sub(/^bool +/, "", f)
        r = part[2]; gsub(/^ +| +$/, "", r); sub(/^bytes +memory +/, "", r)
        if (f !~ /^[A-Za-z_][A-Za-z0-9_]*$/ || !asserted_false(code, f)) continue
        if (r == "" || words(code, r) <= 1) call = 1
      }
      rest = code
      while ((p = index(rest, "catch")) > 0) {
        b = p > 1 ? substr(rest, p - 1, 1) : " "; a = substr(rest, p + 5, 1); rest = substr(rest, p + 5)
        if (isid(b) || isid(a)) continue
        s = rest; sub(/^ +/, "", s); v = ""
        if (s ~ /^[A-Za-z_]+ *\(/ || s ~ /^\(/) {
          q = index(s, "("); e = closing(s, q, "(", ")"); if (!e) continue
          params = substr(s, q + 1, e - q - 1); gsub(/^ +| +$/, "", params)
          k = split(params, tok, / +/)
          if (k >= 2 && tok[k] != "memory" && tok[k] != "calldata") v = tok[k]
          s = substr(s, e + 1); sub(/^ +/, "", s)
        }
        if (substr(s, 1, 1) != "{") continue
        e = closing(s, 1, "{", "}"); if (!e) continue
        body = substr(s, 2, e - 2)
        if (body ~ /(^|[^A-Za-z0-9_$])(fail *\(|revert[ (;])/) continue
        if (v == "" || !words(body, v) || body !~ /assert|require|==|!=/) nocmp = 1
      }
      if (bare) print "bare-expectRevert"
      if (call) print "call-asserted-false"
      if (nocmp) print "catch-not-compared"
    }' "$1"
}

# is_evm_address <string>   exactly "0x" and 40 hex digits, nothing before or after (a newline included)
is_evm_address() {
  [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]
}

# is_git_sha <string>   a full commit hash: exactly 40 lower-case hex digits (a branch, a tag or a short sha is not a pin)
is_git_sha() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

# parse_backtest_totals <report>   (K19: scripts/backtest.sh's .gauntlet/reports/07-backtest.txt)
#   the table under "== totals per run ==": its header line exactly
#     run swaps replayed refused unreplayable took0 took1 returned0 returned1 donated0 donated1 lpFees0 lpFees1 swapFeeMin swapFeeMax gasAvg gasMax booksOpen maxAbsDevPpm
#   then one row per run, up to the first empty line: a name, then 18 whole numbers. Prints the rows as they are. Every
#   number must be digits and nothing else (a "-", an empty column, "12a", a sign: refused, never added up as 0), a row
#   must have exactly 19 columns, a run must be named once, and replayed + refused + unreplayable must be the swaps.
#   Fixtures: scripts/test/fixtures/backtest-*.txt.
#   exit 1: no such table (no header line)
#   exit 2: the header is not that one, a row is malformed, a run is named twice, or no row at all - REFUSED, not read
parse_backtest_totals() {
  local want="run swaps replayed refused unreplayable took0 took1 returned0 returned1 donated0 donated1 lpFees0 lpFees1 swapFeeMin swapFeeMax gasAvg gasMax booksOpen maxAbsDevPpm"
  [ -r "$1" ] || return 1
  _parse_clean "$1" | grep -x '== totals per run ==' > /dev/null || return 1   # not -q: an early exit under pipefail
  _parse_clean "$1" | awk -v want="$want" '
    $0 == "== totals per run ==" { on = 1; next }
    on == 1 { if ($0 != want) { bad = 1; exit } on = 2; next }
    on == 2 && $0 == "" { exit }
    on == 2 {
      if (NF != 19) { bad = 1; exit }
      for (i = 2; i <= 19; i++) if ($i !~ /^[0-9]+$/) { bad = 1; exit }
      if (seen[$1]++ || $3 + $4 + $5 != $2) { bad = 1; exit }
      rows = rows $0 "\n"; n++
    }
    END { if (bad || on == 1 || n == 0) exit 2; printf "%s", rows }'
}

# kill_reasons <forge test log>
#   why each failing test failed, for scripts/mutate.sh's `kill:` lines (doctrine/EVIDENCE.md section 2: MUTATION-TESTED
#   counts a kill only when the test failed on an ASSERTION - a mutant that makes the code revert where nothing expected
#   a revert fails every test that touches it, whatever the test claims). One line per distinct failing test,
#   "<reason> TAB <test>() TAB <forge's message>", in forge's order (forge prints each failure twice: once each). Reasons:
#     setup      the test is setUp() (or forge says `setup failed`): no test ran - the mutant broke the fixture
#     revert     an UNEXPECTED revert: an unexpected-revert count (the kit's invariant_no_unexplained_reverts, a message
#                that says a failure was not predicted), a handler call that reverted in an invariant run (`reverts: N`
#                above 0 on its line, fail_on_revert), `EvmError: ...`, a panic that is not an assertion's (arithmetic,
#                division), a custom error (`CurrencyNotSettled()`), `custom error 0x...`; a require's string that holds
#                a comparison of words (`fee > cap`, `f == 0`, `2 * fee > cap`: an operand is not a value); and any
#                message this does not recognise as an assertion's, in a test that is not an invariant - a require's
#                string and an assertTrue's own message print the same, and an unknown is counted as a revert
#     assertion  an assert failed: `assertion failed` (forge-std's, and `panic: assertion failed (0x01)`), a comparison
#                whose two operands END the message and are both VALUES, as forge prints them for assertEq, assertLt,
#                assertNotEq, assertApproxEq... with a message of their own (`msg: <a> != <b>`, `msg: <a> !~= <b> (max
#                delta: ..., real delta: ...)`): a value is a number (`-5`, `1.500000`), `0x` and hex (an address, a
#                bytes32, bytes), `true`/`false`, or a list of those (`[1, 2]`) - a string compared with a message
#                prints words and reads as a revert (conservative); a require whose own string ends in two values
#                (`"0 != 1"`) is read as an assertion: the line shows the message, read it; an expected revert that did
#                not come (`next call did not revert as expected`) or came with another error (`Error != expected
#                error: ...`) - the test's oracle WAS the revert, and it broke -, and an invariant whose run met no
#                revert (its own check failed)
#   Fixtures: scripts/test/fixtures/kill-real-{assertion,assert-msg,revert,require-op,setup}.txt (forge 1.8.1).
#   exit 1: no failing test read.
kill_reasons() {
  [ -r "$1" ] || return 1
  _parse_clean "$1" | LC_ALL=C awk '
    BEGIN {   # a value as forge prints an assertion operand; a comparison of two of them, at the end of the message
      sc = "(-?[0-9]+([.][0-9]+)?|0x[0-9a-fA-F]*|true|false)"; val = "(" sc "|[[](" sc "(, " sc ")*)?[]])"
      cmp = val " (!=|==|<=|>=|<|>|!~=) " val "$" }
    function valcmp(m) {
      sub(/ [(]max delta: [^()]*, real delta: [^()]*[)]$/, "", m)
      return (m ~ ("^" cmp) || m ~ (": " cmp))
    }
    function classify(name, msg, inv, reverts,   m) {
      m = msg; sub(/; counterexample:.*$/, "", m)
      if (name == "setUp()" || m ~ /^setup failed/) return "setup"
      if (tolower(m) ~ /did not predict|nothing predicted|unexpected revert|unexplained revert/ || name ~ /unexplained_revert|unexpected_revert/) return "revert"
      if (inv && reverts > 0) return "revert"
      if (m ~ /assertion failed/) return "assertion"
      if (m ~ /did not revert as expected/ || m ~ /^Error != expected error/ || m ~ /expected (revert|emit|call)/) return "assertion"
      if (m ~ /^EvmError/ || m ~ /^panic: / || m ~ /^custom error / || m ~ /^[A-Za-z_$][A-Za-z0-9_$]*\(.*\)$/) return "revert"
      if (valcmp(m)) return "assertion"
      if (inv) return "assertion"
      return "revert"
    }
    function emit(name, msg, inv, reverts,   k) {
      k = name SUBSEP msg; if (k in seen) return; seen[k] = 1
      gsub(/\t/, " ", msg); print classify(name, msg, inv, reverts) "\t" name "\t" msg; n++
    }
    # an invariant failure: [FAIL: <msg>] alone, its sequence, then " <name>() (runs: N, calls: N, reverts: N)"
    wait && /^[ \t]*[A-Za-z_$][A-Za-z0-9_$]*\([^)]*\)[ \t]+\(runs:/ {
      nm = $0; sub(/^[ \t]*/, "", nm); sub(/[ \t]+\(runs:.*$/, "", nm)
      rv = 0; if (match($0, /reverts: [0-9]+/)) rv = substr($0, RSTART + 9, RLENGTH - 9) + 0
      emit(nm, wmsg, 1, rv); wait = 0; next }
    /^\[FAIL/ {
      line = $0
      if (match(line, /\] [A-Za-z_$][A-Za-z0-9_$]*\([^)]*\)[ \t]+\(.*\)[ \t]*$/)) {
        nm = substr(line, RSTART + 2); sub(/[ \t]+\(.*$/, "", nm)
        msg = substr(line, 1, RSTART); sub(/^\[FAIL(: )?/, "", msg); sub(/\]$/, "", msg)
        emit(nm, msg, (nm ~ /^invariant/), 0); wait = 0; next }
      msg = line; sub(/^\[FAIL(: )?/, "", msg); sub(/\][ \t]*$/, "", msg); wmsg = msg; wait = 1; next }
    END { if (!n) exit 1 }'
}
