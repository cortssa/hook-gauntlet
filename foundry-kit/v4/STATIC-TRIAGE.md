# Static-analysis triage of the v4 module's worked example (`doctrine/JUDGES.md`, row 1)

Tool: `forge lint`, forge 1.8.1. Command, from `foundry-kit/v4`: `forge lint src/examples/CappedDynamicFeeHook.sol`.
Scope: `src/examples/CappedDynamicFeeHook.sol` (the one-block-late rule, 2026-09-23). **5 warnings, one rule
(`unsafe-typecast`), in two groups: 0 fixed, 5 by design, 0 accepted, 0 false positive; 2 notes (style), listed.**
The same lints run inside `forge build`; this file is where they are answered instead of scrolled past.

| rule | where | verdict | why | proved by |
|---|---|---|---|---|
| unsafe-typecast x1 | `feeForCongestion` L146, `uint24(raw)` | by design | the cast is on the branch `raw < MAX_FEE`, and `MAX_FEE` (5 000) fits `uint24`; `raw` is computed in `uint256`, so the product cannot wrap before the comparison either (`SPEC.md` section 3, "swap many times") | `test_the_fee_schedule_climbs_and_then_stops` (`type(uint32).max` swaps -> `MAX_FEE`), `testFuzz_the_fee_is_never_above_the_cap_or_below_the_base` |
| unsafe-typecast x4 | `_feeOfThisBlock` L153, `beforeSwap` L203 and L204, `afterInitialize` L183: `uint64(block.number)` | by design | `block.number` truncated to the stored `uint64`. It is compared as an IDENTITY ("the stored state is THIS block"), never as an ordering, so a truncated or rolled-back number makes the stored state stale - the fee falls back to the one derived from the block before, and the quote and the charge still agree. 2^64 blocks is ~7e12 years at 12 s. The one place an ordering-like step is taken, "the block right before this one", is computed in `uint256` (`uint256(s.blockNumber) + 1 == block.number`) and cannot overflow | `test_a_stored_block_ahead_of_the_current_one_resets_and_the_quote_agrees` (the `==`->`>=` and `!=`->`<` mutants on these lines are killed by it, `src/examples/MUTANTS.md` family two) |

Notes (style, not triaged one by one): `screaming-snake-case-immutable` x1 - `manager`, a public immutable whose name is
the interface other code reads; `unwrapped-modifier-logic` x1 - `onlyManager`, one comparison, nothing to save.

Regenerate this file whenever the hook changes: the line numbers above are of the one-block-late rule, and the first
rule had five warnings of the same rule at other lines. Not run on this file: Slither (it does not report
`unsafe-typecast`, `doctrine/JUDGES.md`), any other analyser, `--symbolic`. The root kit's own triage is
`../STATIC-TRIAGE.md`.
