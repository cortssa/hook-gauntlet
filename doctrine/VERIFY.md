# Checking work - someone else's, and your own

This kit delegates: auditors, executors, researchers, outside reviewers. Delegating the work does not delegate the
responsibility for believing it. This file is the orchestrator's discipline, written down because every rule in it was
learned by breaking it - several of them on the day this kit was audited, by the people who wrote it.

The short version: **a result you did not check is a rumour with good formatting.**

## Before the work starts

1. **The brief is a file, and the scope in it is physical.** Which paths may be written, which bench is theirs, what
   they must not open. "Stay inside your scope" is a wish; a bench that does not contain the file is a fact.
2. **Every gate has a number.** "Tests pass" is not a gate. "N passed, 0 failed, 0 skipped", with N read from the output and written down, is.
3. **Seal your expectation before you look.** When you test whether a document or an agent gives the right answer,
   write the answer you expect - in the log, dated - BEFORE the reply arrives. Afterwards you will be able to explain
   any answer at all; only the sealed one tells you whether you were surprised.
4. **Freeze what is being reviewed.** A manifest of hashes before the review, checked again before you read the report.
   A report about a tree that moved underneath it is a report about nothing.

## When the work comes back

5. **Read the whole report.** The summary drops the measurements, and the measurements are where the decisions are.
   Say in the log what you did NOT read.
6. **Reproduce before you fix.** Every high and medium finding, on a bench of your own, by your own means - not by
   re-running their script. A finding you could not reproduce is not yet yours to fix, and a fix applied to an
   unreproduced finding is a guess.
7. **Verify with your own instruments, not theirs.** Your own mutants, your own bench, your own copy of the tree. An
   executor's tests passing under the executor's runner is one opinion, stated twice.
8. **Ask WHY it passes, not THAT it passes.** Read the name and the message of the test that went red, the revert
   reason behind an `expectRevert`, the line that made the gate green. "The mutant was killed" by a test that fails for
   an unrelated reason has killed nothing (`LESSONS.md` 13).
9. **Check that nothing else moved.** The contracts' hashes before and after a tests-only task. The files outside the
   scope. The numbers the change should NOT have changed.
10. **A contested claim becomes a test.** When a reviewer says you are wrong and you think you are right, neither
    opinion matters: write the ten-line test. Whoever is wrong finds out, and the test stays.
11. **When two sources disagree, open the primary source.** Two research passes, two documents, a reviewer and your
    memory: do not pick the one you prefer. Read the code, the specification, the file in the repository.

## When you fix what came back

11b. **A fix to a gate arrives with the case that sees it red.** Any change to a gate script, to the harness base, or
    to anything else whose job is to go red: FIRST the new case (in `scripts/selftest.sh`, or a mutant with its test),
    run against the UNFIXED code and seen failing; THEN the fix. The fixes to this kit's first audit skipped that
    step, and a second review found that half of one of them could be deleted without anything noticing, and that two
    others had opened new doors - one of which deleted the project it was asked to copy.
11c. **Then a verifier pass over the fixes, by someone who did not write them** (`briefs/verifier.md`), told to assume
    they were badly applied. Fixes are written faster and reviewed less than the code they repair. That pass found
    four medium findings here, in code that had just been audited and corrected.

## Reviewers you do not control (another vendor's model, a person you cannot question)

12. **Make them prove they read it.** Ask for the last sentence of a named file, the title of a late section. A
    reviewer that invents the quotation did not read the material, and everything it said is worth what an
    unread review is worth - including the praise.
13. **Make them attack the plan, not only the result.** The second question - "here is how I intend to fix what you
    found; what is still naive?" - is usually worth more than the first.
14. **Triage in writing:** valid / partly / wrong (with the evidence) / debatable (the owner's call). A review you
    agreed with in your head changes nothing.

## After a change of rules

15. **Sweep for the old rule.** Grep for its words in every file. A new doctrine file does not retire the five sentences
    elsewhere that still teach the old one; on the day this was written that sweep found fourteen.
16. **Then have a reader with no context hunt for contradictions,** with both sentences quoted. You cannot do this
    yourself: you know what you meant.
17. **One source per number.** Every figure that appears twice will disagree with itself within a week (`LESSONS.md` 4).

## About yourself

18. **Your own work gets the same treatment.** The three false greens in this kit's gate scripts were written by its
    orchestrator and found by an auditor with a fresh context. Plan for that auditor; do not wait to be embarrassed.
19. **Write your mistakes into the log, with the cause.** Not "fixed X" - "I verified that it passed and not why; here is
    what that cost". The next agent inherits your habits from your log.
20. **Every report ends with what was not verified.** It is the most useful paragraph in it and the first one dropped by
    anyone who wants to look finished.
21. **Know when your own checking degrades.** Long sessions make for confident, shallow verification. Say so, stop, and
    leave the state on disk.
