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
(`NEXT.md` row 1): pin the current behaviour with a test, both ways, and ask.
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
| 3 | **Pool-key spoofing / permissionless initialise** | Anyone can create a pool that names your hook. What does the hook do for a pool it never approved, with currencies it never saw? | initialise a second pool with hostile currencies and odd tick spacing; act on it; check the first pool's state is untouched |
| 4 | **Cross-pool contamination** | Is every piece of state and every balance keyed by `PoolId`? Can activity in pool A change what pool B pays? | two pools in one campaign; an around-the-action check that pool B's numbers move only on pool B's actions |
| 5 | **Delta accounting and return deltas** | If the hook returns a delta, is it the amount that actually moved, with the right sign, in the right currency (specified vs unspecified)? | conservation across hook + manager + users per action; exact-in and exact-out, both directions |
| 6 | **Rounding direction, over sequences** | Which way does every division round, who pays the dust, and can one party push it the same way N times? | invariant "nobody gains what nobody lost" checked per action, with a dust-splitting action (many tiny operations) |
| 7 | **Unsettled deltas / forgotten sync** | Does every path end with deltas at zero? Is `sync` called before a transfer that `settle` will measure? | run on the real manager: it reverts `CurrencyNotSettled`; include the failure paths, not only the happy one |
| 8 | **Re-entrancy through `unlock` and through tokens** | What runs attacker code in the middle of your action: a token callback, a recipient, a nested `unlock`? What state is half-written at that moment? | hostile token with callbacks that re-enter every entry point; assert the re-entry never succeeded |
| 9 | **`hookData` and `sender` as attacker input** | Does the hook decode and TRUST bytes the swapper chose - a recipient, a fee, a price, an identity? Does it treat `sender` as the user, when it is the ROUTER (`V4-ACCOUNTING.md` hazard 10)? | empty, enormous and crafted `hookData`; anything decoded from it is treated as hostile |
| 10 | **Return-data encoding** | Right selector, right length, right flag bits (the fee-override flag, for instance)? | covered by running on the real manager, which rejects a bad return; do not mock this away |
| 11 | **Callback timing** | Code that is right against pre-swap state in `beforeSwap` - is it still right in `afterSwap`, or for the other direction? | the same scenario through every callback the hook declares, both swap directions |
| 12 | **State cached across callbacks / nested actions** | Is anything stored in `before*` and trusted in `after*`? Can a nested action change it in between? | two operations inside one `unlock`; a swap inside a liquidity callback |
| 13 | **Transient storage left dirty** | If the hook uses `TSTORE` (locks, scratch values): is it back to zero at the end of the frame, on every path including reverts caught upstream? Two swaps in one transaction see the same transient state. | two operations in ONE transaction; assert the second sees clean state |
| 14 | **Dynamic fees, ordering and JIT** | Can the hook ever return a fee the manager rejects (above the maximum LP fee, or with the override flag bits corrupted) and so brick the pool? Can the swapper move the fee inside their own transaction? Can someone else move it against them first? Does just-in-time liquidity capture what passive providers were promised? | same-block sequences; the fee never above its cap; the quote equals the execution |
| 15 | **Unbounded loops** | Is any walk over ticks, orders or users bounded by WORK done, not by successes? Who can grow the list for free? | flood the structure with entries that are skipped; measure gas at the cap, against the block limit |
| 16 | **Non-essential logic on an exit path** | Can rewards, dust cleanup or a third-party call revert inside remove-liquidity or a withdrawal and lock people in? | make every external dependency revert; exits must still work |
| 17 | **External dependency DoS** | Oracles, lending markets, bridges, another protocol's token: what happens when it reverts, burns all the gas, or lies? | the hostile token's gas-burn and revert switches on every read the hook makes |
| 18 | **ERC-6909 claims** | If the hook mints, burns or holds claims: is every claim backed, and can it be redeemed by the right party only? | sum of claims the hook holds equals what it says it holds; rebuild from events |
| 19 | **Native currency** | If a pool can use the native currency: refunds, `receive`, re-entrancy on send, value stuck in the hook. If not supported: is it REFUSED at initialise? A hook that never moves value still decides this one: anyone can name it in a native pool, so say what it does there and test it once. | initialise with the native currency and expect the documented answer |
| 20 | **`donate`** | Can a donation change what the hook believes about reserves, fees or shares? | a donate action in the handler, against manager, hook and router |
| 21 | **The quote and the views** | Does every view other software will trust equal what execution does, under hostile tokens too? | quote immediately before execute, same arguments; never more than quoted, equal when the world is honest |
| 22 | **Events** | Can the state be rebuilt from the log alone? Two different histories with the same log? | rebuild-from-events invariant |
| 23 | **Privileged roles and upgradeability** | Who can change what, what if the key is lost or stolen, and if there is a proxy: storage layout across versions. Are configuration changes bounded and delayed, or can an admin raise a fee in front of a user's transaction? Is there any path that withdraws users' funds to a privileged party? | the access-control table in the dossier, one test per row |
| 24 | **The layer in front of the hook** | Routers, multicalls and position managers choose which pool and which hook a user touches. Can one be pointed at a look-alike pool? | not testable from inside the hook: a spec decision about which routers are trusted, and an admission rule |
| 25 | **Tick and price boundaries** | Does anything in the hook depend on a tick, a sqrt price or a price limit? What happens AT `MIN_TICK`/`MAX_TICK`, at the min/max sqrt price, at the exact price limit, on an exact tick crossing, across many ticks, at extreme tick spacing, with liquidity near zero? | each boundary hit exactly, one below and one above; rounding immediately before and after a crossing |
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

## Where this list comes from, and how far to trust it

It was merged from the attack list this kit's v4 harness was written against, public write-ups and audits of v4 hooks
(OpenZeppelin's audits of its own `uniswap-hooks` library, and hook-security articles by Cyfrin, Certora, Composable
Security, BlockSec and Trail of Bits), and the two incidents above. On 2026-09-21 it was diffed against the 48 requirements of SCSVS 2.0 component C9 ("Uniswap V4 Hook", Composable
Security): classes 27-30 and the additions to 9 and 23 came from that diff (31-35 came from an independent audit of this kit), and that checklist is worth reading in
full - it is more specific than this list about shared positions and price sources. It has NOT been diffed line by
line against the audit reports; treat it as a good prompt list, and read the primary sources for
the classes that apply to you. If the hook inherits from a maintained base (OpenZeppelin's `BaseHook`), classes 1 and 2
come largely for free - check that they do, do not assume it.

Of these, this kit's own example hook exercises 1, 2, 3 (in part), 9, 14 (the cap) and 21. The rest have no code in
this repository: the list tells you what to ask, the tests are yours to write.
