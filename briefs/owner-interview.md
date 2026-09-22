# Brief template: owner interview (phase 0)

You are talking to the person who owns the hook. Your job is to come out of this conversation with a **scope**, a
**threat model** and a list of **non-goals**, all written down. Everything the route does afterwards is aimed by
these answers, and an answer you guessed will aim it wrongly for twenty rounds.

**How to run it.** Ask in small groups, not as a wall of questions. Play back what you understood in your own
words and let them correct you; the corrections are the valuable part. When they say "I don't know yet", write
**"undecided"** with a date - do not fill it in for them. When an answer contradicts an earlier one, say so.

Record every answer in `DECISIONS.md`, one entry per decision, dated, with the reason. Then write `STATE.md` and
move to phase 1.

This phase works fine in a chat tool with no terminal. It is the only one that does.

---

## 0. Is the idea still moving?

Ask this before anything else: *"If I came back in a week, would the entry points be the same?"* If the honest
answer is no, this is **sketch mode** (`doctrine/CHANGES.md` section 1): help them build and discuss, with the free
judges only, and come back to this interview when the design has stopped moving. Interviewing a moving idea
produces a spec that is wrong by Friday.

## 1. What it does

1. In one sentence a stranger would understand: what does this hook do that the pool would not do without it?
2. Which hook callbacks does it need? Which does it explicitly **not** want?
3. Who calls it, and how? Directly, through a router, through a periphery contract of yours?
4. Is it one pool, many pools, or a factory? Do pools share any state, any balance or any accounting?
5. Does it hold funds? Whose? For how long? Can they be stuck?
6. Does it mint, burn, or account for anything of its own?

## 2. Who is allowed to be hostile

7. Which assets can be paired with it? **Anything**, or a curated set? If curated: who curates, by what rule, and
   can a listed asset later change its behaviour? *(This one answer decides more findings than any other.)*
8. Which token behaviours are you willing to support: fee on transfer, rebasing, no return value, revert on zero,
   blocklists, callbacks on transfer, unusual decimals? For each: **supported**, **rejected at the door**, or
   **undefined**. "Undefined" is an honest answer and becomes a target.
9. Can a counterparty be a contract rather than a wallet? Can a recipient refuse to receive?
10. What does a hostile **caller** get to control: ordering, timing, the same transaction as another call,
    re-entry from a callback?
11. Is there a party with privileges - an owner, a registrar, a keeper? What can they do, and what can they
    **not** do? What happens if their key is lost? If it is stolen?

## 3. What must never happen

12. Finish this sentence in as many ways as you can: *"This is a failure if ..."*. These become the invariants.
13. Who is the party you most want to protect - the liquidity provider, the swapper, the pool, a third party?
14. What is the worst outcome you can live with? Funds stuck but recoverable? A pool that stops trading? One
    counterparty losing a rounding error every time?
15. Is the contract **immutable** after deployment, or upgradeable, or pausable? If immutable: the shape of every
    event is frozen forever, and the cheapest moment to get it right is before deployment.

## 4. Scope and non-goals

16. What are you explicitly **not** solving? Write it down; it goes in the spec and it stops rounds wandering.
17. Which chain, and what does that change - gas prices, block times, sequencer behaviour, a public mempool or not?
    *(Once the chain is known, the tests should run against the pool manager that actually exists there, not only
    the one compiled from source: `foundry-kit/v4/README.md`. That needs an RPC endpoint. **Never take a key in
    this conversation**: the owner sets `RPC_URL` in their own terminal. `AGENTS.md` section 5.)*
18. Are there off-chain components that the contract's guarantees depend on? An indexer, a keeper, a front end?
    If so, what happens when they are down or lying?
19. Any size, gas or cost ceiling you have to fit inside? *(Contract size is a first-class constraint in v4 hooks.
    Features get built and reverted because they do not fit. Establish the ceiling now.)*

## 5. Process

20. **How much compute are you willing to spend?** Light mode (about 3 adversarial rounds plus a black-box) or
    full mode (rounds until one closes clean)? Agree a **ceiling** - the number of rounds after which you stop and
    reconsider, whatever the state - and write it down. See `doctrine/COST.md`.
21. Who decides trade-offs - you, or someone you have to ask?
22. Do you have a human audit lined up? Budget? Timing? *(The whole route aims at that handoff.)*
22b. **Score the hook with the Uniswap Foundation's Hook Security Framework** (`doctrine/UPSTREAM.md` section 2), with
    the owner, now. Write the score per dimension, the tier, the feature triggers and the date in `DECISIONS.md`. *(It is
    the ecosystem's own yardstick for how many audits, of what kind, plus bounty and monitoring, a hook like this is
    expected to have. It sizes questions 20 and 22 with somebody else's ruler, and the dossier reports against it. If
    the idea is too young to score, say so and score it at the end of phase 1.)*
23. Is any part of this confidential? Names, addresses, mechanics that must not appear in reports or briefs? If
    so, write the forbidden list now and check it before anything leaves the project.
24. Which model families are available to you? *(At least one round should run on a different vendor. If only one
    family is available, that is a stated limit of the result, not a reason to skip the round.)*

## Output of this phase

- `DECISIONS.md` with one dated entry per answered question, and one entry per **undecided** item with the date it
  was deferred.
- `STATE.md` at phase 0, listing the undecided items as blockers for phase 1.
- A first `LOG.md` entry, with its ROUND line, for the interview itself.

**Gate to phase 1:** every question above has an answer or an explicit "undecided", and the owner has read the
scope and the non-goals back and confirmed them.
