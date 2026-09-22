# Static-analysis triage of this kit's own sources (the worked example for `doctrine/JUDGES.md`, row 1)

Tool: Slither 0.11.6. Command, from `foundry-kit/`: `slither . --filter-paths "test|lib|v4" --exclude-dependencies`.
Scope: `src/HostileERC20.sol`, `src/InvariantBase.sol`, `src/examples/ToyVault.sol`. **35 findings: 0 fixed, 6 by design,
0 accepted, 0 false positive, 29 informational / optimisation (listed by class, not triaged one by one).**

These are test fixtures and a toy, not a product. The point of this file is the shape: every line above
"informational" gets a verdict, a reason, and a test - including when the verdict is "this is the whole point of the
contract", which for a deliberately hostile token it usually is.

| detector | where | verdict | why | proved by |
|---|---|---|---|---|
| incorrect-return (High) | `HostileERC20.transfer` -> `_maybeOmitReturn` | by design | the `omitReturn` switch models tokens that return no data at all; the assembly `return(0, 0)` halting the call IS the behaviour | `test_switch_omitReturnValue` |
| incorrect-return (High) | `HostileERC20.transferFrom` -> `_maybeOmitReturn` | by design | same switch, the other entry point | `test_switch_omitReturnValue` |
| reentrancy-benign (Low) | `HostileERC20._move` | by design | the token calls a registered callback in the middle of a transfer so that tests can re-enter the contract under test; state written after the call is the token's own | `test_callbacks_are_bounded_by_their_fire_count` |
| reentrancy-events (Low) | `HostileERC20._move` | by design | same callback; the event order is not something any consumer of a TEST token relies on | same |
| reentrancy-benign (Low) | `ToyVault.deposit` | by design | the vault reads its balance, calls the token, reads it again: the measured delta is its defence against a lying token, and it sits behind a re-entrancy guard | `invariant_reentrancy_never_succeeded`, `test_a_deposit_that_delivers_nothing_is_refused_not_credited_as_zero` |
| missing-zero-check (Low) | `ToyVault.constructor(token_)` | by design | a toy deployed only by its own tests; a product would check it, and the spec would say who deploys | - (no test: stated as a limit of the example) |

Informational and optimisation (29), by class: `dead-code` **x23** - the internal helpers of `HandlerBase` and
`InvariantAsserts`, which exist to be inherited and are unused until a project does; `low-level-calls` **x2** - the
vault's tolerant token calls; `cache-array-length` **x2** - the two loops in the census printers;
`assembly` **x1** and `missing-inheritance` **x1** - the hostile token's return-data trick, and the fact that it
satisfies `IBalanceReader` without declaring it. None changes behaviour.

## The number itself is a finding, and it was one

This file said **30 findings, dead-code x19**. An independent audit ran the same command with the same version and
got **32** and **x21**; re-measured here after the audit's fixes, **35** and **x23**. Nothing regressed: every extra
row is a helper or a loop that was ADDED (`_bitOneIn`, `_noteInternalDonation`, `boundaryNameAt`, the reach-census
printer), so the count follows the code, which is exactly why a hand-copied one goes stale. Regenerate this file
whenever `src/` changes; `doctrine/SEVERITY.md`: *a number that does not reproduce is a finding*.

Not run: any second static analyser, `forge lint`, `--symbolic`.
