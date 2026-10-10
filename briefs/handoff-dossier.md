# Template: the handoff dossier (phase 8)

The reader is a professional auditor who has never heard of this project and is paid by the day. The dossier exists
to give them back the days they would spend asking for what a dossier should already say: what the hook is for, what it promises, what was tried against it, what is
known to be imperfect, and - the section they will read first - **what nobody checked**.

Write it in the language the AUDITOR reads. If the spec is in another language because the owner reads that one,
say so in the status line above section 0 and translate at least sections 0, 1, 4 and 9.

It lives at `.gauntlet/DOSSIER.md` (or the project root, where `STATE.md` says the state lives). It is assembled, not written: almost every section points at a file that already exists if the route was walked. If a
section has nothing to point at, do not pad it. Write "not done" and the reason. An honest gap costs the auditor five
minutes; a confident paragraph over a gap costs them a day and costs you their trust.

Items marked **must** are what audit firms' own readiness guides ask for (the rows were taken from several firms'
published guides; the dossier's author should cite the ones they checked against, with dates, in the scope sheet). **if applicable** means: say "n/a" and why.

---

# {{PROJECT}} {{REVISION}} - dossier for security review

**Commit / manifest:** {{COMMIT}} · `{{MANIFEST}}` (sha256 of every file in scope, and of the build configuration)
**Not deployed. No human security review yet.** Prepared with AI agents under the owner's direction; every claim carries its
evidence label (`doctrine/EVIDENCE.md`); MUTATION-TESTED means a test seen red on a deliberately broken version of the code; PROPERTY-TESTED means the claim survived generated sequences over a stated domain, with the success and reach censuses attached; MODEL-TESTED means the contract agrees with an independently written reference model over generated inputs; PROVED means a proof, within its stated bounds; TESTED means a test that passes and has not been seen red - work in progress, not evidence; REASONED means an argument, not a test.
**Not done: {{N_NOT_DONE}} of the {{N_ROWS}} judges in section 6, {{N_SKIPPED}} steps skipped with the owner's agreement · ceiling_reached: {{yes/no}} · skeleton: {{K}} findings open** -
the status line: the one line every flag in `doctrine/NEXT.md` points at. `N_ROWS` is the number of rows section 6 has
for this hook (`doctrine/JUDGES.md`'s rows, its row 1 counted as the two it becomes here; the sandbox row counts only when it was asked for). A dossier can be complete and thin at the
same time; this line says which one it is. In `skeleton: {{K}} findings open`, K is the number of findings still open,
high + medium + low (`open_findings` in `STATE.md`); informational findings are NOT counted in it - the same K that
`STATE.md` writes as `dossier: skeleton (K open, ...)` and `NEXT.md` row 9b reads against `open_findings`. Three things
are added to the line when `STATE.md` says them, in these words: `black-box: not run - ceiling reached` (`ceiling_reached:
yes` and `blackbox` still `never_run` or `stale`); `black-box: stopped at <step>` (`blackbox: stopped (<round id>)`);
`ceiling set by the operator, owner absent` (`ceiling: ... set by the operator ...`, `doctrine/COST.md` 1 - never written
as one the owner agreed). Each is also in section 8; a high still to be told to the owner is on this line too
(`high <ids> - to tell`, `NEXT.md` row 1). A spec re-recorded with the owner's signature adds `spec: re-recorded <date>,
signed --by "<name>"` (the last `re-recorded` line of `.gauntlet/spec.sha256`); it is not verified by `next.sh` - the
owner confirms the signature is theirs, or the spec in force is not the owner's.

## Start here

The one page an auditor reads before anything else. Every line points into the body below, which is the record;
assemble it last, with section 0, from the sections it names, and put nothing here that they do not hold. It fits on
one page: the PDF starts section 0 on the next.

| | |
|---|---|
| commit and scope | {{COMMIT}} · in scope: {{FILES_SLOC}} · out of scope: {{OUT_OF_SCOPE}} (section 1) |
| what the hook does | {{WHAT_IT_DOES}} - one or two sentences (section 2) |
| what it holds | {{WHAT_IT_HOLDS}} - the tokens, balances or rights it keeps between calls, and who can move them; "nothing" if nothing (sections 2, 3) |
| the spec | section 2, from `SPEC.md`: the promises, the hostile-actor table, the invariants with their evidence labels, the trust assumptions |
| known and accepted issues | {{ACCEPTED}} - by id, each with who accepted it; "none" if none (section 4) |
| main findings already fixed (at most three) | {{FIXED}} - by id and severity, each with its regression test, seen red (sections 4 and 7) |
| what was NOT checked | {{NOT_CHECKED_TOP}} - the top items of section 9; the full list is there |

Set up and run - section 10 in full, from a clean checkout:

```sh
git clone {{REPOSITORY}} {{DIR}} && cd {{DIR}} && git checkout {{COMMIT}}
lib/hook-gauntlet/scripts/doctor.sh   # what this machine lacks, with the commands; installs nothing
{{BUILD_AND_RUN}}                     # forge clean, forge build, the battery: section 10's commands
```

## 0. Executive summary (must)

{{EXEC_SUMMARY}}

Two to four sentences, before the reader hits a table: what the hook does, the round count and model families spent
on it, the headline finding if there was one, and the one sentence the reader most needs before section 1 - whether
anything here is still moving. No word a paid auditor would have to walk back later - none of the words `AGENTS.md` section 1
lists, not even negated (the list, the reason and the phrase to use instead are there) - point at the evidence label (`doctrine/EVIDENCE.md`). The same holds for the Start here page. Write it last, after every other section
exists: it is the only section with no file to assemble from. Three honest sentences beat four padded ones.

## 1. Scope sheet (must)

| | |
|---|---|
| the exact commit (or tree hash) this dossier and the review are scoped to | {{COMMIT}} |
| files in scope, with lines of code each | {{FILES_SLOC}} |
| out of scope, and why | {{OUT_OF_SCOPE}} |
| compiler, EVM version, optimizer, `via_ir` | {{BUILD}} |
| runtime size and margin to the target chain's code-size limit (24,576 bytes on Ethereum, EIP-170), per contract; initcode size and margin to the initcode limit (49,152 on Ethereum, EIP-3860) | {{SIZES}} |
| pool admission: which pools may use this hook, who may create one, what the hook does with a `PoolKey` and `hookData` it has never seen (in v4 anyone can initialise a pool pointing at a hook unless `beforeInitialize` refuses) | {{POOL_ADMISSION}} |
| external calls the hook makes, and to whom | {{EXTERNAL_CALLS}} |
| oracles and price sources it depends on (including a pool's own spot price) | {{PRICE_SOURCES}} |
| prior HUMAN security reviews (firm, date, report) - or "none" | {{PRIOR_REVIEWS}} |
| Uniswap Foundation Hook Security Framework: self-score per dimension, tier, feature triggers, date scored; and which of its recommendations for that tier are met, not met, or outside this route (`doctrine/UPSTREAM.md`) | {{UF_FRAMEWORK}} |
| documentation coverage: is every external function, event and event parameter documented (NatSpec)? Counted, not assumed - and whether what it says is true is section 2's self-claims table | {{NATSPEC}} |
| wanted start date and deadline for the review | {{DATES}} |
| external dependencies and their pinned versions | {{DEPS}} |
| hook permission bits declared, and the mined address they match | {{FLAGS}} |
| deployment: constructor arguments, deployer (a CREATE2 proxy makes `msg.sender` in the constructor the PROXY), salt, expected address, and how to reproduce the mining | {{DEPLOYMENT}} |
| keccak256 of the runtime and creation bytecode, per contract, from a clean build | {{CODE_HASHES}} |
| exact solc version, and the known compiler bugs that affect it | {{SOLC_BUGS}} |
| routers / periphery assumed trusted (the decision for the "layer in front of the hook" class) | {{TRUSTED_PERIPHERY}} |
| tokens / currencies supported; behaviours rejected at the door (fee-on-transfer, rebasing, callbacks, native) | {{TOKENS}} |
| target chain(s); was the suite run against that chain's real pool manager? | {{CHAIN_AND_MANAGER}} |
| upgradeable? pausable? who holds which key? (if none: say "immutable, no owner") | {{GOVERNANCE}} |
| novel arithmetic or custom accounting the auditor should spend time on | {{FOCUS}} |

## 2. What it is and what it promises (must)

- One paragraph, and one diagram of who calls what (a Mermaid block is enough). -> `SPEC.md` sections 1-2
- The hostile-actor table, ALL FIVE COLUMNS: what an attacker can do, what the contract answers, which test proves it,
  which fuzz action reaches it (with the census boundary that shows it did), and the mutant that test was seen to
  kill. Empty cells stay empty: a row defended only by text is something the auditor wants to know before they
  start, and it is the cheapest day of their time you can save. -> `SPEC.md` section 3
- **What the code says about itself**, the spec's section 3b as it stands - each claim (an event and its fields, a
  NatSpec or document sentence about behaviour, an error, a limit, an interface's promise), where it is, what the code
  does, and how it was checked - each row with its **evidence label** (`doctrine/EVIDENCE.md`), the spec row's "how
  checked" cell as it stands (TESTED or stronger with the test's name, REASONED, or not checked). A row whose "does" is
  not its "said" is a finding (section 4); a row not checked is in section 9 too. -> `SPEC.md` section 3b
- **The invariants, in words**, each with the test that checks it and its **evidence label** (PROVED / MODEL-TESTED /
  PROPERTY-TESTED / MUTATION-TESTED / SUPPORTED / REASONED / UNVERIFIED - `doctrine/EVIDENCE.md`). A test nobody has
  seen fail is not listed as evidence. MUTATION-TESTED cites the mutant and its `kill: assertion` line; a mutant whose
  only kill is a revert is written `KILLED (revert)` and does not earn the label. REASONED is a target, and the auditor should know it is one. -> `SPEC.md` section 4
- The assumptions the spec stands on, and which of them a discovery round tried to break. -> `SPEC.md` section 5b
- Trust assumptions and admission rules: what must be true of a pool, a token or an operator, and **who enforces it**.
  -> `SPEC.md` section 5

## 3. Access control (must)

| function | who may call it | enforced by | what happens to everyone else | test |
|---|---|---|---|---|
| {{FUNCTION}} | {{CALLER}} | {{MECHANISM}} | {{ANSWER}} | {{TEST}} |

Include the hook callbacks (only the pool manager), anything "anyone" may call (sweeps, evictions), and every view
that other software will trust.

## 4. Known issues and accepted trade-offs (must)

Every finding that was accepted rather than fixed: what an attacker achieves, who loses how much, what it costs them,
why it was not fixed, and who accepted it. -> `SPEC.md` section 6. Refusals with their reasons -> `DECISIONS.md`.
Every finding carries a status: `accepted` (with the owner's line), `fixed` (with the regression test), or
`open - owner triage pending`. A dossier with an open finding is a **skeleton** (`doctrine/NEXT.md` row 9b): sections
0, 4, 5, 6, 7, 8, 9 filled honestly, the open ids listed here by id and severity, and the status line above section 0 carrying `skeleton: K findings
open` (K: high + medium + low still open, informational not counted). Sections 1, 2, 3 and 10 are filled as far as they are known (10 only if a fresh agent can actually run it; else
`not yet`). In a skeleton, a cell that waits on the owner for something OTHER than triage (a not-run judge's reason in
section 6, a full-mode reason while the mode is undecided, the chain, the framework self-score, the decline of
promotion) reads `owner decision pending: <what>` - never `triage pending`, which is for findings only - and each such
item is also a named entry in `STATE.md` `waiting_on_owner:`. None of these is a skip, and each of them COUNTS as not done in `N` (a judge waiting on the owner is a judge not run). A row that does not apply to this
hook (the real-manager battery for a hook on no manager) reads `n/a: <what replaced it, section 8>` and does not count as
not done; neither does an optional judge the owner did not ask for (the sandbox: `not run: optional, not requested`).
A black-box round the ceiling left unrun (`doctrine/NEXT.md` row 2) is a round, not a judge: it is not a row of section 6 and does not count in `N`. It goes on the status line (`ceiling_reached: yes, black-box: not run - ceiling reached`) and in section 8, and section 9 says what it would have added. So does a black-box round the environment stopped twice (`doctrine/NEXT.md` row 11b, `blackbox: stopped (<round id>)`): the status line and section 8 say `black-box: stopped at <step>`, section 9 what it would have added; it counted against the ceiling, and it is not in `N` either.
What DOES count as not done: `N` counts the rows of section 6 only (the judges of `doctrine/JUDGES.md`): a judge not
run because light mode skips it (the fork battery, symbolic, the second engine, the reference model) and a tool the owner
did not allow (Slither never installed, or the install declined: `not done: static triage by forge lint only`). Promotion and rehearsal are
phases, not judges: skipping them - light mode's default, or the owner's decision in writing in full mode (`doctrine/NEXT.md` row 18b) - goes in the status line's `skipped` count and in section 8, not in `N`.
Phase-3 `pending` findings are listed in section 4 as open. It is a status report for the owner, not a handoff; nothing below it moves to promotion.
An auditor judges new findings against this list; leaving something out of it is how a known issue becomes a "critical".

## 5. Candidates raised and refuted (must)

Every idea that was chased and refuted - a class walked in `doctrine/HOOK-ATTACKS.md`, a shape a round's brief
named under "where to press hardest", a suspicion an owner or an agent raised in `DECISIONS.md` - listed even though
it never became a finding. One line each: the candidate, the round or judge that refuted it, and the test or
argument that closed it, with its evidence label. Do not fold this into section 4: an accepted trade-off and an
attack that was tried and failed are not the same claim, and merging them hides which one a given row is.

| candidate | round / judge that refuted it | test or argument | evidence label |
|---|---|---|---|
| {{CANDIDATE}} | {{ROUND}} | {{TEST_OR_ARGUMENT}} | {{LABEL}} |

Goes red the same way section 9 (what was NOT checked) does: an empty table with no line explaining why nothing was
raised this route is not a credible claim on any hook that went through more than one adversarial round. A reader
who finds a class missing from both section 4 and this one cannot tell "looked at and refuted" from "never looked at" - this section
is what tells them apart.

## 5b. The independent threat model (must)

What a reader who never saw the route's work thought could go wrong, and what became of each (`briefs/threat-model.md`),
read from `.gauntlet/reports/06-threats.txt` - the report `scripts/threat-diff.sh` wrote - as it stands, never retyped:

- who wrote the independent list (the report's `model:`, and its family), what it received (`received:`), and who wrote
  the walker's list; one family for both is said here, as a limit: a blind spot they share is in neither list;
- the line `threat_model: diffed (<n> matched, <m> new, <k> refused, <h> handed)`, and the two files' hashes;
- one row per independent threat:

| threat (T-<n>: who / what is lost / the call sequence) | matched by (W-<n>) / new - the invariant that names it (`/// @custom:threat`) / refused - the `DECISIONS.md` line / handed - `handed: round, became F-<n>` or `handed: audit` | the test's evidence label (`doctrine/EVIDENCE.md`) |
|---|---|---|
| {{THREAT}} | {{STATUS}} | {{LABEL}} |

- the pairs, as the report gives them (`the pairs - ...`): each threat a test names, its text beside the test's name and
  file, so that the reader judges the fit - the script only checks that the test's name carries the id;
- the handed threats, by name: each `handed: audit` one (and each `handed: round` the round did not turn into a finding)
  listed as **untested**, its three fields written out - they are in section 9 too;
- the walker's own threats (`new` in `.gauntlet/THREATS.md`): the ones the independent reader did not see.

The `new` rows are the ones the route would have missed without this step, and the refused ones are claims: an auditor
reads both first. Not done (the route stopped before phase 3 closed: `threat_model: not yet`): say so here and in
section 9.

## 6. What the judges said (must; the rows of `doctrine/JUDGES.md` - its row 1 is split in two here)

| judge | command, tool version | result, read from the output | where the output is (inside the project, `.gauntlet/reports/...`: a bench or scratch path is not a place an auditor can read) |
|---|---|---|---|
| build + lints | | warnings: | |
| static analysis | `scripts/static-triage.sh`: what ran, each with its version (the report's header), and what did not - `not installed`, or `the owner declined the install` | N findings per tool, from the report's counts; what was triaged: fixed / by design / accepted / false positive -> `STATIC-TRIAGE.md` (each finding above informational, or its group) | `.gauntlet/reports/05-static.txt` |
| unit tests | | passed / failed / skipped | |
| invariant fuzzing | | runs x depth, calls; corpus on? the CAMPAIGN census from `scripts/census.sh` - for each core action, in how many runs it succeeded at least once; for each boundary, in how many runs it was reached; runs with an unexplained revert (not the smoke test's numbers, and not the one block of logs forge prints: that is a single run); the gate's attempts, from `.gauntlet/reports/03-census-attempts.txt` - how many, and every CORE action, REACH boundary or floor dropped or lowered since the first (the gate's record says them): a gate that passed after its boundaries were cut is not the gate first set. `reverts: 0` is not a result: in a green campaign with `fail_on_revert = true` it cannot be anything else | |
| coverage | | lines / **branches** per file in scope; every uncovered branch named | |
| mutation | | which files, against which tests; mutants generated, killed, survived, invalid, skipped, timed out; each kill with its reason, the `kill:` line `scripts/mutate.sh` writes - `assertion`, or `KILLED (revert)` (the code reverted where the test expected nothing: it does not count toward MUTATION-TESTED, `doctrine/EVIDENCE.md` section 2); each survivor -> test or proof of equivalence (`MUTANTS.md`) | |
| brutalize | | | |
| real pool manager | | chain id, address, code hash; suite result with `V4_MANAGER=fixture` | |
| independent reference model | | which property, how the model differs in structure from the code, sequences compared - or "not done", and in full mode the owner's reason | |
| symbolic / formal | | what was proven, for which bounds - or "not done", and in full mode the owner's reason | |
| second fuzzing engine | | or "not done" | |
| size, gas | | sizes and margins; gas of the main paths, regenerated for this revision | |
| simulation sandbox (`doctrine/SIMULATE.md`; optional, owner-requested) | scenario, agents, ordering model, seeds, steps; `scripts/sim-report.sh`. A backtest (`scripts/backtest.sh`, SIMULATE.md section 6) goes in this row too: the pool (id, key, chain), the window, the fixture's SHA-256 | the ledger table over seeds and the spec line each number was compared against - SUPPORTED, never PROVED; for a backtest, the totals per run NEXT TO THE CONTROL's, the refusals by selector and the substitutions the report prints; or "not run: <owner's written reason>" | the census TSV and the report; for a backtest, WHICH report, by its name - `.gauntlet/reports/07-backtest-<id8>-<from>-<to>-<Hook>.txt` (one per pool, window and hook) - and the fixture under `.gauntlet/backtests/` |

## 7. The adversarial history (must)

The ROUND lines of `LOG.md` (`grep '^ROUND '`), one per round: id, kind (audit / black-box / verifier / simulation), model family, findings by severity, what
changed because of it. Every report in full, in the repository. Say which model families were used; if only one, say
that a blind spot shared by that family is invisible in everything above.

## 8. Where we diverged from the usual process (must)

Every divergence recorded under `AGENTS.md` section 6b: which question, what was done instead, why. Here too: a black-box
round the ceiling left unrun (`black-box: not run - ceiling reached`) or the environment stopped twice (`black-box: stopped at
<step>`, `doctrine/NEXT.md` row 11b), and promotion and rehearsal when they were skipped
(`not done: light mode` or `not done: the owner's decision in writing`, `doctrine/NEXT.md` row 18b). A ceiling the
OPERATOR set, the owner absent in full mode: `ceiling: N model rounds, set by the operator (owner absent), not agreed by
the owner` with the reason for N from `DECISIONS.md` - every round it cut short was cut by the operator's number. An
interview whose ROUND line says `gate pass (read-back pending)`: the owner was absent, the interview was played from their
files, and nobody has yet read the scope and the non-goals back to them - say so here, with the item still in
`waiting_on_owner`; and a spec whose ROUND line says it: the owner has not yet read the spec (phase 1's gate). An
anchor the walker signed, the owner absent (`by: walker (owner absent)` in `.gauntlet/spec.sha256` or `src.sha256`;
`scripts/next.sh` names it in a note on the dossier's rows): `anchor signed by the walker, the owner absent` - the spec
or the code in force was fixed by the walker, not confirmed by the owner.

| | |
|---|---|
| environment divergences stated by the owner | {{DIVERGENCES}} - each `DECISIONS.md` entry `## <id> · <date> · divergence: <what>` (interview question 17c; `scripts/next.sh` lists them in a note on the dossier's rows), by id; none: `none stated` |

## 9. What was NOT checked (must - the auditor reads this first)

Be specific. Examples of the form this takes: economic and ordering attacks (MEV, JIT liquidity) were reasoned about,
not tested · native currency paths do not exist and were not tested · behaviour on chains other than {{CHAIN}} ·
the deployment script was simulated, never broadcast · nothing here was reviewed by a human with security training ·
rows of section 6 marked "not done" · every bound a handler puts on its own actions narrower than the legal range (a
price kept within 16x of the start, an amount cap, a clock that never passes a window): what the campaign never
exercised, with the handler line (`doctrine/FUZZ-ACTIONS.md`) · a black-box round the ceiling left unrun or the environment stopped, and what it would have added · what
promotion would have added, when it was skipped · for a backtest, what the replay cannot say: how the real swappers, arbitrageurs
and LPs would have REACTED to the hook (the replay keeps their real orders, placed against another price), the LP set it
replaced with one position, the swap types it did not replay, and the windows not run (`doctrine/SIMULATE.md` section 6).

## 10. Reproduce it (must)

From a clean checkout on a machine with nothing but Foundry: the exact commands, in order, that rebuild the bytecode
(`forge clean` first), run the battery, and check the manifest. A HANDOFF ships the kit inside the project
(`lib/hook-gauntlet`, a submodule or a copy) with RELATIVE remappings (`QUICKSTART.md` step 7b: `lib/hook-gauntlet/...`
from the project's root, `../lib/hook-gauntlet/...` from a sub-directory) so that this section runs on a clean machine.
Absolute remappings or `libs` paths in `foundry.toml` (a kit that lives elsewhere) are not portable: then this section
says so - `not yet: the project is not portable, its remappings name <the absolute path>` - and the dossier is a
skeleton, whatever else it holds. If it needs an RPC endpoint, say for which step; never
include one. Cite the kit's own proof, read from `<kit>/.gauntlet/selftest-passed` (`scripts/selftest.sh` leaves it only
when it ends PASSED; `scripts/next.sh` names no row without it): "the kit's selftest passed on <date> for scripts
<hash>", with forge's version from the same file - the reproducer runs `scripts/selftest.sh` first and gets the same
scripts hash from the same kit (the file's machine hash is the machine it ran on: a copied kit starts with the
selftest).

## 10b. What comes after the handoff (so the owner is ready for it)

A professional review ends with a report and then a **fix review**. Expect to supply: a written response to every
finding (fixed / acknowledged / disputed, with the reason); **one commit per fix**, so each can be reviewed alone; a
changelog between the commit the auditors reviewed and the fixed one; and the re-run of section 6 on the fixed code. Findings come
back marked resolved, partially resolved or acknowledged - "acknowledged" is public, and it is the owner's name on it.
Reports also carry a disclaimer that the review is not a guarantee; neither is this dossier.

Separately from the code: key management, who can pause or upgrade, monitoring, an incident plan and a disclosure
channel are not measured by anything in this kit. Say where they stand, or say "nothing yet".

## 11. If applicable

Deployment runbook and the rehearsal report (phase 7) · upgrade / pause procedure · off-chain components the guarantees
depend on, and what happens when they are down or lying · incident plan: who can do what, how fast, if something goes
wrong after deployment · security contact.

---

**Gate for phase 8:** the project is a git repository and its commit is on the first line (a manifest of hashes is an
exercise's substitute, not a handoff's); the Start here page is filled from the body and fits on one page (in the PDF,
section 0 begins on page 2); every path in section 6's "where" column is inside the project; section 10 runs
on a clean machine; every "must" section is filled or says "not done" with a reason, the not-done count is on the status
line above AND in `STATE.md`'s `dossier:` flag, and every skip has the owner's written agreement; section 9 is not empty (an
empty list of unchecked things is never true); section 5 is not empty either, on the same terms; a fresh agent, given
only this dossier and the repository, can run section 10 to the end and get the numbers in section 6.

**How it is handed over:** the auditor receives two files, `DOSSIER.md` AND `DOSSIER.pdf`. The Markdown is the record:
the file that is diffed, cited and corrected, and the one every other file points at. The PDF is the reading copy,
rendered from it as the last step, after the Markdown's final edit: `python3 scripts/dossier-pdf.py .gauntlet/DOSSIER.md`
(needs the `reportlab` package; without it the script writes nothing and exits 2, and the Markdown goes alone - never
an older PDF beside a newer Markdown). Both leave at the same commit, and where they disagree, the Markdown is right.
