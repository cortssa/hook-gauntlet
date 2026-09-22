# Brief template: executor with gates

For applying a decision that has already been made. The executor is **not** an auditor and **not** an architect.
It does exactly what the brief says, in the order the brief says, and it **stops at the first gate that fails**
instead of improvising.

A gate is a check with a number. "It looks right" is not a gate. Every gate must be something the agent can run
and paste the output of.

---

# EXECUTOR {{TASK}} - apply what {{DECIDING_ROUND}} decided, up to {{STOP_POINT}}, and stop there

You are the executor. Read `{{DECISION_REPORT}}` in full first. **You do not {{FORBIDDEN_STEP}}**: you do not
touch {{FROZEN_PATHS}}.

## Rules

- You write **only** in: {{WRITABLE_PATHS}}. Everything else is read-only.
- Bench: `{{BENCH}}`, and it is the only place you compile.
- No mainnet writes, no keys, no broadcast, no installs, no browser, no commits.
- **Apply patches with a script that asserts uniqueness**: a helper that replaces `old` with `new` and **fails if
  the match count is not exactly 1**. Write the script to a file with a file-writing tool; do not paste
  multi-line code through a shell. This pattern survives quoting, paths and encodings; ad-hoc shell editing does
  not.
- **Every number you write is read from an output in this session.** Never from memory, never copied from another
  document.
- {{PLATFORM_GOTCHAS}} *- put the ones that will otherwise eat an hour here. Common examples: em dashes inside
  string literals break the Solidity compiler, so strip them from any file you touch; line endings must be
  normalised before the toolchain sees a config file; the shell you are given may mangle paths for a nested
  environment, so call it through a script file instead of an inline command.*

## Steps

**1. {{STEP_1}}, verbatim.** *Say exactly what to apply and from where. If comments may be added, say how many and
in what form.*
**Gate:** the diff against `{{REFERENCE_TREE}}` shows only {{ALLOWED_DIFF}}. Paste the diff.

**2. {{STEP_2}} - the tests.** *List each test to add or change, what it must assert, and why. A test that only
asserts a selector, a length or a boolean is usually asserting less than its name claims: say what the full
assertion is.*
**Gate:** each new regression **fails** when you break the thing it guards (remove the guard, swap the argument,
delete the event) and passes when you restore it. Paste both results. `scripts/mutate.sh` does this on a throwaway
copy and refuses to call it a result when the change did not apply or does not compile.

**3. Full battery.** Run `{{BATTERY}}`. **Gate:** all tests pass ({{EXPECTED_COUNT}} expected) and the measured
size is exactly {{EXPECTED_SIZE}}. If not, **STOP and report**. Do not adjust the expectation to match the result.

**4. Long fuzz.** Run `{{FUZZ}}` (about {{FUZZ_TIME}}; use a generous timeout). **Gate:** the campaign completes
and the campaign's census (`scripts/census.sh` with `CORE="<the actions that matter>"` and `REACH="<the boundaries the promises are about>"`, or the table `scripts/fuzz-long.sh` prints at the end) shows every core action succeeding, and every named boundary reached, in at least the share of RUNS the spec sets as its floor (`MIN_PCT`; measure a few campaigns first and put the floor BELOW the range you see, never inside it - a campaign's reach is a sample) and zero runs with an unexplained revert. The block of logs forge prints is one run, not the campaign, and `reverts: 0` alone is not a gate: it cannot be anything else. If it fails: **change nothing**, save the reduced sequence, and report.

**5. Documents.** *List each document edit as its own lettered item, with the exact source of the text. Include
the table of volatile numbers and the counts.*

**6. Record.** Append a dated entry to `LOG.md` with what you did, the numbers you measured, and the files you
touched. Update `STATE.md`. Start the entry with the ROUND line (`state/README.md`).

## Final answer (at most 15 lines)

Each gate, passed or failed, with its number. What you added. The measured size. The fuzz result. **What you did
not do, and what you did not verify.**
