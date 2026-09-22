# Template: the handoff dossier (phase 8)

The reader is a professional auditor who has never heard of this project and is paid by the day. The dossier exists
to give them back the days they would spend asking for what a dossier should already say: what the hook is for, what it promises, what was tried against it, what is
known to be imperfect, and - the section they will read first - **what nobody checked**.

Write it in the language the AUDITOR reads. If the spec is in another language because the owner reads that one,
say so on the first line and translate at least sections 1, 4 and 8.

It is assembled, not written: almost every section points at a file that already exists if the route was walked. If a
section has nothing to point at, do not pad it. Write "not done" and the reason. An honest gap costs the auditor five
minutes; a confident paragraph over a gap costs them a day and costs you their trust.

Items marked **must** are what audit firms' own readiness guides ask for (the rows were taken from several firms'
published guides; the dossier's author should cite the ones they checked against, with dates, in the scope sheet). **if applicable** means: say "n/a" and why.

---

# {{PROJECT}} {{REVISION}} - dossier for security review

**Commit / manifest:** {{COMMIT}} · `{{MANIFEST}}` (sha256 of every file in scope, and of the build configuration)
**Not deployed. Not audited by humans.** Prepared with AI agents under the owner's direction; every claim below carries
its evidence label, and a test is cited as evidence only if it has been seen to fail on broken code.
**Not done: {{N_NOT_DONE}} of the {{N_ROWS}} judges in section 5, {{N_SKIPPED}} steps skipped with the owner's agreement** -
a dossier can be complete and thin at the same time; this line says which one it is.

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
| documentation coverage: is every external function and event documented (NatSpec)? | {{NATSPEC}} |
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
- **The invariants, in words**, each with the test that checks it and its **evidence label** (PROVED / MODEL-TESTED /
  PROPERTY-TESTED / MUTATION-TESTED / SUPPORTED / REASONED / UNVERIFIED - `doctrine/EVIDENCE.md`). A test nobody has
  seen fail is not listed as evidence. REASONED is a target, and the auditor should know it is one. -> `SPEC.md` section 4
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
An auditor judges new findings against this list; leaving something out of it is how a known issue becomes a "critical".

## 5. What the judges said (must; the rows of `doctrine/JUDGES.md` - its row 1 is split in two here)

| judge | command, tool version | result, read from the output | where the output is |
|---|---|---|---|
| build + lints | | warnings: | |
| static analysis | | N findings: fixed / by design / accepted / false positive -> `STATIC-TRIAGE.md` | |
| unit tests | | passed / failed / skipped | |
| invariant fuzzing | | runs x depth, calls; corpus on? the CAMPAIGN census from `scripts/census.sh` - for each core action, in how many runs it succeeded at least once; for each boundary, in how many runs it was reached; runs with an unexplained revert (not the smoke test's numbers, and not the one block of logs forge prints: that is a single run). `reverts: 0` is not a result: in a green campaign with `fail_on_revert = true` it cannot be anything else | |
| coverage | | lines / **branches** per file in scope; every uncovered branch named | |
| mutation | | which files, against which tests; mutants generated, killed, survived, invalid, skipped, timed out; each survivor -> test or proof of equivalence (`MUTANTS.md`) | |
| brutalize | | | |
| real pool manager | | chain id, address, code hash; suite result with `V4_MANAGER=fixture` | |
| independent reference model | | which property, how the model differs in structure from the code, sequences compared - or "not done", and in full mode the owner's reason | |
| symbolic / formal | | what was proven, for which bounds - or "not done", and in full mode the owner's reason | |
| second fuzzing engine | | or "not done" | |
| size, gas | | sizes and margins; gas of the main paths, regenerated for this revision | |

## 6. The adversarial history (must)

The ROUND lines of `LOG.md` (`grep '^ROUND '`), one per round: id, kind (audit / black-box / verifier), model family, findings by severity, what
changed because of it. Every report in full, in the repository. Say which model families were used; if only one, say
that a blind spot shared by that family is invisible in everything above.

## 7. Where we diverged from the usual process (must)

Every divergence recorded under `AGENTS.md` section 6b: which question, what was done instead, why.

## 8. What was NOT checked (must - the auditor reads this first)

Be specific. Examples of the form this takes: economic and ordering attacks (MEV, JIT liquidity) were reasoned about,
not tested · native currency paths do not exist and were not tested · behaviour on chains other than {{CHAIN}} ·
the deployment script was simulated, never broadcast · nothing here was reviewed by a human with security training ·
rows of section 5 marked "not done".

## 9. Reproduce it (must)

From a clean checkout on a machine with nothing but Foundry: the exact commands, in order, that rebuild the bytecode
(`forge clean` first), run the battery, and check the manifest. If it needs an RPC endpoint, say for which step; never
include one.

## 9b. What comes after the handoff (so the owner is ready for it)

A professional review ends with a report and then a **fix review**. Expect to supply: a written response to every
finding (fixed / acknowledged / disputed, with the reason); **one commit per fix**, so each can be reviewed alone; a
changelog between the audited commit and the fixed one; and the re-run of section 5 on the fixed code. Findings come
back marked resolved, partially resolved or acknowledged - "acknowledged" is public, and it is the owner's name on it.
Reports also carry a disclaimer that the review is not a guarantee; neither is this dossier.

Separately from the code: key management, who can pause or upgrade, monitoring, an incident plan and a disclosure
channel are not measured by anything in this kit. Say where they stand, or say "nothing yet".

## 10. If applicable

Deployment runbook and the rehearsal report (phase 7) · upgrade / pause procedure · off-chain components the guarantees
depend on, and what happens when they are down or lying · incident plan: who can do what, how fast, if something goes
wrong after deployment · security contact.

---

**Gate for phase 8:** every "must" section is filled or says "not done" with a reason, the not-done count is on the first
line above AND in `STATE.md`, and every skip has the owner's written agreement; section 8 is not empty (an
empty list of unchecked things is never true); a fresh agent, given only this dossier and the repository, can run
section 9 to the end and get the numbers in section 5.
