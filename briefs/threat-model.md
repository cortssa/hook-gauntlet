# Brief template: the independent threat model (before phase 3 closes)

Everything the route writes before round 1 - the spec's hostile-actor table, the threat list, the invariants, the
tests - comes from one reader. A threat that reader never thought of has no row, no invariant and no test, and no judge
of the route can see the gap: the battery is green on what was written down. This step puts a second reader in front
of the same promises, one that has never seen the first reader's work, and makes the difference between the two lists
a gate (`doctrine/NEXT.md` row 4b). It is reverse reasoning: start from what can be lost, and ask who can take it.

It has three parts: the walker's own list (phase 2), the independent list (a fresh agent, before phase 3 closes), and
the diff (`scripts/threat-diff.sh <proj>`). Every input is a file with ids and one-line forms; nothing is read as free
text, and a line that starts like one of these forms and is not of it is refused with its line number.

## 1. The walker's list, `.gauntlet/THREATS.md` (phase 2)

Written in phase 2, once the spec is written (phase 1) and before any invariant: from `doctrine/HOOK-ATTACKS.md` (every
class the spec says *applies*, one threat or more each) and from the spec itself (each row of section 3, each
assumption of section 5b that someone could break, each invariant of section 4 read backwards: who would gain by
breaking it). One block per threat:

```
W-<n>: <who acts> / <what is lost, and by whom> / <the call sequence>
from: doctrine/HOOK-ATTACKS.md class <#>      (or: SPEC.md section <s> row <r>, SPEC.md section 5b assumption <a>)
matches: T-<n>[, T-<n>...]                    (or, alone on the line: new)
```

- `W-<n>` at column 0, `<n>` from 1 with no leading zero, each id once. The three fields are separated by ` / `, none
  empty or a placeholder (`?`, `TBD`, `...`, `<who>`). Who acts is a party (a stranger, a router, the paired token, the
  owner's key, a JIT provider, the block builder); what is lost names the party that loses it; the call sequence is the
  calls, in order, in words (`initialize a pool naming the hook, swap on it, claim`).
- `from:` says where the threat came from, in one line.
- The matching line is filled AFTER the independent list is in, and only then: `matches: T-3` when the independent
  agent's T-3 is this threat (several ids when it is several of theirs), `new` when none of theirs is. An optional
  comment in parentheses may follow either.
- A block is its `W-` line and the lines right under it; a blank line or a heading ends it. Prose may stand between
  blocks.
- **The walker's threats are frozen once the independent list is read.** After that, the walker writes matching lines
  only. An independent threat its list does not have is answered with an invariant or a refusal (section 3) - never by a
  `W-` block written after the fact with `matches:`, which would count a threat the walker missed as one it had. The
  LOG entry that fills the matching lines says when they were filled. **After the diff, both lists are frozen:** the
  report keeps both files' sha256, and `scripts/next.sh` refuses a `threat_model: diffed (...)` line once either list
  is no longer the file the report hashed - an edit after the diff means running it again.

## 2. The independent list, `.gauntlet/THREATS-independent.md` (before phase 3 closes)

**Who.** A FRESH agent: a subagent with no context of the route, or a second session the owner opens for it. It is
started from ONLY the part of this file below the `---` line, written out as its own file with the placeholders filled:
sections 1-3 above it are the walker's and name actors and classes the independent agent must not be handed. A model of another family than the walker's, when one is available - the dossier says
which family wrote each list; one family for both is a stated limit, not a reason to skip the step. It is not an
adversarial round: it writes words, not tests, and it does not count against the ceiling (`doctrine/NEXT.md`, "What
counts against the ceiling"); its ROUND line (`scripts/round.sh --type threat-model`, findings `0`) records the model.

**What it receives - ONLY these, in a directory of its own outside the project (`doctrine/ORCHESTRATION.md` section 1:
one agent, one brief, one bench), named in the brief as `{{BENCH}}`:**

1. the owner's spec, as the owner wrote it (the file `.gauntlet/spec.sha256` names, unchanged) - never the route's
   `.gauntlet/SPEC.md`, whose hostile-actor table IS the walker's threat list;
2. the hook's public interface: its ABI - functions, events, errors - from `forge inspect <Hook> abi` (or the artifact's
   `abi` field), and the callbacks it declares; no source;
3. the economic model in the owner's words: who puts value in, who takes it out, what the hook charges, pays or holds,
   and for how long - the owner's spec's own section on it, or the interview's answers to questions 1, 5, 6, 13 and 14
   copied verbatim from the `DECISIONS.md` entries marked `source: owner` (or `source: <the owner's file>`). Never a
   summary the walker wrote: a summary is the walker's reading, and carries its blind spots. No economic model in the
   owner's words: the file says so, and the agent works from the spec.

**What it must not see:** anything of the route's - `.gauntlet/` (the route's `SPEC.md`, `THREATS.md`, `STATE.md`,
`DECISIONS.md` beyond the verbatim answers above, `LOG.md`, `reports/`, `rounds/`, benches), the source (`src/`), the
tests (`test/`, `pending/`), any round's report or brief, the dossier, and `doctrine/HOOK-ATTACKS.md` and
`doctrine/INVARIANTS.md` (the walker's own prompt lists: the point is a list that did not come from them). Isolation is
physical: build the directory with the three files and nothing else, list it before launching, and start the agent there.

**What it writes:** a `model:` line, a `received:` line, and one line per threat, numbered from 1:
`T-<n>: <who acts> / <what is lost, and by whom> / <the call sequence>` (the form, exactly, is in the brief below).

**After it returns:** copy its file, unchanged, to `<proj>/.gauntlet/THREATS-independent.md`; open the `LOG.md` entry
with its ROUND line (`scripts/round.sh <LOG.md> --type threat-model --model "<the model>" ...`, `state/README.md`) and
say what it received and the bench; fill the matching lines of `.gauntlet/THREATS.md` (section 1); run
`scripts/threat-diff.sh <proj>`.

## 3. The diff, `scripts/threat-diff.sh <proj>`

It reads each independent threat, in this order, as:

- **matched** - a walker's block names it in `matches:`;
- **new** - the walker's list does not have it, and a test now names it, on a line of its own right above the test
  function, in a `.sol` file under `test/` (or `pending/`, when it turned out to be a finding):

  ```
  /// @custom:threat T-<n>[, T-<n>...]
  function invariant_<what it keeps>() public { ... }
  ```

  the invariant (or test) that turns the threat into something the battery checks - seen red first, like every test
  (`AGENTS.md` 6.3). The tag is `@custom:threat` because solc reads every `///` line as NatSpec and builds no tag of a
  project's own but `@custom:<name>`: a `@threat` tag there breaks the build ("Documentation tag @threat not valid for
  functions"), and the script refuses it;
- **refused** - neither, and `DECISIONS.md` (the one beside `STATE.md`) refuses it in one heading, in this form and no
  other - an id (a letter and a digit at least), a real date, a middle dot between spaces:

  ```
  ## <id> · <YYYY-MM-DD> · threat T-<n>[, T-<n>...] refused: <why, in one line>
  ```

  A heading with no id or no date, a date that is not one, or hyphens for the dots is not a refusal: the threat stays
  unmatched, and the diff names that line and what is wrong with it;

  the reason a predicate someone can check (the hook holds no balance; the entry point does not exist), the entry's
  body saying more and its `source:` (`assumed, owner absent` when the owner is not there to read it) - a refusal is a
  claim, like "does not apply" (`doctrine/EVIDENCE.md` 6);
- **unmatched** - none of the three.

While one is unmatched it refuses, naming each with its three fields (and a `DECISIONS.md` heading that names it in
another shape, when there is one), and the `STATE.md` line stays `threat_model: not yet`. When none is, it prints

```
threat_model: diffed (<n> matched, <m> new, <k> refused)
```

for `STATE.md`, and writes `.gauntlet/reports/06-threats.txt`: the model that wrote the independent list and what it
received, both files' sha256, one line per independent threat with its status, and the walker's own threats (`new` in
`THREATS.md`: the ones the independent agent did not see). `scripts/next.sh` refuses `phase:` 4 or higher with
`threat_model: not yet`, and reads a `diffed` line against the files themselves and against the report's hashes. The dossier carries the report
(`briefs/handoff-dossier.md`, section 5b). The forms, read the same way by both scripts: `scripts/lib/threats.sh`.

---

# THREAT MODEL {{ID}} - who can lose what in `{{TARGET}}`, from its promises alone

You write the list of threats to a Uniswap v4 hook from what it promises, before anyone shows you how it keeps them.

## What this is, and what it is not

This is a defensive review of **the owner's own, undeployed code**, requested by the owner: you read three files and
write one. You write **words only** - no code, no tests, no exploit, nothing that runs. Your list is compared with
another reader's, and every threat on yours that theirs lacks is turned into a test of the hook or refused in writing:
a threat you are unsure of still goes on the list, because refusing it costs a line and missing it costs a finding.
(Orchestrator: keep this paragraph only if every word of it is true. If the target is deployed or is not the owner's,
this kit is the wrong tool - STOP and ask.)

## The one rule you cannot break

**You read only the files in `{{BENCH}}`.** Not the hook's source, not its tests, not any other threat list, report or
spec of the route, not by any tool, not through a quoted excerpt. If you see anything else anyway, say so in your file's
`received:` line - a declared contamination is a manageable fact, an undeclared one makes the list worthless.

## What you have

- `{{OWNER_SPEC}}` - the owner's spec: what the hook does and what it promises.
- `{{INTERFACE}}` - its public interface: every function, event and error, and the callbacks it declares.
- `{{ECONOMICS}}` - the economic model in the owner's words: who puts value in, who takes it out, what the hook charges,
  pays or holds, and for how long.

## What to do

Think as the attacker of THIS product, from these three files alone. List who can lose what, and through which
sequence of calls; number the threats. Nothing else - no severity, no fix, no code, no method from anywhere but the
three files.

## The file you write: `{{OUT}}`, exactly this form

```
# THREATS - independent - {{TARGET}}

model: <the model you are, as specific as you can be>
received: <the files you were given, and anything else you saw>

T-1: <who acts> / <what is lost, and by whom> / <the call sequence>
T-2: <who acts> / <what is lost, and by whom> / <the call sequence>
```

- `model:` and `received:` once each, at column 0.
- One line per threat, `T-<n>:` at column 0, numbered from 1 in order with no leading zero and no gap reused; the three
  fields separated by ` / ` (space, slash, space), none empty or a placeholder. An example of the FORM only, about a
  made-up vending machine contract, not your product:
  `T-4: a customer / the operator's stock / insert one coin, press two buttons at once, receive two items`.
- No other line may start with a threat id: no list markers before it, no headings named `T-<n>`. Prose may stand between
  the threat lines, and is not read.

## Rules

- You write **only** `{{OUT}}`, in `{{BENCH}}`. No network, no installs, no browser, nothing outside the bench.
- No code and no test of any kind; no other file.
- Every threat on one line. If one needs a qualification, it is two threats.

## Deliverable

`{{OUT}}`, in the form above, and in your reply: how many threats, and one sentence on the part of the hook you
trust least.
