# Brief template: promotion (phase 6)

Promotion is making one copy of the code **canonical**: the copy that a human auditor reads and that a deployment
would use. Everything after this point compares against it.

Promotion is an executor task with gates. It changes no Solidity. If a gate fails, the mistake is in your copy or
in your manifest, never in the guard - **do not fix the guard**.

Promote code that has stopped moving. If a promoted revision has to change afterwards - and the late rounds exist
to make that happen - reopen it on purpose: `doctrine/CHANGES.md` section 4.

The copy is also the one step of the whole route that nobody has audited, because it did not exist before. Plan an
audit round **against the promoted artifact**, not only against the working tree.

---

# PROMOTION {{REVISION}} - executor, with gates

Owner's decision ({{DATE}}): **{{CHOICE}}**. The working tree already is the verified {{REVISION}}
({{BASELINE_TESTS}} tests, size {{SIZE}}, fuzz clean, rounds {{ROUNDS}}). Promote it to `{{CANONICAL_DIR}}`.

Read first: `{{REVISION_NOTES}}` in full, the existing `{{MANIFEST}}`, the drift guard `{{GUARD}}`, and the voting
sections of `{{VERIFIER_REPORT}}`.

## Rules

- No broadcast, ever. No keys, no installs, no browser, no commits.
- **Do not change any `.sol` file, any test, or the guard.**
- Document edits through a patch script with a uniqueness assertion (`count == 1`), written to a file.
- Every number you write is read from an output in this session.

## Steps and gates

**1. The copy.** Copy the sources into `{{CANONICAL_DIR}}`.
**Gate:** a recursive diff between the working sources and the canonical copy, excluding documents, is **empty**.
Paste it.

**2. The manifest.** Write `{{MANIFEST}}`: revision; the **sha256 of every file**, including the build
configuration; battery numbers; measured contract sizes and the margin to the size limit; the long-fuzz result;
who decided the promotion and on the strength of which reports; and, for each contract, one line saying what it is
and what about it depends on a human.
Include, per contract, the keccak256 of the runtime and of the creation bytecode from a CLEAN build.
**Gate:** each hash reproduces when recomputed. Say which files changed since the previous revision and which did
not - a small perimeter is itself evidence about what the revision touched.

**3. The documents that ship with the code.** Update the spec and the runbook: header numbers, every changed
behaviour, every new event or error signature, and the sections the verifier asked for.
**Gate:** none of them contradicts the manifest.

**4. Guard and battery.** Run the full battery AND the drift guard (`scripts/release-guard.sh` - the kit's `battery.sh`
does not call it for you; a project's own runner should).
**Gate:** the guard reports the canonical copy identical to the working sources **and** matching the manifest, and
every test passes. If the guard fails, fix the manifest or the copy, **not the guard**.

**5. Bytecode, not source.** Run the deployment **simulation** (no broadcast).
**Gate:** it completes, and the **keccak256 of each contract's runtime bytecode matches the manifest** (record the hash,
not only the size: an old artifact that differs by one constant has the same size and would pass). Clean the build directory first,
inside the script. A build tool that skips compilation and reuses a stale artifact will pass every source-level
check while simulating the wrong code; this gate is the only one that catches it. See `doctrine/LESSONS.md` §6.

**6. Stale-number sweep.** Grep the documents for the **previous** revision's numbers - the old test count, the
old sizes, the old margins, the old event signatures.
**Gate:** every hit is either corrected or explicitly marked as history. Report the count before and after.

**7. Record.** Mark the revision notes as promoted, with the gate numbers. Append a dated entry to `LOG.md`,
update `STATE.md`, with the ROUND line at the top of the entry.

## Verify the guard actually guards

Once, not every time: introduce a difference on purpose in a scratch copy and confirm the battery goes red. Check
it also catches an **added** file and a **deleted** file, not only a modified one. A guard that iterates over the
files it already knows about is blind to a new one.

## Final answer (at most 12 lines)

Each gate with its number. The new hashes. The simulation's printed runtime size. What the stale-number sweep
found. What you did not verify.
