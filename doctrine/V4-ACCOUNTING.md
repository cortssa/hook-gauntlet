# How the pool manager keeps its books: the map your invariants come from

`HOOK-ATTACKS.md` is a list of prompts. This is the thing underneath them: what the v4 `PoolManager` does, in what
order, to whose delta, at every operation a hook can be part of. A hook that touches value has to model this, operation
by operation; the invariants that matter ("who can lose what", `INVARIANTS.md`) are statements about these rows.

**Provenance and limits.** Read from `Uniswap/v4-core` at commit `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc` (the pin in
`scripts/install-v4.sh`), by one agent drafting and a second one falsifying every row against the source with file and
line: 29 rows confirmed, 10 corrected, 0 wrong. Evidence label for this file (except the section "Sign and side, measured", 2026-09-24, which is TESTED in `foundry-kit/v4/test/DeltaAccounting.t.sol` and the DeltaFeeHook mutants): **SUPPORTED by source reading - not
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

## Sign and side, measured (added 2026-09-24, K13)

The rows above were read, not run. These were run, on the source manager at the pin, by the kit's v4 module
(`foundry-kit/v4`); each line names the test that holds it. Evidence label for this section: **TESTED**, on one pin.

- **A hook's returned delta is the HOOK's own delta, and the caller pays the difference.** Per currency,
  `callerDelta = poolDelta - hookDelta`, where `poolDelta` is what the manager's `Swap` event reports (emitted BEFORE
  `afterSwap`) and `callerDelta` is what `swap` returns to the router. Held in all four orientations with a hook that
  pays on the specified side and takes on the unspecified side, before and after the swap
  (`test/DeltaAccounting.t.sol`, four `test_exact_*` tests): the hook's balance moved by exactly its booked delta, the
  swapper's by exactly the returned delta, the manager's by exactly minus the pool's delta.
- **The specified half moves the POOL, never the swapper.** On a full fill the caller's specified delta is exactly
  `amountSpecified`; the pool swaps `amountSpecified + hookSpecifiedDelta`. The unspecified half is the sum of what
  `beforeSwap` and `afterSwap` returned, in the other currency.
- **Nobody but the hook can clear a positive hook delta** (`take`, `mint` and `clear` act on `msg.sender`), so the hook
  settles its own delta inside its own callbacks, and the router settles only what the manager returned to it. A
  router that pays anything else - the pool's delta, as a hookless quote gives it - is refused `CurrencyNotSettled` in
  all four orientations (`test_red_a_router_that_pays_the_pools_delta_is_refused_*`; the same router with the hook's
  deltas at zero passes, `test_the_quote_router_is_fine_when_the_hook_returns_no_delta`).
- **13. A specified delta is committed before the pool knows its fill.** `beforeSwap` returns it; the pool may then
  fill less (a price limit, liquidity running out). The caller's specified delta is still `pool - hook`, so a NEGATIVE
  specified delta (a rebate the hook paid) on a swap the pool barely filled is paid to the swapper in the currency it
  was selling. Measured on the kit's `DeltaFeeHook` before its fix: a swap limited at the pool's price received
  906 067 445 652 208 of currency0 (the whole block's rebate budget) and paid nothing
  (`test_a_swap_the_pool_does_not_fill_earns_no_rebate`, red then). Defence: carry the rebate to `afterSwap` (transient
  storage) and refuse unless the pool's specified amount is exactly `amountSpecified + hookSpecifiedDelta`.
  That defence costs liveness, and the cost is the whole class: while a rebate is paid, EVERY partial fill is refused
  (the verifier V13's sweep, 160 limited swaps: 17 filled with the rebate, 143 refused, 0 stood; the example's P11).
  Say it as a limit of the hook, and clear the transient slot after reading it: two swaps in one transaction share
  it, and forge's unit tests never see that (it clears transient storage between a test's top-level calls), so it
  takes a helper that swaps twice in one call (`test_two_swaps_in_one_transaction_*`).
  *(Invariant: a swapper whose specified side is not exactly `amountSpecified` was paid no specified-side rebate.)*
- **14. A hook that pays the manager calls `sync`, and item 1 then applies to the hook itself.** A router that pays
  FIRST (sync, transfer, swap, settle) has its payment in flight while the hook runs; a hook that syncs, transfers
  and settles in between resets the checkpoint under it, the router's `settle` credits nothing, and the whole swap is
  refused (`CurrencyNotSettled`). Measured with the kit's `PrepayRouter` against `DeltaFeeHook` with its
  synced-currency check removed; with the check (read `getSyncedCurrency`, pay nothing if one is set) the swap stands
  (`test_a_router_that_pays_first_is_not_clobbered_by_the_rebate`).
  **The fee side** (added 2026-09-24, K14b, from the verifier V14): the check stops the hook's rebate, not its fee. When
  the synced currency is the pool's own token and the hook's fee is taken in it, the hook's `take` lowers the manager's
  balance of that token after the payer's checkpoint: with nothing sent yet the payer's `settle()` underflows
  (`Panic(0x11)`, unnamed), with a payment sent it is credited the payment less the fee (`CurrencyNotSettled`). The
  payer's transaction dies - a denial of service, not a theft (`test_a_payment_in_flight_in_the_fee_currency_dies_on_the_fee_take`,
  `DeltaFeeHook` on an ETH / token pool, ETH in, the fee in the token). Skipping the `take` leaves the hook's own delta
  open; keeping the fee as a claim (`mint`) while that currency is synced moves no balance - not run.
- **15. Return what the manager CREDITED, not what you meant to pay.** `settle()` returns the amount that arrived;
  a token that delivers short from the hook makes the two differ, and a hook that returns the intended amount leaves
  its own delta open (`test_the_rebate_returned_is_what_the_manager_credited_not_what_was_meant`).
- **16. Re-entering while holding a delta** (from `afterSwap`, after `take`, before returning): `unlock` is refused
  (`AlreadyUnlocked`); `take` is allowed - a flash loan out of the manager's reserves, mid-swap - and `swap` on the
  hook's own pool is allowed and skips the hook's own callbacks. Either stands only if the hook reads its OWN open delta
  (`TransientStateLibrary.currencyDelta(manager, hook, currency)`) after the re-entry and squares the residue; a hook that
  trusts its own arithmetic kills the swapper's whole transaction (`test/HostileDeltaHook.t.sol`).
  **`settle()` while a ROUTER's payment is in flight** (added 2026-09-24, K13b, from the verifier V13): a router that
  pays first (`sync`, transfer, swap, `settle`) leaves its transfer synced and unpaid while the hook runs; a bare
  `settle()` from the hook is allowed and credits that transfer to the HOOK (measured by reading both deltas inside
  the router's callback, a probe outside the repo: the hook's currency0 delta +1e18; the router's own `settle` then
  credits 0 and it still owes -1e18). Against a router that settles once, the
  whole transaction is refused (`CurrencyNotSettled`), with or without the hook's own-delta check - a denial of
  service (`test_settle_while_a_router_payment_is_in_flight_kills_the_transaction`). Against a router that then
  pays whatever its books still show owing, the hook that takes the credit it was handed keeps the first payment and
  the swapper pays its input twice (1e18 kept by the hook, 2e18 paid;
  `test_settle_while_a_topping_up_router_payment_is_in_flight_takes_the_first_payment`) - a theft. Item 1 from the
  other side: whoever calls `settle` while another party's payment is synced is paid for it.
  *(Invariant: what the swapper paid in is what its router was credited - per party, not per currency total.)*

**The class these belong to** is `HOOK-ATTACKS.md` class 5, "delta accounting and return deltas" - SIGN-AND-SIDE
CONFUSION: the right amount in the wrong currency (specified for unspecified, or chosen by direction alone when the
orientation needs direction AND exact-in/out), or the right currency with the wrong sign. Class 36 ("gate
unit-confusion") is its neighbour: there a GATE reads the wrong unit, here a DELTA moves the wrong one. Measured on
`DeltaFeeHook` (2026-09-24): nine one-line mutants of this kind; a naive suite (exact-in only, 1:1 price, a fresh hook
per test, an approximate fee check, total supply conserved) let eight of the nine through, including "specified chosen
by `zeroForOne` alone", "fee computed on the specified amount", "rebate sign flipped" and "rebate returned in the
unspecified slot"; the example's own unit suite killed all nine. What killed them: all four orientations, a price far
from 1 (at price 4 a fee on the wrong side is off by a factor of four; at 1:1 by the price impact and the LP fee, which
an approximate check forgives), a FUNDED reserve (a fresh hook pays no rebate, so a sign bug in the rebate never runs),
and exact equality against the manager's own numbers.

## Native currency and claims, measured (added 2026-09-24, K14)

Run, like the section above, on the source manager at the pin by the kit's v4 module; each line names the test that
holds it. Evidence label: **TESTED**, on one pin.

- **17. ETH is delivered at two moments, and the manager is in a different state at each.** ETH owed to a swapper or a
  provider leaves through the manager's `take` - `call(gas(), to, amount, ...)` - INSIDE the unlock: the recipient's
  `receive()` runs with the manager unlocked and can `take`, `swap`, `settle` and `sync` in its own name. A router's
  refund of excess ETH is sent after `unlock` returns: the manager is locked (`take` -> `ManagerLocked`) and the only
  way back in is a lock of the recipient's own. Measured with the kit's `HostileNativeActor`
  (`test/NativeCounterparty.t.sol`): from inside `take`, `unlock` is refused (`AlreadyUnlocked`), `take` of 1 ETH is
  allowed and the transaction dies at the outer unlock (`CurrencyNotSettled`), a whole swap in the recipient's own name
  with its own delta squared STANDS - the hook sees a second swap, from a `sender` that is not the router, placed after
  the first swap's `afterSwap` and before the router has finished settling. From inside the refund, a lock of its own
  and a swap in it also stand. **And `mint`** (added 2026-09-24, K14b, found by the verifier V14): `settle{value}`
  followed by `mint` of the ETH claim to itself, from inside `take`, nets to zero and STANDS - the recipient turns ETH
  into claims in the middle of somebody else's swap, the manager's ETH and the claims it has issued both up by the same
  amount; either half alone leaves its own delta open and the transaction dies (`CurrencyNotSettled`;
  `test_reentry_by_settle_and_mint_during_take_stands_and_turns_eth_into_a_claim`,
  `test_reentry_by_settle_alone_or_mint_alone_during_take_kills_the_transaction`). From inside the refund both are
  refused, `ManagerLocked` (V14's run). *(A hook that reasons "one swap per unlock", or "every `sender` is a router I
  know", or "the claims outstanding only change in my callbacks", is wrong on a native pool.)*
- **18. A recipient that cannot receive ETH is refused by v4's own wrapped error, and everything goes with it.**
  `WrappedError(recipient, 0x00000000, <its revert data>, NativeTransferFailed())`, raised by the manager's transfer
  and bubbled unchanged through `unlock`: the swap, the hook's callbacks and the hook's state are rolled back. Such a
  contract CAN swap ETH in when it sends exactly the input (nothing to refund) and can never take ETH out; as a
  provider it can add (sending exactly what is charged) and can never remove - the position is stuck, not lost, until
  the provider can receive, PROVIDED the position manager lets only the position's owner touch it. A helper that owns
  every position and pays whoever calls it lets a stranger with no approvals name the pool, range and salt, remove the
  position and keep its value: the kit's `LiquidityHelper` did, until 2026-09-24 (measured by the verifier V14); it now
  keeps positions per caller and the stranger is refused (`test_reverting_provider_can_add_exactly_and_can_never_remove`).
  A `receive()` that burns its gas takes all but the 1/64 each frame keeps: 4 664 718 of 5 000 000 on the manager's
  transfer (five frames deep), 4 884 379 on a refund (4 664 701 and 4 884 372 before the kit's router began counting
  `msg.value`).
- **19. `settle` of ETH takes no `sync`, and a synced ERC-20 makes it revert.** `settle()` credits `msg.value` only when
  the synced slot is empty; with an ERC-20 synced and not settled, `settle{value}` reverts `NonzeroNativeValue`. A hook
  that pays in ETH keeps item 14's check (read `getSyncedCurrency`, pay nothing if one is set): its own `sync(0)` would
  clear another payer's checkpoint exactly as an ERC-20 `sync` does. (Followed by `DeltaFeeHook`'s P10, and run: with
  an ERC-20 that is not in the pool synced, its ETH rebate is skipped and the swap stands - the control in
  `test_a_payment_in_flight_in_the_fee_currency_dies_on_the_fee_take`. The `NonzeroNativeValue` refusal itself was run
  by the verifier V14, not in the kit.)
- **20. A hook that takes ETH needs `receive()`, and without one every swap that owes it ETH dies.** `take` of ETH to a
  hook with no `receive()` is item 18 with the hook as the recipient: `WrappedError(hook, afterSwap, ...)` around it,
  the whole swap refused - a denial of service of the pool the hook guards, on the orientations that pay the hook in
  ETH. Measured on `DeltaFeeHook` with its `receive()` removed: all five native tests red; on two ERC-20s the campaign stayed green and only the unit test that sends
  the hook ETH noticed.
- **21. A claim is value the manager holds and owes; count it per party, never summed.** `mint(to, id, amount)` debits
  the CALLER's delta and credits `to` with a claim; the tokens stay in the manager. After a fee kept as a claim the
  hook's `balanceOf` has not moved, the manager's balance moved by the pool's delta PLUS the fee, and conservation over
  balances alone - swapper + hook + manager - closes to zero with the hook's fee invisible. Summing claims over every
  holder does not help: a claim and the manager's debt for it cancel. What catches a claim that went to the wrong party
  is the books PER PARTY: each party's balance + claims against what the manager booked for it (`pool - caller` for the
  hook), and the manager's net (balance minus claims issued to every listed holder) against the pool's delta. Measured on
  the kit's `ClaimsFeeHook` (`test/examples/ClaimsFeeHook.invariants.t.sol`): the fee claim minted to the router instead
  of the hook left ETH conservation, token conservation, per-swap balance books AND the manager's net all green; it was
  killed by the per-party books, by "the router holds nothing, claims included", and by "the hook's claims are the fees
  the manager booked less what was withdrawn". A claim minted to an address nobody lists is killed by the manager's net.
  **Operators, allowances, and other people's claims** (added 2026-09-24, K14b, from the verifier V14). An operator
  (`setOperator`) or an allowance (`approve`) the hook grants moves its claims with `transferFrom`, outside any swap: a
  latent grant in the constructor passed every per-swap check and every invariant, because nothing in a campaign calls
  `transferFrom`. Count the manager's `OperatorSet` and `Approval` events with the hook as owner (an operator can be any
  address, so a holder list is not enough), and hold the hook's claims between actions to what its own last action left
  (`test_the_hook_grants_nobody_an_operator_or_an_allowance`, `invariant_the_hook_grants_nobody_its_claims`,
  `invariant_the_hooks_claims_move_only_in_its_swaps_and_withdrawals`). And keep the check about the HOOK's claims: "nobody
  but the hook holds a claim" calls a third party that deposits and passes on claims of its own a leak, while a claim
  that reaches anybody else from a swap is caught per swap and per party without it
  (`test_a_third_party_moving_its_own_claims_trips_nothing`).
  *(Invariant: for every party and currency, Δbalance + Δclaims equals what the manager booked to that party; the
  holder list names every contract that can receive a claim; the hook's claims move only in its own actions, and it
  grants nobody an operator or an allowance.)*

**The class** is `HOOK-ATTACKS.md` rows 18 (ERC-6909 claims) and 19 (native currency). Row 18's check, "the sum of
claims the hook holds equals what it says it holds", is right as far as it goes; item 21 is why it has to be per party
and against the manager's books, not against the hook's own ledger alone.

## A currency's own code during settlement, two pools, the edges - measured (added 2026-09-24, K15)

Run, like the two sections above, on the source manager at the pin by the kit's v4 module; each line names the test that
holds it. Evidence label: **TESTED**, on one pin.

- **22. A currency with transfer hooks runs its code between a payer's `sync` and its `settle`** - with the manager
  mid-accounting for that payment, and every door open to it in its own name (`sync`, `settle`, `take`, `mint`, `swap`;
  `unlock` is refused). Measured with the kit's `TokenCallbackActor` on `HostileERC20`'s callbacks
  (`test/TokenReentry.t.sol`): against a payer that settles ONCE, every door that moves the synced slot, the checkpoint or
  a delta - `sync` of another currency or of the zero address, `sync` of the same currency after the balances moved, a
  bare `settle`, `settle` + `take`, `settle` + `mint`, `take`, `mint`, a swap in its own name - kills the payer's whole
  transaction at the outer unlock (`CurrencyNotSettled`) and takes nothing; `sync` of the same currency BEFORE the move
  and `unlock` leave it standing. Against a payer that then pays what its books still show owing, `settle` + `take` is a
  theft of one payment. Against a HOOK paying its own delta the same way, a hook that reads its own delta afterwards
  (item 16) pays twice and the callback keeps one payment; the defence is to read `getSyncedCurrency` and
  `getSyncedReserves` after the transfer and refuse unless both are what the hook's own `sync` set - measured on
  `DeltaFeeHook` (its P12): without it the swap stood and the callback kept the rebate, with it the swap is refused
  (`test_P12_a_currency_that_moves_the_checkpoint_mid_rebate_is_refused`). The slot and the checkpoint are not the whole
  payment (added 2026-09-24, K15b, from the verifier V15): a callback that `take`s x and pays for it with x of its OWN
  claims (`burn`) squares its books and moves neither, and the payer's `settle` credits x less - against a payer that
  settles once, `CurrencyNotSettled`; against `DeltaFeeHook` with the first check only, the swap stood, the pool's
  reserve fell by the rebate and nobody got it. So compare, AFTER settling, what the manager credited (`settle`'s return,
  what it added to your own delta) with what left your balance, and refuse a short credit
  (`test_P12_a_take_paid_with_the_callbacks_own_claims_mid_rebate_is_refused`). Its price: a fee-on-transfer currency
  looks the same, and is refused the same (`test_P12_price_a_rebate_in_a_currency_that_charges_on_transfer_is_refused`).
  And `settleFor(the payer)` from the callback after the move is harmless: it credits the payer its own payment
  (`test_two_more_doors_a_take_paid_with_own_claims_and_settle_for_the_payer`). A callback on a DELIVERY (the manager's `take`)
  can also leave a `sync` of its own behind: the synced slot outlives the unlock inside the transaction, so "a currency
  is synced" does not mean "a payment is in flight" (`test_a_callback_on_a_delivery_leaves_the_synced_slot_behind`).
  *(Invariant: whatever a hook pays the manager is credited to the hook, in the currency it paid, or the swap is refused.)*
  **A test harness can go blind here too** (K15b, from V15): a helper that reads a swap's events with `vm.recordLogs()` /
  `vm.getRecordedLogs()` consumes the recorder, and a test recording around it sees nothing the hook emitted inside the
  swap - a grant made in `afterSwap` passed a unit test built to catch grants. `V4Harness._keepSwapLogs`.
- **23. State keyed by currency is shared by every pool that names the hook - a stranger's included.** Anybody can
  initialise a pool with any hook and any second currency. A hook that keeps a reserve or a budget per currency, hook-wide,
  lets one pool spend what another earned; measured on `DeltaFeeHook` before its P13: a stranger's pool of the earned
  currency against a token the stranger mints, with the stranger as its only provider, took the block's whole rebate cap
  of the earned currency (906 067 445 652 208 of a 906 067 445 652 210 cap) in one block. And conservation per currency
  PASSED throughout - the hook held exactly what its pools, summed, left it - while books per pool failed
  (`test/examples/DeltaFeeHook.multipool.t.sol`). ETH is on one side of almost every pool, so for a hook that holds ETH
  this is the common case, not a corner (`test_the_eth_reserve_of_one_pool_pays_no_eth_rebate_on_another`). A value the
  manager keeps per (owner, currency) - an ERC-6909 claim - cannot be split per pool on chain; only the hook's own events
  can (`test_two_pools_fees_in_one_currency_are_one_claim_and_only_the_events_split_it`).
  *(Invariant: per pool and per currency, what the hook paid out of a pool's books never exceeds what that pool paid in -
  next to, not instead of, conservation per currency.)*
- **24. `take` moves what the manager holds NOW; on an exact-out swap the input arrives after `afterSwap`.** A hook that
  takes a fee in the unspecified currency takes, on an exact-out swap, the INPUT currency - before the router has paid
  it. If the manager holds less of that currency than the fee (a pool whose liquidity is all on the other side, a young
  currency, a price near an end of the range), the hook's `take` fails and the swap with it: the token's own error,
  wrapped twice (`test_the_fee_on_an_input_the_manager_does_not_hold_yet_kills_an_exact_out_swap`; 8 of 60 swaps of the
  edge grid, `test_the_delta_example_at_the_edges`). A fee kept by `mint` moves no token and has no such failure (the
  claims example: 0 of 60). And at those edges amounts pass 2^96 in one swap - 5.5e34 of a fee from a 1e6-unit swap 100
  ticks from the low end - so a narrow cast of a reserve truncates silently: `DeltaFeeHook`'s `uint96` cap did
  (`test_the_block_cap_holds_above_2_to_the_96`), as it would at any price for an 18-decimal token with a trillion-token
  supply. At the maximum tick spacing the widest position stops 2 563 ticks short of each end: a pool priced near an end
  is outside every position that spacing allows.

## Four rules the 2026-09-24 series measured (items 13-24 are the evidence)

1. Against a payer that settles once, a token's callback inside the payment can only DENY it. Against a payer that
   later pays what its books still owe, or a hook that reads its own delta, it can KEEP a payment. The defence is to
   check the synced currency and the checkpoint before every `settle`, AND to check after it that the manager credited
   what left your balance (`DeltaFeeHook`'s `RebateNotCredited`): a callback paying with its own claims passes the first
   two checks and leaves the rebate as nobody's - a loss with no beneficiary, still a loss.
2. State kept per currency is shared by every pool that names the hook, a stranger's included. Conservation per
   currency passes while pools mix; only books per pool catch it.
3. `take` moves what the manager holds NOW. A fee taken from the input of an exact-out swap comes before the swapper's
   payment; `mint` does not have that problem.
4. Near the price edges amounts pass 2^96 in one swap. A narrow cast truncates silently, as it would at any price for
   an 18-decimal token with a trillion-unit supply.

## A payer that pays first, on a pool that fills short - measured (added 2026-09-24, K15c)

- **25. A router that pays BEFORE the swap has paid for the swap it asked for, not the one the pool filled.** `sync`,
  transfer, swap, `settle`: the `settle` credits the whole prepayment, the swap debits only what the pool filled, and
  on a pool with no liquidity (or a price limit) the difference is the ROUTER's own open credit. A router that does not
  `take` it back leaves its own delta open and the manager refuses the whole transaction (`CurrencyNotSettled`) - with
  every token honest and the hook's books square. Caught by the `DeltaFeeHook` campaign in CI, not by any unit test or
  local draw: the only provider withdrew its whole position, then a prepaid exact-in swap of 128 wei ran on the empty
  pool (`Swap` with `amount0: 0, amount1: 0`, the hook booking nothing) - the kit's own `PrepayRouter`, which the
  handler trusted to close its books, did not. The fix is in the payer: take back `settle`'s return plus the pool's
  delta in the paid currency when that is positive (`test_ci_replay_a_prepaid_swap_on_a_pool_emptied_of_liquidity`).
  The lesson for a handler: "with every switch off, `CurrencyNotSettled` can only be the hook" is a claim about EVERY
  party in the unlock, the test's own routers included - a surprise names a suspect, and the trace names the culprit.
  *(Invariant: after any swap through any router, the payer's balance moved by exactly the caller delta the manager
  returned - P1 from true balances, which a refund that did not happen fails.)*

## A handler's forecast of a guard, and a refund that only a partial fill can test - measured (added 2026-09-24, K15d)

- **26. A pool's liquidity says nothing about how much of ONE currency it holds.** `L` is the same number whether the
  price sits in the middle of the range or next to one end; near an end, the pool holds almost none of the currency
  that end runs out of. The `DeltaFeeHook` handler filed a P9 refusal (`RebateOnPartialFill`) on a swap with no price
  limit as a surprise whenever the pool's liquidity was >= 1e18, on the premise that such a pool fills any swap of at
  most 5e17. The verifier's replays refuted it: a burst on an almost empty pool pushed the price far to one side,
  liquidity came back, and an exact-out swap asked for more of the scarce currency than the whole range could deliver
  (the verifier's numbers: 4.5e17 of currency0 asked, 1.9e17 held, liquidity 1.0e18). The pool filled short, the hook
  refused the rebated swap - correctly - and the handler went red. The forecast is now the guard's own arithmetic, made
  before the swap: the rebate the hook will pay (nominal, cut to the block's budget, the pool's reserve and what the
  hook's transfer delivers), the amount the pool must then fill (`|amountSpecified| + rebate` of input exact-in,
  `|amountSpecified| - rebate` of output exact-out), and what the range can fill from the price now to its end in the
  swap's direction (`SqrtPriceMath.getAmount0Delta`/`getAmount1Delta` over the range's liquidity, the LP fee on top for
  an input). The manager's balance is not that number either: it also holds donations and the providers' fees, which no
  swap reaches. The rule, for any handler that classifies a guard's refusal: **predict it from the quantity the guard
  compares, never from a proxy, and hold the prediction to the calls that STOOD as well** - a forecast that says "it
  will be refused" too often is the blanket excuse it replaced, so a swap forecast short that stands, or a rebate other
  than the forecast one, is itself a failure. *(Invariant: `forecastWrong == 0` inside
  `invariant_no_unexplained_reverts`; a hook whose delta moves the fill - rebate sign flipped, rebate in the other slot
  - still dies on "P9 refused an UNLIMITED swap the pool could fill whole".)*
- **27. A refund that is right when the pool uses all or nothing is not yet tested.** Item 25's router hands back
  `settle`'s credit plus the pool's delta. A mutant that hands back the whole credit instead agrees with it whenever the
  pool uses all of the prepayment (nothing to return) or none of it (the credit IS the rest), and the campaign's prepaid
  swaps, all unlimited, only ever produced those two cases: the mutant survived the whole suite (found by the verifier).
  A price limit near the pool's price makes the pool use part of the prepayment, and there the mutant leaves the router
  owing and the unlock refuses. *(Test: `test_a_prepaid_swap_stopped_by_its_price_limit_pays_exactly_what_the_pool_used`,
  the payer's balance equal to the one a router that pays afterwards leaves on the same state; the campaign's
  `swapPrepaidLimited`.)*

## A currency that can refuse, on a fork - measured (added 2026-09-25, K16)

- **28. A hook that receives a currency inherits that currency's power to freeze it, and its pool freezes with it.**
  USDC can refuse any transfer to or from a blocklisted account, and every transfer while it is paused. The manager
  holds every v4 pool's USDC in one balance, so the question for a hook is only whether IT is ever a party to a USDC
  transfer inside a swap. `DeltaFeeHook` is: it `take`s its fee TO itself in the unspecified currency and pays its
  rebate FROM itself in the specified one, so once it holds USDC every swap on its pool touches USDC on the hook's side,
  and a blocklisted `DeltaFeeHook` reverts every swap its pool is asked for (before it holds any USDC, only the swaps
  whose fee is USDC). `ClaimsFeeHook` is not: it squares its fee with `mint` (claims, no transfer), so a blocklisted
  `ClaimsFeeHook`'s pool keeps trading, and it still withdraws to a clean recipient (the manager is the sender, the
  recipient is the treasury - the hook is not a party). The rule: **list, per currency the pool can hold, every transfer
  in which the hook is the sender or the recipient during a swap; each one is a switch somebody else can turn off**, and
  the spec says what the pool does then (freeze, skip the fee, fall back to claims). A swapper, an LP and the manager
  itself are the other parties the token can refuse: the swapper's own swaps die, an LP's USDC stays in the pool until
  it is unblocked (the position is intact), and a blocklisted manager or a pause stops every USDC pool at once.
  *(Tests: `test/fork/ForkUsdcBlocklist.t.sol` on a mainnet fork, `test_a_blocklisted_delta_hook_freezes_its_own_pool`
  seen red first with the expectation that ignores the token; foundry-kit/v4/README.md, "The fork".)*
- **29. A test that funds a USDC account with `deal` can un-blocklist it.** FiatToken v2.2 keeps the blocklist flag in
  the top bit of the balance's own storage word. forge-std's `deal` to a blocklisted account either reverts inside its
  slot search or, when the slot was found earlier in the test, overwrites the word and clears the flag - and the test
  then measures an account the token no longer blocks. Fund first, blocklist after, fund no more; the harness's
  `_fundReal` refuses a blocklisted USDC account. *(Test: `test_deal_on_a_blocklisted_usdc_account_reverts_or_silently_unblocklists`.)*
