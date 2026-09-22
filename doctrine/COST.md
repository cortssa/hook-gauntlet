# Cost: spend the local judges first, and buy rounds only where something changed

An adversarial round by a strong model is the expensive thing in this kit. Everything else is cheap or free.
Most people will run this on a subscription, so the scarce things are **tokens, rate limits and wall-clock time**,
not an invoice. Count tokens: they are the unit that travels between plans and vendors. The
discipline below exists so that nobody walks the whole route on a weekend experiment, and nobody skips the part
that matters on a contract that will hold other people's money.

## 1. Size the route to the stakes - decide this with the owner in phase 0

| what the hook is for | walk | skip |
|---|---|---|
| learning, a hackathon, a testnet toy | phases 0-3, one adversarial round if curious | everything else |
| real but small: capped funds, upgradeable or pausable, the owner is the only user at first | phases 0-5 in **light mode** (3 adversarial rounds, 1 black-box) and phase 8 | promotion and rehearsal, unless a release is being frozen |
| immutable, or holds third-party funds without a cap | the whole route in **full mode**, then the human audit | nothing |

When two rows describe the hook, **the heavier one wins**: third-party funds without a cap is full mode whether or not
the contract is upgradeable or pausable. Upgradeability does not make the route lighter, it adds work (the roles, the
lost or stolen key, the storage layout across versions - `HOOK-ATTACKS.md` class 23, for which this kit has no tooling).

Write the choice in `DECISIONS.md`, with a **ceiling**: the maximum number of rounds (or of money) the owner is
willing to spend before stopping to reconsider. **STOP and ask when the ceiling is reached**, whatever the state.

## 2. The local judges go first

Compute on the owner's machine costs no model credits. Exhaust it before you buy an opinion.

1. `forge build` with lints on, and static analysis with a written triage (Slither is free and takes seconds;
   installing it is the owner's call).
2. The full battery, and coverage by branch.
3. **The long fuzz campaign**, with the corpus on. A violation found by the fuzzer is a finding you did not pay a
   round for.
4. A mutation pass (`forge test --mutate`, or aimed mutants with `scripts/mutate.sh`): a test that stays green over
   broken code is not a test. Read the survivors, not the score.

`JUDGES.md` has the whole ladder: the question each one answers, when to skip it, and how each one lies.

Only when all of that is quiet do you launch an adversarial round. Launching a round on a project whose own fuzz
campaign has not been run since the last change is paying a model to find what the CPU would have found for free.

## 3. Aim regression rounds at what changed, and keep discovery rounds blind

- There are two kinds of round (`briefs/audit-round.md`). **Discovery** rounds read everything and get NO earlier
  reports: round 1 is one, the round that closes the loop must be one, and their rediscoveries are the price of an
  independent look. Budget for at least two. **Regression** rounds are everything in between, and each is aimed at the diff since the previous one, plus the two or
  three places the orchestrator trusts least. The brief names them. An auditor told to "review the contract" again
  re-reads and re-reports what is already known.
- List the accepted trade-offs and the written refusals in the brief. A rediscovery is a round's worth of credits
  spent on something you already decided.
- **A change that touches no bytecode does not get an adversarial round.** Documentation, comments, scripts and
  tests get a verifier pass: one agent, a short brief, "falsify these sentences against the code". It can run on a
  cheaper model.
- One round at a time. Two in parallel attack the same code, and the first high finding makes the other's report
  obsolete before you have read it.

## 4. Put the black-box round early

As soon as the spec is stable and the battery is green - typically after the first or second adversarial round,
not after the last. Its findings are about the spec, and the spec aims every later round. Run late, it finds the
same things, after you have paid for rounds aimed by a spec that was wrong. Repeat it at the end only if the spec
changed materially since.

## 5. Match the model to the role

| role | needs |
|---|---|
| orchestrator, auditor, black-box attacker | the strongest model you have; this is where a weak model produces opinions instead of measurements |
| executor applying an already-decided change through gates | strong, but the brief does the thinking |
| verifier of a documentation-only change, scribe, report formatting | a cheaper model is fine |
| the judge | not a model |

If you can afford one round on a model from a different vendor, spend it on the verifier or the black-box round:
it is the only defence against the blind spots one family of models shares.

## 6. Keep the paperwork small, because the orchestrator must read all of it

The rule "read the whole report before touching code" is non-negotiable, so the size of the report is a cost you
pay every round.

- Briefs of about 40 lines. Point at files; do not paste them.
- Tell the auditor: raw outputs go to files in the scratch directory; the report quotes the few lines that carry
  the number. A report is a few hundred lines, not a few thousand.
- Every round's `LOG.md` entry starts with a ROUND line carrying its cost (`state/README.md`). After three rounds you have your own price per round, and
  the owner can decide the next one with a number instead of a feeling.

## 7. Know when to stop

- The exit criterion is the stop rule: a **discovery** round closes with zero high and zero medium findings, and no REASONED high or medium is left open. **Do not run "one more to be safe".** If you want more assurance after the exit criterion,
  the next unit of assurance is a different kind of reviewer - another vendor's model, or a human - not another
  round of the same kind.
- Watch the yield. When a round's findings are all about wording, numbers in documents and test quality, the
  code has converged and the remaining spend belongs to documentation passes, which are cheap.
- Promotion (phase 6) and rehearsal (phase 7) are for a release candidate. Do not run them on code that is still
  moving: every change after them invalidates the manifest and you pay for them again.

## 8. What this kit does not know

It does not publish a price per round: the project it was distilled from was not metered. The blind benchmark in
`README.md` will publish the first measured numbers. Until then, measure your own with the ROUND lines of your `LOG.md`, and treat any
figure you read elsewhere about this kit as unverified.
