#!/usr/bin/env bash
#
# next.sh - read STATE.md's flag block and name the row of doctrine/NEXT.md that comes next.
#
# The problem it solves: NEXT.md calls its table computable, and every agent walked its rows by hand. A mistyped enum
# (`battery: gren`) went unnoticed and was read as whatever the reader guessed; a flag left out was read as its default;
# and a gap in the table was only ever found by a reviewer. So the flags are parsed here, each one checked, and a block
# that is not of NEXT.md's shape is REFUSED before any row is read. Then the rows are evaluated top to bottom.
#
# What the flags cannot decide is not guessed. A row whose condition needs something STATE.md does not carry (a fuzzer's
# report, what the owner wants, whether the spec's promises changed) is printed as "needs judgement: row <id> - <the
# question>", and the evaluation goes on to the first row the flags alone make true, printed as the answer ONLY IF every
# row needing judgement above it is false (exit 3). The agent answers with --judge, and the answers are echoed in the
# output, so the judgement is on the record, not in anyone's head. Rows that need judgement: 1 (a high open that the
# flags do not show recorded to tell), 5, 8, 9 and 9b (a finding open, once round 1 has run or the ceiling is reached; 9b
# only while the dossier does not name them yet), 10 (after a round, with no bytecode change since), 11b, 12, 16, 18b.
# Not row 3: the flags decide it (below).
#
# The rows are DATA (the ROWS table below): a new row of NEXT.md is one line here, not new parser code. The action a row
# prints is read from NEXT.md itself, as NEXT.md words it. And every run checks the two against each other (the drift
# guard): the same rows - every row under NEXT.md's "## The table", whatever the form of its id (12, 12b, 12a) - in the
# same order, and each row's condition cell the text its entry here was written from (the entry keeps a hash of the
# cell, whitespace normalised; --check-table prints the new one). A row added to NEXT.md with no line here, the reverse,
# another order, or a condition reworded without its entry being re-read, is a refusal naming the row. And inside the
# table every non-blank line must be a row ("|" at column 0, four cells): an indented row, a row without its leading "|"
# (Markdown shows both in the table) or a line of prose there is a refusal naming the line - no row can hide.
#
# NEXT.md says, and this script does:
#   - rows 2 and 14 are GATES, not stops. A gate that is true is printed "in force", the rows it names are off wherever
#     they stand, and the reading goes on: row 2 (the ceiling is reached) turns off every model row - 11, 11b (a retry
#     is a model round), 12, 13, 13b, 15; row 14 (the loop is over) turns off 11, 12, 13, 13b - not 11b: a stopped
#     round, the closing black-box included, still gets its one retry - and the next row that can apply is 15;
#   - at the ceiling the black-box is a model round like any other, so it does not run: with row 2 in force, rows 16 and
#     18b also take `blackbox: never_run` or `stale` (the dossier then says "black-box: not run - ceiling reached");
#   - rehearsal (row 17) is the `rehearsal:` flag: promoted and `not yet` is 17; promoted and `n/a` or `done` is 18;
#   - row 7b is off while `waiting_on_owner` asks the owner for the endpoint or the chain: an item that contains `RPC_URL`,
#     or that IS the chain question (`chain`, or starting with the WORD `chain`, `target chain` or `which chain`, any case;
#     `chain-id`, `chain_id`, `chains` are other words) - `off-chain`, `cross-chain` or the word inside another question
#     do not count: its action waits on the owner, so row 3 skips it;
#   - rows 12 and 16 are off while 7b is owed (`real_manager_battery` `never` or `stale` - the chain is known - and no
#     `real manager:` note); when 7b is silenced by the wait and no other row stands, that is row 3's pause, as NEXT.md's
#     row 3 says: it stops and says what is waiting (no answer makes the rows the wait turned off stand: row 3 is not
#     answered);
#   - rows 9 and 9b count every open finding, from any round - a phase-3 `pending:` one too, once round 1 has run; before
#     round 1 (`last_audit_round: none`) they are off, pending findings ride into round 1 - unless the ceiling is reached
#     (row 2: round 1 will not run, every open finding goes to 9 or 9b);
#   - `blackbox: stopped (<round id>)` (a black-box round stopped twice, row 11b): rows 12 and 15 do not fire on it, rows
#     16 and 18b take it;
#   - row 1 goes quiet only by the flags' record of the owner absent, BY ID (K28): open_findings names the open highs,
#     `high=N (<ids>)` - the parentheses exactly when N > 0, one id per high, each once (case aside), ids between commas
#     or spaces; a count without its ids, ids with N = 0, a count that is not the number of ids, a placeholder (none,
#     TBD, nobody, n/a, ?), a word between the ids, or a word that is not an id - an id has a letter and a digit (F-1,
#     r01-A1; `all`, `TBA`, `pending`, `1`, `None.` are not: V28, the same non-id on both sides quieted the row) - is
#     refused. The row is quiet when EVERY one of those ids is among the ids of the items `high <id>[, <id>...] - to
#     tell` of waiting_on_owner (compared case-insensitively, the same rules for the ids there); an id recorded there
#     that is not an open high is refused (a recorded high is no longer open: remove it - V26b: `high all`, `high 1`, a
#     medium's id, one high spelled twice quieted the row by their number alone). Then the row is false, and the
#     because: line of whatever is given names those ids - a quiet row 1 always leaves a trace. Otherwise, with a high
#     open, it is a question naming the highs not recorded (the owner present: answered 1=false once told). v0.5.1: the
#     owner present, a note `told: <YYYY-MM-DD> <id>[, <id>...]` (a real date first, then the ids) records the highs told,
#     by id, and quiets the row for them like the to-tell items do for the owner absent - an id there that is not an
#     open high is refused, a told: note with no date first is not read. A provisional high from phase 3 counts in
#     open_findings high like any other (NEXT.md row 6b);
#   - row 9b is quiet once the dossier names the open findings: `dossier: skeleton (<K> open, ...)` with K the number
#     open (high + medium + low; informational findings are not counted) decides it false by the flags, unasked; `none`,
#     or a skeleton naming another number (stale), keeps it standing, and the owner's presence is what is asked.
#     `dossier: complete` with a finding open is refused: a dossier with an open finding is a skeleton (K28, NEXT.md's
#     `dossier:` flag);
#   - row 3 ends the route with the owner absent: when waiting_on_owner is not `none` and no row below stands on the flags
#     and none is left to judge, the answer is `next: STOP - paused, waiting on the owner: <items>` (exit 0) - decided
#     by the flags, never asked, and never answered: `--judge 3=...` is REFUSED (V26b: `3=true` gave that STOP over row
#     6 and row 9b, which the flags made true - the answer to row 3 could hide the rows below; an answer refused hides
#     nothing, where one ignored would still stand on the record as judged). A row below that waits on the owner's
#     answer is skipped the way the table skips it: a row that needs judgement is answered false, row 7b is off by the
#     flags. While rows still need judgement (above or below row 3), the pause is not given: exit 3, the questions, and
#     one line, `if every answer is false: STOP - paused, waiting on the owner: <items>`;
#   - a note is read by its name only at the START of a note item (a note line, or a part of one after the middle dot
#     or ";", a Markdown list marker `- ` / `* ` / `+ ` before it allowed): `real manager:` for row 7b;
#   - the ceiling the OPERATOR set in full mode with the owner absent (`<N> model rounds, set by the operator (owner
#     absent); <M> used`) is a ceiling like the owner's: row 2 fires on it; "operator" in any other shape or case is refused;
#   - rows 13b and 14 count a finding against "closed with 0 high and 0 medium" only while it is OPEN in `open_findings`
#     (one accepted by the owner, refused in writing or handed to the human audit by name does not): the terms are
#     `open_findings.high=0 open_findings.medium=0`, not the round's own counts;
#   - row 18b is either mode: the owner declined promotion in writing (light mode by default) - a judgement;
#   - row 10 does not count the route's whole workspace (everything under .gauntlet/ - STATE.md, DECISIONS.md, LOG.md,
#     SPEC.md, the dossier, briefs/, reports/, rounds/, bench/, backtests/, ... - or those same files at the root with
#     location: root; an owner's own SPEC.md, README or NatSpec outside it still counts): its question says so - a
#     walker of the route found the row true at the letter over the skeleton it had just written, and answered it false
#     to reach the pause (K31); the benches and the tests written in them were still outside the words (V31, K31b).
# And two checks before any row (K31, K31b), neither of them a flag of STATE.md:
#   - the kit is proven on this machine: scripts/selftest.sh, ending PASSED, leaves <kit>/.gauntlet/selftest-passed with
#     the SHA-256 of the kit's scripts, a hash of the machine's identity and forge's version (scripts/lib/kit-proof.sh).
#     Absent, with one of the three missing, or written for other scripts, on another machine or with another forge,
#     this prints ONE line, `next: FIRST - prove the kit on this machine: <kit>/scripts/selftest.sh - it takes about <N>
#     minutes; give it a tool timeout above that or run it in the background (then run next.sh again) - <which>` (the
#     scripts / the machine / forge; <N> is SELFTEST_MINUTES below, measured - v0.4.1, D3), and exits 0 - nothing else, no
#     row (but the MANIFEST note, below). --check-table does not look;
#   - a test in pending/ that STATE.md does not name is refused: the project is the STATE.md's directory (its parent
#     when that directory is .gauntlet/), and each .sol file below its pending/ (subdirectories and hidden files too:
#     row 6b's profile compiles and runs them all) needs a note `pending: <id> ...`, the id its name without .t.sol or
#     .sol, and each id of such a note (`pending: F-4, F-5 - ...` names two) its file (NEXT.md row 6b); no pending/,
#     nothing is checked.
# And three more before any row (K40, K41), for what a walker of the route wrote that nothing read (the local-model walk, judged 2026-09-30):
#   - STATE.md still the kit's example is refused before it is parsed (exit 2, no escape: an example is never a state):
#     `next: REFUSED - FIRST - fill STATE.md: it is still the kit's example (state/README.md, "empty the examples")`. The example
#     is known by its marker line, `*Example file. The project is fictional. Delete this and start yours.*` (anywhere
#     in STATE.md; in DECISIONS.md and LOG.md only as a whole line - a log that quotes it is not the example, K48), or
#     by the example hook's name, BlockCapHook, in the title (the first `# ` line). The same for the DECISIONS.md and
#     LOG.md beside it. And STATE.md by its values (K48): a flag block that shares three or more lines with the kit's
#     own state/STATE.md's, whatever the spacing (K49: each line trimmed and its runs of spaces and tabs made one, on
#     both sides) - counting only the non-generic flags (last_audit_round, last_other_round, open_findings, ceiling,
#     waiting_on_owner, notes, bytecode_changed_since, threat_model) - is the example with its marker deleted and its
#     title changed:
#     `next: REFUSED - FIRST - fill STATE.md: its values are still the kit's example's (<the first shared line, as the example
#     has it>)`. (the local-model walk: STATE.md stayed the example for 2 h 20 min, and next.sh answered "row 13 - a
#     REGRESSION round" on it, twice);
#   - each .sol file below pending/ needs its record of being seen RED on src/ as it stands, written by
#     scripts/pending-red.sh (scripts/lib/pending-record.sh: keyed by the SHA-256 of the file list and contents of src/,
#     test/, pending/, foundry.toml and remappings.txt - edit any and the record is not the current one; a record whose
#     failure is the v4 harness's permission-bits line stays current while src/ and that file are as recorded, v0.4.2):
#     without it `next: REFUSED - pending/<file> - not seen red on the code as it stands: <kit>/scripts/pending-red.sh <proj>
#     pending/<file>` (exit 2), and with a record made on another key the same line says, in brackets before the
#     command, which part of the key changed since (`its red record of <date> is stale - test/ changed since`). The record is read: its first line `pending-red: red <file> key=<key> <date>`, for that file and the
#     key in its name, else `next: REFUSED - pending/<file>: record unreadable - run scripts/pending-red.sh again` (exit 2). A
#     directory below pending/ named *.sol is refused (it is not a test file). Escape: PENDING_RED=0, said on stderr -
#     never printed in a refusal (v0.4.2) - and, when it lets a test through, written down (below, "a used escape");
#   - a file STATE.md or DECISIONS.md cites under the project - a path starting `pending/`, `test/`, `src/` or
#     `.gauntlet/reports/` (or the same after `./`) whose last part has an extension - must be a non-empty regular file
#     (not LOG.md's: a LOG is history, and a file it names may be gone since, legitimately - K47):
#     `next: REFUSED - <file> cites a file that does not exist: <path>`, `... that is empty: <path>`, `... that is a directory:
#     <path>` (exit 2). Not a citation: a path inside a fenced code
#     block (the flag block's `pending:` notes excepted: they are read), one after `to write`, `planned` or `TODO` on
#     the same line, one followed by `*`, `?`, `<`, `{` or `[` (a pattern or a placeholder), one with `..` (a range),
#     one inside a longer path (`lib/forge-std/src/Test.sol`); one found in a bench (.gauntlet/bench/<name>/) exists.
#     Escape: CITED_FILES=0, said on stderr - never printed in a refusal (v0.4.2) - and written down when it lets a
#     citation through (below).
#   - a used escape (v0.4.2): PENDING_RED=0 or CITED_FILES=0 that let through what the check would have refused appends
#     one line to the LOG.md beside STATE.md, its own paragraph - `<date> next.sh ran with PENDING_RED=0, an escape: it
#     let through <the files, and why each> - not checked here (the owner reads this line, and the dossier carries it)`
#     (CITED_FILES=0 likewise, naming each citation) - and says so on stderr. Set, and nothing to let through: the
#     stderr line alone. (A walker read an escape in a refusal and used it; one used leaves only stderr behind.)
# And, v0.4.1 (what the hosted and local walks of 2026-09-30/10-01 showed):
#   - the spec is the owner's: with <proj>/.gauntlet/spec.sha256 (`<sha256>  <the spec's path relative to the project>`,
#     written by scripts/init-state.sh), a spec whose hash differs is refused, `next: REFUSED - <spec> changed since
#     init-state recorded it: the spec is the owner's. Undo the change (put the owner's text back) and write what you
#     assumed in DECISIONS.md (source: assumed, owner absent); the route's own spec - phase 1's rows - is
#     <proj>/.gauntlet/SPEC.md, never the owner's file (AGENTS.md section 4). The owner, present, re-records a change of
#     their own with scripts/init-state.sh, signed; an agent never does it.` - and a spec that is gone, the same with
#     `is missing`. No record: nothing said here - from phase 2 a missing record is refused (v0.5.3, below). No escape, and the refusal never prints a command an agent could run.
#     When spec.sha256 carries a `re-recorded` line (init-state --spec --by), every answer but the FIRST carries one note
#     under it, `next: note - the spec <spec> was re-recorded [(<N> re-records; the last:)] on <date>, signed --by
#     "<name>" (<old8> -> <new8>; .gauntlet/spec.sha256): the owner confirms that signature is theirs, or the spec in
#     force is not the owner's` - as the MANIFEST note is printed, never a refusal. Checked before the example (below);
#   - the K40 refusal of an example STATE.md names the command that writes an empty one: `... ("empty the examples") -
#     <kit>/scripts/init-state.sh <proj> writes an empty one`;
#   - `key:value` with no space after the first colon is `key: value` in the comparison with the example's values;
#   - the phase against its records, once the flags are read: `phase:` 2 or higher with no green build record
#     (<proj>/.gauntlet/reports/01-build.txt, forge's success line in it), and `phase:` 3 or higher with `battery: never`,
#     are refused, naming scripts/battery.sh (the first also scripts/setup-deps.sh before it: both may run at phase 1).
#     No escape;
#   - and the flags against their records (v0.4.2: a judge walked phase 2 -> 3 -> 4 by hand edits, `battery: green` typed
#     over a battery that had FAILED, and phase 4 with no invariant suite, no census and no fork note were answered with
#     a row): `battery: green` with the battery's test record, <proj>/.gauntlet/reports/02-test.txt, absent or not green
#     (forge's summary line read by scripts/lib/parse.sh: no test failed, at least one passed) is refused, naming
#     scripts/battery.sh; `phase:` 3 or higher with a 02-test.txt that shows no test ran (absent, or no summary - the
#     battery FAILED before its tests: its green 01-build.txt is not a battery that ran) likewise; `phase:` 4 or higher
#     (phase 3 closed) with no invariant suite under test/ (no .sol file there with a `function invariant...(`), with no
#     census report (.gauntlet/reports/06-census.txt or 06-census-gate.txt, one that is not a FAILED campaign's) or with
#     no `fork:` note (read at the start of a note item, as `real manager:` is) is refused, each naming its command:
#     the suite (QUICKSTART.md 7b, then scripts/battery.sh), scripts/census.sh, the note itself. No escape;
#   - v0.5, the independent threat model (NEXT.md row 4b, briefs/threat-model.md): `threat_model:` is `not yet` or
#     `diffed (<n> matched, <m> new, <k> refused, <h> handed)`, the line scripts/threat-diff.sh prints. `phase:` 4 or higher with
#     `not yet` is refused, naming the brief and the script; a `diffed (...)` at any phase is read against the files the
#     way that script reads them (scripts/lib/threats.sh: .gauntlet/THREATS-independent.md, .gauntlet/THREATS.md, the
#     refusals in the DECISIONS.md beside STATE.md, the /// @custom:threat tags under test/ and pending/) - a list
#     missing or not of its form, an independent threat neither matched, an invariant nor refused (each named), or other
#     counts than the line's, is refused; and so is a `diffed` line with no report of the diff
#     (.gauntlet/reports/06-threats.txt), a report that does not give that line, or two lists that are no longer the
#     files the report hashed (the lists are frozen after the diff: threat-diff.sh is run again). A STATE.md with no
#     `threat_model:` line (written before v0.5) is refused naming the line to add, `threat_model: not yet`. No escape;
#   - v0.5.1: the line is `diffed (<n> matched, <m> new, <k> refused, <h> handed)` - an independent threat the owner
#     leaves undecided is handed on by name in THREATS.md (`T-<n>: handed: round | audit`), and phase 3 closes with it.
#     Once a round has run (last_audit_round not none), `phase:` 4 or higher with a `handed: round` that has no
#     `became: <finding id>` under it is refused, naming each and its two answers - the finding, or `handed: audit` -
#     never the phase. And the rows that write the dossier (9b, 18, 18b) add one note after the answer: the environment
#     divergences the owner stated in the DECISIONS.md beside STATE.md (`## <id> · <YYYY-MM-DD> · divergence: <what>`),
#     or `none stated` - the dossier's section 8 row - and one more naming a heading that says divergence in another shape;
#   - v0.5.3, silence is a refusal - a missing record is never a pass:
#     - the anchors: from phase 2 (`phase:` 2 or higher - doctrine/NEXT.md row 4b, the first row by which init-state.sh
#       must have run on a hook that compiles, its spec's phase closed; before it a hook still to be written or a spec not
#       found leave init-state.sh nothing to record), a missing .gauntlet/spec.sha256 or .gauntlet/src.sha256 is refused,
#       `next: REFUSED - anchor record missing: <proj>/.gauntlet/<spec|src>.sha256; re-run scripts/init-state.sh <proj>
#       --spec <the spec>|--src --by <owner> - ...` (the owner's act, signed). A line 1 rewritten by hand with no
#       `re-recorded` line is not caught by any hash (every anchor is recomputable from public inputs): procedure, not code;
#     - the reports a check below reads (.gauntlet/reports/01-build.txt, 02-test.txt, 06-census.txt, 06-census-gate.txt,
#       06-threats.txt) are records only with their seal, `<report>.sha256` beside each, written by the script that writes
#       the report (scripts/lib/src-anchor.sh, report_check): no seal, a seal that does not match the report, or one made
#       on another src/ than the one there is now (the anchor of src/ as it stands) - the check reads the report as
#       missing, and its refusal says why in its parentheses: `report <name>: no anchor ...`, `... mismatch ...`, `...
#       stale ...`. A file cited under .gauntlet/reports/ that has a seal is held to it (`cites a file that is not a
#       record`), never for currency: a cited report is history;
#     - four flags against the round records - the ROUND lines of the LOG.md beside STATE.md, read by scripts/round.sh
#       --json: `last_audit_round` is the id of the newest discovery or regression ROUND line (none: no such line) - one
#       the environment stopped, named by row 11b's note `round <id> stopped`, delivered nothing and is passed over;
#       `ceiling ...; <M> used` has M the number of discovery, regression and black-box ROUND lines (every model round,
#       NEXT.md); `blackbox` never_run with no black-box ROUND line (skipped_by_owner is not checked - left for later), current or stale with one,
#       `stopped (<id>)` with a black-box ROUND line of that id; and `bytecode_changed_since` last_audit_round=no with the
#       anchor of src/ as it stands the one scripts/round.sh wrote under that round's line (`src/ at round <id>: <hex>`)
#       - a round recorded before v0.5.3 has no such line, and the flag is taken as written with one note after the
#       answer, never refused for it. A flag that disagrees: `next: REFUSED - STATE says <flag>: <value>; the record says
#       <value> (...)` - for last_audit_round naming the audit rounds after it that no `round <id> stopped` note names
#       (row 11b: each stopped attempt is a ROUND line of its own, and needs its own note). A ROUND line round.sh cannot
#       read back is refused, naming it (`next: REFUSED - <LOG.md> line <n> is not a ROUND line of the fixed shape ...`).
#       The anchors, the owner absent: `init-state.sh <proj> --spec|--src --by walker`, accepted only with a note
#       `owner absent: <why>` in STATE.md (init-state.sh's header); the record says `by: walker (owner absent)`, and the
#       rows that write the dossier (9b, 18, 18b) add a note naming it - a divergence of the dossier's section 8;
#     - every line next.sh prints with exit 2 starts `next: REFUSED - ` (the example's `FIRST - fill`, a pending/ test's,
#       a cited file's included), on stderr as before;
#   - after the answer, whatever it is, `next: note - the kit has N files not in its MANIFEST (<first three>): ...` on
#     stdout when the kit's root has a MANIFEST and files under the kit are not in it - deps, builds, .git and what the
#     kit's own runs write (corpus/, census/, broadcast/, .gauntlet/) aside, by the rule scripts/gen-manifest.sh and
#     scripts/doctor.sh use too (below, THE EXCLUSIONS, kit_files and manifest_note). Not a refusal: the exit code is
#     unchanged.
# Readings of NEXT.md this script makes, each from NEXT.md's own words: `phase` advances only when a phase's gate is met,
# so rows 4 and 4b are `phase` 0-1 and 2-3; "promoted" is `last_promotion=no` (`yes` = changed since, no longer promoted;
# `n/a` = never promoted); "the loop is over" (rows 15-18b) is row 14's condition; a finding from outside the fuzzer
# (row 8) comes from a round, so row 8 is false before any round has run.
#
# Usage:   scripts/next.sh [STATE.md | <proj>] [--judge <row>=true|false[,<row>=true|false...]]... [--table <NEXT.md>]
#          scripts/next.sh --check-table [<NEXT.md>]     the drift guard alone
#   STATE.md defaults to .gauntlet/STATE.md, then ./STATE.md; a project's directory <proj> reads <proj>/.gauntlet/STATE.md,
#   then <proj>/STATE.md - neither, `next: REFUSED - <proj> has no .gauntlet/STATE.md and no STATE.md:
#   <kit>/scripts/init-state.sh <proj> writes one (or give the STATE.md)`. --table defaults to the kit's doctrine/NEXT.md.
#   Before any row: the kit's selftest marker (above); without it, or not for these scripts, this machine and this
#   forge, the one line `next: FIRST - ...` (above: it says what the selftest costs) and exit 0.
#   --judge answers a row that needs judgement: `true` makes it true (it is then given, if it is the first), `false`
#   passes it. Row 3 (waiting on the owner) is not one: `--judge 3=...` is refused - answer `false` each row below that
#   depends on the owner's answer; when nothing below stands and nothing is left to judge, the pause is given.
# Output:  zero or more "in force: row <2|14> - ..." and "needs judgement: row <id> - <question>" lines,
#          then "next: row <id> - <the action, as NEXT.md words it>" and "because: <the flags that made it true>" -
#          or, the owner absent, nothing below row 3 standing and nothing left to judge, "next: STOP - paused, waiting on
#          the owner: <items>" (STOP, not "row": a caller that walks the rows stops here, and runs this again when the
#          owner has answered) - or, with rows still to judge and nothing below standing on the flags, the questions and
#          "if every answer is false: STOP - paused, waiting on the owner: <items>" (exit 3: answer them, run it again).
# Env:     NEXT_SELFTEST=1  the selftest's own cases: the marker is not checked, and the first line on stderr says so
#          every time it is set (a user never sets it; any other value is refused)
#          PENDING_RED=0  the tests in pending/ are not checked for their red record; said on stderr every time (any
#          other value is refused), and a line in the LOG.md beside STATE.md when it lets one through (above)
#          CITED_FILES=0  the files STATE.md and DECISIONS.md cite are not checked (LOG.md never is); said on stderr
#          every time (any other value is refused), and a line in that LOG.md when it lets one through
# Exit:    0 the row given is the first true one, or the pause, or FIRST (the kit not proven here); 1 no row is true and
#          nothing waits on the owner: the table has a hole or a flag is stale (NEXT.md's STOP rule); 2 REFUSED - a flag
#          missing, of an unknown value, a malformed line, a bad --judge, a pending/ test and the notes disagreeing, or the
#          table and NEXT.md disagree, the spec changed or gone since init-state recorded it, a phase or a battery flag its
#          records do not bear out, an anchor record missing from phase 2, a round flag its ROUND lines do not bear out: one
#          line on stderr naming what - and, one line on stderr too, a state file that is still the kit's example (next:
#          REFUSED - FIRST - fill ...), a pending/ test with no current, readable red record, a cited file that is not a
#          non-empty regular file (or not the report its seal sealed): every exit-2 line starts `next: REFUSED - `;
#          3 a row above the one given needs judgement
#          (named), or rows still need judgement before the pause can be given.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TABLE="$HERE/../doctrine/NEXT.md"

refuse() { echo "next: REFUSED - $*" >&2; exit 2; }

KIT="$(cd "$HERE/.." && pwd)"
# what the selftest costs, said in the FIRST line (v0.4.1, D3: a walker gave it a 300 s tool timeout, twice, and it was
# cut short at ~320 s). Measured 2026-10-01: the full scripts/selftest.sh, PASSED (1408 cases, forge 1.8.1, Linux under
# WSL2), 331 to 359 s in three runs; again at 1477 cases, 336 s alone and 339-348 s under load (another selftest
# running beside it) - 6 minutes left 3-7 % of margin, so 7. Measure it again when the selftest grows.
# Measured again 2026-10-05 at 1636 cases (v0.4.2): 371-402 s alone, 386 s with the configuration variables exported,
# 423-457 s two at once - above 7 minutes, so 8.
SELFTEST_MINUTES=8
# the selftest's own cases run without the marker - said on one line every time, never silently (K31)
case "${NEXT_SELFTEST-}" in
  "") ;;
  1) echo "next: NEXT_SELFTEST=1 - the kit's selftest marker is NOT checked (the selftest's own cases set this; a user never does)" >&2 ;;
  *) refuse "NEXT_SELFTEST='${NEXT_SELFTEST}' is not 1: it is set by the kit's selftest for its own cases only - unset it." ;;
esac
# the two escapes of K41's checks - each said on stderr every time it is set, never silently
case "${PENDING_RED-}" in
  "") ;;
  0) echo "next: PENDING_RED=0 - the tests in pending/ are NOT checked for a record of being seen red on the code as it stands (scripts/pending-red.sh)" >&2 ;;
  *) refuse "PENDING_RED='${PENDING_RED}' is not 0: it turns off the pending/ red-record check (0), or it is unset." ;;
esac
case "${CITED_FILES-}" in
  "") ;;
  0) echo "next: CITED_FILES=0 - the files STATE.md and DECISIONS.md cite are NOT checked to exist" >&2 ;;
  *) refuse "CITED_FILES='${CITED_FILES}' is not 0: it turns off the cited-file check (0), or it is unset." ;;
esac

# ------------------------------------------------------------------------------------------------ the rows, as data
# id | NEXT.md hash | kind | turns off | condition | the question, when the flags cannot decide the row ("-": they can)
#   NEXT.md hash: of the row's condition cell in NEXT.md (whitespace normalised; cksum's CRC, 8 hex digits) as it read
#   when this entry was written. When the cell changes, the drift guard refuses and --check-table prints the new hash:
#   re-read the row, make the entry say what it now says, then paste the hash - never the hash alone.
#   kind: act (a destination) | gate (rows 2 and 14: when its condition is true it is printed "in force", the rows in
#   "turns off" are false wherever they stand - above it or below - and the reading goes on). A gate needs no judgement.
#   condition: groups separated by " ; " (any group true), terms in a group separated by spaces (all true). A term is
#   <name>=<v>[,<v>...] (one of) | <name>!=<v> | <name>><n> (a number above n) | row:<id> (that row's condition) | -
#   (always). Names: the flags of STATE.md, and the parts parse_state below derives from them.
ROWS='
0   | 58249b92 | act  | -                   | phase=sketch | -
1   | 89ce9899 | act  | -                   | open_findings.high_not_recorded>0 | does a high finding reproduce (open_findings high: {highs_not_recorded} not recorded to tell) that the owner has not been told of? The owner present: tell them, then write the note told: <YYYY-MM-DD> <id>[, <id>...] in notes: and the flags quiet this row (a told: note in another shape is not read; answered false once told, it stays on the record only here); absent: record every open high in waiting_on_owner as high <id>[, <id>...] - to tell, and the flags quiet this row
2   | 64c00456 | gate | 11,11b,12,13,13b,15 | ceiling=reached | -
3   | 8949c656 | act  | -                   | waiting_on_owner!=none | -
4   | 46e1bfdb | act  | -                   | phase=0,1 | -
4b  | 11eb8fb8 | act  | -                   | phase=2,3 | -
5   | 2a2d739a | act  | -                   | - | has the fuzzer reported a violation of a promise that is not yet a deterministic test?
6   | e0949a62 | act  | -                   | bytecode_changed_since.last_battery=yes ; battery=never | -
6b  | 021321a6 | act  | -                   | battery=red | -
7   | 72863a27 | act  | -                   | bytecode_changed_since.last_long_fuzz=yes battery=green ; bytecode_changed_since.last_other_free_judges=yes battery=green | -
7b  | 4135edaa | act  | -                   | real_manager.owed=yes waiting_on_owner.real_manager=no | -
8   | c328f377 | act  | -                   | any_round=yes | is there an ACCEPTED or FIXED finding (triaged in row 9) from outside the fuzzer with no rule for it yet (an invariant or action, or a unit test and a not fuzzable: note)?
9   | 6d5b5f55 | act  | -                   | last_audit_round!=none open_findings.total>0 ; ceiling=reached open_findings.total>0 | is a finding from any round still open (not fixed, refused in writing, accepted by the owner with a number, or handed to the human audit by name - one triaged fix at the cause whose fix is not written yet is still open; a phase-3 pending: finding is one too, now that round 1 has run or the ceiling is reached), and is the owner there to answer, or is it already triaged fix at the cause?
9b  | 3fac6ddc | act  | -                   | last_audit_round!=none open_findings.total>0 dossier.lists_open=no ; ceiling=reached open_findings.total>0 dossier.lists_open=no | open findings from any round (a phase-3 pending: finding too, now that round 1 has run or the ceiling is reached) wait on the owner'"'"'s triage, and the dossier does not name them yet ({dossier_names}): is the owner unavailable to triage them now (an exercise, or away)?
10  | 335ae40f | act  | -                   | any_round=yes bytecode_changed_since.last_audit_round=no | did only documents, comments, scripts or tests change since the last round, making claims about the code? The route'"'"'s whole workspace does not count - everything under .gauntlet/ (STATE.md, DECISIONS.md, LOG.md, the route'"'"'s SPEC.md, the dossier, STATIC-TRIAGE.md, briefs/, reports/, rounds/, the benches in bench/ and the tests written in them, backtests/, the triage notes), or with location: root those same files and directories at the root; an owner'"'"'s own SPEC.md, README or NatSpec outside that workspace still counts. A skeleton written since the last round does not make this row true
11b | 39b95289 | act  | -                   | - | was a model round STOPPED by the environment (the harness, the provider'"'"'s classifier) before delivering, and not yet retried - or stopped again, and not yet recorded (notes: round <id> stopped; a black-box round also blackbox: stopped (<id>))?
11  | 29326122 | act  | -                   | last_audit_round=none battery=green | -
12  | 9f085660 | act  | -                   | last_audit_round!=none battery=green blackbox=never_run real_manager.owed=no | did the spec'"'"'s promises stay unchanged in the last triage (no triage yet counts as unchanged)?
13  | 78bc1c8a | act  | -                   | last_audit_round!=none bytecode_changed_since.last_audit_round=yes battery=green | -
13b | 4e8baa1f | act  | -                   | last_audit_round.type=regression open_findings.high=0 open_findings.medium=0 ; last_audit_round!=none open_findings.reasoned_high_or_medium>0 | -
14  | 89e14495 | gate | 11,12,13,13b        | last_audit_round.type=discovery open_findings.high=0 open_findings.medium=0 open_findings.reasoned_high_or_medium=0 bytecode_changed_since.last_audit_round=no ; ceiling=reached open_findings.total=0 | -
15  | d7de1684 | act  | -                   | row:14 blackbox=stale,never_run | -
16  | f4763e2e | act  | -                   | row:14 blackbox=current,skipped_by_owner,stopped bytecode_changed_since.last_promotion=n/a,yes real_manager.owed=no ; row:2 row:14 blackbox=never_run,stale bytecode_changed_since.last_promotion=n/a,yes real_manager.owed=no | does the owner want to freeze a release candidate?
17  | 496e473f | act  | -                   | bytecode_changed_since.last_promotion=no rehearsal=not_yet | -
18  | da261889 | act  | -                   | bytecode_changed_since.last_promotion=no rehearsal=n/a,done | -
18b | 41757769 | act  | -                   | row:14 blackbox=current,skipped_by_owner,stopped ; row:2 row:14 blackbox=never_run,stale | did the owner decline promotion in writing (light mode by default, COST.md; full mode by the owner'"'"'s own written decision)?
'

declare -a IDS=()
declare -A HASH=() KIND=() OFFS=() COND=() ASK=()
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
while IFS='|' read -r c_id c_hash c_kind c_off c_cond c_ask; do
  c_id="$(trim "$c_id")"; [ -n "$c_id" ] || continue
  IDS+=("$c_id"); HASH[$c_id]="$(trim "$c_hash")"; KIND[$c_id]="$(trim "$c_kind")"; OFFS[$c_id]="$(trim "$c_off")"
  COND[$c_id]="$(trim "$c_cond")"; ASK[$c_id]="$(trim "$c_ask")"
done <<< "$ROWS"
for c_id in "${IDS[@]}"; do   # the row data's own shape: a bug here is refused, never half-read
  [[ ${HASH[$c_id]} =~ ^[0-9a-f]{8}$ ]] || refuse "next.sh's row data: row $c_id has no NEXT.md hash of 8 hex digits (a bug in ROWS)."
  case "${KIND[$c_id]}:${OFFS[$c_id]}" in
    act:-) ;;
    gate:-) refuse "next.sh's row data: gate $c_id turns no row off (a bug in ROWS)." ;;
    gate:*) [ "${ASK[$c_id]}" = "-" ] || refuse "next.sh's row data: gate $c_id needs judgement; a gate must not (a bug in ROWS)."
      for c_x in ${OFFS[$c_id]//,/ }; do
        [ -n "${KIND[$c_x]+x}" ] || refuse "next.sh's row data: gate $c_id turns off row $c_x, which it does not have (a bug in ROWS)."
      done ;;
    *) refuse "next.sh's row data: row $c_id is '${KIND[$c_id]}' turning off '${OFFS[$c_id]}' (a bug in ROWS)." ;;
  esac
done

# ------------------------------------------------------------------------------------------------ NEXT.md's table
# table_rows <NEXT.md>: "id US action US condition" (US: the unit separator, \037) per row of the table under "## The
# table", in order - every row, whatever the form of its id; the condition with its whitespace normalised. The table
# runs from the first line under the heading that starts with "|" to the first blank line, and inside it EVERY line must
# be a row: "|" at column 0 and four cells. One that is not (indented, no leading "|" - Markdown shows both in the
# table -, a line of prose, a "|" inside a cell, no id) is printed "BAD US <line number> US <the line>": refused, never
# half-read, never skipped. A "|" line under the heading after the table has ended is read as a row too.
table_rows() {
  LC_ALL=C awk '
    { sub(/\r$/, "") }
    /^## / { intable = ($0 ~ /^## The table/); started = 0; ended = 0; next }
    !intable { next }
    !started && /^\|/ { started = 1 }
    !started { next }
    !ended && /^[ \t]*$/ { ended = 1; next }
    ended && !/^\|/ { next }
    {
      line = $0; n = gsub(/[|]/, "|", line)
      if ($0 ~ /^\|[-:| ]+$/ && n == 5) next
      split($0, c, /[|]/); id = c[2]; gsub(/^[ \t]+|[ \t]+$/, "", id)
      if ($0 !~ /^\|/ || n != 5 || id == "" || id ~ /[ \t]/) { print "BAD\037" NR "\037" $0; next }
      if (id == "#") next
      act = c[4]; gsub(/^[ \t]+|[ \t]+$/, "", act)
      cond = c[3]; gsub(/[ \t]+/, " ", cond); gsub(/^ | $/, "", cond)
      print id "\037" act "\037" cond
    }' "$1"
}
cell_hash() { local c; c="$(printf '%s' "$1" | cksum)"; printf '%08x' "${c%%[[:space:]]*}"; }   # POSIX cksum: the same CRC everywhere
declare -A ACTION=() CELL=()
load_table() { # load_table <NEXT.md>: fills ACTION, and refuses when its rows and ROWS disagree (the drift guard)
  local f="$1" id act cond ours theirs="" x changed=""
  [ -f "$f" ] || refuse "no decision table at $f (doctrine/NEXT.md)."
  while IFS=$'\037' read -r id act cond; do
    [ "$id" = "BAD" ] && refuse "$f line $act is inside the table but is not a row of it (a '|' at column 0 and four cells, an id; a '|' inside a cell?): '$cond'."
    [ -z "${ACTION[$id]+x}" ] || refuse "$f has row $id twice."
    ACTION[$id]="$act"; CELL[$id]="$(cell_hash "$cond")"; theirs="${theirs:+$theirs }$id"
  done < <(table_rows "$f")
  [ -n "$theirs" ] || refuse "$f has no rows under '## The table'."
  ours="${IDS[*]}"
  if [ "$ours" != "$theirs" ]; then
    for x in $theirs; do [ -n "${KIND[$x]+x}" ] || refuse "drift: $f has row $x, and next.sh has no entry for it (add one to ROWS)."; done
    for x in $ours; do [ -n "${ACTION[$x]+x}" ] || refuse "drift: next.sh has an entry for row $x, and $f has no row $x."; done
    refuse "drift: $f and next.sh name the same rows in another order ($theirs / $ours)."
  fi
  for x in $ours; do
    [ "${HASH[$x]}" = "${CELL[$x]}" ] && continue
    changed="${changed:+$changed, }$x"
    if [ "$check_only" = 1 ]; then
      echo "row $x: its condition in $f is not the text next.sh's entry was written from - re-read the row, make its ROWS entry say the same, then paste its new hash ${CELL[$x]} over ${HASH[$x]}"
    fi
  done
  [ -z "$changed" ] || refuse "drift: the condition of row $changed in $f changed since next.sh's entry was written from it (ROWS keeps a hash of each cell; scripts/next.sh --check-table prints the new one, to paste once the entry says the same)."
}

# ------------------------------------------------------------------------------------------------ STATE.md's flags
FLAGS="phase bytecode_changed_since battery blackbox open_findings last_audit_round last_other_round ceiling real_manager_battery waiting_on_owner location dossier rehearsal threat_model notes"
declare -A RAW=() V=() RECORDED=() SHOW_NOTE=() OPEN_HIGH=()
declare -a RECORDED_ORDER=() OPEN_HIGH_ORDER=() TOLD_ORDER=()
declare -A TOLD=() TOLD_DATE=()
ROW1_QUIET="" HIGHS_NOT_RECORDED=""
declare -a NOTE_LINES=()

# finding_id <where> <id> <the form expected>: one finding id, or refused - a placeholder, a word between ids, anything
# that is not one id (open_findings' high=N (<ids>) and waiting_on_owner's high <id>[, <id>...] - to tell alike)
finding_id() {
  local where="$1" id="$2" form="$3"
  case "${id,,}" in
    none | tbd | nobody | n/a | '?') refuse "$where, '$id' is a placeholder, not a finding id ($form: the ids of the open highs)." ;;
    and | or | '&' | plus) refuse "$where, '$id' is a word, not a finding id (ids between commas or spaces: $form)." ;;
  esac
  [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || refuse "$where, '$id' is not one finding id ($form)."
  # an id is an id: a letter and a digit at least (F-1, P-02, r01-A1, R01-3). The same non-id written on both sides -
  # `high=1 (all)` and `high all - to tell`, `TBA`, `pending`, the count `1`, `None.` - quieted row 1 (V28)
  [[ $id =~ [A-Za-z] && $id =~ [0-9] ]] \
    || refuse "$where, '$id' is not an id: an id has at least one letter and one digit (F-1, r01-A1; $form)."
}

# enum <flag> <allowed...>: the value's first word is one of them, and anything after it is a comment in parentheses
enum() {
  local f="$1" v first rest; shift
  v="${RAW[$f]}"; first="${v%%[[:space:]]*}"; rest="$(trim "${v#"$first"}")"
  case " $* " in *" $first "*) ;; *) refuse "$f: '$first' is not one of: $*." ;; esac
  case "$rest" in "" | "("*) ;; *) refuse "$f: after '$first' only a comment in parentheses may follow (got '$rest')." ;; esac
  V[$f]="$first"
}
# pairs <flag> <value regex> <what a value is> <key...>: every key exactly once as key=value, then optionally a comment
# in parentheses
pairs() {
  local f="$1" re="$2" what="$3" w k val; shift 3
  local -a words
  local -A seen=()
  read -ra words <<< "${RAW[$f]}"
  for w in "${words[@]}"; do
    case "$w" in "("*) break ;; esac
    k="${w%%=*}"; val="${w#*=}"
    case "$w" in *=*) ;; *) refuse "$f: '$w' is not key=value (keys: $*)." ;; esac
    case " $* " in *" $k "*) ;; *) refuse "$f: '$k' is not one of its keys: $*." ;; esac
    [ -z "${seen[$k]+x}" ] || refuse "$f: $k= is given twice."
    [[ $val =~ $re ]] || refuse "$f: $k='$val' is not $what."
    seen[$k]=1; V[$f.$k]="$val"
  done
  for k in "$@"; do [ -n "${seen[$k]+x}" ] || refuse "$f: $k= is missing."; done
}

# flag_block, and the kit's example test (is_kit_example, example_by_values): lib/state-example.sh, read by
# scripts/init-state.sh too - sourced below, after --check-table (which reads no STATE.md and needs no library)
parse_state() {
  local st="$1" block line n=0 name val prev=""
  block="$(flag_block "$st")" \
    || refuse "$st has no flag block (a fenced block with a 'phase:' line, doctrine/NEXT.md)."
  while IFS= read -r line; do
    n=$((n + 1))
    [ -n "$(trim "$line")" ] || continue
    if [[ $line =~ ^([a-z_]+):(.*)$ ]]; then
      name="${BASH_REMATCH[1]}"; val="$(trim "${BASH_REMATCH[2]}")"
      case " $FLAGS " in *" $name "*) ;; *) refuse "unknown flag '$name' (line $n of the flag block; the flags: $FLAGS)." ;; esac
      [ -z "${RAW[$name]+x}" ] || refuse "flag '$name' appears twice in the flag block."
      RAW[$name]="$val"; prev="$name"
      [ "$name" != notes ] || [ -z "$val" ] || NOTE_LINES+=("$val")
    elif [[ $line =~ ^[[:space:]] ]] && [ "$prev" = "notes" ]; then
      RAW[notes]="${RAW[notes]} $(trim "$line")"   # notes: may run on over indented lines, each a note line
      NOTE_LINES+=("$(trim "$line")")
    else
      refuse "line $n of the flag block is not 'name: value': '$line'."
    fi
  done <<< "$block"
  for name in $FLAGS; do
    # a STATE.md written before v0.5 has no threat_model: line - the refusal names the line to add (its starting value)
    [ "$name" != threat_model ] || [ -n "${RAW[$name]+x}" ] \
      || refuse "flag 'threat_model' is missing from the flag block (a STATE.md written before v0.5): add the line \"threat_model: not yet\" to the flag block (doctrine/NEXT.md lists the flags)."
    [ -n "${RAW[$name]+x}" ] || refuse "flag '$name' is missing from the flag block (doctrine/NEXT.md lists the flags)."
    [ "$name" = "notes" ] || [ -n "${RAW[$name]}" ] || refuse "flag '$name' has no value."
  done

  enum phase sketch 0 1 2 3 4 5 6 7 8
  pairs bytecode_changed_since '^(yes|no|n/a)$' "yes or no (n/a: last_promotion only)" \
    last_battery last_long_fuzz last_other_free_judges last_audit_round last_promotion
  for name in last_battery last_long_fuzz last_other_free_judges last_audit_round; do
    [ "${V[bytecode_changed_since.$name]}" != "n/a" ] || refuse "bytecode_changed_since: $name='n/a' is not yes or no (n/a: last_promotion only)."
  done
  enum battery never green red
  val="${RAW[blackbox]}"   # stopped (<round id>): a black-box round the environment stopped twice (row 11b)
  if [[ $val =~ ^stopped([^A-Za-z0-9_]|$) ]]; then
    local re_stop='^stopped[[:space:]]+[(][A-Za-z0-9][A-Za-z0-9._-]*([,;[:space:]][^()]*)?[)]$'
    [[ $val =~ $re_stop ]] \
      || refuse "blackbox: '$val' is not stopped (<round id>): the id of the black-box round stopped twice (row 11b), in parentheses."
    V[blackbox]=stopped; V[blackbox.id]="${val#*(}"; V[blackbox.id]="${V[blackbox.id]%%[),; ]*}"
  else
    enum blackbox never_run current stale skipped_by_owner stopped
  fi
  # open_findings names the open highs (NEXT.md, K28): `high=N (<ids>)`, the parentheses right after high=N - the first
  # high= key, before any "(" (a comment after the keys may say anything) - exactly when N > 0. They are taken out here,
  # checked, and the rest is read as key=value pairs like any other
  local id key hid_given=0 hid_raw="" hid_show
  local -a ids=()
  local re_hid='^([^(]*[[:space:]]|)high=([0-9]+)[[:space:]]*[(]([^()]*)[)]'
  val="${RAW[open_findings]}"
  if [[ $val =~ $re_hid ]]; then
    hid_given=1; hid_raw="$(trim "${BASH_REMATCH[3]}")"
    RAW[open_findings]="${BASH_REMATCH[1]}high=${BASH_REMATCH[2]}${val:${#BASH_REMATCH[0]}}"
  fi
  pairs open_findings '^[0-9]+$' "a whole number" high medium low reasoned_high_or_medium
  local h="${V[open_findings.high]}" m="${V[open_findings.medium]}" l="${V[open_findings.low]}" r="${V[open_findings.reasoned_high_or_medium]}"
  V[open_findings.total]=$((10#$h + 10#$m + 10#$l))
  hid_show="high=$((10#$h))"
  if [ "$hid_given" = 1 ]; then
    hid_show="high=$((10#$h)) ($hid_raw)"
    [ $((10#$h)) -gt 0 ] \
      || refuse "open_findings: high=0 with ids in parentheses ($hid_raw): the parentheses name the open highs, none when high is 0 (high=N (<ids>), NEXT.md)."
    read -ra ids <<< "${hid_raw//,/ }"
    for id in ${ids[@]+"${ids[@]}"}; do
      finding_id "open_findings: in '$hid_show'" "$id" "high=N (<ids>)"
      key="${id,,}"
      [ -z "${OPEN_HIGH[$key]+x}" ] \
        || refuse "open_findings: in '$hid_show', '$id' is named twice ('${OPEN_HIGH[$key]}' and '$id', case aside): each open high once."
      OPEN_HIGH[$key]="$id"; OPEN_HIGH_ORDER+=("$id")
    done
    key="ids"; [ "${#ids[@]}" != 1 ] || key="id"
    [ "${#ids[@]}" -eq $((10#$h)) ] \
      || refuse "open_findings: high=$((10#$h)) names ${#ids[@]} $key ($hid_raw): one id per open high (high=N (<ids>), NEXT.md)."
  elif [ $((10#$h)) -gt 0 ]; then
    refuse "open_findings: high=$((10#$h)) names no ids: the ids of the open highs go in parentheses right after it, high=$((10#$h)) (<ids>) (NEXT.md)."
  fi
  [ $((10#$r)) -le $((10#$h + 10#$m)) ] \
    || refuse "open_findings: reasoned_high_or_medium=$r is more than high+medium open ($((10#$h + 10#$m))): a REASONED finding is one of them."

  local re_type='^[A-Za-z0-9._-]+,?[[:space:]]+([a-z-]+)(,|[[:space:]]|$)'
  local re_audit='^([A-Za-z0-9._-]+),?[[:space:]]+([a-z-]+),?[[:space:]]+([0-9]+)H[[:space:]]+([0-9]+)M[[:space:]]+([0-9]+)L([[:space:]].*)?$'
  val="${RAW[last_audit_round]}"
  if [[ $val =~ $re_type ]] && [ "$val" != none ]; then
    case "${BASH_REMATCH[1]}" in discovery | regression) ;;
      *) refuse "last_audit_round: '${BASH_REMATCH[1]}' is not discovery or regression (black-box and verifier rounds go in last_other_round)." ;; esac
  fi
  if [[ $val =~ ^none([[:space:]]+\(.*)?$ ]]; then
    V[last_audit_round]=none; V[last_audit_round.type]=none; V[last_audit_round.high]=0; V[last_audit_round.medium]=0
  elif [[ $val =~ $re_audit ]]; then
    V[last_audit_round]="${BASH_REMATCH[1]}"; V[last_audit_round.type]="${BASH_REMATCH[2]}"
    V[last_audit_round.high]="${BASH_REMATCH[3]}"; V[last_audit_round.medium]="${BASH_REMATCH[4]}"
  else
    refuse "last_audit_round: '$val' is neither 'none' nor '<id> discovery|regression <n>H <n>M <n>L' (e.g. r06 regression 0H 1M 3L)."
  fi
  local re_other='^([A-Za-z0-9._-]+),?[[:space:]]+([a-z-]+)(,|[[:space:]]|$)'
  val="${RAW[last_other_round]}"
  if [[ $val =~ ^none([[:space:]]+\(.*)?$ ]]; then V[last_other_round]=none
  elif [[ $val =~ $re_other ]]; then
    case "${BASH_REMATCH[2]}" in black-box | verifier) V[last_other_round]="${BASH_REMATCH[1]}" ;;
      *) refuse "last_other_round: '${BASH_REMATCH[2]}' is not black-box or verifier (discovery and regression rounds go in last_audit_round)." ;; esac
  else
    refuse "last_other_round: '$val' is neither 'none' nor '<id> black-box|verifier <result>'."
  fi
  V[any_round]=no
  if [ "${V[last_audit_round]}" != none ] || [ "${V[last_other_round]}" != none ]; then V[any_round]=yes; fi

  local re_ceil='^([0-9]+)[^;]*;[[:space:]]*([0-9]+)[[:space:]]+used'
  # the ceiling the OPERATOR set, the owner absent in full mode (NEXT.md row 3, COST.md 1): one fixed form, read strictly -
  # a line that says "operator" in any other shape, or in any other case, is refused, never read as the owner's
  local re_op='^([0-9]+) model rounds?, set by the operator \(owner absent\);[[:space:]]*([0-9]+)[[:space:]]+used([[:space:]]+[(][^()]*[)])?$'
  val="${RAW[ceiling]}"
  if [[ $val =~ ^not\ agreed ]]; then V[ceiling]=not_agreed
  elif [[ $val =~ ^undecided ]]; then V[ceiling]=undecided
  elif [[ ${val,,} == *operator* ]]; then   # in ANY case: `set by the Operator` passed as the owner's ceiling (V24)
    [[ $val =~ $re_op ]] || refuse "flag 'ceiling': '$val' is not the operator's form, '<N> model rounds, set by the operator (owner absent); <M> used'."
    if [ "${BASH_REMATCH[2]}" -ge "${BASH_REMATCH[1]}" ]; then V[ceiling]=reached; else V[ceiling]=open; fi
    V[ceiling.used]=$((10#${BASH_REMATCH[2]}))
    CEIL_SHOW="${BASH_REMATCH[2]} of ${BASH_REMATCH[1]} used, set by the operator (owner absent)"
  elif [[ $val =~ $re_ceil ]]; then
    if [ "${BASH_REMATCH[2]}" -ge "${BASH_REMATCH[1]}" ]; then V[ceiling]=reached; else V[ceiling]=open; fi
    V[ceiling.used]=$((10#${BASH_REMATCH[2]}))
    CEIL_SHOW="${BASH_REMATCH[2]} of ${BASH_REMATCH[1]} used"
  else
    refuse "flag 'ceiling': '$val' is none of 'not agreed ...', 'undecided ...', '<N> model rounds ...; <M> used', '<N> model rounds, set by the operator (owner absent); <M> used'."
  fi

  enum real_manager_battery n/a never stale current
  val="${RAW[waiting_on_owner]}"
  if [[ $val =~ ^none([[:space:]]+\(.*)?$ ]]; then V[waiting_on_owner]=none; else V[waiting_on_owner]="$val"; fi
  # row 7b's own question waits on the owner when an item of waiting_on_owner (items: separated by ";" or the middle dot
  # NEXT.md uses) contains RPC_URL, or IS the chain question: the item is `chain`, or starts with `chain`, `target chain`
  # or `which chain` (any case) as a word. The word anywhere else - `off-chain keeper address`, `triage of F-2
  # (cross-chain replay)`, `severity of F-7 (it depends on the chain)` - asks the owner something else, and 7b, a
  # local judge, does not wait on it (a verifier's G03 and G12)
  local item; local -a items=()
  V[waiting_on_owner.real_manager]=no
  # row 1 with the owner absent: the highs recorded to tell are the items `high <id>[, <id>...] - to tell` (both real walks
  # wrote several ids in one item, between commas or between spaces). Each id once, compared case-insensitively; a
  # placeholder, a word between the ids, or an item that says "to tell" in any other shape is refused - never counted,
  # never ignored
  local re_tell='^high[[:space:]]+(.*[^[:space:]])[[:space:]]+-[[:space:]]+to[[:space:]]+tell([[:space:]]|$)'
  local re_tell_empty='^high[[:space:]]+-[[:space:]]+to[[:space:]]+tell([[:space:]]|$)'
  if [ "${V[waiting_on_owner]}" != none ]; then
    IFS=';' read -ra items <<< "${val//$'\302\267'/;}"
    for item in "${items[@]}"; do
      case "$item" in *RPC_URL*) V[waiting_on_owner.real_manager]=yes ;; esac
      item="$(trim "$item")"
      [[ ${item,,} =~ ^(target[[:space:]]+|which[[:space:]]+)?chain([^a-z0-9_-]|$) ]] && V[waiting_on_owner.real_manager]=yes
      if [[ $item =~ $re_tell_empty ]]; then
        refuse "waiting_on_owner: '$item' names no finding id (high <id>[, <id>...] - to tell)."
      elif [[ $item =~ $re_tell ]]; then
        read -ra ids <<< "${BASH_REMATCH[1]//,/ }"
        [ "${#ids[@]}" -gt 0 ] || refuse "waiting_on_owner: '$item' names no finding id (high <id>[, <id>...] - to tell)."
        for id in "${ids[@]}"; do
          finding_id "waiting_on_owner: in '$item'" "$id" "high <id>[, <id>...] - to tell"
          key="${id,,}"
          [ -n "${RECORDED[$key]+x}" ] && continue
          RECORDED[$key]="$id"; RECORDED_ORDER+=("$id")
        done
      elif [[ ${item,,} == *"to tell"* ]]; then
        refuse "waiting_on_owner: '$item' is not 'high <id>[, <id>...] - to tell' (NEXT.md row 1: the ids of the open highs, then ' - to tell')."
      fi
    done
  fi
  enum location .gauntlet/ root
  # the skeleton says how many open findings it names (row 9b reads it): skeleton (<K> open, <N> judges not done)
  val="${RAW[dossier]}"
  if [[ $val =~ ^skeleton([^A-Za-z0-9_]|$) ]]; then
    local re_skel='^skeleton[[:space:]]+[(]([0-9]+)[[:space:]]+open([,;[:space:]][^()]*)?[)]$'
    [[ $val =~ $re_skel ]] \
      || refuse "dossier: '$val' is not skeleton (<K> open, <N> judges not done): row 9b reads K, the number of open findings the skeleton names."
    V[dossier]=skeleton; V[dossier.open]=$((10#${BASH_REMATCH[1]}))
  else
    enum dossier none skeleton complete
  fi
  # a complete dossier has no finding open (NEXT.md's dossier: flag): one next to an open finding is a skeleton, refused
  # (K28: it quieted row 9b, and the route paused on a "complete" dossier with findings still open)
  [ "${V[dossier]}" != complete ] || [ "${V[open_findings.total]}" -eq 0 ] \
    || refuse "dossier: complete, and open_findings has ${V[open_findings.total]} open (high + medium + low): a dossier with an open finding is a skeleton - dossier: skeleton (<K> open, <N> judges not done)."
  # row 9b is done once the dossier names what is open: a skeleton naming exactly the number open (a complete dossier has
  # none open)
  V[dossier.lists_open]=no
  case "${V[dossier]}" in
    complete) V[dossier.lists_open]=yes ;;
    skeleton) [ "${V[dossier.open]}" -ne "${V[open_findings.total]}" ] || V[dossier.lists_open]=yes
      SHOW_NOTE[dossier.lists_open]="the skeleton names ${V[dossier.open]}, open_findings has ${V[open_findings.total]} open" ;;
    none) SHOW_NOTE[dossier.lists_open]="dossier: none" ;;
  esac
  local re_na='^n/a([[:space:]]+[(].*[)])?$' re_ny='^not yet([[:space:]]+[(].*[)])?$'
  local re_done='^done[[:space:]]+[(]([0-9]{4})-([0-9]{2})-([0-9]{2})[)]$'
  val="${RAW[rehearsal]}"
  if [[ $val =~ $re_na ]]; then V[rehearsal]=n/a
  elif [[ $val =~ $re_ny ]]; then V[rehearsal]=not_yet
  elif [[ $val =~ $re_done ]] && real_date "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"; then V[rehearsal]="done"
  else refuse "rehearsal: '$val' is not one of: n/a (no runbook) | not yet | done (YYYY-MM-DD), a real date."; fi
  # the independent threat model (v0.5, NEXT.md row 4b): `not yet`, or the line scripts/threat-diff.sh prints, as it
  # prints it - read against the files themselves below, after the phase's records
  local re_tm='^diffed[[:space:]]+[(]([0-9]+) matched,[[:space:]]+([0-9]+) new,[[:space:]]+([0-9]+) refused,[[:space:]]+([0-9]+) handed[)]$'
  local re_tny='^not yet([[:space:]]+[(][^()]*[)])?$'
  val="${RAW[threat_model]}"
  if [[ $val =~ $re_tny ]]; then V[threat_model]=not_yet
  elif [[ $val =~ $re_tm ]]; then
    V[threat_model]=diffed; V[threat_model.counts]="$((10#${BASH_REMATCH[1]})) matched, $((10#${BASH_REMATCH[2]})) new, $((10#${BASH_REMATCH[3]})) refused, $((10#${BASH_REMATCH[4]})) handed"
  else refuse "threat_model: '$val' is not one of: not yet | diffed (<n> matched, <m> new, <k> refused, <h> handed) - the line scripts/threat-diff.sh prints."; fi
  # a note is read by its name only at the START of a note item: a note line (the value of notes:, or an indented line
  # under it), or a part of one after the middle dot or ";" - never where the words merely appear
  V[notes.real_manager]=no
  for line in "${NOTE_LINES[@]}"; do
    IFS=';' read -ra items <<< "${line//$'\302\267'/;}"
    for item in "${items[@]}"; do
      item="$(trim "$item")"
      # a note written as a Markdown list item (`- real manager: ...`) is read like a plain one
      if [[ $item =~ ^[-*+][[:space:]]+(.*)$ ]]; then item="${BASH_REMATCH[1]}"; fi
      [[ $item =~ ^real\ manager: ]] && V[notes.real_manager]=yes                                            # row 7b
      # row 1 with the owner present (v0.5.1): `told: <YYYY-MM-DD> <id>[, <id>...]` - the highs told to the owner, by
      # id, on that day. Read only when a date opens it; a told: note in any other shape is not read (row 1 is asked)
      if [[ $item =~ ^told:[[:space:]]*([0-9]{4})-([0-9]{2})-([0-9]{2})([^0-9].*)?$ ]]; then
        local t_date="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}" t_rest="${BASH_REMATCH[4]}" t_tok t_n=0 re_ttail='^(.+)[.;:]$'
        local -a t_words=()
        real_date "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
          || refuse "notes: '$item' - $t_date is not a real date (told: <YYYY-MM-DD> <id>[, <id>...]: the highs told to the owner, by id, on that day)."
        read -ra t_words <<< "${t_rest//,/ }"
        for t_tok in ${t_words[@]+"${t_words[@]}"}; do
          case "${t_tok,,}" in and | '&') continue ;; esac
          while [[ $t_tok =~ $re_ttail ]]; do t_tok="${BASH_REMATCH[1]}"; done
          [[ $t_tok =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $t_tok =~ [A-Za-z] && $t_tok =~ [0-9] ]] || break
          t_n=$((t_n + 1))
          [ -n "${TOLD[${t_tok,,}]+x}" ] || { TOLD[${t_tok,,}]="$t_tok"; TOLD_ORDER+=("$t_tok"); TOLD_DATE[${t_tok,,}]="$t_date"; }
        done
        [ "$t_n" -gt 0 ] || refuse "notes: '$item' names no finding id after its date (told: <YYYY-MM-DD> <id>[, <id>...]: the highs told to the owner, by id - F-1, r01-A1)."
      fi
    done
  done
  # row 1, by id (K28): quiet by the flags only when EVERY open high named in open_findings is recorded to tell, or
  # (v0.5.1) told: the owner present, a note `told: <YYYY-MM-DD> <id>[, <id>...]` names it. An id recorded to tell, or
  # told, that is not an open high is a stale entry (a high fixed or re-triaged since) or not a high at all (V26b:
  # `high all`, `high 1`, a medium's id, one high spelled twice quieted the row by their number): refused, so that it is
  # read and removed - never counted. One open high neither: the row is a question naming it. A told: note in any other
  # shape - no date first - is not read (V26: a told: of a closed high, or told: none, quieted it with nothing on the
  # record): the row is asked.
  for id in ${RECORDED_ORDER[@]+"${RECORDED_ORDER[@]}"}; do
    [ -n "${OPEN_HIGH[${id,,}]+x}" ] \
      || refuse "waiting_on_owner: '$id' is recorded to tell (high <id>[, <id>...] - to tell), and it is not an open high in open_findings ($hid_show): a recorded high is no longer open: remove it."
  done
  for id in ${TOLD_ORDER[@]+"${TOLD_ORDER[@]}"}; do
    [ -n "${OPEN_HIGH[${id,,}]+x}" ] \
      || refuse "notes: told: ${TOLD_DATE[${id,,}]} '$id' - it is not an open high in open_findings ($hid_show): a high told and since closed or re-triaged is no longer open: take its id out of the told: note (LOG.md keeps when it was told)."
  done
  local rec_n=0 rec_ids="" nrec_n=0 told_n=0 told_ids=""
  for id in ${OPEN_HIGH_ORDER[@]+"${OPEN_HIGH_ORDER[@]}"}; do
    if [ -n "${RECORDED[${id,,}]+x}" ]; then rec_n=$((rec_n + 1)); rec_ids="${rec_ids:+$rec_ids, }$id"
    elif [ -n "${TOLD[${id,,}]+x}" ]; then told_n=$((told_n + 1)); told_ids="${told_ids:+$told_ids, }$id on ${TOLD_DATE[${id,,}]}"
    else nrec_n=$((nrec_n + 1)); HIGHS_NOT_RECORDED="${HIGHS_NOT_RECORDED:+$HIGHS_NOT_RECORDED, }$id"; fi
  done
  V[open_findings.high_not_recorded]=$nrec_n
  SHOW_NOTE[open_findings.high_not_recorded]="$hid_show, recorded to tell in waiting_on_owner: ${rec_ids:-none};${told_ids:+ told (notes: told:): $told_ids;} not recorded: ${HIGHS_NOT_RECORDED:-none}"
  if [ $((10#$h)) -gt 0 ] && [ "$nrec_n" -eq 0 ]; then
    local q_why=""
    [ "$rec_n" -eq 0 ] || q_why="recorded to tell in waiting_on_owner ($rec_ids)"
    [ "$told_n" -eq 0 ] || q_why="${q_why:+$q_why; }told to the owner (notes: told: $told_ids)"
    if [ $((rec_n + told_n)) -eq 1 ]; then ROW1_QUIET="row 1 is quiet: the 1 high open is $q_why"
    else ROW1_QUIET="row 1 is quiet: the $((rec_n + told_n)) highs open are $q_why"; fi
  fi
  # row 7b is owed (and rows 12 and 16 wait on it): the chain is known, the real-manager battery never ran or is stale,
  # and no real manager: note says what replaced it
  V[real_manager.owed]=no
  case "${V[real_manager_battery]}" in never | stale) [ "${V[notes.real_manager]}" = yes ] || V[real_manager.owed]=yes ;; esac
}
real_date() { # real_date <YYYY> <MM> <DD>: 0 when it is a day of the calendar
  local y=$((10#$1)) mo=$((10#$2)) d=$((10#$3)) last=31
  [ "$mo" -ge 1 ] && [ "$mo" -le 12 ] || return 1
  case "$mo" in
    4 | 6 | 9 | 11) last=30 ;;
    2) last=28; if [ $((y % 4)) = 0 ] && { [ $((y % 100)) != 0 ] || [ $((y % 400)) = 0 ]; }; then last=29; fi ;;
  esac
  [ "$d" -ge 1 ] && [ "$d" -le "$last" ]
}

# ------------------------------------------------------------------------------------------------ evaluating a row
CEIL_SHOW=""
show() { # show <name>: name=value, as the because: line prints it (with what it was derived from, for a derived one)
  if [ "$1" = ceiling ] && [ -n "$CEIL_SHOW" ]; then printf 'ceiling=%s (%s)' "${V[ceiling]}" "$CEIL_SHOW"
  elif [ -n "${SHOW_NOTE[$1]:-}" ]; then printf '%s=%s (%s)' "$1" "${V[$1]}" "${SHOW_NOTE[$1]}"
  else printf '%s=%s' "$1" "${V[$1]}"; fi
}
have() { [ -n "${V[$1]+x}" ] || refuse "next.sh's row data names '$1', which is not a flag it reads (a bug in ROWS)."; }
TERM_SHOW="" COND_WHY=""
term_true() {
  local t="$1" k v
  case "$t" in
    row:*)
      k="${t#row:}"; [ -n "${COND[$k]+x}" ] || refuse "next.sh's row data names row $k, which it does not have."
      cond_true "${COND[$k]}" || return 1
      TERM_SHOW="row $k [$COND_WHY]" ;;
    *'!='*) k="${t%%!=*}"; v="${t#*!=}"; have "$k"; TERM_SHOW="$(show "$k")"; [ "${V[$k]}" != "$v" ] ;;
    *'>'*) k="${t%%>*}"; v="${t#*>}"; have "$k"; TERM_SHOW="$(show "$k")"; [ "${V[$k]}" -gt "$v" ] ;;
    *=*) k="${t%%=*}"; v="${t#*=}"; have "$k"; TERM_SHOW="$(show "$k")"
      case ",$v," in *",${V[$k]},"*) return 0 ;; *) return 1 ;; esac ;;
    *) refuse "next.sh's row data has a term it cannot read: '$t' (a bug in ROWS)." ;;
  esac
}
cond_true() { # cond_true <condition>: 0 when one group holds; COND_WHY is that group's terms with their values
  local cond="$1" group t why ok
  local -a groups terms
  if [ "$cond" = "-" ]; then COND_WHY=""; return 0; fi
  IFS=';' read -ra groups <<< "$cond"
  for group in "${groups[@]}"; do
    read -ra terms <<< "$group"; ok=1; why=""
    for t in "${terms[@]}"; do
      if term_true "$t"; then why="${why:+$why }$TERM_SHOW"; else ok=0; break; fi
    done
    if [ "$ok" = 1 ]; then COND_WHY="$why"; return 0; fi
  done
  return 1
}

# ------------------------------------------------------------------------------------------------ arguments
STATE="" JUDGED="" check_only=0
declare -A JUDGE=()
while [ $# -gt 0 ]; do
  case "$1" in
    --check-table) check_only=1; [ $# -ge 2 ] && { TABLE="$2"; shift; }; shift ;;
    --table) [ $# -ge 2 ] || refuse "--table has no value."; TABLE="$2"; shift 2 ;;
    --judge) [ $# -ge 2 ] || refuse "--judge has no value (<row>=true|false[,...])."; JUDGED="${JUDGED:+$JUDGED,}$2"; shift 2 ;;
    -*) refuse "unknown argument '$1'." ;;
    *) [ -z "$STATE" ] || refuse "one STATE.md only (got '$STATE' and '$1')."; STATE="$1"; shift ;;
  esac
done

# after the answer, whatever it is (a row, the pause, FIRST, a refusal), one line on stdout when the kit holds files its
# MANIFEST does not list (v0.4.1, D6: a walker's `cd` drifted into the kit and wrote a test under
# foundry-kit/v4/test/examples/proj/ - nothing noticed). MANIFEST, at the kit's root, is one line per file in sha256sum's
# format, `<hash>  <path relative to the kit>` (scripts/gen-manifest.sh writes it; only the paths are read here). Not a
# refusal: the exit code is the answer's. No MANIFEST: nothing said. Not for --check-table, which reads no project.
# Generated outputs are not intruders: the selftest and the kit's own batteries write corpus/ and .gauntlet/reports/
# inside the kit (K52), and they are excluded below.
# THE EXCLUSIONS - one rule, in the same words in scripts/gen-manifest.sh, scripts/doctor.sh and scripts/next.sh (the
# selftest holds these lines equal in the three): MANIFEST itself; `.git`, file or directory, at any depth; and every
# directory named in KIT_SKIP_DIRS, anywhere under the kit - dependencies (lib/, but scripts/lib/: the scripts' own
# library, source), builds (cache/, out/) and what the kit's own runs write (corpus/, census/, broadcast/, .gauntlet/,
# where the selftest's marker is). The kit's .gitignore names the same directories.
KIT_SKIP_DIRS="lib cache out corpus census broadcast .gauntlet"
kit_files() { # kit_files: every file and link under the kit but the exclusions above, one path from the kit's root per line
  local kit_prune=() d
  for d in $KIT_SKIP_DIRS; do [ ${#kit_prune[@]} = 0 ] || kit_prune+=(-o); kit_prune+=(-name "$d"); done
  (cd "$KIT" && find . \( -name .git -o \( -type d \( "${kit_prune[@]}" \) ! -path ./scripts/lib \) \) -prune \
    -o \( -type f -o -type l \) -print 2> /dev/null) | sed 's#^\./##' | LC_ALL=C awk -v skip="$KIT_SKIP_DIRS" '
    BEGIN { k = split(skip, s, " "); for (i = 1; i <= k; i++) dir[s[i]] = 1 }
    $0 == "" || $0 == "MANIFEST" { next }
    { n = split($0, p, "/")
      for (i = 1; i <= n; i++) {
        if (p[i] == ".git") next
        if (i < n && (p[i] in dir) && !(i == 2 && p[1] == "scripts" && p[i] == "lib")) next
      }
      print }' | LC_ALL=C sort -u
}
manifest_note() {
  local m="$KIT/MANIFEST" extra n first
  [ -f "$m" ] || return 0
  extra="$(kit_files | LC_ALL=C awk 'NR == FNR { sub(/\r$/, ""); if (match($0, /^[0-9A-Fa-f]+ [ *]/)) { p = substr($0, RLENGTH + 1); sub(/^\.\//, "", p); listed[p] = 1 } next }
      !($0 in listed)' "$m" -)"
  [ -n "$extra" ] || return 0
  n="$(grep -c . <<< "$extra")"
  first="$(head -3 <<< "$extra" | paste -sd, - | sed 's/,/, /g')"
  if [ "$n" = 1 ]; then echo "next: note - the kit has 1 file not in its MANIFEST ($first): the kit is not to be changed; move it out"
  else echo "next: note - the kit has $n files not in its MANIFEST ($first): the kit is not to be changed; move them out"; fi
}
on_exit() { local rc=$?; [ -z "${SPEC_NOTE:-}" ] || echo "$SPEC_NOTE"; [ -z "${ROUND_NOTE:-}" ] || echo "$ROUND_NOTE"; manifest_note; exit "$rc"; }
if [ "$check_only" != 1 ]; then trap on_exit EXIT; fi

# before any row: the kit's own tools proven on this machine, for these scripts and this forge (K31, K31b). Not for
# --check-table, which reads no STATE.md
if [ "$check_only" != 1 ] && [ "${NEXT_SELFTEST-}" != 1 ]; then
  [ -f "$HERE/lib/kit-proof.sh" ] || refuse "$HERE/lib/kit-proof.sh is missing (the kit's own check that its selftest passed here)."
  # shellcheck source=lib/kit-proof.sh
  . "$HERE/lib/kit-proof.sh"
  if ! kit_why="$(kit_proof_check "$KIT")"; then
    echo "next: FIRST - prove the kit on this machine: $KIT/scripts/selftest.sh - it takes about $SELFTEST_MINUTES minutes; give it a tool timeout above that or run it in the background (then run next.sh again) - $kit_why"
    exit 0
  fi
fi
load_table "$TABLE"
if [ "$check_only" = 1 ]; then echo "next: next.sh's rows and $TABLE agree: ${#IDS[@]} rows, ${IDS[*]}."; exit 0; fi

IFS=',' read -ra answers <<< "$JUDGED"
for a in "${answers[@]}"; do
  k="${a%%=*}"; v="${a#*=}"
  case "$a" in *=*) ;; *) refuse "--judge '$a' is not <row>=true|false." ;; esac
  [ -n "${KIND[$k]+x}" ] || refuse "--judge $a: NEXT.md has no row $k."
  # row 3: its answer used to be read, and 3=true gave the pause over rows the flags made true below it (V26b)
  [ "$k" != 3 ] || refuse "--judge $a: row 3 is decided by the flags: waiting_on_owner and the rows below. Answer false each row below that waits on the owner's answer; with none standing and none left to judge, the pause is given."
  [ "${ASK[$k]}" != "-" ] || refuse "--judge $a: row $k is decided by the flags, not by judgement."
  case "$v" in true | false) ;; *) refuse "--judge $a: the answer is true or false." ;; esac
  [ -z "${JUDGE[$k]+x}" ] || refuse "--judge: row $k is answered twice."
  JUDGE[$k]="$v"
done

if [ -z "$STATE" ]; then
  for c in .gauntlet/STATE.md STATE.md; do [ -f "$c" ] && { STATE="$c"; break; }; done
  [ -n "$STATE" ] || refuse "no STATE.md given, and none at .gauntlet/STATE.md or ./STATE.md."
fi
# a project's directory (next.sh <proj>, the entry skill's last line): its .gauntlet/STATE.md, then its STATE.md (K47)
if [ -d "$STATE" ]; then
  if [ -f "${STATE%/}/.gauntlet/STATE.md" ]; then STATE="${STATE%/}/.gauntlet/STATE.md"
  elif [ -f "${STATE%/}/STATE.md" ]; then STATE="${STATE%/}/STATE.md"
  else # the command that writes one, absolute like the other refusals' (V50: a walk from nothing read state/README.md here)
    P_NONE="$(cd "$STATE" && pwd)" || refuse "cannot enter $STATE."
    refuse "$P_NONE has no .gauntlet/STATE.md and no STATE.md: $KIT/scripts/init-state.sh $P_NONE writes one (or give the STATE.md)"; fi
fi
[ -f "$STATE" ] || refuse "$STATE does not exist."

# ------------------------------------------------------------------------------------------------ the kit's example
# K40: a STATE.md that is still the kit's example is not a state, and no row is read from it (the local-model walk: next.sh answered
# "row 13 - a REGRESSION round ... r05" on the example BlockCapHook, twice, and the walker gave up on next.sh). Known by
# its marker line, or by the example hook's name in the title (the first "# " line); the DECISIONS.md and LOG.md beside
# it likewise. In STATE.md the marker counts anywhere; in DECISIONS.md and LOG.md only as a whole line (K48). And
# STATE.md by its values (K48, K49, D7): a flag block that shares three or more non-generic lines with the kit's own
# state/STATE.md (found from this script's place), the spacing collapsed and `key:value` read as `key: value` on both
# sides, is the example; the refusal names the example's own line. The test is lib/state-example.sh's (is_kit_example,
# example_by_values), the one scripts/init-state.sh calls to replace an example in the same step. No escape: an
# example is never a state.
# shellcheck source=lib/state-example.sh
. "$HERE/lib/state-example.sh" || refuse "$HERE/lib/state-example.sh is missing (the flag block, and the test of the kit's example)."
ST_DIR="$(cd "$(dirname "$STATE")" && pwd)" || refuse "cannot read the directory of $STATE."
# the project: the STATE.md's directory, or its parent when that directory is .gauntlet/
if [ "$(basename "$ST_DIR")" = ".gauntlet" ]; then PROJ="$(dirname "$ST_DIR")"; else PROJ="$ST_DIR"; fi

# ------------------------------------------------------------------------------------------------ the spec is the owner's
# v0.4.1, D1: a walker appended 35 "owner decisions" to the owner's SPEC.md before it had read the hook, three of them
# false on the code and one the inverse of a defect planted there; nothing refused it. scripts/init-state.sh records
# the spec's hash in <proj>/.gauntlet/spec.sha256 (`<sha256>  <the spec's path relative to the project>`, the
# .gauntlet/ beside STATE.md); with that record, a spec whose hash differs, or that is gone, is refused. No escape: the
# owner's re-record (init-state.sh --spec ... --by "<name>", v0.4.1b D1b: signed, refused without the signature) is the
# way on, and it is a written act - and the refusal never prints that command. No record: nothing said here (a project
# set up by hand, or before v0.4.1) - from phase 2 its absence is refused after the flags are read (v0.5.3, below).
c_sha256() { if command -v sha256sum > /dev/null 2>&1; then sha256sum < "$1" | cut -d' ' -f1; else shasum -a 256 < "$1" | cut -d' ' -f1; fi; }
c_rec="$PROJ/.gauntlet/spec.sha256"
if [ -f "$c_rec" ]; then
  c_line="$(sed -n '1{s/\r$//;p;}' "$c_rec")"
  [[ $c_line =~ ^([0-9a-f]{64})\ \ (.+)$ ]] \
    || refuse "$c_rec is not '<sha256>  <the spec's path>' (scripts/init-state.sh writes it): the owner records the spec again, signed (scripts/init-state.sh --spec ... --by)."
  c_want="${BASH_REMATCH[1]}"; c_spec_rel="${BASH_REMATCH[2]}"; c_spec="$c_spec_rel"
  case "$c_spec" in /*) ;; *) c_spec="$PROJ/$c_spec" ;; esac
  # the re-record note (D1b): when spec.sha256 carries a `re-recorded` line, every answer but the FIRST one carries it,
  # under the answer as the MANIFEST note does, never a refusal of its own - the owner confirms the signature is theirs,
  # or the spec in force is not the owner's. The last re-recorded line; with more than one, the count before it.
  c_rr="$(grep -c '^re-recorded ' "$c_rec" 2> /dev/null)" || c_rr=0
  if [ "${c_rr:-0}" -gt 0 ]; then
    c_last="$(grep '^re-recorded ' "$c_rec" | tail -n 1)"
    if [[ $c_last =~ ^re-recorded\ ([^\ ]+)\ by\ \"(.*)\"\ ([0-9a-f]{8}|none)\ -\>\ ([0-9a-f]{8})$ ]]; then   # old8 is `none` when there was no record before
      if [ "$c_rr" -gt 1 ]; then c_rp="($c_rr re-records; the last:) "; else c_rp=""; fi
      SPEC_NOTE="next: note - the spec $c_spec_rel was re-recorded ${c_rp}on ${BASH_REMATCH[1]}, signed --by \"${BASH_REMATCH[2]}\" (${BASH_REMATCH[3]} -> ${BASH_REMATCH[4]}; .gauntlet/spec.sha256): the owner confirms that signature is theirs, or the spec in force is not the owner's"
    fi
  fi
  c_tail="the spec is the owner's. Undo the change (put the owner's text back) and write what you assumed in DECISIONS.md (source: assumed, owner absent); the route's own spec - phase 1's rows - is $PROJ/.gauntlet/SPEC.md, never the owner's file (AGENTS.md section 4). The owner, present, re-records a change of their own with scripts/init-state.sh, signed; an agent never does it."
  [ -f "$c_spec" ] || refuse "$c_spec is missing since init-state recorded it: $c_tail"
  [ "$(c_sha256 "$c_spec")" = "$c_want" ] || refuse "$c_spec changed since init-state recorded it: $c_tail"
fi

for c_f in "$STATE" "$ST_DIR/DECISIONS.md" "$ST_DIR/LOG.md"; do
  [ -f "$c_f" ] || continue
  c_whole=1; [ "$c_f" != "$STATE" ] || c_whole=0
  if is_kit_example "$c_f" "$c_whole"; then
    # STATE.md: init-state.sh writes the three empty (v0.4.1, D1), and replaces a .gauntlet/STATE.md that is the
    # example - and the example DECISIONS.md/LOG.md beside it - in the same step (K52; the same test, the library's).
    # Not for a DECISIONS.md or LOG.md beside a STATE.md of the project's own: init-state.sh refuses that STATE.md
    # (nor for the kit's own example read in place, <kit>/state/STATE.md: the kit is not a project)
    c_cmd=""; [ "$c_f" != "$STATE" ] || [ "$ST_DIR" = "$KIT/state" ] || c_cmd=" - $KIT/scripts/init-state.sh $PROJ writes an empty one"
    echo "next: REFUSED - FIRST - fill $(basename "$c_f"): it is still the kit's example (state/README.md, \"empty the examples\")$c_cmd" >&2
    exit 2
  fi
  [ "$c_f" = "$STATE" ] || continue
  if c_same="$(example_by_values "$c_f" "$KIT")"; then
    echo "next: REFUSED - FIRST - fill STATE.md: its values are still the kit's example's ($(head -1 <<< "$c_same"))" >&2
    exit 2
  fi
done
parse_state "$STATE"

# ------------------------------------------------------------------------------------------------ silence is a refusal (v0.5.3)
# The anchors: from phase 2 - doctrine/NEXT.md row 4b, a hook that compiles and a spec phase closed: init-state.sh had
# something to record by then - a missing anchor record is a refusal, never the "nothing said" it was (a review found it: delete
# .gauntlet/spec.sha256 and the spec check was off, without a word). Before phase 2 they may be absent: a hook still to
# be written, no spec found. A line 1 rewritten by hand with no `re-recorded` line is not caught here: the anchors are
# recomputable from public inputs, and that defence is procedural (doctrine/EVIDENCE.md, "silence is a refusal").
# shellcheck source=lib/src-anchor.sh
. "$HERE/lib/src-anchor.sh" || refuse "$HERE/lib/src-anchor.sh is missing (the anchor of src/, and the reports' seals)."
SRC_NOW="$(src_anchor_key "$PROJ")"
if [ "${V[phase]}" != sketch ] && [ "${V[phase]}" -ge 2 ]; then
  [ -f "$PROJ/.gauntlet/spec.sha256" ] \
    || refuse "anchor record missing: $PROJ/.gauntlet/spec.sha256; re-run scripts/init-state.sh $PROJ --spec <the owner's spec> --by <owner> - the owner's act, signed, never an agent's: from phase 2 (doctrine/NEXT.md row 4b) the spec is anchored, and phase ${V[phase]} is open; the owner absent: --by walker, with the note 'owner absent: <why>' in STATE.md's notes (the record then says by: walker (owner absent), and the dossier's section 8 carries it)"
  [ -f "$PROJ/.gauntlet/src.sha256" ] \
    || refuse "anchor record missing: $PROJ/.gauntlet/src.sha256; re-run scripts/init-state.sh $PROJ --src --by <owner> - the owner's act, signed, never an agent's: from phase 2 (doctrine/NEXT.md row 4b) src/ is anchored, and phase ${V[phase]} is open; the owner absent: --by walker, with the note 'owner absent: <why>' in STATE.md's notes (the record then says by: walker (owner absent), and the dossier's section 8 carries it)"
fi
# The round records: the ROUND lines of the LOG.md beside STATE.md (scripts/round.sh writes them, and reads them back
# with --json - a line of another shape is not a record and is not counted). Four flags are held to them (the header).
c_log="$ST_DIR/LOG.md"; c_logn="$(basename "$ST_DIR")/LOG.md"
declare -a RR_ID=() RR_TYPE=()
if [ -f "$c_log" ]; then
  # a ROUND line round.sh cannot read back is no record, and it is not passed over in silence: refused, naming it
  c_bad="$("$HERE/round.sh" --json "$c_log" 2>&1 > /dev/null | grep -m 1 '^round: line ')"
  [ -z "$c_bad" ] \
    || refuse "$c_logn ${c_bad#round: } - a round record is a ROUND line in the shape scripts/round.sh writes and reads back (round.sh --json): write it with scripts/round.sh, or correct it to that shape (state/README.md, \"The ROUND line\")"
  while IFS=$'\t' read -r c_id c_ty; do RR_ID+=("$c_id"); RR_TYPE+=("$c_ty"); done \
    < <("$HERE/round.sh" --json "$c_log" 2> /dev/null | LC_ALL=C sed -nE 's/^\{"id":"(([^"\\]|\\.)*)","phase":[0-9]+,"type":"([a-z-]+)",.*/\1\t\3/p')
fi
# a round the environment STOPPED (row 11b's note, `round <id> stopped`, read at the start of a note item) is spent - it
# counts toward the ceiling - and delivered nothing: it is not the last audit round
declare -A RR_STOPPED=()
for c_line in ${NOTE_LINES[@]+"${NOTE_LINES[@]}"}; do
  IFS=';' read -ra c_items <<< "${c_line//$'\302\267'/;}"
  for c_item in ${c_items[@]+"${c_items[@]}"}; do
    c_item="$(trim "$c_item")"
    if [[ $c_item =~ ^[-*+][[:space:]]+(.*)$ ]]; then c_item="${BASH_REMATCH[1]}"; fi
    if [[ $c_item =~ ^round[[:space:]]+([A-Za-z0-9._-]+)[[:space:]]+stopped([^A-Za-z0-9_]|$) ]]; then RR_STOPPED[${BASH_REMATCH[1]}]=1; fi
  done
done
rr_audit="" rr_model=0 rr_bb=""
for c_i in "${!RR_ID[@]}"; do
  case "${RR_TYPE[$c_i]}" in
    discovery | regression) [ -n "${RR_STOPPED[${RR_ID[$c_i]}]+x}" ] || rr_audit="${RR_ID[$c_i]}"; rr_model=$((rr_model + 1)) ;;
    black-box) rr_bb="${rr_bb:+$rr_bb, }${RR_ID[$c_i]}"; rr_model=$((rr_model + 1)) ;;
  esac
done
c_rwhere="the ROUND lines of $c_logn, scripts/round.sh writes one per round"
# the audit rounds recorded after the one last_audit_round names (all of them when it names none, or one not on record)
# that no `round <id> stopped` note names: when the environment stopped them (row 11b - a died attempt and its retry are
# two ROUND lines, two ids), each needs its note; the refusal names them
c_after=""
for c_i in "${!RR_ID[@]}"; do
  case "${RR_TYPE[$c_i]}" in discovery | regression) ;; *) continue ;; esac
  [ "${RR_ID[$c_i]}" != "${V[last_audit_round]}" ] || { c_after=""; continue; }
  [ -n "${RR_STOPPED[${RR_ID[$c_i]}]+x}" ] || c_after="${c_after:+$c_after, }${RR_ID[$c_i]}"
done
c_stopwhy=""
[ -z "$c_after" ] || c_stopwhy="; if the environment stopped them (row 11b), each attempt needs its own note, and these have none: $c_after (notes: round <id> stopped)"
if [ "${V[last_audit_round]}" = none ] && [ -n "$rr_audit" ]; then
  refuse "STATE says last_audit_round: ${RAW[last_audit_round]}; the record says $rr_audit (the newest discovery or regression round in $c_rwhere)$c_stopwhy"
elif [ "${V[last_audit_round]}" != none ] && [ "${V[last_audit_round]}" != "$rr_audit" ]; then
  refuse "STATE says last_audit_round: ${RAW[last_audit_round]}; the record says ${rr_audit:-none} (the newest discovery or regression round in $c_rwhere)$c_stopwhy"
fi
if [ -n "${V[ceiling.used]+x}" ] && [ "${V[ceiling.used]}" != "$rr_model" ]; then
  refuse "STATE says ceiling: ${RAW[ceiling]}; the record says $rr_model used (the discovery, regression and black-box rounds in $c_rwhere: every model round counts, doctrine/NEXT.md)"
fi
case "${V[blackbox]}" in
  current | stale) [ -n "$rr_bb" ] \
      || refuse "STATE says blackbox: ${RAW[blackbox]}; the record says none (no black-box round in $c_rwhere)" ;;
  never_run) [ -z "$rr_bb" ] \
      || refuse "STATE says blackbox: ${RAW[blackbox]}; the record says $rr_bb (a black-box round in $c_rwhere)" ;;
  stopped) case ", $rr_bb, " in *", ${V[blackbox.id]}, "*) ;;
      *) refuse "STATE says blackbox: ${RAW[blackbox]}; the record says ${rr_bb:-none} (the black-box rounds in $c_rwhere: ${V[blackbox.id]} is not one of them)" ;; esac ;;
esac
# bytecode_changed_since.last_audit_round=no: the anchor of src/ now, against the one round.sh wrote under that round's
# line. A round recorded before v0.5.3 has no such line: the flag is taken as written, and a note says so - never refused
ROUND_NOTE=""
if [ "${V[last_audit_round]}" != none ] && [ "${V[bytecode_changed_since.last_audit_round]}" = no ]; then
  c_key="$(LC_ALL=C awk -v p="src/ at round ${V[last_audit_round]}: " '{ sub(/\r$/, "") } index($0, p) == 1 { k = substr($0, length(p) + 1) } END { print k }' "$c_log")"
  if [[ $c_key =~ ^([0-9a-f]{64}|none)$ ]]; then
    [ "$c_key" = "$SRC_NOW" ] \
      || refuse "STATE says bytecode_changed_since.last_audit_round: no; the record says yes (src/ is ${SRC_NOW:0:8} now, ${c_key:0:8} when round ${V[last_audit_round]} was recorded: its line 'src/ at round ${V[last_audit_round]}: ...' in $c_logn)"
  else
    ROUND_NOTE="next: note - round ${V[last_audit_round]} has no 'src/ at round ${V[last_audit_round]}: <anchor>' line in $c_logn (recorded before v0.5.3, or by hand): bytecode_changed_since.last_audit_round=no is taken as written, not checked"
  fi
fi
# The reports' seals (v0.5.3): rep_ok <name> - 0 when .gauntlet/reports/<name> is a record: there, its seal matching it
# and made on the src/ there is now (scripts/lib/src-anchor.sh, report_check). REP_WHY says why not (empty: not there).
rep_ok() { local r=0; report_check "$PROJ/.gauntlet/reports/$1" "$SRC_NOW" || r=$?; REP_WHY="$RA_WHY"; return "$r"; }

# ------------------------------------------------------------------------------------------------ the phase against its records
# v0.4.1, D2: a walker wrote `phase: 2` seventeen minutes after `phase: 0`, by hand, while this script answered "row 4 -
# finish it" - and the hook never compiled. The kit cannot measure phase 1; it can measure the records a later phase
# claims. `phase:` 2 or higher (phase 2 OPEN, doctrine/NEXT.md) needs a green build record: the battery's,
# <proj>/.gauntlet/reports/01-build.txt (scripts/battery.sh tees `forge build` into it) - forge's own success line in it
# (`Compiler run successful`, with or without warnings, or `No files changed, compilation skipped`) and no `Compiler run
# failed`. The refusal names the way in - two walkers in a row read its earlier wording ("claims a compiling hook") as
# a loop: setup-deps.sh then battery.sh, which may run while phase 1 is open. `phase:` 3 or higher claims phase 2
# closed, and its gate includes a battery run: `battery: never` is refused. No escape: the records are one command away.
build_green() { # build_green <01-build.txt>: 0 when it is forge's record of a build that succeeded
  [ -f "$1" ] || return 1
  LC_ALL=C sed -e 's/\r$//' -e "s/$(printf '\033')\[[0-9;]*m//g" "$1" | LC_ALL=C awk '
    /Compiler run failed/ { bad = 1 }
    /^(\[[^]]*\] )?(Compiler run successful|No files changed, compilation skipped)/ { ok = 1 }
    END { exit (ok && !bad) ? 0 : 1 }'
}
if [ "${V[phase]}" != sketch ] && [ "${V[phase]}" -ge 2 ]; then
  { rep_ok 01-build.txt && build_green "$PROJ/.gauntlet/reports/01-build.txt"; } \
    || refuse "phase ${V[phase]} is open but there is no green build record (.gauntlet/reports/01-build.txt${REP_WHY:+ - $REP_WHY}): run $KIT/scripts/setup-deps.sh $PROJ then $KIT/scripts/battery.sh $PROJ (they may run at phase 1), or write the phase that is open"
  [ "${V[phase]}" -lt 3 ] || [ "${V[battery]}" != never ] \
    || refuse "phase ${V[phase]} claims phase 2 closed and battery is never: $KIT/scripts/battery.sh $PROJ, or write the phase that is open"
fi
# v0.4.2: the flags against their records (the header). The battery's test record, read by forge's own summary line
# (scripts/lib/parse.sh, parse_test_summary: "passed failed skipped total"), and phase 3's gate items for `phase:` 4+.
# shellcheck source=lib/parse.sh
. "$HERE/lib/parse.sh" || refuse "$HERE/lib/parse.sh is missing (forge's summary line, read in the battery's record)."
c_test="$PROJ/.gauntlet/reports/02-test.txt"
c_sum="" c_twhy=""
if rep_ok 02-test.txt; then c_sum="$(parse_test_summary "$c_test" 2> /dev/null)" || c_sum=""; else c_twhy="$REP_WHY"; fi
c_pass="" c_fail="" c_total=""
[ -z "$c_sum" ] || read -r c_pass c_fail _ c_total <<< "$c_sum"
if [ "${V[battery]}" = green ]; then
  if [ ! -f "$c_test" ] || [ -n "$c_twhy" ]; then c_why="there is no test record (.gauntlet/reports/02-test.txt${c_twhy:+ - $c_twhy})"
  elif [ -z "$c_sum" ]; then c_why="its test record (.gauntlet/reports/02-test.txt) has no summary of forge's: no test ran"
  elif [ "$c_fail" != 0 ]; then c_why="its test record (.gauntlet/reports/02-test.txt) says $c_fail test(s) FAILED"
  elif [ "$c_pass" = 0 ]; then c_why="its test record (.gauntlet/reports/02-test.txt) says 0 tests passed: no test ran"
  else c_why=""; fi
  [ -z "$c_why" ] || refuse "battery is green and $c_why: $KIT/scripts/battery.sh $PROJ, then write the battery flag its verdict gives"
fi
if [ "${V[phase]}" != sketch ] && [ "${V[phase]}" -ge 3 ] && { [ -z "$c_sum" ] || [ "${c_total:-0}" = 0 ]; }; then
  refuse "phase ${V[phase]} claims phase 2 closed and the battery's test record (.gauntlet/reports/02-test.txt${c_twhy:+ - $c_twhy}) shows no test ran - a battery that failed before its tests left only a build record: $KIT/scripts/battery.sh $PROJ, or write the phase that is open"
fi
if [ "${V[phase]}" != sketch ] && [ "${V[phase]}" -ge 4 ]; then
  # phase 3's gate (AGENTS.md section 3, NEXT.md row 4b): an invariant suite, a census, the fork question answered
  c_inv="$( { [ -d "$PROJ/test" ] && grep -rlE --include='*.sol' 'function[[:space:]]+invariant[A-Za-z0-9_]*[[:space:]]*\(' "$PROJ/test" 2> /dev/null; } | head -1)"
  [ -n "$c_inv" ] \
    || refuse "phase ${V[phase]} claims phase 3 closed and there is no invariant suite under $PROJ/test (no .sol file with a function invariant...()): write it on the kit's InvariantBase (QUICKSTART.md 7b), then $KIT/scripts/battery.sh $PROJ - or write the phase that is open"
  c_cen="" c_cwhy=""
  for c_f in 06-census.txt 06-census-gate.txt; do
    c_p="$PROJ/.gauntlet/reports/$c_f"
    if ! rep_ok "$c_f"; then [ -z "$REP_WHY" ] || c_cwhy="${c_cwhy:+$c_cwhy; }$REP_WHY"; continue; fi
    if [ -s "$c_p" ] && ! grep -q 'the campaign FAILED - no census' "$c_p"; then c_cen="$c_p"; break; fi
  done
  [ -n "$c_cen" ] \
    || refuse "phase ${V[phase]} claims phase 3 closed and there is no census report (.gauntlet/reports/06-census.txt or 06-census-gate.txt${c_cwhy:+ - $c_cwhy}): $KIT/scripts/census.sh $PROJ - or write the phase that is open"
  c_fork=""
  for c_line in ${NOTE_LINES[@]+"${NOTE_LINES[@]}"}; do
    IFS=';' read -ra c_items <<< "${c_line//$'\302\267'/;}"
    for c_item in ${c_items[@]+"${c_items[@]}"}; do
      c_item="$(trim "$c_item")"
      if [[ $c_item =~ ^[-*+][[:space:]]+(.*)$ ]]; then c_item="${BASH_REMATCH[1]}"; fi
      if [[ $c_item =~ ^fork: ]]; then c_fork=1; fi
    done
  done
  [ -n "$c_fork" ] \
    || refuse "phase ${V[phase]} claims phase 3 closed and the fork question is unanswered: write the note 'fork: <what ran against what exists, or n/a - no chain, no manager yet>' in STATE.md notes (NEXT.md row 4b) - or write the phase that is open"
  [ "${V[threat_model]}" != not_yet ] \
    || refuse "phase ${V[phase]} claims phase 3 closed and the independent threat model is not diffed (threat_model: not yet): a fresh agent writes $PROJ/.gauntlet/THREATS-independent.md from $KIT/briefs/threat-model.md, then $KIT/scripts/threat-diff.sh $PROJ - or write the phase that is open"
fi
# v0.5 (NEXT.md row 4b): `threat_model: diffed (...)` read against the files, the way scripts/threat-diff.sh reads them
# (scripts/lib/threats.sh) - the two lists, the refusals in the DECISIONS.md beside STATE.md, the /// @custom:threat
# tags in test/ and pending/. A list missing or not of its form, an independent threat neither matched, an invariant
# nor refused, or other counts than the line's: refused, naming it. Then the diff's report: it must be there, give the
# same line, and hash the two lists as they are now - the lists are frozen after the diff (a walker's threat written
# after reading the other list would count a threat the walker missed as one it had). No escape: the files are the record.
# shellcheck source=lib/threats.sh
. "$HERE/lib/threats.sh" || refuse "$HERE/lib/threats.sh is missing (the independent threat model against the walker's list)."
if [ "${V[threat_model]}" = diffed ]; then
  c_tmw="threat_model is diffed (${V[threat_model.counts]})"
  if [ "${V[phase]}" != sketch ] && [ "${V[phase]}" -ge 4 ]; then c_tmw="phase ${V[phase]} claims phase 3 closed, $c_tmw"; fi
  threats_diff "$PROJ" "$ST_DIR/DECISIONS.md"
  case "$TD_STATE" in
    diffed) [ "$TD_LINE" = "threat_model: diffed (${V[threat_model.counts]})" ] \
        || refuse "$c_tmw and the files give ${TD_LINE#threat_model: }: $KIT/scripts/threat-diff.sh $PROJ, then write the line it prints" ;;
    unmatched) refuse "$c_tmw and $TD_WHY - $KIT/scripts/threat-diff.sh $PROJ names them; until each is answered, write threat_model: not yet and the phase that is open" ;;
    *) refuse "$c_tmw and $TD_WHY: $KIT/scripts/threat-diff.sh $PROJ, then write the line it prints" ;;
  esac
  c_rep="$PROJ/.gauntlet/reports/06-threats.txt"
  rep_ok 06-threats.txt \
    || refuse "$c_tmw and there is no .gauntlet/reports/06-threats.txt (${REP_WHY:-the report threat-diff.sh writes, with the sha256 of the two lists it diffed}): re-run $KIT/scripts/threat-diff.sh $PROJ, then write the line it prints"
  for c_f in THREATS-independent.md THREATS.md; do
    c_h="$(LC_ALL=C awk -v p="sha256 .gauntlet/$c_f: " '{ sub(/\r$/, "") } index($0, p) == 1 { print substr($0, length(p) + 1); exit }' "$c_rep")"
    c_now="$(td_sha256 "$PROJ/.gauntlet/$c_f")"; c_hs="${c_h:0:8}"
    [ "$c_h" = "$c_now" ] \
      || refuse "$c_tmw and .gauntlet/$c_f is not the file threat-diff.sh diffed (sha256 ${c_now:0:8} now, ${c_hs:-none} in .gauntlet/reports/06-threats.txt); the lists are frozen after the diff: re-run $KIT/scripts/threat-diff.sh $PROJ, then write the line it prints"
  done
  c_h="$(LC_ALL=C awk '{ sub(/\r$/, "") } /^the line for STATE\.md[^:]*: / { sub(/^the line for STATE\.md[^:]*: /, ""); print; exit }' "$c_rep")"
  [ "$c_h" = "threat_model: diffed (${V[threat_model.counts]})" ] \
    || refuse "$c_tmw and .gauntlet/reports/06-threats.txt does not give it (the line it gives: ${c_h:-none}): re-run $KIT/scripts/threat-diff.sh $PROJ, then write the line it prints"
  # v0.5.1: a threat handed to the model round is answered after it - the finding it produced (`became: <id>` under its
  # handed line) or `handed: audit`. Once a round has run, phase 4 or higher with one unanswered is refused, naming the
  # threats and the two answers - never the phase: no phase is written back to reach the dossier
  if [ -n "$TD_HOPEN" ] && [ "${V[last_audit_round]}" != none ] && [ "${V[phase]}" != sketch ] && [ "${V[phase]}" -ge 4 ]; then
    refuse "phase ${V[phase]}, round ${V[last_audit_round]} has run, and the independent threat(s) handed to it have no answer: $TD_HOPEN (T-<n>: handed: round in .gauntlet/THREATS.md). Under each handed line write became: <the finding's id> - the finding the round produced from it - or change it to handed: audit (to the human audit, by name: the dossier's 5b lists it as untested); then $KIT/scripts/threat-diff.sh $PROJ, and write the line it prints (its counts stay the same)"
  fi
fi

# ------------------------------------------------------------------------------------------------ pending/ and the notes
# NEXT.md row 6b: a phase-3 test that shows the code breaking a promise, the owner absent, goes to pending/<id>.t.sol,
# OUTSIDE test/, so that the battery is honestly green - and the finding goes into open_findings and a note `pending:
# <id> - <promise>, owner undecided`. A test moved there and never written down is a red test hidden from the battery
# and from the route alike. So, before any row (K31): the project is the STATE.md's directory, or its parent when that
# directory is .gauntlet/; with a pending/ there, every file row 6b's profile would run needs its note and every id of a
# pending: note its file (ids compared case aside, as everywhere here). No pending/, nothing is checked. A note is read
# by its name at the START of a note item, like real manager: above.
# What the profile runs (`[profile.pending] test = "pending"`, forge 1.8.1, measured - K31b): every .sol file below
# pending/, in subdirectories, without .t, hidden (.F-5.t.sol) or in a hidden directory - so each is read here, its id
# the file's name without .t.sol or .sol (and without a leading dot). pending/ is matched case-sensitively, as forge
# matches it. A note may name several ids: `pending: F-4, F-5 - ...` (commas, `and`, `&` or spaces between them; the
# list ends at the first word that is not an id - at least one letter and one digit - such as the ` - ` before the
# promise), and each needs its file.
pending_ids() { # pending_ids <the text after pending:>: its ids, one per line; exit 1 when the first word is not an id
  local rest="$1" tok first=1 re_comma='^[[:space:]]*,[[:space:]]*((and|[&])[[:space:]]+)?(.*)$' re_amp='^[[:space:]]*[&][[:space:]]*(.*)$'
  while :; do
    rest="${rest#"${rest%%[![:space:]]*}"}"
    tok=""
    if [[ $rest =~ ^([A-Za-z0-9][A-Za-z0-9._-]*)(.*)$ ]]; then tok="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"; fi
    while [[ $tok =~ ^(.+)[._-]$ ]]; do tok="${BASH_REMATCH[1]}"; done   # `pending: F-1. ...`
    if ! [[ $tok =~ [A-Za-z] && $tok =~ [0-9] ]]; then [ "$first" = 1 ] && return 1; return 0; fi
    printf '%s\n' "$tok"; first=0
    if [[ $rest =~ $re_comma ]]; then rest="${BASH_REMATCH[3]}"
    elif [[ $rest =~ $re_amp ]]; then rest="${BASH_REMATCH[1]}"
    elif [[ $rest =~ ^[[:space:]]+and[[:space:]]+(.*)$ ]]; then rest="${BASH_REMATCH[1]}"
    elif [[ $rest =~ ^[[:space:]]+(.*)$ ]]; then rest="${BASH_REMATCH[1]}"
    else return 0; fi
  done
}
check_pending() {
  local st_dir proj f id ids key line item re_pend='^pending:(.*)$'
  local -a items=() order=()
  local -A note=() file=()
  st_dir="$(cd "$(dirname "$1")" && pwd)" || refuse "cannot read the directory of $1."
  if [ "$(basename "$st_dir")" = ".gauntlet" ]; then proj="$(dirname "$st_dir")"; else proj="$st_dir"; fi
  [ -d "$proj/pending" ] || return 0
  # a directory named *.sol is not a test: the walk below sees files only, so it is refused here (K48)
  f="$(pending_sol_dirs "$proj" | head -1)"
  [ -z "$f" ] || refuse "$proj/$f is a directory: a test in pending/ is a file, pending/<id>.t.sol (NEXT.md row 6b) - move what is in it out, or rename it."
  for line in ${NOTE_LINES[@]+"${NOTE_LINES[@]}"}; do
    IFS=';' read -ra items <<< "${line//$'\302\267'/;}"
    for item in ${items[@]+"${items[@]}"}; do
      item="$(trim "$item")"
      if [[ $item =~ ^[-*+][[:space:]]+(.*)$ ]]; then item="${BASH_REMATCH[1]}"; fi
      [[ $item =~ $re_pend ]] || continue
      ids="$(pending_ids "${BASH_REMATCH[1]}")" \
        || refuse "notes: a pending: note names no id ('$item'): pending: <id>[, <id>...] - <promise>, owner undecided - NEXT.md row 6b."
      while IFS= read -r id; do
        [ -n "${note[${id,,}]+x}" ] || order+=("${id,,}")
        note[${id,,}]="$id"
      done <<< "$ids"
    done
  done
  while IFS= read -r -d '' f; do
    id="$(basename "$f")"; id="${id%.sol}"; id="${id%.t}"; while [ "${id#.}" != "$id" ]; do id="${id#.}"; done
    file[${id,,}]="$id"
    [ -n "${note[${id,,}]+x}" ] \
      || refuse "$f is a test in pending/, and STATE.md's notes have no 'pending: $id ...' for it: write it in STATE.md notes and in open_findings before anything else - NEXT.md row 6b."
  done < <(find -L "$proj/pending" -name '*.sol' -type f -print0 2> /dev/null | LC_ALL=C sort -z)
  for key in ${order[@]+"${order[@]}"}; do
    [ -n "${file[$key]+x}" ] \
      || refuse "STATE.md's notes name 'pending: ${note[$key]}', and $proj/pending/${note[$key]}.t.sol does not exist (nor any ${note[$key]}.sol below pending/): a pending finding's test is pending/<id>.t.sol - put it there, or, if the finding is closed, take the note out and the finding out of open_findings - NEXT.md row 6b."
  done
}
# shellcheck source=lib/pending-record.sh
. "$HERE/lib/pending-record.sh" || refuse "$HERE/lib/pending-record.sh is missing (the pending/ red records)."
check_pending "$STATE"

# ------------------------------------------------------------------------------------------------ pending/: seen red (K41)
# A test in pending/ is a finding's test only once it has been seen RED on src/ as it stands (EVIDENCE.md section 2):
# scripts/pending-red.sh runs it under row 6b's profile and, when it is red, writes the record this reads
# (scripts/lib/pending-record.sh: keyed by the SHA-256 of the file list and contents of src/, test/, pending/,
# foundry.toml and remappings.txt, so an edit to any of them leaves no current record - but a permission-bits record,
# current while src/ and its own file are as recorded, v0.4.2; a stale one is refused saying which part changed since,
# from the record's own `keyed:` line). the local-model walk's judge:
# the one pending test of the local-model walk did not compile, and mended it PASSED on the planted code; DECISIONS.md
# called it red. The first file with no current record is refused. A current record is READ (K48: an empty file with
# the key's name was taken - V40): its first line must be `pending-red: red <file> key=<key> <date>`, for that file and
# the key its name carries; an empty or handwritten one is "unreadable". PENDING_RED=0 lets them through, says so on
# stderr (above), and writes down what it let through (escape_used, below) - the refusal never names it (v0.4.2).
# escape_used <the variable> <what it let through>: one line, its own paragraph, in the LOG.md beside STATE.md, and on
# stderr (the header: a used escape)
escape_used() {
  local logf="$ST_DIR/LOG.md" entry
  entry="$(date +%F) next.sh ran with $1=0, an escape: it let through $2 - not checked here (the owner reads this line, and the dossier carries it)"
  if [ -e "$logf" ] && [ ! -f "$logf" ]; then echo "next: $1=0 let through $2 - and $logf is not a file: nothing written down" >&2; return 0; fi
  if [ -s "$logf" ] && [ -n "$(tail -c 1 "$logf")" ]; then printf '\n' >> "$logf"; fi
  if [ -s "$logf" ] && [ -n "$(tail -n 1 "$logf")" ]; then printf '\n' >> "$logf"; fi
  if printf '%s\n' "$entry" >> "$logf" 2> /dev/null; then echo "next: $1=0 let through $2 - written down in $logf" >&2
  else echo "next: $1=0 let through $2 - and $logf could not be written" >&2; fi
}
c_let=""
while IFS= read -r c_f; do
  [ -f "$PROJ/$c_f" ] || continue
  # current: on the full key, or a permission-bits record on its own (src/ and the file as recorded: pending-record.sh)
  pending_record_current "$PROJ" "$c_f" && continue
  case "$PR_STATE" in
    unreadable) c_msg="next: REFUSED - $c_f: record unreadable - run scripts/pending-red.sh again ($KIT/scripts/pending-red.sh $PROJ $c_f)"; c_why="record unreadable" ;;
    stale) c_msg="next: REFUSED - $c_f - not seen red on the code as it stands ($PR_WHY): $KIT/scripts/pending-red.sh $PROJ $c_f"; c_why="not seen red on the code as it stands: $PR_WHY" ;;
    *) c_msg="next: REFUSED - $c_f - not seen red on the code as it stands: $KIT/scripts/pending-red.sh $PROJ $c_f"; c_why="not seen red on the code as it stands" ;;
  esac
  if [ "${PENDING_RED-}" = 0 ]; then c_let="${c_let:+$c_let, }$c_f ($c_why)"; continue; fi
  echo "$c_msg" >&2
  exit 2
done < <(pending_files "$PROJ")
[ -z "$c_let" ] || escape_used PENDING_RED "$c_let"

# ------------------------------------------------------------------------------------------------ cited files exist (K41)
# A file the route's own record cites must exist (the local-model walk's judge: DECISIONS.md cited five tests in pending/ and a fork test
# that never existed). Read: STATE.md, and the DECISIONS.md beside it - not LOG.md: a LOG is history, and a file it
# names may have been moved or deleted since, legitimately (K47). A citation is a path under the
# project that starts `pending/`, `test/`, `src/` or `.gauntlet/reports/` (after `./` too), not inside a longer path,
# whose last part has an extension - a file, not a directory. Not a citation: a path inside a fenced code block (in
# STATE.md the flag block's `pending:` notes are read all the same), one after `to write`, `planned` or `TODO` on the
# same line (any case), one followed by `*`, `?`, `<`, `{` or `[` (a pattern, a placeholder), one with `..` in it (a
# range, `pending/F-1..F-4.t.sol`: FR16's LOG.md). The first that is a non-empty regular file neither from the
# project's directory nor in one of its benches (.gauntlet/bench/<name>/: a verifier's `test/verify/V01.t.sol` in its
# bench, A/B round 3) is refused, saying whether it does not exist, is empty or is a directory (K48: a 0-byte
# test/fork/Fork.t.sol, or a directory by that name, passed as "exists" - V40). CITED_FILES=0 lets them through, says
# so on stderr (above), and writes down what it let through (escape_used) - the refusal never names it (v0.4.2).
cited_paths() { # cited_paths <file> <1 when it is STATE.md>: "<line number> TAB <path>" per citation
  LC_ALL=C awk -v isstate="$2" '
    { sub(/\r$/, "") }
    /^ ? ? ?(```|~~~)/ { fence = !fence; next }
    {
      line = $0
      if (fence) {
        if (isstate != 1 || !match(line, /(^|[^A-Za-z0-9_-])pending:/)) next
        line = substr(line, RSTART)
      }
      low = tolower(line)
      if (match(low, /(^|[^a-z])(to write|planned|todo)([^a-z]|$)/)) line = substr(line, 1, RSTART)
      rest = line
      while (match(rest, /(^|[^A-Za-z0-9_.\/-])(\.\/)?(pending|test|src|\.gauntlet\/reports)\/[A-Za-z0-9_.@+\/-]*/)) {
        tok = substr(rest, RSTART, RLENGTH); after = substr(rest, RSTART + RLENGTH, 1)
        rest = substr(rest, RSTART + RLENGTH)
        sub(/^[^A-Za-z0-9_.\/-]/, "", tok); sub(/^\.\//, "", tok)
        if (after ~ /[*?<{[]/ || tok ~ /\.\./) continue
        while (tok ~ /[.-]$/) tok = substr(tok, 1, length(tok) - 1)
        n = split(tok, part, "/")
        if (part[n] !~ /[^.]\.[A-Za-z0-9]+$/) continue
        print NR "\t" tok
      }
    }' "$1"
}
c_let=""
for c_f in "$STATE" "$ST_DIR/DECISIONS.md"; do
  [ -f "$c_f" ] || continue
  c_is=0; [ "$c_f" != "$STATE" ] || c_is=1
  while IFS=$'\t' read -r c_n c_p; do
    # a non-empty regular file (K48: an empty file or a directory at the cited path passed as "exists" - V40) - and a
    # report under .gauntlet/reports/ with a seal beside it, the report its seal sealed (v0.5.3; history: not currency)
    if [ -f "$PROJ/$c_p" ] && [ -s "$PROJ/$c_p" ]; then
      case "$c_p" in .gauntlet/reports/*) [ -f "$PROJ/$c_p.sha256" ] && ! report_check "$PROJ/$c_p" - && c_what="is not a record ($RA_WHY)" || continue ;;
        *) continue ;; esac
    else
      c_what=""
    fi
    c_hit=""   # a path written relative to a bench named on its line (`.gauntlet/bench/v01`, `test/verify/V01.t.sol`)
    [ -n "$c_what" ] || for c_b in "$PROJ"/.gauntlet/bench/*/; do [ -f "$c_b$c_p" ] && [ -s "$c_b$c_p" ] && { c_hit=1; break; }; done
    [ -z "$c_hit" ] || continue
    if [ -n "$c_what" ]; then :
    elif [ -d "$PROJ/$c_p" ]; then c_what="is a directory"
    elif [ -f "$PROJ/$c_p" ]; then c_what="is empty"
    elif [ -e "$PROJ/$c_p" ]; then c_what="is not a regular file"
    else c_what="does not exist"; fi
    if [ "${CITED_FILES-}" = 0 ]; then c_let="${c_let:+$c_let, }$c_p (cited by $(basename "$c_f") line $c_n; it $c_what)"; continue; fi
    echo "next: REFUSED - $(basename "$c_f") cites a file that $c_what: $c_p (line $c_n of $c_f)" >&2
    exit 2
  done < <(cited_paths "$c_f" "$c_is")
done
[ -z "$c_let" ] || escape_used CITED_FILES "$c_let"

# ------------------------------------------------------------------------------------------------ the table, top to bottom
# The gates first (NEXT.md: a gate that is true turns its rows off wherever they stand - row 14's are above it), then
# the rows in order, a row turned off by a gate in force being false.
declare -A OFF=()
for id in "${IDS[@]}"; do
  [ "${KIND[$id]}" = gate ] || continue
  cond_true "${COND[$id]}" || continue
  for x in ${OFFS[$id]//,/ }; do OFF[$x]="$id"; done
done
# The lines before the answer - gates in force, rows that need judgement - are kept in order and printed with it.
declare -a SAID=()
pending=""
said() { local x; for x in ${SAID[@]+"${SAID[@]}"}; do printf '%s\n' "$x"; done; }   # the lines kept so far, in order
# because <why>: the because: line of what is given - with the trace of a row 1 the flags quieted (the ids that did)
# divergence_note (v0.5.1): on the rows that write the dossier (9b, 18, 18b), the environment divergences the owner
# stated - the DECISIONS.md headings `## <id> · <YYYY-MM-DD> · divergence: <what>` (briefs/owner-interview.md 17c) - for
# the dossier's section 8 row "environment divergences stated by the owner"; none: "none stated". A heading that names a
# divergence in another shape is named, not read.
divergence_note() {
  local dec="$ST_DIR/DECISIONS.md" got="" odd=""
  if [ -f "$dec" ]; then
    got="$(LC_ALL=C awk '{ sub(/\r$/, "") } /^##[ \t]+[A-Za-z0-9][A-Za-z0-9._-]*[ \t]+·[ \t]+[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ \t]+·[ \t]+divergence:[ \t]*[^ \t]/ {
        s = $0; sub(/^##[ \t]+/, "", s); id = s; sub(/[ \t].*$/, "", id); d = s; sub(/^[^·]*·[ \t]+/, "", d); dt = substr(d, 1, 10)
        w = s; sub(/^.*divergence:[ \t]*/, "", w); out = out (out == "" ? "" : "; ") id " (" dt "): " w }
      END { printf "%s", out }' "$dec")"
    odd="$(LC_ALL=C awk '{ sub(/\r$/, "") } /^#/ && tolower($0) ~ /divergence/ && $0 !~ /^##[ \t]+[A-Za-z0-9][A-Za-z0-9._-]*[ \t]+·[ \t]+[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ \t]+·[ \t]+divergence:[ \t]*[^ \t]/ { out = out (out == "" ? "" : ", ") NR }
      END { printf "%s", out }' "$dec")"
  fi
  if [ -n "$got" ]; then echo "next: note - environment divergences stated by the owner (DECISIONS.md, ## <id> · <date> · divergence: <what>): $got - the dossier's section 8 row \"environment divergences stated by the owner\" carries each"
  else echo "next: note - environment divergences stated by the owner (DECISIONS.md, ## <id> · <date> · divergence: <what>): none stated - the dossier's section 8 row \"environment divergences stated by the owner\" says \"none stated\""; fi
  [ -z "$odd" ] || echo "next: note - DECISIONS.md line(s) $odd name a divergence in another shape than ## <id> · <YYYY-MM-DD> · divergence: <what>, and are not read"
  # an anchor the walker signed, the owner absent (init-state.sh --by walker): a divergence the dossier's section 8 carries
  local c_w
  for c_w in spec.sha256 src.sha256; do
    if [ -f "$PROJ/.gauntlet/$c_w" ] && grep -qx 'by: walker (owner absent)' "$PROJ/.gauntlet/$c_w"; then
      echo "next: note - .gauntlet/$c_w says by: walker (owner absent): the walker signed that anchor, not the owner - the dossier's section 8 carries it as a divergence (\"anchor signed by the walker, the owner absent\")"
    fi
  done
}
because() { local w="$1"; [ -z "$ROW1_QUIET" ] || w="${w:+$w; }$ROW1_QUIET"; echo "because: ${w:-the row holds whatever the flags say}"; }
# paused <why>: NEXT.md row 3, "if none, stop and say what is waiting" - the end of the route with the owner absent (after
# row 9b's skeleton, typically). A distinct first word, STOP, so that a caller walking the rows can tell it from one.
# Given ONLY when it is true: while a row still needs judgement nothing is given - the questions, and one line saying
# what an all-false answer gives (V26: "next: STOP" and "no row below row 3 stands" were printed while rows 5, 8, 9,
# 10 - or the black-box, below the ceiling - were still to judge).
paused() {
  said
  if [ -n "$pending" ]; then
    [ -z "$JUDGED" ] || echo "judged: $JUDGED"
    echo "if every answer is false: STOP - paused, waiting on the owner: ${V[waiting_on_owner]}"
    exit 3
  fi
  echo "next: STOP - paused, waiting on the owner: ${V[waiting_on_owner]}"
  because "$1"
  [ -z "$JUDGED" ] || echo "judged: $JUDGED"
  exit 0
}
for id in "${IDS[@]}"; do
  [ -z "${OFF[$id]+x}" ] || continue
  cond_true "${COND[$id]}" || continue
  why="$COND_WHY"
  if [ "${ASK[$id]}" != "-" ]; then
    q="${ASK[$id]//\{waiting_on_owner\}/${V[waiting_on_owner]}}"; q="${q//\{highs_not_recorded\}/$HIGHS_NOT_RECORDED}"
    q="${q//\{dossier_names\}/${SHOW_NOTE[dossier.lists_open]:-dossier: ${V[dossier]}}}"
    case "${JUDGE[$id]:-}" in
      false) continue ;;
      true) why="${why:+$why; }judged true: $q" ;;
      *) SAID+=("needs judgement: row $id - $q"); pending="${pending:+$pending,}$id"; continue ;;
    esac
  fi
  if [ "${KIND[$id]}" = gate ]; then SAID+=("in force: row $id - ${ACTION[$id]}" "  because: $why"); continue; fi
  # row 3 true: its action - the pause - is taken only when no row below stands (after the loop), never here: the rows
  # below are read on, and the first that stands is given (V26b: taken here on 3=true, the pause hid rows 6 and 9b)
  [ "$id" != 3 ] || continue
  said
  echo "next: row $id - ${ACTION[$id]}"
  because "$why"
  [ -z "$JUDGED" ] || echo "judged: $JUDGED"
  case "$id" in 9b | 18 | 18b) divergence_note ;; esac   # the rows that write the dossier (v0.5.1)
  if [ -n "$pending" ]; then
    echo "only if every row that needs judgement above is false (rows $pending): answer them with --judge <row>=true|false."
    exit 3
  fi
  exit 0
done
# No row below stands on the flags. With the owner absent that is row 3's end, not a hole: "take the first [row] that
# does not [depend on the answer]; if none, stop and say what is waiting" (NEXT.md) - decided by the flags (row 3 is
# never answered), and given only once no row is left to judge (paused). The because line says what stood last: the
# skeleton that names the open findings (row 9b done), and the wait that turned 7b off (and 12 and 16 with it).
if [ "${V[waiting_on_owner]}" != none ]; then
  why="waiting_on_owner=${V[waiting_on_owner]}, and no row below row 3 stands"
  if [ "${V[open_findings.total]}" -gt 0 ] && [ "${V[dossier.lists_open]}" = yes ]; then
    why="$why; the dossier names the ${V[open_findings.total]} open finding(s) (dossier=${V[dossier]}: row 9b is done)"
  fi
  if [ "${V[waiting_on_owner.real_manager]}" = yes ] && [ "${V[real_manager.owed]}" = yes ]; then
    why="$why; row 7b waits on that answer (an item names RPC_URL or is the chain question), rows 12 and 16 wait on 7b (real_manager_battery=${V[real_manager_battery]})"
  fi
  paused "$why - stop and say what is waiting; run this again when the owner has answered"
fi
said
[ -z "$JUDGED" ] || echo "judged: $JUDGED"
if [ -n "$pending" ]; then
  echo "no row below them is true on the flags alone: if every row that needs judgement (rows $pending) is false, no row is true: the table has a hole or a flag is stale."
  exit 3
fi
echo "no row is true: the table has a hole or a flag is stale"
exit 1
