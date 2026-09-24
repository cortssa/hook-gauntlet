# Baseline prompts: things that go wrong in v4 hooks. Walk them in phase 1, and again before phase 5

**This is a prompt list, not a taxonomy, and finishing it is not coverage.** It collects what is generic to hooks. The
bugs that cost the most live in what is NOT generic: your own arithmetic, your own accounting, your own state machine.
Those come from `INVARIANTS.md` (who can lose what), from the spec's assumptions (`EVIDENCE.md` 8), and from the pool
manager's accounting rules, which every delta-touching hook must model operation by operation (`V4-ACCOUNTING.md`).

**ADAPT: this is a prompt list, not a checklist to tick.** For each class decide one of four things and write it in
`SPEC.md`: *applies* (then it is a row in the hostile-actor table, with a test); *does not apply to this hook* (say why
in section 7, out of scope); *applies and is accepted* (section 6, with a number); or ***prevented by an admission
rule or an operational procedure, not by the code*** (section 5: name the rule, the probe that checks it, who runs
the probe, and what happens if it is violated anyway). The fourth is not a weaker answer, but it is the one an
auditor most needs to see, because those are the guarantees that stop holding the day an operator stops looking.
"Does not apply" is itself a claim: it needs an architectural predicate someone can check, the evidence, and the
counter-example you tried - not a search result (`EVIDENCE.md` 6) - and one discovery round is told to break that list.
A class with no decision is a hole - and "not supported" is not a decision until something REFUSES it and a test
shows the refusal. If you find an undecided class on code that is already promoted, that is an owner decision
(`NEXT.md` row 3): pin the current behaviour with a test, both ways, and ask.
Your hook will also have classes of its own that are not here; `INVARIANTS.md` is how you find those.

Two public incidents are worth knowing before you read the table, because both were hooks and both were ordinary bugs:

- **An unguarded callback (Cork, May 2025, over 10M USD).** A hook entry point could be called by someone other than
  the pool manager, with parameters the attacker chose. Class 1, combined with class 9.
- **Rounding direction over a sequence (Bunni, September 2025, about 8M USD).** A rounding error that was harmless in
  any single call was pushed in one direction by dozens of small withdrawals in a row. Class 6. No single-call test
  finds this; a stateful campaign with an around-the-action check on "who gained what nobody lost" can.

## The classes

| # | class | the question to ask of YOUR hook | what a test for it looks like |
|---|---|---|---|
| 1 | **Unguarded callbacks** | Can anyone but the pool manager call a hook entry point, or the unlock callback? | call every entry point from a stranger and from a contract, **with an address on each side of the manager's** - this tests the SUITE, not the guard: a correct `!=` whose tests cannot tell it from `<` is one refactor from a hole (`LESSONS.md` 11); expect a named revert |
| 2 | **Permission bits vs the address** | Do the bits of the deployed address equal EXACTLY what the hook implements - no more, no fewer? | mine for equality; a wrong-flag address must fail in the constructor or be refused by the manager |
| 3 | **Pool-key spoofing / permissionless initialise** | Anyone can create a pool that names your hook. What does the hook do for a pool it never approved, with currencies it never saw? | initialise a second pool with hostile currencies and odd tick spacing; act on it; check the first pool's state is untouched (`foundry-kit/v4/test/examples/DeltaFeeHook.multipool.t.sol`, `test_a_pool_nobody_approved_cannot_drain_the_rebates_another_pool_earned`: a stranger's pool took another pool's rebate budget until the example kept it per pool) |
| 4 | **Cross-pool contamination** | Is every piece of state and every balance keyed by `PoolId`? Can activity in pool A change what pool B pays? | two pools in one campaign; an around-the-action check that pool B's numbers move only on pool B's actions - books PER POOL, not only per currency: conservation per currency passed while one pool paid out of another's fees (`DeltaFeeHookMultiPoolInvariants`; `test_congestion_on_one_pool_does_not_move_another_pools_fee`) |
| 5 | **Delta accounting and return deltas** | If the hook returns a delta, is it the amount that actually moved, with the right sign, in the right currency (specified vs unspecified)? | conservation across hook + manager + users per action; exact-in and exact-out, both directions |
| 6 | **Rounding direction, over sequences** | Which way does every division round, who pays the dust, and can one party push it the same way N times? | invariant "nobody gains what nobody lost" checked per action, with a dust-splitting action (many tiny operations) |
| 7 | **Unsettled deltas / forgotten sync** | Does every path end with deltas at zero? Is `sync` called before a transfer that `settle` will measure? | run on the real manager: it reverts `CurrencyNotSettled`; include the failure paths, not only the happy one |
| 8 | **Re-entrancy through `unlock` and through tokens** | What runs attacker code in the middle of your action: a token callback, a recipient, a nested `unlock`? What state is half-written at that moment? | hostile token with callbacks that re-enter every entry point; assert the re-entry never succeeded - and point them at the MANAGER in the middle of a payment (sync, settle, take, mint, swap), where a door that "succeeds" can still kill or rob the payer (`foundry-kit/v4/test/TokenReentry.t.sol`, `test_P12_a_currency_that_moves_the_checkpoint_mid_rebate_is_refused`) |
| 9 | **`hookData` and `sender` as attacker input** | Does the hook decode and TRUST bytes the swapper chose - a recipient, a fee, a price, an identity? Does it treat `sender` as the user, when it is the ROUTER (`V4-ACCOUNTING.md` hazard 10)? | empty, enormous and crafted `hookData`; anything decoded from it is treated as hostile |
| 10 | **Return-data encoding** | Right selector, right length, right flag bits (the fee-override flag, for instance)? | covered by running on the real manager, which rejects a bad return; do not mock this away |
| 11 | **Callback timing** | Code that is right against pre-swap state in `beforeSwap` - is it still right in `afterSwap`, or for the other direction? | the same scenario through every callback the hook declares, both swap directions |
| 12 | **State cached across callbacks / nested actions** | Is anything stored in `before*` and trusted in `after*`? Can a nested action change it in between? | two operations inside one `unlock`; a swap inside a liquidity callback |
| 13 | **Transient storage left dirty** | If the hook uses `TSTORE` (locks, scratch values): is it back to zero at the end of the frame, on every path including reverts caught upstream? Two swaps in one transaction see the same transient state. | two operations in ONE transaction; assert the second sees clean state |
| 14 | **Dynamic fees, ordering and JIT** | Can the hook ever return a fee the manager rejects (above the maximum LP fee, or with the override flag bits corrupted) and so brick the pool? Can the swapper move the fee inside their own transaction? Can someone else move it against them first? Does just-in-time liquidity capture what passive providers were promised? | same-block sequences; the fee never above its cap; the quote equals the execution |
| 15 | **Unbounded loops** | Is any walk over ticks, orders or users bounded by WORK done, not by successes? Who can grow the list for free? | flood the structure with entries that are skipped; measure gas at the cap, against the block limit |
| 16 | **Non-essential logic on an exit path** | Can rewards, dust cleanup or a third-party call revert inside remove-liquidity or a withdrawal and lock people in? | make every external dependency revert; exits must still work |
| 17 | **External dependency DoS** | Oracles, lending markets, bridges, another protocol's token: what happens when it reverts, burns all the gas, or lies? | the hostile token's gas-burn and revert switches on every read the hook makes |
| 18 | **ERC-6909 claims** | If the hook mints, burns or holds claims: is every claim backed, and can it be redeemed by the right party only? | conservation PER PARTY against the manager's own books - ERC-20 + claims + native for each of hook, router, swapper, LP - never a sum: a claim minted to the wrong party passes every summed check (`foundry-kit/v4/test/examples/ClaimsFeeHook.invariants.t.sol`, mutant C1); rebuild from events |
| 19 | **Native currency** | If a pool can use the native currency: refunds, `receive`, re-entrancy on send, value stuck in the hook. If not supported: is it REFUSED at initialise? A hook that never moves value still decides this one: anyone can name it in a native pool, so say what it does there and test it once. | initialise with the native currency and expect the documented answer |
| 20 | **`donate`, and any payout to "whoever is in range"** | Can a donation change what the hook believes about reserves, fees or shares? And WHO receives what the hook donates or pays out: a donation goes to the positions in range at that moment, so a dust position placed just before the payout (after pushing the price, or once the price has left every honest range) takes it - a JIT recipient. A fresh reader's hook that swept accrued fees back to LPs lost ~100 % of each sweep this way while every amount-conservation invariant and the census gate stayed green | a donate action in the handler, against manager, hook and router; for a payout: a JIT-recipient actor (place dust in range, trigger the payout, remove) and an invariant on WHO was paid, not only how much - the kit has no such actor yet (README v4, gaps) |
| 21 | **The quote and the views** | Does every view other software will trust equal what execution does, under hostile tokens too? | quote immediately before execute, same arguments; never more than quoted, equal when the world is honest |
| 22 | **Events** | Can the state be rebuilt from the log alone? Two different histories with the same log? | rebuild-from-events invariant |
| 23 | **Privileged roles and upgradeability** | Who can change what, what if the key is lost or stolen, and if there is a proxy: storage layout across versions. Are configuration changes bounded and delayed, or can an admin raise a fee in front of a user's transaction? Is there any path that withdraws users' funds to a privileged party? | the access-control table in the dossier, one test per row |
| 24 | **The layer in front of the hook** | Routers, multicalls and position managers choose which pool and which hook a user touches. Can one be pointed at a look-alike pool? | not testable from inside the hook: a spec decision about which routers are trusted, and an admission rule |
| 25 | **Tick and price boundaries** | Does anything in the hook depend on a tick, a sqrt price or a price limit? What happens AT `MIN_TICK`/`MAX_TICK`, at the min/max sqrt price, at the exact price limit, on an exact tick crossing, across many ticks, at extreme tick spacing, with liquidity near zero? | each boundary hit exactly, one below and one above; rounding immediately before and after a crossing; the hook's narrow casts at amounts above 2^96, which one swap near an end of the range produces (`foundry-kit/v4/test/examples/Edges.t.sol`) |
| 26 | **Composition inside one unlock** | `swap -> settle` and `swap -> take -> swap -> settle` are different state machines. Multi-hop routes carry deltas across intermediate currencies. What does the hook assume about what came before it and what comes after it in the same unlock? | two and three operations in one unlock, on one pool and on two; a multi-hop through the hook's pool in the middle |
| 27 | **Approvals the hook holds** | If users approve the hook (or it pulls by allowance): can ANY path make it `transferFrom` a wallet for someone else's benefit - a spoofed pool, crafted `hookData`, a callback, a permissionless entry point? | every entry point called by a stranger naming a victim who has approved the hook; the victim's balance may fall only when the victim is paid what the spec says |
| 28 | **The hook as liquidity owner / shared positions** | If the hook adds liquidity on users' behalf, the pool sees ONE owner. Are per-user shares exact? Can one LP withdraw another's liquidity, or harvest fees by adding and removing around someone else's swap? | two users in one shared position; add/remove around a swap; sum of user claims equals the position, per action |
| 29 | **Prices the hook reads** | Does any decision use `slot0` / the spot price, this pool's or another's? It can be moved inside the same transaction. External price sources: bounded, fresh, not callable into a lie? Do internal swaps enforce a minimum output? | move the price with a swap in the same transaction, then act; an oracle that returns extremes, stale values, or reverts |
| 30 | **Construction and initialisation parameters** | Can a constructor argument, an immutable, or the data passed at pool initialisation leave funds locked or the pool bricked for good - a zero address, a fee above its bound, a cap below a floor, a malicious `initialize` overwriting another pool's configuration? Can the hook brick itself as time passes or state grows? | deploy and initialise with each parameter at zero, at its maximum and just outside its range; re-initialise attempts; long time jumps |
| 31 | **What your CHAIN changes** | "Per block", "per second", "this opcode exists": on an L2 `block.number` may be the L1's or the sequencer's, block times differ by orders of magnitude, the code-size limit and the available opcodes (transient storage) are per chain, and so is the gas per block. What does each time- or block-based rule in the hook MEAN on the target chain? | the time and block actions of the handler run with the target chain's cadence; the size check uses the target chain's limit |
| 32 | **Deployment through CREATE2** | In the constructor `msg.sender` is the deployer PROXY, not you: `owner = msg.sender` hands the hook to a factory. Can someone deploy the same initcode to the mined address first, with their own constructor arguments? Does the salt depend on them? | deploy through the same factory the real deployment will use; assert who ends up privileged; try a front-run with other arguments |
| 33 | **Forced failure by gas (63/64)** | Wherever the hook wraps a call in `try/catch` or checks `success`: the CALLER chooses the gas, and can make the inner call fail on purpose so that the "it failed, carry on" branch runs. What does that branch give them? | call with gas chosen so that only the inner call runs out; assert the outcome is one the spec allows |
| 34 | **The protocol fee** | If governance turns a protocol fee on, does any arithmetic in the hook that assumed gross amounts still hold? The fee is taken in the input currency and is not a delta | run the suite with a non-zero protocol fee set on the manager |
| 35 | **Custom curves / the hook takes the whole swap** | If the hook returns a delta equal to the whole specified amount (the pool's own curve does nothing): who guarantees the price, the solvency of the hook's reserves, and the behaviour at zero liquidity? | the reference model of `EVIDENCE.md` 5 is mandatory here; conservation of the hook's own reserves per action |
| 36 | **Gate unit-confusion** | Does any `beforeSwap`/`afterSwap` gate compare a raw amount or a raw price to a fixed constant without asking which currency and which decimals it is looking at on THIS call? Two shapes: (a) a cap compared straight against raw `amountSpecified` - exact-in vs exact-out AND direction choose which currency is "specified", so one constant silently governs BOTH tokens, and on a sub-18-decimal specified token the cap fails OPEN; (b) a balance / skew / heavier-side gate on the two virtual reserves - `StateLibrary` gives `amount0 = L*2^96/sqrtP` and `amount1 = L*sqrtP/2^96`, so `amount0/amount1 = 1/price` (`L` cancels): an unanchored gate is really comparing the pool's raw price to an implicit `1.0`, permanently one-directional on any pair that is not a same-decimals pool near parity. | Fix: anchor to the pool's OWN reference - `sqrtPriceX96` captured at `afterInitialize` (flag `0x1000`) or an explicit target ratio - never a bare constant compared to a raw amount or a raw price. Test to write: exercise the gate at a price away from 1:1 and confirm BOTH legs can bind; repeat with a sub-18-decimal specified token and confirm the cap still holds. Goes red the moment either check only passes at parity, or only fires in one direction. |

*Source of class 36: a third-party public checklist (aeon, `hook-checklist.md`, their class 10), read 2026-09-22.
A harness that silently does nothing (an unchecked `.call`, a `view` callee reached through `STATICCALL`) is a different
failure: `EVIDENCE.md` §2.*

## Aeon cross-check additions to existing classes (2026-09-22)

Three more items from the same source, each small enough to be a sub-bullet on a class this list already has rather
than a class of its own. Source: aeon's public `hook-checklist.md`, classes 4 and 5 (their numbering).

- **Class 28, shared positions - first-depositor / share inflation, named.** A hook that mints a shared LP position
  on users' behalf inherits the classic vault bug: seed the position with a dust amount, then donate or transfer
  tokens directly to the hook or the pool to move the price-per-share before the first real depositor mints. Guard:
  seed and lock a minimum-liquidity floor, or mint shares at high enough precision that a dust-deposit-plus-direct-
  transfer cannot move the rate. Goes red the moment a direct transfer, rather than a call through `addLiquidity`,
  changes what the next depositor's shares are worth.
- **Class 8, reentrancy - the guard's SCOPE, not just its presence.** "Has a reentrancy guard" is not the claim that
  matters; "nothing but enter and exit can write the guard, and its scope matches the state it protects" is. A single
  global transient slot for every pool the hook serves fails two ways: any other path that writes that slot - a
  rebalance or maintenance helper that resets the flag so it can call back into the manager - disarms EVERY pool at
  once for the rest of the transaction (the public incident the source names is exactly this); and a legitimate
  nested action on pool B inside pool A's callback either is refused (liveness) or, with a set-then-clear flag,
  clears the guard on its way out and leaves the rest of A's action unguarded. (Placed on class 8, not class 4: the
  defect is in the guard, not in state keyed by `PoolId`.) Fix: the lock's scope is the BALANCE's scope - one lock for the whole hook when it holds one shared balance (a per-pool
  lock is still drained through a second pool: seen in a blind round), one slot per `PoolId` only when every balance is
  per pool - or a depth counter; and no function other than enter/exit may write it. Test to write: an action on pool B nested inside pool A's callback,
  then a re-entry into A; and every helper that touches the slot, called mid-callback. Goes red the moment either
  reaches state that should have been unreachable.
- **Class 24, the layer in front of the hook - canonical hook enforced on the deploy paths.** Knowing which router
  is trusted is not enough if the deploy path itself can be pointed at the wrong hook. Every path that deploys or
  registers a pool or a token pair for this hook asserts `require(hook == expectedHookAddress)` before it goes live.
  Goes red the moment a pool or token can be deployed against a look-alike hook address and this hook's own
  admission rules never run.

## Where this list comes from, and how far to trust it

It was merged from the attack list this kit's v4 harness was written against, public write-ups and audits of v4 hooks
(OpenZeppelin's audits of its own `uniswap-hooks` library, and hook-security articles by Cyfrin, Certora, Composable
Security, BlockSec and Trail of Bits), and the two incidents above. On 2026-09-21 it was diffed against the 48 requirements of SCSVS 2.0 component C9 ("Uniswap V4 Hook", Composable
Security): classes 27-30 and the additions to 9 and 23 came from that diff (31-35 came from an independent audit of this kit), and that checklist is worth reading in
full - it is more specific than this list about shared positions and price sources. It has NOT been diffed line by
line against the audit reports; treat it as a good prompt list, and read the primary sources for
the classes that apply to you. If the hook inherits from a maintained base (OpenZeppelin's `BaseHook`), classes 1 and 2
come largely for free - check that they do, do not assume it. Class 36, and the three sub-bullets on classes 8, 24
and 28, came from a 2026-09-22 read of a third-party public checklist (aeon's `hook-checklist.md`) against this
list; it had one class this list lacked entirely - see the class 36 note above for the attribution. What was
read and not carried over (a verdict word, a badge, a rule that a clean report never fuzzes) is by design.

Of these, this kit's three example hooks (`CappedDynamicFeeHook`, `DeltaFeeHook`, `ClaimsFeeHook`, `foundry-kit/v4/`) exercise 1, 2, 3, 4, 5, 8, 9, 14, 18, 21 and 25 as of 2026-09-24; each class's test cell names the file, and a class with no file named is not exercised by the kit. The rest have no code in
this repository: the list tells you what to ask, the tests are yours to write.
