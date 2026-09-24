# Contributing

This repository is a method with numbers attached. A contribution is useful when it adds a measurement, a guard, or a
case - not when it adds a claim. In order of usefulness:

1. **A run of the route on a hook we did not write.** Open an issue with: the step where you stalled or guessed
   (document line, command, output line), what the human auditor found afterwards that the route did not, and what a
   test declared as evidence turned out to be vacuous. That is the evidence this repository lacks most (`README.md`,
   *Status*).
2. **A run on another model or another agent harness.** Same score sheet as the walks in *Status*: steps clean /
   guessed / stalled, findings against a sealed key, cost. The README names this as the next measurement.
3. **One new hostile behaviour** in `foundry-kit/src/HostileERC20.sol` (rebasing by shares, a per-wallet fee, revert on
   a zero transfer, `approve` refused from non-zero to non-zero, a sender blocklist, "moves and then returns false",
   another return-data shape): one switch, one unit test per switch, seen red on a contract that does not check it.
4. **One new attack class or one new row** in `doctrine/HOOK-ATTACKS.md`, with the test that exercises it named in
   the row. A class without a test file is a question, and is labelled so.
5. **One regression test** for a false green you found in `scripts/`: the self-test case that sees it red first
   (`scripts/selftest.sh`; `doctrine/VERIFY.md` 11b).
6. **One verifier report** over an existing example: reproduce a claim by your own means and say what held and what
   broke, without fixing it.
7. **A fork test or a block-pinned fixture** against a real chain: the one line left on the v4 module's gap list.

Rules that every contribution keeps:

- **Red first.** A test enters with the broken code it was seen to fail on; a guard enters with the self-test case that
  makes it go red on purpose.
- **Say what you measured, on which forge.** The kit pins forge 1.8.1 and CI adds 1.8.3; a number from another version
  says so.
- **Never a deploy, a broadcast or a key.** The route ends at audit-ready; a contribution that suggests otherwise is
  declined.
- **Nothing that identifies a private project.** Measurements of tool cost are fine; names, addresses and mechanics
  of a hook that is not an example here are not.
- **Plain Markdown, plain bash, no new dependency** unless the CI job that needs it comes with it.

Before opening a pull request, run the three gates and paste their last lines:

```sh
scripts/selftest.sh                              # SELFTEST PASSED: every guard went red exactly where it was supposed to.
scripts/battery.sh foundry-kit                   # BATTERY PASSED
V4_MANAGER=source scripts/battery.sh foundry-kit/v4   # BATTERY PASSED
```

A flaw in the kit itself - a guard that can be made to pass when it should fail - goes through `SECURITY.md` first.
