# The state convention

Three files, installed in **the owner's project**, not in this repository. Any agent that arrives with no context
reads them and continues.

```
STATE.md        where we are, what is open, what blocks it     - rewritten in place
DECISIONS.md    one entry per owner decision, with the reason  - append only
LOG.md          one entry per change                           - append only
```

## Installing

Copy the three files into the project (a `.gauntlet/` directory works well, or the project root), then **empty the
examples**. Copy `state/.gitignore` into `<project>/.gauntlet/` too, wherever the three files go: the benches live in
`<project>/.gauntlet/bench/` (`scripts/bench.sh`, `fuzz-long.sh`, `mutate.sh`: inside the project, never `$HOME` - and
only once `.gauntlet/` exists: in a tree without it the scripts refuse and ask for `BENCH_ROOT` outside it), and it
keeps them out of git while the state files and reports stay committable. The examples in this directory describe a fictional hook called `BlockCapHook`, which caps how much
one address may swap per block and charges a surcharge above a threshold. It does not exist. Delete it.

## The rules that make it work

1. **`LOG.md` is for changes.** Reading something is not a log entry. If a session changed nothing, it writes
   nothing. This keeps the log readable, which is the only reason anyone will read it.
2. **Write incrementally.** An agent that dies on a rate limit halfway through a round should lose nothing. Open
   the report and update the state as you go, not at the end.
3. **Separate what you measured from what you inferred.** Every entry ends with **what was not checked yet**. That
   line is the most useful one in the file and the first to be dropped by anyone wanting to look finished.
4. **Numbers are read from outputs**, in that session, never from memory and never copied from another document.
5. **If the files and the repository disagree, the repository wins** and you fix the files.

## Where the route is: `scripts/next.sh`

The flag block at the top of `STATE.md` is what `doctrine/NEXT.md` reads, and the table is taken top to bottom. Walking
~25 rows by hand, a mistyped value (`battery: gren`) or a flag left out is read as whatever the reader guesses. So:

```sh
scripts/next.sh .gauntlet/STATE.md
scripts/next.sh .gauntlet/STATE.md --judge 5=false,8=false,12=true    # the answers to the rows that need judgement
```

It refuses (exit 2, one line naming the flag) a flag that is missing, a value not on the flag's list, a line of the
block that is not `name: value`, a `ceiling` of no known shape (`not agreed ...`, `undecided ...`, or `N model rounds
...; M used`), a `rehearsal: done` without a real date (`done (YYYY-MM-DD)`), a `blackbox: stopped` without its round
id (`stopped (<round id>)`), more `reasoned_high_or_medium` than high + medium open, a `dossier: skeleton` that does
not say how many open findings it names (`skeleton (<K> open, <N> judges not done)`), an item of `waiting_on_owner`
that says "to tell" in any shape but `high <id>[, <id>...] - to tell` or names a placeholder there (`none`, `TBD`,
`nobody`, `n/a`, `?`), an id recorded to tell that is not an open high ("a recorded high is no longer open: remove it"), and an `open_findings` whose
high count does not match the ids in its parentheses (`high=N (<ids>)`; no parentheses when N is 0).
Then it prints the first true row: `next: row <id> - <the action, as NEXT.md words it>` and `because:`
the flags that made it true (exit 0). With the owner absent, nothing below row 3 standing AND no row left to judge -
typically once row 9b's skeleton names the open findings, `waiting_on_owner` asks for their triage, and rows 5, 8, 9, 10
are answered false - it prints `next: STOP - paused, waiting on the owner: <items>` (exit 0; STOP, not `row`, so that
a caller walking the rows can tell the end of the route with the owner absent from a row): decided by the flags, not
asked; run it again when the owner has answered. While a row still needs judgement it does not print that: exit 3, the
questions, and one line, `if every answer is false: STOP - paused, waiting on the owner: <items>` - answer them and run
it again. No row true and nothing waiting on the owner: `no row is true: the table has a hole or a flag is stale`
(exit 1, NEXT.md's STOP rule: say which in `STATE.md` and ask - do not change a flag to get moving).

Row 1 is quiet by the flags in one case only: the owner absent, and every id of the open highs - `open_findings:
high=N (<ids>)` - is in an item `high <id>[, <id>...] - to tell` of `waiting_on_owner` (commas or spaces, case aside,
each once; an id there that is not an open high is refused) - then the `because:` line of whatever is given names those ids. Otherwise, with a high open, it is a question
(the owner present: answer `--judge 1=false` once they have been told; a `told:` note is not read). Row 9b is quiet once
the dossier names the open findings: `skeleton (<K> open, ...)` with K the number open (high + medium + low;
informational findings are not counted); `complete` next to an open finding is refused. What the flags cannot decide is not guessed. Rows 1 (a high
open, not every one recorded to tell), 5, 8, 9 and 9b (a finding open, from any round, once round 1 has run or the ceiling is reached), 10 (after a round, with no bytecode change since),
11b, 12 (did the spec's promises change?), 16 and 18b
need something `STATE.md` does not carry, and are printed `needs judgement: row <id> - <the question>`; the row after
them is printed as the answer only if they are all false (exit 3). Answer with `--judge <row>=true|false`: the answers
are printed back, so the judgement is on the record. Row 3 is decided by the flags and never answered (`--judge 3=...`
is refused: an answer `true` once gave the pause over rows the flags made true below it): answer `false` each row below
that depends on the owner's answer (row 7b, decided by the flags, is off by itself while
`waiting_on_owner` asks for the endpoint or the chain - an item that contains `RPC_URL`, or that IS the chain question:
`chain`, or an item starting with the word `chain`, `target chain` or `which chain`, in any case - `chain-id`, `chain_id`
and `chains` are other words; `off-chain`, `cross-chain` or the word inside
a triage or a severity question do not count; rows 12 and 16 are off
while 7b is owed, so when the wait silences 7b and no other row stands, the route pauses: `next: STOP - paused, ...`).
A note is read by its name only at the start of a note item (a note line, or a part of one after `·` or `;`, a Markdown
list marker `- `, `* ` or `+ ` before it allowed): `real manager:` for row 7b. A ceiling the
operator set with the owner absent is read in one form only, `<N> model rounds, set by the operator (owner absent); <M>
used` (`doctrine/COST.md` 1); "operator" in any other shape or case is refused, never read as the owner's. Two rows are gates, not destinations (`NEXT.md`): when true they are
printed `in force`, the rows they name are off wherever they stand, and the reading goes on - row 2 (ceiling reached)
turns off every model row (11, 11b, 12, 13, 13b, 15), row 14 (the loop is over) turns off 11, 12, 13 and 13b (not 11b:
a stopped round still gets its one retry).

The rows are data inside `next.sh`: a new row of `NEXT.md` is one line there, and every run checks the two against each
other (`scripts/next.sh --check-table`): every row of the table is read, whatever the form of its id (`12`, `12b`,
`12a`), and a row in one and not the other, the same rows in another order, or a row whose condition cell in `NEXT.md`
is no longer the text its line in `next.sh` was written from (each line keeps a hash of the cell, whitespace
normalised), is a refusal naming the row. `--check-table` then prints the cell's new hash: re-read the row, make the
line say the same, and paste the hash - never the hash alone. Inside the table every non-blank line must be a row, `|`
at column 0 and four cells: an indented row, a row without its leading `|` (Markdown shows both in the table) or a line
of prose there is a refusal naming the line, so no row can hide from the guard.

## The ROUND line

There used to be a fourth file, a machine-readable record of every round. Nothing ever read it, and three reviewers
independently called four state files bureaucracy that an agent maintains instead of working. It is now ONE LINE at the
top of the `LOG.md` entry that closes a round, in a fixed shape so that `grep '^ROUND ' LOG.md` is the history:

```
ROUND r05 | phase 4 | regression | vendor-a/large | bench .gauntlet/bench/a05 | 2026-03-09..2026-03-12 | 0H 1M 4L 7I reasoned 0 | gate pass | 230k tokens, 95 min, 41 files read, 6 tests written | reports/r05.md | conf 0.7
```

Fields, in order: id · phase · type (`interview`, `spec`, `battery`, `discovery`, `regression`, `black-box`, `verifier`,
`executor`, `promotion`, `rehearsal`, `handoff`, `simulation`) · model, as specific as you can be · bench · dates · findings AS THE ROUND
CLASSIFIED THEM, with REASONED high/medium counted apart · did the gate pass (discovery and regression: the phase-4 gate, zero high and zero medium open; black-box: no divergence left; verifier: every claim held; an interview, spec or battery line: that phase's gate in `AGENTS.md` §3; an interview played from the owner's files with the read-back pending: `gate pass (read-back pending)` - a real state, not a pass with a footnote: the owner was absent, every question has an answer or an explicit "undecided" from their files, and nobody has yet read the scope and the non-goals back to them; the route continues, the pending item is in `waiting_on_owner` (`read-back of scope`), nothing in phases 6-8 closes without it (`briefs/owner-interview.md`), and the dossier says so in section 8. `scripts/round.sh` writes it for `--type interview` only, and refuses any other wording) · cost AND effort (tokens, wall-clock,
files read, tests written; leave out what you cannot measure, never guess - an orchestration harness does not always
return a subagent's usage, and then the field says `cost not measured`, what `scripts/round.sh` writes when no cost
field is given) · the report · and, optionally,
`conf` - the raw_confidence, 0 to 1: what the round's author would bet on its own verdict. Unused by any policy today;
it is there so that one day a verdict can be weighed against how often its author was right. The effort fields exist for one
reason: the loop ends on a discovery round after which zero high and zero medium findings are still open (`NEXT.md` row
14), and a round that found nothing because it did not look has the same findings line as one that looked hard. The effort line is how the two are told apart. What the OWNER decided about the findings goes in `DECISIONS.md`, not here.

It costs nothing to write, and after a few rounds it is what lets you choose the next one from history instead of by
feel: which kind of round finds the most per token, at which phase, on which model.

### Writing it, and reading it back: `scripts/round.sh`

Type the line by hand and it drifts - a type that is not on the list, `1-2` where a count goes, `03-12` for a date, a
field left out so that every field after it moves one place - and nobody notices until the history is read. So write it
with the script, from named arguments; it checks each one and refuses (exit 2, nothing written) a malformed line:

```sh
scripts/round.sh .gauntlet/LOG.md --id r05 --phase 4 --type regression --model "vendor-a/large" --bench .gauntlet/bench/a05 \
  --dates 2026-03-09..2026-03-12 --high 0 --medium 1 --low 4 --info 7 --reasoned 0 --gate pass \
  --tokens 230k --minutes 95 --files-read 41 --tests-written 6 --report reports/r05.md --conf 0.7
scripts/round.sh --json .gauntlet/LOG.md      # the history, one JSON object per ROUND line
```

What a stranger hits: the LOG.md must exist (the script never creates one); dates are ISO in full, both ends
(`2026-03-09..03-12` is refused - write `2026-03-09..2026-03-12`); an id already in the file is refused, so a
second attempt at a round gets its own id (`r05b`); the cost fields and `--conf` are optional and a round with none
says `cost not measured`, never a zero; the line is appended at the END of the file as its own paragraph, so run it
FIRST, when you open the entry that closes the round, and write the entry's heading and prose UNDER the ROUND line (the
example `LOG.md` shows the order); `--dry-run` prints the line and writes
nothing, for pasting into an entry you have already written. `--json` is a VIEW computed from the ROUND lines each
time it runs, never a stored file: a ROUND line typed by hand in another shape is named on stderr (exit 1) and left
out, and the others are printed.

### Conventions worth keeping

- A round that died on a rate limit still gets its ROUND line, with `gate fail` and a note. Rounds that vanish make
  the history lie about how expensive the method is.
- A finding with no reproducing test is **REASONED**: count it apart (`reasoned N` in the ROUND line,
  `reasoned_high_or_medium` in `STATE.md`), never mixed with the tested ones and never dropped. It blocks the exit until it is
  tested, answered by the owner in writing, or handed to the human audit by name (`doctrine/EVIDENCE.md` 3).
