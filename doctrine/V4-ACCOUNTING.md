# How the pool manager keeps its books: the map your invariants come from

`HOOK-ATTACKS.md` is a list of prompts. This is the thing underneath them: what the v4 `PoolManager` does, in what
order, to whose delta, at every operation a hook can be part of. A hook that touches value has to model this, operation
by operation; the invariants that matter ("who can lose what", `INVARIANTS.md`) are statements about these rows.

**Provenance and limits.** Read from `Uniswap/v4-core` at commit `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc` (the pin in
`scripts/install-v4.sh`), by one agent drafting and a second one falsifying every row against the source with file and
line: 29 rows confirmed, 10 corrected, 0 wrong. Evidence label for this whole file: **SUPPORTED by source reading - not
tested.** No row here has a test in this kit yet. If your pin differs, diff it. Line numbers are for that commit;
`PM` = `src/PoolManager.sol`, `H` = `src/libraries/Hooks.sol`. Nothing is quoted from the manager's source, which is BUSL.

## The spine

- Inside `unlock`, every (account, currency) pair may carry a non-zero delta. When the callback returns, the COUNT of
  non-zero pairs must be zero, or the whole thing reverts `CurrencyNotSettled` (PM 104-114). It is a count of pairs, not
  a sum: nobody can leave a delta open for someone else to absorb unless that someone actively settles it.
- Callable with the manager LOCKED: `initialize`, `updateDynamicLPFee`, **and `sync`** (no modifier at all, PM 279).
  Everything else that moves a delta needs the unlock.
- Any combination of the operations below may run inside one callback. `swap -> settle` and
  `swap -> take -> swap -> settle` are different state machines (`HOOK-ATTACKS.md` 26).

## Operation by operation

| operation | hooks, and the flag that gates each | deltas created, for whom | whose code can run here | does a hook's return value change the books? | what must hold |
|---|---|---|---|---|---|
| **initialize** (PM 117-142) | `beforeInitialize`, then `afterInitialize` | none | both hooks; a hook may call `updateDynamicLPFee` from `afterInitialize` | no - selector only | hook address valid for the fee; no lock needed |
| **modifyLiquidity** (PM 145-184) | `beforeAdd/RemoveLiquidity` by the sign of `liquidityDelta` (`> 0` add, `<= 0` remove); then `afterAdd/RemoveLiquidity` | `hookDelta` to the hook (if non-zero); `callerDelta` to the caller | both hooks | **yes** - the after-hook's delta is parsed ONLY with the matching RETURNS_DELTA flag; `callerDelta -= hookDelta`. Without the flag the returned delta is **discarded silently** | per currency: `callerDelta_final + hookDelta == principalDelta + feesAccrued` |
| **swap** (PM 187-227) | `beforeSwap`, then `afterSwap` | `hookDelta` to the hook; `swapDelta` to the caller; the protocol fee goes to a storage mapping and is **not** a delta | both hooks | **yes, three ways**: (1) the SPECIFIED half of `BeforeSwapDelta` changes the amount swapped (needs BEFORE_SWAP_RETURNS_DELTA); it may not flip exact-in into exact-out, but it MAY reduce the amount to zero, and then the pool swap returns a zero delta; (2) `afterSwap` returns an int128 in the UNSPECIFIED currency (needs AFTER_SWAP_RETURNS_DELTA); (3) an LP-fee override - needs a dynamic-fee pool and the override bit `0x400000`, NOT a returns-delta flag; without the bit an invalid value is ignored, with it a fee above 100 % reverts inside the pool | `amountSpecified != 0`; `swapDelta_final + hookDelta == the pool's swapDelta`; hook deltas map to currency0/1 by `(amountSpecified < 0) == zeroForOne` - test all four combinations |
| **donate** (PM 256-276) | `beforeDonate`, then `afterDonate` | a negative delta to the caller, booked BEFORE `afterDonate` runs | both hooks | no | the pool must have in-range liquidity |
| **take** (PM 291-297) | none | `-amount` to the caller, booked BEFORE the transfer | **yes**: a native transfer is a raw call with ALL gas to an arbitrary recipient; an ERC-20 transfer is an arbitrary token | - | the debt is repaid before the unlock ends |
| **settle / settleFor** (PM 300-307, 349-365) | none | `+paid` to the caller, or to the named recipient | the token's `balanceOf` | - | ERC-20 path: `paid = balance now - the synced checkpoint`, non-zero `msg.value` reverts, a balance that FELL reverts (checked subtraction), the synced-currency slot is reset; native path: `paid = msg.value`. `settle` does not make the unlock "settled" - only the spine does |
| **sync** (PM 279-288) | none | none | the token's `balanceOf` | - | writes the ONE global synced-currency slot and the reserves checkpoint; callable by anyone, locked or not |
| **mint / burn** (PM 322-336) | none | `-amount` / `+amount` to the caller; an ERC-6909 claim appears / disappears; **no token moves** | none | - | the id is normalised to its low 160 bits; `burn` runs the full ERC-6909 authorisation (owner, operator or allowance) |
| **clear** (PM 310-319) | none | zeroes the caller's positive delta | none | - | the amount must equal the delta EXACTLY and be positive; the tokens are forfeited for good |
| **updateDynamicLPFee** (PM 339-346) | none | none | none | - | only the pool's own hook, only on a dynamic-fee pool, fee <= 100 %, no lock needed |

## Twelve things that bite hook authors

1. **The synced currency is global.** One slot for the whole manager, writable by anyone through `sync`, locked or not. The
   normal payment is `sync(A)` -> transfer A -> `settle()`. If anything reachable in between calls `sync(B)` - your hook,
   a token's transfer callback, a recipient of a `take` - the payer's `settle()` credits currency B. A hook must never
   call `sync` inside a callback, and a hook that pays the manager must check what is synced immediately before it
   settles. *(Invariant: no path through the hook leaves a different currency synced than it found, unless it settles it.)*
2. **Your hook's callbacks do not fire when your hook is the caller.** Every hook entry is skipped when
   `msg.sender` of the manager call is the hook itself (H 170-175 and inline at 217, 253, 293). A hook that rebalances by
   swapping on its own pool runs the raw pool: no fee override, no delta, none of its own checks.
3. **Return data is validated by selector AND by exact length, and the lengths differ.** Most hooks: at least 32 bytes.
   After-hooks with a returns-delta flag: exactly 64. `beforeSwap`: **always exactly 96**, even on a static-fee pool with
   no delta flag. A wrong selector or length reverts `InvalidHookResponse`.
4. **A hook's revert is wrapped** (`HookCallFailed` around the hook's own error), so routers and tests cannot match the
   hook's error selector at the top level: assert the wrapper and what it wraps (`LESSONS.md` 13). The hook call forwards
   ALL remaining gas and never carries value.
5. **A delta returned without the flag vanishes.** No error, no log. Permissions in the address, the return values in the
   code and the tests must agree, or value is silently not accounted.
6. **When your after-hook runs, this operation's deltas are NOT yet booked** (swap, modifyLiquidity) - reading deltas from
   transient storage there shows the state BEFORE the operation. In `donate` it is the opposite: the delta is already
   booked when `afterDonate` runs.
7. **`take`, native sends and token transfers are arbitrary-code sites inside the unlock window.** Combined with 6 and 1,
   a hook can be re-entered while deltas are in flight and the synced slot belongs to someone else.
8. **Everything transient is publicly readable** (`exttload`): any account's live delta, the unlocked flag, the non-zero
   count, the synced currency and reserves. So can a searcher simulating your hook.
9. **Flags are checked once, at `initialize`,** and only for consistency (a returns-delta flag needs its action flag; a
   non-zero hook needs a flag or a dynamic fee). Nothing checks that the address has code, and nothing checks that the
   address matches what the hook IMPLEMENTS - that is `validateHookPermissions`, which exists only if the hook calls it.
10. **`sender` is the router.** The address every hook receives is the manager's caller - a router or a position
    manager, not the end user. `hookData` is the same unvalidated, uncapped blob for the before- and the after-hook.
11. **A dynamic-fee pool starts at ZERO LP fee.** If the hook neither calls `updateDynamicLPFee` in `afterInitialize` nor
    overrides in `beforeSwap`, the pool trades free for LPs - while a protocol fee, if governance set one, still applies.
12. **Only `initialize`, `modifyLiquidity`, `swap` and `donate` refuse delegatecall.** `unlock`, `take`, `settle`, `sync`,
    `mint`, `burn`, `clear` do not.

## Using this file

- For each operation your hook takes part in, write the row for YOUR hook: what it returns, which delta that creates,
  and the equation in the last column with your terms in it. Those equations are your first invariants.
- Exercise the four swap orientations (exact-in / exact-out x zeroForOne / oneForZero) for every delta you return.
- Put the hazards that apply into the spec's hostile-actor table; put the ones that do not into "does not apply", each
  with its predicate (`EVIDENCE.md` 6).
- Run on the real manager's code (`JUDGES.md` row 7): half of this file is behaviour a hand-written mock would not have.

Not covered: the pool's swap loop and tick crossing, position accounting, protocol-fee governance, the periphery
(routers, position manager, permit2). Verified by reading; nothing here was executed.
