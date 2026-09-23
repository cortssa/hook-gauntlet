# LOG - BlockCapHook

*Example file. The project is fictional. Delete this and start yours.*

Append only, newest at the bottom. **One entry per change.** Reading something is not an entry. Each entry says:
date and model, what changed, why, which files, the verification with numbers read from outputs, and **what was
not verified**.

---

## 2026-03-09 (orchestrator) - round 5 launched

- Brief `briefs/r05.md` from `hook-gauntlet/briefs/audit-round.md`. Bench `~/hg-a05`, dependencies symlinked.
  Aimed at the r04 change to the budget accounting and at the two trade-offs nobody had re-measured.
- Baseline given to the auditor, all read from `runs/r04/battery.txt`: 83 passing, hook 20 986 bytes, fork gas for
  the capped swap 149 302.
- Not verified: that the auditor's bench reproduces the baseline. That is its first task and its report must say so.

## 2026-03-13 (executor) - r05 findings applied

ROUND r05 | phase 4 | regression | vendor-a/large | bench ~/hg-a05 | 2026-03-09..2026-03-12 | 0H 1M 4L 7I reasoned 0 | gate pass | 230k tokens, 95 min | reports/r05.md

- **`F-21` (medium) fixed at the cause.** The per-block budget was reset by comparing a stored block number, and
  the comparison was done in two places that could disagree. Replaced with a single read. This also closed `F-09`
  and `F-17` from rounds 2 and 4, which had been fixed pointwise; both point fixes removed.
- Four lows fixed. One informational refused - the auditor wanted a named error where the design deliberately
  excludes silently; reason written into `SPEC.md` section 3 so round 6 does not re-report it.
- Files: `src/BlockCapHook.sol`, `test/BlockCap.t.sol` (5 regressions, each citing the auditor's test name),
  `SPEC.md` sections 3, 6, 8, 9.
- **Verification:** 88 passing (84 + 2 fork + 2 invariant). Hook 21 104 bytes, margin 3 472 (was 20 986 / 3 590).
  Long fuzz `runs: 1000, calls: 128000`; census: swap succeeded in 912 of 1000 runs, 0 unexplained reverts. Each of the 5 regressions was **mutated** and each went red,
  then green again when restored; output in `runs/r05/mutants.txt`.
- **Not verified:** the gas cost of the new guard on the *sell* path was measured only on the mock, not on the
  fork. The fork is the reference. Carried into the round 6 brief as the first thing to press on.

## 2026-03-14 (scribe) - record brought up to date

- `STATE.md` rewritten for r05. ROUND line for r05 written; the triage counts went to `DECISIONS.md` once the
  executor finished. `DECISIONS.md` entry D-06 added for the undecided item.
- Not verified: nothing to verify, no code changed.
