# The survivors of `forge test --mutate src/examples/CappedDynamicFeeHook.sol`

Same rule as the root kit's `src/examples/MUTANTS.md`: every mutant the suite did not kill is either killed by
a named test in `test/examples/CappedDynamicFeeHook.t.sol`, or argued here to be an **equivalent mutant** - a
different program text that no input can tell apart from the original. "The suite never tried that" is not an
argument.

```sh
cd foundry-kit/v4 && forge test --mutate src/examples/CappedDynamicFeeHook.sol
```

**This file is the only place this hook's mutation numbers live.** They used to be repeated in
`v4/README.md` as well; one of the two went stale first, which is what a duplicated number does.

| | generated | valid | killed | survived | invalid | score | time |
| --- | --- | --- | --- | --- | --- | --- | --- |
| first run | 93 | 89 | 79 | **10** | 4 | 88.8 % | 51 s |
| after the tests below | 93 | 89 | **83** | 6, all equivalent | 4 | **93.3 %** | 51-67 s |

forge 1.8.1, solc 0.8.26. Re-measured after an independent audit and after the handler was reworked: same
generated count, same score, 55 s. The time varies with what else the machine is doing; the counts do not.

## What the first run said

**10 survivors** out of 89 valid mutants, on a hook that already had a threat model, a unit test per line of
it, an invariant campaign with a `swapBurst` action written specifically to defeat a vacuous pass, and a
mutant hunt done by hand in review. Six of the ten are equivalent. The other four were real, and they fall
into exactly two families.

## Family one: `!=` on an address, changed to `<` (2 mutants, both killed)

```solidity
if (msg.sender != address(manager)) revert NotTheManager();      // -> msg.sender < address(manager)
if (address(key.hooks) != address(this)) revert NotMyPool();     // -> address(key.hooks) < address(this)
```

Both survived, and the reason is worth more than the fix. Every caller the suite had ever used - `0xB0B`,
`0xA11CE`, `address(this)`, `0xDEAD` - sorts **below** a mined hook address and below a freshly deployed
manager. A guard reduced to "refuse everyone below me" therefore refused every attacker the tests owned, and
looked exactly like a working guard.

Killed by `test_a_caller_above_the_managers_address_is_refused_too` and
`test_afterInitialize_refuses_a_pool_naming_a_hook_above_this_one`, which probe with
`address(uint160(target) - 1)` and `address(uint160(target) + 1)` and assert that the two probes really are on
opposite sides before using them.

**The generalisable rule: an address is an identity, not an ordering. Wherever your hook compares one with
`!=`, test an address on each side of it.** Mined hook addresses make this worse than usual, because the
mining puts your own address in a region the hand-written fixtures in your tests will never reach.

## Family two: the block comparison, in both directions (2 mutants, both killed)

```solidity
return feeForSwapIndex(s.blockNumber == uint64(block.number) ? s.swapsInBlock : 0);  // -> >=
if (s.blockNumber != uint64(block.number)) { ... reset ... }                          // -> <
```

Both mutations are invisible while the stored block number is never ahead of the current one, which is to say
while the chain only moves forwards. The hook, though, is not relying on the chain here - it is asserting an
identity, "the state I stored belongs to THIS block" - and the suite had never checked what happens when the
identity fails in the unexpected direction. That direction is what a `uint64` truncation looks like, and what
a replay or a fork pinned behind cached state looks like.

Killed by `test_a_stored_block_ahead_of_the_current_one_resets_and_the_quote_agrees`, which rolls the block
backwards and then asserts the two things the hook promises: the counter is stale, and **the quote and the
execution still agree**. Each mutation breaks one side of that agreement, so one test kills both.

## Equivalent mutants (6)

### 1 and 2. `AFTER_INITIALIZE_FLAG | BEFORE_SWAP_FLAG` -> `+`, and -> `^`

The two flags are distinct single bits of the address (`1 << 12` and `1 << 7`). When two operands share no
bits, `a | b`, `a + b` and `a ^ b` are the same number. Nothing downstream can distinguish them.

The premise - that the two flags stay disjoint - is asserted in
`test_the_premises_behind_the_equivalent_mutants_still_hold`, so that this argument goes red if Uniswap ever
renumbers a flag rather than quietly becoming false.

### 3 and 4. `fee | LPFeeLibrary.OVERRIDE_FEE_FLAG` -> `+`, and -> `^`

Same argument, with a condition that is this hook's own doing: `fee` comes from `feeForSwapIndex`, which caps
it at `MAX_FEE` (5 000), and `OVERRIDE_FEE_FLAG` is bit 22 (4 194 304). No value the cap allows can touch that
bit, so the three operators agree.

Worth noticing: **this equivalence is bought by the cap.** A hook that returned an uncapped fee here would
have three genuinely different programs, and `+` would corrupt the override flag on any fee above 4 194 303.
The same test asserts `MAX_FEE < OVERRIDE_FEE_FLAG`.

### 5. `raw >= MAX_FEE ? MAX_FEE : uint24(raw)` -> `raw > MAX_FEE`

The two differ on exactly one input, `raw == MAX_FEE`, and there the original returns the constant `MAX_FEE`
while the mutant returns `uint24(raw)`, which is the same 5 000. Same value, so no caller can tell.

### 6. `s.swapsInBlock != type(uint32).max` -> `s.swapsInBlock < type(uint32).max`

`s.swapsInBlock` is a `uint32`. For a value of that type, "not the maximum" and "below the maximum" are the
same predicate over every value the type can hold; there is no state in which they differ. The saturation
behaviour they both guard is tested by
`test_the_counter_saturates_at_the_top_instead_of_wrapping_back_to_the_base`, which writes the counter to its
maximum with `vm.store` and asserts the layout first.

## What this pass is worth

The four real survivors were found by a free tool in under a minute, on a hook that had already been through
a hand-written mutant hunt in review. Neither the unit tests, nor the invariant campaign, nor a reviewer
looking for exactly this kind of thing had produced a caller above the manager's address or a stored block
ahead of the current one. **Run the mutation pass before you pay for a round, and read the survivor list one
line at a time.**
