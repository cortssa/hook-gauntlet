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
examples**. The examples in this directory describe a fictional hook called `BlockCapHook`, which caps how much
one address may swap per block and charges a surcharge above a threshold. It does not exist. Delete it.

## The rules that make it work

1. **`LOG.md` is for changes.** Reading something is not a log entry. If a session changed nothing, it writes
   nothing. This keeps the log readable, which is the only reason anyone will read it.
2. **Write incrementally.** An agent that dies on a rate limit halfway through a round should lose nothing. Open
   the report and update the state as you go, not at the end.
3. **Separate what you measured from what you inferred.** Every entry ends with **what was not verified**. That
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
block that is not `name: value`, and a `ceiling` of no known shape (`not agreed ...`, `undecided ...`, or `N model rounds
...; M used`). Then it prints the first true row: `next: row <id> - <the action, as NEXT.md words it>` and `because:`
the flags that made it true (exit 0). No row true: `no row is true: the table has a hole or a flag is stale` (exit 1,
NEXT.md's STOP rule: say which in `STATE.md` and ask - do not change a flag to get moving).

What the flags cannot decide is not guessed. Rows 1 (a high or a `pending:` finding is open), 3 (`waiting_on_owner`), 5,
8, 9, 9b, 10 (after a round, with no bytecode change since), 11b, 12 (did the spec's promises change?), 16, 17 and 18b
need something `STATE.md` does not carry, and are printed `needs judgement: row <id> - <the question>`; the row after
them is printed as the answer only if they are all false (exit 3). Answer with `--judge <row>=true|false`: the answers
are printed back, so the judgement is on the record. Row 3: answer `false` each row below that depends on the owner's
answer, and 3 itself `false` once none left does. Two rows are not destinations: row 2 (ceiling reached) is `in force`
and turns every model row below it off; row 14 (the loop is over) is `passed`, and the table goes on at row 15.

The rows are data inside `next.sh`: a new row of `NEXT.md` is one line there, and every run checks that the two name the
same rows in the same order (`scripts/next.sh --check-table`); a row in one and not the other is a refusal.

## The ROUND line

There used to be a fourth file, a machine-readable record of every round. Nothing ever read it, and three reviewers
independently called four state files bureaucracy that an agent maintains instead of working. It is now ONE LINE at the
top of the `LOG.md` entry that closes a round, in a fixed shape so that `grep '^ROUND ' LOG.md` is the history:

```
ROUND r05 | phase 4 | regression | vendor-a/large | bench $HOME/.gauntlet/bench/a05 | 2026-03-09..2026-03-12 | 0H 1M 4L 7I reasoned 0 | gate pass | 230k tokens, 95 min, 41 files read, 6 tests written | reports/r05.md | conf 0.7
```

Fields, in order: id · phase · type (`interview`, `spec`, `battery`, `discovery`, `regression`, `black-box`, `verifier`,
`executor`, `promotion`, `rehearsal`, `handoff`, `simulation`) · model, as specific as you can be · bench · dates · findings AS THE ROUND
CLASSIFIED THEM, with REASONED high/medium counted apart · did the gate pass (discovery and regression: the phase-4 gate, zero high and zero medium open; black-box: no divergence left; verifier: every claim held; an interview, spec or battery line: that phase's gate in `AGENTS.md` §3; an interview played from the owner's files with the read-back pending: `gate pass (read-back pending)` - the pending item is in `waiting_on_owner`) · cost AND effort (tokens, wall-clock,
files read, tests written; leave out what you cannot measure, never guess - an orchestration harness does not always
return a subagent's usage, and then the field says `not reported`) · the report · and, optionally,
`conf` - the raw_confidence, 0 to 1: what the round's author would bet on its own verdict. Unused by any policy today;
it is there so that one day a verdict can be weighed against how often its author was right. The effort fields exist for one
reason: the route ends on a discovery round that finds nothing, and a round that found nothing because it did not look
has the same findings line as one that looked hard. The effort line is how the two are told apart. What the OWNER decided about the findings goes in `DECISIONS.md`, not here.

It costs nothing to write, and after a few rounds it is what lets you choose the next one from history instead of by
feel: which kind of round finds the most per token, at which phase, on which model.

### Writing it, and reading it back: `scripts/round.sh`

Type the line by hand and it drifts - a type that is not on the list, `1-2` where a count goes, `03-12` for a date, a
field left out so that every field after it moves one place - and nobody notices until the history is read. So write it
with the script, from named arguments; it checks each one and refuses (exit 2, nothing written) a malformed line:

```sh
scripts/round.sh .gauntlet/LOG.md --id r05 --phase 4 --type regression --model "vendor-a/large" --bench "~/hg-a05" \
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
