# SPEC - CappedDynamicFeeHook (the kit's worked example), revision r1

Battery: `scripts/battery.sh foundry-kit/v4` · size and margins in section 8 · 1 adversarial round (r01, DISCOVERY),
0 black-box rounds. **A toy. Not deployed. Not audited by humans.** The shape of `briefs/spec-template.md`, cut to what
a hook this small needs; the threat model it stands on is written at the top of `CappedDynamicFeeHook.sol`.

## 1. What this is

A v4 hook that sets a pool's LP fee from congestion, one block late: every swap in block B pays
`min(BASE_FEE + STEP * n, MAX_FEE)` = `min(500 + 500 n, 5000)` hundredths of a bip, where `n` is the number of swaps the
pool saw in block B-1 (0 if B-1 saw none, or if the pool's last swap is older than B-1). No delta, no token, no owner.
**Failure** = the pool charges more than 5 000; or a swap in block B is charged other than what `quoteNextFee` returned
at any earlier moment of block B.

## 2. The principle

One pure function (`feeForCongestion`) is the whole rule; the fee of a block is computed once, at its first swap, and
stored (`blockFee`), so nothing inside a block can move it; state is per `PoolId`; every DECLARED entry point is
`onlyManager` (the undeclared ones revert `NotImplemented` for every caller, the manager included); an unknown pool is
refused, never defaulted.

## 3. What a hostile actor can do -> what the hook answers

| a hostile actor can ... | answer | proved by | reached in the campaign by |
|---|---|---|---|
| call an entry point directly | `NotTheManager` (declared) / `NotImplemented` (undeclared) | `test_only_the_manager_may_call_the_hook`, `test_a_caller_above_the_managers_address_is_refused_too`, `test_every_undeclared_entry_point_reverts` (MUTATION-TESTED, `MUTANTS.md` family one) | - |
| swap many times in one block | that block's fee does not move; the NEXT block's rises, capped at 5 000; the counter saturates | `test_every_swap_in_a_block_pays_the_same_fee`, `test_congestion_cannot_push_the_fee_past_the_cap`, `test_the_counter_saturates_...`, `invariant_the_pool_never_charged_more_than_the_cap` | `swapBurst`; reach "fee at the cap" |
| **read the quote, then have others trade ahead of it in the same block** (r01, F1) | the victim is charged the quote it read | `test_r01_F1_nine_dust_swaps_ahead_of_a_victim_do_not_move_the_fee_it_was_quoted` (seen red on the first rule, `5000 != 500`), `invariant_the_fee_never_moves_inside_a_block` (seen red on the first rule) | `dustAheadOfVictim`; reach "victim traded after dust in its block" |
| inflate congestion to raise the next block's fee | allowed, in the open: the next block's fee is fixed before it begins and readable by anyone before they trade | `test_r01_F1_residual_the_dust_raises_the_next_blocks_fee_in_the_open_and_only_that` | `swapBurst` |
| read the quote in one block and land in a later one | not bound: see T1 | `test_latency_one_shows_a_gap_the_calibration_cannot` (sandbox, SUPPORTED) | - |
| pass arbitrary `hookData` | ignored | `testFuzz_hook_data_changes_nothing` | - |
| initialise a pool naming this hook with a static fee, or naming another hook | `NotADynamicFeePool` / `NotMyPool` | `test_a_static_fee_pool_cannot_use_this_hook`, `test_afterInitialize_refuses_*` | - |
| swap on, or quote, a pool never initialised | `UnknownPool` | `test_beforeSwap_refuses_an_unknown_pool`, `test_the_quote_refuses_a_pool_the_hook_has_never_seen` | - |
| initialise a **native-currency** pool (r01, F2) | accepted: the hook moves no value and reads no currency, so nothing changes | `test_r01_F2_a_native_currency_pool_is_accepted_and_charges_its_quote` (a real swap each way; a mutant that refuses native pools is KILLED by it) | - (the kit's router refuses native currency) |
| use a hostile currency (fee on transfer, short delivery, gas hog, paused, a manager it blocks or lies to) | the failure lands on the router or the settlement, never on a wrong fee | the invariant suite with `HostileERC20`'s seven switches | `setFeeOnTransfer`, `setShortDeliver`, `setGasHog`, `setPaused`, `setOmitReturn`, `setManagerBlocked`, `setManagerUnreadable` |
| roll the block backwards (a replay, a fork behind cached state) | the stored state is stale whichever side; the quote and the charge agree | `test_a_stored_block_ahead_of_the_current_one_resets_and_the_quote_agrees` (MUTATION-TESTED, family two) | - |

## 4. Invariants, in words

1. The pool never charges more than 5 000 (`invariant_the_pool_never_charged_more_than_the_cap`, read off the manager's
   `Swap` event, not the hook).
2. What the hook quoted just before a swap is what the pool charged (`invariant_every_quote_matched_the_execution`).
3. **Inside one block the fee does not move**: every quote read and every charge in a block equals the first quote read
   in it (`invariant_the_fee_never_moves_inside_a_block`). Added by the growth rule after r01: invariant 2 was true on
   the first rule and F1 was still there, because 2 only ever compared a swap with the quote read immediately before it.
4. The hook holds no token; the router and the helper hold nothing between actions; both currencies are conserved; the
   hook's stored state is within its bounds; no unexplained revert.

## 4b. Fuzz actions

The 19 handler actions of `test/examples/CappedDynamicFeeHook.invariants.t.sol`: `fund`, `swap`, `swapBurst` (N swaps in
one block, then one block step and a swap, where they are charged), `dustAheadOfVictim` (r01: a victim's quote, 1-12
dust swaps by somebody else, the victim's swap compared with ITS quote), `addLiquidity`, `removeLiquidity`,
`nextBlock`, `readQuote`, `donateToHook`, `donateToManager`, seven hostile switches, `calmDown`, `fundReserve`.

## 5. Admission rules

`afterInitialize` refuses a pool whose fee is not the dynamic-fee flag, or that names another hook. Any currency pair
may be initialised, native currency included (section 3, F2).

## 5b. Assumptions

| assumption | why | breaks if false | evidence |
|---|---|---|---|
| the protocol fee is 0 | the harness sets none | invariant 1 and 2's oracle (the event's fee is the LP fee) | REASONED |
| `block.number` is the block a swapper lands in | Ethereum L1 | "one block late" means something else on a chain whose `block.number` is an L1 estimate (`SimClock`) | UNVERIFIED |
| the deployed manager behaves like the pinned source | the fixture manager runs the same suite | everything | SUPPORTED (the suite on both managers) |

## 6. Accepted trade-offs, each with a number

- **T1 - a quote binds its own block only.** A quote read in block B and executed in a later block pays that block's
  fee, which the swaps of the block before it set. Measured in the sandbox (`latency-one`, one run, deterministic): a
  trader one block late was short 3.1e14 raw quote units over 40 swaps of 1e17. An off-chain reader should evaluate
  `quoteNextFee` at the block it expects to land in; a call against the latest block answers for that block.
- **T2 - the fix of F1 costs honest swappers when blocks are busy.** The fee now stays up for a whole block after a busy
  one instead of resetting. Measured on the sandbox's ordering population, same seeded world, seeds 1-3, first rule ->
  this one: the honest victim's P&L per run +1.16e15 -> -1.23e15 under FCFS and -4.65e16 -> -5.08e16 under BUNDLE; the
  sandwicher +8.9e15 -> -2.5e16. The cause, measured by a verifier on an instrumented copy: with the same constants the
  MEAN fee of the pool rises about 60-70 % for everyone (640 -> 1 080 per swap under FCFS, 1 420 -> 2 240 under BUNDLE),
  because a busy block now raises the whole next block instead of resetting; and the victim's edge under the first rule
  was an artifact of its place in the seeded world - it was first in its block in 29 of 29 swaps and paid the base fee
  every time. Chosen over the first rule because it removes the ordering attack on a quoted swap; the price is a higher
  fee level, not a different one for the victim. This is the kit's example, and the choice is the kit's, not an
  owner's acceptance.

## 7. Round r01 (DISCOVERY, 2026-09-23): what it found, and what became of it

| finding | severity | what was done | evidence now |
|---|---|---|---|
| F1: nine 1-wei swaps ahead of a victim in its block push its fee 500 -> 5 000 (0.372 % of output on 10 tokens; 1 349 046 gas of dust) | medium | **fixed at the cause**: the fee of a block is fixed by the block before it. Red first: the round's test, the new invariant and the new action were each seen red on the first rule; the first rule put back as a one-line mutant is KILLED three ways | MUTATION-TESTED |
| F2: native-currency pools accepted, spec undecided | low | **decided: accepted** (section 3); a real native swap each way | MUTATION-TESTED (the refusing mutant dies) |
| F3: "six hostile switches" (there are seven) | info | this spec says seven | - |
| F4: "not tested both directions" | info | the campaign swaps both ways (`swap` takes a direction, `swapBurst` alternates) | PROPERTY-TESTED |
| F5: "every entry point is onlyManager" | info | section 2 now says "every declared entry point" | - |
| F6: `poolState().lastQuotedFee` stale after a block change | info | the field is now `blockFee`, documented as the fee of the stored block ("history, not the next fee: read `quoteNextFee`") | - |
| F7: no measured numbers in the spec | info | section 8 | - |
| F8: several swaps of one pool inside one unlock step the fee each time | info (REASONED) | closed by the F1 fix: every swap of a block pays the same fee, one unlock or many | REASONED (the kit's router does one swap per unlock) |

## 8. Measured numbers (forge 1.8.1, solc 0.8.26, cancun, 2026-09-23)

- Sizes (`scripts/size.sh foundry-kit/v4 CappedDynamicFeeHook CappedDynamicFeeHook.manager`): runtime 4 881 B / initcode
  5 636 B (default profile), 4 697 B / 5 360 B (the build the tests deploy); margins to EIP-170 / EIP-3860: 19 695 /
  43 516 and 19 879 / 43 792.
- Native mutation (`forge test --mutate src/examples/CappedDynamicFeeHook.sol`): 109 generated, 104 valid, 98 killed,
  6 survived (all equivalent, `MUTANTS.md`), 94.2 %, 166 s.
- Census, five fresh campaigns of 64 runs (65 lines each; the root README says why): "fee at the cap" reached in 33,
  42, 40, 49 and 30 runs; "victim traded after dust in its block" in 31, 26, 22, 42 and 30.
- `forge lint`: 5 `unsafe-typecast`, triaged in `../../STATIC-TRIAGE.md`.

## 9. Surface for the next round

The residual of F1 (congestion inflated for the next block: who profits, at what gas, against which victims - a
sandbox agent does not exist yet); T1 on a chain whose `block.number` is not the landing block; the native pool under
the hostile campaign (not run: the harness has no native support); two pools sharing a currency in one campaign.

## 10. What an outside consumer sees

`FeeQuoted(id, swapCountAfter, fee)` per swap: `fee` is the block's (the same in every event of one block and pool),
`swapCountAfter` sets the next block's. Views: `quoteNextFee(key)` (this block's fee), `feeForCongestion(n)`,
`poolState(id)` (`blockFee` is the fee of `blockNumber`, which may be in the past). Not in the log: initialisation emits
no hook event; a block that sees no swap emits nothing, and the fee after it is the base.
