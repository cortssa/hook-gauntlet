# Changing the code: sketch first, measure before deciding, reopen on purpose

Most of this kit is about finding problems. This file is about the moment after: you are about to change the
contract. Four situations, each with the mistake that taught it.

## 1. Sketch mode - before there is a spec worth attacking

The route starts with a falsifiable spec, and that is right for an idea that has stopped moving. It is wrong for
an idea that has not. If the owner is still discovering what the hook IS - who holds the tokens, whether orders
queue, what the fee depends on - a spec written now will be frozen too early, or rewritten every day, and
every adversarial round aimed by it is spent on a target that will not exist next week.

**Sketch mode is allowed, under three rules:**

- It lives in a directory named as a sketch, and `STATE.md` says `phase: sketch`. Nobody mistakes it for the route.
- The only judges are the local ones: the compiler, unit tests, a first fuzz. **No model rounds in sketch mode.** A
  design conversation with the owner is cheaper and better than an audit of a moving target.
- **Nothing leaves the sketch without passing through phase 1.** When the design stops changing - the owner has
  said "yes, this is it" and the last few changes have not moved an entry point - write the spec from the sketch,
  and start the route at phase 1. The sketch's tests come along; its reputation does not.

How to tell you are in it: the last three changes each altered what a row of the hostile-actor table would say.

## 2. Measure before you decide - variants, bytes, gas

A hook is a single contract near a hard size limit, on a path where gas is somebody else's money. Almost every
fix can be written two or three ways, and they differ in bytes, gas and what they give up. Arguing about it is
an inference; building it is a measurement.

1. Take a baseline: `scripts/size.sh . MyHook` (keep the file it saves), and the gas of the paths the fix touches.
2. For each candidate, `EXPECT=green scripts/mutate.sh . src/MyHook.sol '<old line>' '<new line>'`. It applies
   the change to a throwaway copy, runs the battery, and prints the sizes. For a change larger than one line,
   make the copy yourself with `scripts/bench.sh` and run `battery.sh` and `BASELINE=... size.sh` there.
3. Put the results in a table - bytes, margin left, gas, what each one gives up - and decide from the table.
   If the decision trades something away, it is the owner's (`TRIAGE.md`).
4. **Apply the chosen variant verbatim.** The code that goes in is the code that was measured, not a tidier
   version of it written afterwards.
5. **A margin is a budget.** Decide with the owner what margin must be left for future fixes (`MIN_MARGIN`), and
   treat a fix that would cross it as a finding in its own right: the next bug may not fit.

The mistake that taught it: a fix was diagnosed, sized from memory and applied; the size did not reproduce and
the diagnosis was wrong. Both would have been caught by building the variant first.

## 3. Comparing two revisions - replay the sequence, not the seed

When the fuzzer fails on the new revision, the first question is whether the old one had the same problem. **Do
not answer it by re-running the same seed on the old code.** A fuzzer builds its inputs partly from what the
contract emits and stores; change an event and the same seed is a different campaign. It will pass, and you will
conclude, wrongly, that the new revision introduced the bug.

Do this instead:

1. Take the **shrunk sequence** from the failure output: the list of handler calls with their arguments.
2. Write it as a plain deterministic test that calls the handler's actions in that order:

   ```solidity
   function test_replay_campaign_failure_2026_01_31() public {
       handler.placeOrder(16, 3, 1e18); // copied from the shrunk sequence, in order
       handler.warp(7 days + 1);
       handler.setHostile(2, true);
       handler.swap(4, 5e17);
       invariant_an_order_fills_at_most_once(); // the invariant that failed, called directly
   }
   ```

3. Run that test on **both** revisions (two benches). Now the comparison means something.
4. Then ask whether the arbiter is wrong before you ask whether the contract is (`INVARIANTS.md`). Keep the test
   either way: it is a regression test now.

Replaying a seed is fine for one thing only: reproducing a failure on the **same** code, to watch it again.

## 4. Reopening a promoted revision

Promotion freezes a release candidate: a canonical copy, a manifest of hashes, a guard that fails on drift. Then a
late round or the black-box finds something, and the code has to change. This will happen. Do it on purpose:

1. **Say it.** `DECISIONS.md`: what is being reopened, why, and what the owner chose (fix now, or accept with a
   number and ship as is). `STATE.md`: `last_promotion=yes` under `bytecode_changed_since`. From this line on,
   nothing is "promoted".
2. **The guard must go red, and stay in the release path.** Do not delete it, do not refresh the manifest to make
   it quiet. While you work, use a development runner - the battery WITHOUT the guard, under a different name -
   so that the everyday command is green for the right reason and the release command is red for the right reason.
3. **Batch what you can.** A reopened revision pays for the whole tail again (battery, long fuzz, a diff-aimed
   round, promotion). If other accepted-for-later items exist, this is when they go in - with the owner's say.
   Anything that changes what integrators read (events, errors, views) is cheapest to fix now and impossible
   later if the contract is immutable.
4. **Walk the table again from row 6** of `NEXT.md`. The diff-aimed round is not optional because the change is
   small; small changes to frozen code are where the last bugs live.
5. **Promote again from scratch**: new copy, new manifest, guard green, bytecode reproduced from a clean build
   (`forge clean` first - a stale `out/` directory has passed a guard while simulating the previous revision).
   If the hook's address depends on its bytecode, **the address changed**: everything that names it is stale.
6. The reports of the previous revision stay in the dossier. A reopened release is part of the history, not an
   embarrassment to tidy away.
