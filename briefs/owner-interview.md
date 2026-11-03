# Brief template: owner interview (phase 0)

You are talking to the person who owns the hook. Your job is to come out of this conversation with a **scope**, a
**threat model** and a list of **non-goals**, all written down. Everything the route does afterwards is aimed by
these answers, and an answer you guessed will aim it wrongly for twenty rounds.

**How to run it.** Ask in small groups, not as a wall of questions. Play back what you understood in your own
words and let them correct you; the corrections are the valuable part. When they say "I don't know yet", write
**"undecided"** with a date - do not fill it in for them. When an answer contradicts an earlier one, say so.

Record every answer in `DECISIONS.md`, one dated entry per answered question (an undecided item gets its own entry with the date), with the reason. Then write `STATE.md` and
move to phase 1.

This phase works fine in a chat tool with no terminal. It is the only one that does.

Each question below has its canonical sentence (what is recorded) and, under it, a plain way to ask it with an
example. Ask the plain form; if the owner answers in the canonical terms, fine; record the answer under the canonical
number either way. Choices are offered only where the answer space is closed; 'I don't know' is always allowed and is
recorded as `undecided` with the date.

**What blocks the route and what does not.** None of your answers stops the route, with one exception: question 0
answered "still moving" puts the hook in sketch mode (`doctrine/NEXT.md` row 0). There the compiler, the unit tests and
a first fuzz run (a test that throws random inputs at the code) still run, but the spec and the model rounds (a round is
one fresh AI agent attacking the code and reporting) wait until the design has stopped moving. An "I don't know"
anywhere else is recorded as `undecided` with the date, and the route goes on with everything that does not depend on
it (row 3). Question 20 left undecided does not block round 1 (row 3): the kit reads light or full from the hook's own
facts (immutable, or holding other people's funds without a cap, means full; `doctrine/COST.md` section 1). A light run
comes with its own stop number (4: three rounds plus the attack from outside); a full run has none until you set
one or, when you are not there to be asked, the person running the kit sets one in writing, and the dossier then
says whose number it was; until then the ceiling row (the row that ends the model rounds once your stop number is
reached) cannot fire. Question 17's chain is
what row 7b needs (the tests run against the real pool manager of that chain); row 7b is owed before rows 12 (the
black-box round, an attack from outside that cannot see the source) and 16 (the release freeze), never before round 1.
What the kit will come back for is the read-back of the scope and of the spec (the gate at the end of this file, and
phase 1's), not the answers.

---

## 0. Is the idea still moving?

Ask this before anything else: *"If I came back in a week, would the entry points be the same?"* If the honest
answer is no, this is **sketch mode** (`doctrine/CHANGES.md` section 1): help them build and discuss, with the free
judges only, and come back to this interview when the design has stopped moving. Interviewing a moving idea
produces a spec that is wrong by Friday.
    Ask it as: If I came back in a week, would the ways people can use your hook - what it can be asked to do - be
        the same?
    For example: A fee hook where you are still choosing between a flat fee and a volume-based fee is still moving; one
        where only the numbers are left to tune is not.
    Choices: the entry points (the ways people can use it) would be the same in a week / still moving / I don't know -
        then say it back: "I cannot treat the design as settled, so we work in sketch mode until you tell me the entry
        points are fixed"; the owner's yes, or correction, is what puts the hook in sketch mode (`doctrine/NEXT.md` row
        0: only the owner does); record it as `undecided` with the date either way.
    Why the kit asks: a moving design stays in sketch mode (compiler, unit tests, a first fuzz run - random-input
        testing - and no model rounds), because an audit of a moving target is money spent on code that will not exist
        (`doctrine/NEXT.md` row 0).

**Owner absent** (an exercise, or a hook handed over with no one to ask): sketch mode is the owner's to declare, never
yours. A hook handed over as code with a spec is NOT a sketch - the route starts here, at phase 0, with the code and the
spec as the sources the answers are read from. Write it in `DECISIONS.md` as one entry, `Q0: not a sketch`, with
`source: assumed, owner absent` (the owner may overturn it), and continue (`doctrine/NEXT.md` row 0).

## 1. What it does

1. In one sentence a stranger would understand: what does this hook do that the pool would not do without it?
    Ask it as: In one sentence that someone who has never heard of your hook would follow: what does a pool with your
        hook do that a pool without it would not?
    For example: "It charges a higher fee on swaps that come right after a big price move, and the extra fee goes to
        the people who provided the liquidity."
    Why the kit asks: it becomes section 1 of the spec (the written, testable description of the hook that the rounds
        attack), the paragraph from which a reader can say what would make the hook a failure.
2. Which hook callbacks does it need? Which does it explicitly **not** want?
    Ask it as: At which moments in a pool's life does your hook need to step in? And at which moments do you
        deliberately want it to stay out?
    For example: A "callback" is one of these moments: the pool calls your code at that point. A fee hook that only
        sets the price of swaps needs "before a swap" and does not want "a pool is created", "donate", or anything to
        do with adding or removing liquidity.
    Choices: for each moment below, one answer: need / do not want / no view (it does not matter to you) / I don't know
        (you cannot tell yet).
        beforeInitialize, afterInitialize - just before / just after a pool that uses the hook is created
        beforeAddLiquidity, afterAddLiquidity - just before / just after liquidity is added
        beforeRemoveLiquidity, afterRemoveLiquidity - just before / just after liquidity is taken out
        beforeSwap, afterSwap - just before / just after a swap
        beforeDonate, afterDonate - just before / just after someone donates tokens to the liquidity providers
        Four more permissions let a callback change the amounts the pool moves; same answers for each:
        beforeSwapReturnDelta, afterSwapReturnDelta, afterAddLiquidityReturnDelta, afterRemoveLiquidityReturnDelta
    Why the kit asks: the permission bits in the hook's address must equal exactly what it implements, no more and no
        fewer (`doctrine/HOOK-ATTACKS.md` class 2), and every callback it declares is run through the same scenarios in
        both swap directions (class 11).
3. Who calls it, and how? Directly, through a router, through a periphery contract of yours?
    Ask it as: How do people reach your hook: by calling the hook itself or the pool manager (the core contract that
        runs every pool) with nothing in between, through another contract that carries their swap or deposit for them,
        or through a contract of your own that sits in front of the hook? And who are they: anyone, or only certain
        callers?
    For example: A limit-order hook is used through its own order-book contract (a periphery contract of yours) and, for
        plain swaps, through the usual routers; it also has one direct call to the hook itself (a bot that calls its
        sweep function, an owner who sets a parameter). A router is a contract that carries a user's swap or deposit to
        the pool; periphery is the name for contracts like it that sit around the pool.
    Choices: pick every one that applies, for the first sentence: directly (a call to the hook itself or to the pool
        manager, nothing in between) / through a router / through a periphery contract of yours / other: ... / I don't
        know. Who they are is open: no list.
    Why the kit asks: the hook sees the router as its caller, not the user (`doctrine/HOOK-ATTACKS.md` class 9), and
        which routers are trusted is a spec decision and an admission rule - a rule about what may use the hook and who
        checks it (class 24; the dossier's scope sheet has a row for it - the dossier is the final document handed to
        the human auditors).
4. Is it one pool, many pools, or a factory? Do pools share any state, any balance or any accounting?
    Ask it as: Is your hook attached to one pool, to many pools, or to pools created by a factory (a contract that
        makes new pools or new copies of the hook on demand)? Do those pools share anything - stored data, token
        balances, or the bookkeeping of who is owed what?
    For example: "Many pools, and yes: two pieces of stored data
        (storage slots) are shared by all of them." Or: "One pool; nothing shared."
    Choices: for the first question only: one pool / many pools / a factory / I don't know. The second question is
        open: no list.
    Why the kit asks: anyone can create a pool that names your hook, so the kit checks that state and balances are kept
        per pool (`doctrine/HOOK-ATTACKS.md` classes 3 and 4) and the dossier's scope sheet has a row on pool admission.
        If you answer "a factory": a launcher, factory, locker or periphery contract shipped with the hook that creates
        or configures its pools, positions, orders or tokens is in the files in scope; leaving one out is an owner
        decision, written in the dossier's scope sheet with its reason. A setup step that one way of creating a pool
        performs and another way skips lives in that contract, not in a hook callback, so a review of the hook alone
        never sees it.
5. Does it hold funds? Whose? For how long? Can they be stuck?
    Ask it as: Does your hook ever keep tokens or ETH in its own account, even briefly? If so, whose are they, how long
        do they stay, and could they ever get stuck with no way out?
    For example: A rebate hook keeps the fees it collected until the next payout, which can be days; the funds belong
        to the liquidity providers; they would be stuck if the payout call failed and undid itself
        (reverted) for good.
    Why the kit asks: "this contract holds nothing but donations" is one of the kit's starting invariants
        (`doctrine/INVARIANTS.md`; an invariant is a rule that must hold after every action), a hook that does keep
        custody is asked instead whether it ever ends an action still holding tokens, and an exit path that can lock
        people in is class 16 of `doctrine/HOOK-ATTACKS.md`.
6. Does it mint, burn, or account for anything of its own?
    Ask it as: Does your hook create or destroy any token or receipt of its own, or keep its own books of who owns or is
        owed what?
    For example: A hook that gives liquidity providers an IOU token for their share of collected fees creates it when
        they deposit and destroys it when they withdraw; a hook that only reads prices does none of this.
    Why the kit asks: every claim the hook mints must be backed and redeemable by the right party only
        (`doctrine/HOOK-ATTACKS.md` class 18), and the invariants check each party's books against the pool manager's.

## 2. Who is allowed to be hostile

7. Which assets can be paired with it? **Anything**, or a curated set? If curated: who curates, by what rule, and
   can a listed asset later change its behaviour? *(This one answer decides more findings than any other.)*
    Ask it as: Can anyone pair any token with your hook, or only tokens from a list that somebody maintains? If there
        is a list: who decides what goes on it, by what rule, and can a token on it later start behaving differently?
    For example: A whitelist hook accepts only tokens its owner added after reading their code, but a token whose code
        its issuer can swap later (an upgradeable token) could still change after it was added.
    Choices: for the first question only: any token / a curated set (a list someone maintains) / a mix: one side
        fixed, the other any (say which) / I don't know. The rest is open: no list.
    Why the kit asks: it sets the spec's admission rules (what is checked at admission, what can change after it) and
        decides which hostile-token findings are in scope (`briefs/spec-template.md` section 5).

8. Which token behaviours are you willing to support: fee on transfer, rebasing, no return value, revert on zero,
   blocklists, callbacks on transfer, unusual decimals? For each: **supported**, **rejected at the door**, or
   **undefined**. "Undefined" is an honest answer and becomes a target.
    Ask it as: For each odd token behaviour in the list below: does your hook work with it (supported), does it refuse
        a pool whose token does that (rejected at the door), or do you make no promise either way (undefined)?
    For example: A swap hook might say: blocklists - supported; rebasing tokens - rejected at the door; fee on transfer
        - undefined.
    Choices: one answer for each behaviour, from supported / rejected at the door / undefined / I don't know
        ("undefined" = no promise, on purpose; "I don't know" = you have not thought about it yet). The behaviours:
        fee on transfer - the token keeps a cut every time it moves, so less arrives than was sent
        rebasing - balances change on their own, with no transfer
        no return value - the token's transfer does not say whether it worked
        revert on zero - moving zero tokens fails
        blocklists - the token's issuer can freeze an address
        callbacks on transfer - the token runs other code whenever it moves
        unusual decimals - not the usual 18 decimal places (for instance 6 or 8)
    Why the kit asks: "rejected at the door" goes into the spec's out-of-scope section with the rule that refuses it,
        "undefined" becomes a target for the rounds, and the hostile-token actions (a test token that misbehaves on
        purpose) are wired into the fuzz campaign whatever you answer (`doctrine/FUZZ-ACTIONS.md` question 3) - for
        the behaviours that test token has a switch for: fee on transfer, no return value (and a transfer that returns
        `false`), revert on zero, a blocklist (a recipient that refuses), callbacks on transfer. Unusual decimals are
        set when the test token is made, not switched mid-campaign. Rebasing is modelled only as a balance that lies
        when it is read, not as a supply that changes: for a rebasing token the test is yours to write.

9. Can a counterparty be a contract rather than a wallet? Can a recipient refuse to receive?
    Ask it as: Can the other side of a trade or payment be a smart contract rather than a person's wallet? Can someone
        who is owed money refuse to receive it?
    For example: Yes to both: a vault contract (a contract that holds many people's deposits) can be the
        swapper, and a recipient contract can be written so that it rejects every payment.
    Choices: for each of the two questions: yes / no / I don't know.
    Why the kit asks: a recipient that refuses is the "exit path" and "external dependency" cases
        (`doctrine/HOOK-ATTACKS.md` classes 16 and 17), and the spec's answer for it must not let one bad counterparty
        deny the hook to everybody else (`briefs/spec-template.md` section 2).

10. What does a hostile **caller** get to control: ordering, timing, the same transaction as another call,
    re-entry from a callback?
    Ask it as: What can an attacker who calls your hook decide for themselves: the order of calls, the moment they act,
        doing several things in one transaction together with other people's calls, or calling your hook again while it
        is still in the middle of something, for instance from inside a token transfer?
    For example: Against a limit-order hook: they can see a pending order and swap just before it, pick the block they
        act in, and bundle a swap and a cancel in one transaction.
    Why the kit asks: these powers become the clock and strange-actor actions of the fuzz campaign (time moved across
        every boundary; two operations in one unlock - the pool manager's single session - and a token that calls back
        into the hook: `doctrine/FUZZ-ACTIONS.md` questions 2 and 4).

11. Is there a party with privileges - an owner, a registrar, a keeper? What can they do, and what can they
    **not** do? What happens if their key is lost? If it is stolen?
    Ask it as: Does anyone have special powers over your hook - an owner, someone who approves pools or tokens, or a bot
        that calls its maintenance functions (a keeper)? What exactly can they do, and what can they not do? What
        happens if their key is lost, and what happens if it is stolen?
    For example: An owner who can move the fee between 0.05% and 1% but cannot touch anyone's funds; if the key is lost
        the fee stays where it is, and if it is stolen the thief can set the fee to the 1% maximum.
    Why the kit asks: the answers fill the dossier's access-control table (who may call each function) and decide
        class 23 of `doctrine/HOOK-ATTACKS.md`, which asks about lost or stolen keys and an admin raising a fee in front
        of a user's transaction.

## 3. What must never happen

12. Finish this sentence in as many ways as you can: *"This is a failure if ..."*. These become the invariants.
    Ask it as: Finish this sentence in as many ways as you can: "I would call this hook broken if ...".
    For example: "...a swapper pays more than the posted fee." "...tokens are left sitting in the hook after a swap."
        "...a liquidity provider cannot withdraw."
    Why the kit asks: each one becomes an invariant - a rule written in words in section 4 of the spec and then tested
        after every action of the fuzz campaign (`doctrine/INVARIANTS.md`).

13. Who is the party you most want to protect - the liquidity provider, the swapper, the pool, a third party?
    Ask it as: Whom do you most want to protect: the liquidity providers, the swappers, the pool itself, or someone else?
    For example: A fee hook might put the liquidity providers first, and the swappers too, who must never pay more than
        the posted fee.
    Choices: pick every one that applies: the liquidity provider / the swapper / the pool / a third party (name them) /
        I don't know
    Why the kit asks: that party is on the list of "who can lose what", from which the invariants are derived backwards
        (`doctrine/INVARIANTS.md`), and severity is anchored to who loses (`doctrine/SEVERITY.md`); more than one party
        on the list is normal.

14. What is the worst outcome you can live with? Funds stuck but recoverable? A pool that stops trading? One
    counterparty losing a rounding error every time?
    Ask it as: If something went wrong, what is the worst result you could still live with?
    For example: "Funds stuck for a while but recoverable." Or: "The pool stops trading until we fix it." Or: "A
        swapper loses a rounding error of a fraction of a cent on every trade."
    Why the kit asks: nothing in the kit reads this answer by itself; it is written in `DECISIONS.md` as your side of
        triage - when a finding is accepted rather than fixed (`doctrine/NEXT.md` row 9), the number it is accepted with
        starts here (`doctrine/TRIAGE.md` section 3: a trade-off without a number is a hope).

15. Is the contract **immutable** after deployment, or upgradeable, or pausable? If immutable: the shape of every
    event is frozen forever, and the cheapest moment to get it right is before deployment.
    Ask it as: Once deployed, can the code never change (immutable), can it be replaced later (upgradeable), can
        someone freeze it (pausable), or a mix? If it can never change, the exact shape of the records it writes to the
        public log (its events) is frozen forever too, so the cheapest moment to get them right is before deployment.
    For example: A fee hook with no owner and no upgrade path is immutable; one whose owner can move the fee between two
        fixed limits is "immutable code with an admin parameter: the fee".
    Choices: pick every one that applies: immutable / upgradeable / pausable / immutable code with an admin parameter
        (say which parameter) / I don't know
    Why the kit asks: immutable, or third-party funds without a cap, means the full route (`doctrine/COST.md` section
        1), and upgradeable or pausable adds work - the roles, lost or stolen keys, the storage layout across versions
        (class 23 of `doctrine/HOOK-ATTACKS.md`).

## 4. Scope and non-goals

16. What are you explicitly **not** solving? Write it down; it goes in the spec and it stops rounds wandering.
    Ask it as: What are you deliberately not trying to solve? Whatever you list will be written in the spec (the hook's
        written description, which every review round reads), so that nobody spends time on it.
    For example: "Not defending against a compromised token issuer. No support for tokens that change their own
        balance. No front end."
    Why the kit asks: the list becomes the spec's out-of-scope section, and every round gets the whole spec, that
        section included, so the rounds do not spend their budget there (`briefs/spec-template.md` section 7;
        `briefs/audit-round.md`).

17. Which chain, and what does that change - gas prices, block times, sequencer behaviour, a public mempool or not?
    *(Once the chain is known, the tests should run against the pool manager that actually exists there, not only
    the one compiled from source: `foundry-kit/v4/README.md`. That needs an RPC endpoint. **Never take a key in
    this conversation**: the owner sets `RPC_URL` in their own terminal. `AGENTS.md` section 5.)*
    Ask it as: Which blockchain will it run on, and what is different there that could matter: the price of gas, how
        fast blocks come, who puts transactions in order, and whether pending transactions are visible to everyone
        before they happen?
    For example: "A rollup chain (a chain that settles its results onto another chain): cheap gas, 2-second blocks,
        one company's server orders the transactions (a sequencer), and there is no public waiting room for pending
        transactions (a mempool)."
    Why the kit asks: what the chain changes feeds class 31 of `doctrine/HOOK-ATTACKS.md` and the code-size limit check
        of phase 2, and once the chain is known the tests also run against its real pool manager (`doctrine/NEXT.md`
        row 7b), which needs an endpoint (a web address for reading the chain) that you set yourself, never in the chat.

17b. May the kit install Slither and Aderyn on this machine (static analyzers; without them the static triage is
    `forge lint` only)? **yes / no / already installed.** *(Record it like every answer, `source: owner`, as an entry whose
    heading ends in exactly `Q17b static analyzers: yes`, `Q17b static analyzers: no` or `Q17b static analyzers: already
    installed` - e.g. `## D-07 · 2026-10-06 · Q17b static analyzers: no`; a later entry of that form replaces it.
    `scripts/static-triage.sh` installs nothing and runs only what is installed; from that heading it reads one thing:
    when nothing is installed and the last answer is `no`, its line for `STATE.md` is `static triage: forge lint only -
    the owner declined the install`. A `yes` is the owner's permission for the install, which the agent then asks to
    run, command by command (`scripts/doctor.sh` prints Slither's; Aderyn has its own installer).)*
    Ask it as: May I install two free programs on this computer, Slither and Aderyn, that read your code looking for
        common mistakes (static analyzers)? Without them the kit only has the build tool's own
        quick check for common slips (`forge lint`).
    For example: "yes" - the agent then asks you to approve each install command, one at a time (you can still say no
        to one of the two at its own command); "no" - the kit has only the build tool's own quick check (`forge lint`)
        and says so in its report; "already installed" - nothing to install.
    Choices: yes / no / already installed / I don't know
    Why the kit asks: `scripts/static-triage.sh` installs nothing and runs only what is installed; your answer is read
        from the heading of the `DECISIONS.md` entry, and a `no` is reported as "forge lint only - the owner declined".

17c. Is anything in this project's environment not as it ships: pinned dependencies swapped, remappings, a renamed type?
    *(Record each one the owner names as its own entry, `source: owner`, whose heading is exactly `## <id> · <YYYY-MM-DD>
    · divergence: <what>`, in one line - e.g. `## D-08 · 2026-10-07 · divergence: v4-core pinned at another commit than
    the one it ships with`; none: the answer as an ordinary entry. The rows of `scripts/next.sh` that write the dossier
    (9b, 18, 18b) list those headings in a note, and the dossier's section 8 row "environment divergences stated by the
    owner" carries them - `none stated` when there is none. What the route tested ran on this environment, not on the
    one that ships: a divergence nobody wrote down is a claim about code that was never run.)*
    Ask it as: Is anything about this project's setup different from how it ships - a library replaced by another
        version or copy, import paths redirected to somewhere else (remappings), or a type that has been renamed?
    For example: "Yes: one library is pinned (held) at an older version than the one this hook normally builds
        with." Or: "Yes: an import path points at a local copy." Or: "Yes: a type called Price is renamed Quote in our
        fork (our own copy of the code)." Or: "No."
    Why the kit asks: each difference you name is written as its own entry and lands in the dossier's section 8 row
        "environment divergences stated by the owner" (`none stated` if none), because the route tested the environment
        you have, not the one that ships.

18. Are there off-chain components that the contract's guarantees depend on? An indexer, a keeper, a front end?
    If so, what happens when they are down or lying?
    Ask it as: Does anything outside the contract have to work for the contract to keep its promises - a program that
        reads its events and builds a database (an indexer), a bot that must call a function regularly (a keeper), a
        website? If so, what happens to the promises when it is down, or when it gives wrong information?
    For example: "A bot must poke the hook once an hour to roll the fee window. If it is down, the old fee stays in
        force; if it lies about the time, nothing happens because the hook reads the block time itself."
    Why the kit asks: the off-chain parts you are not defending against go into the spec's out-of-scope section; the
        dossier's section 11 lists the off-chain components the guarantees depend on and what happens when they are down
        or lying (`briefs/handoff-dossier.md`); and the events must rebuild the state, which is what an indexer relies on
        (class 22 of `doctrine/HOOK-ATTACKS.md`).

19. Any size, gas or cost ceiling you have to fit inside? *(Contract size is a first-class constraint in v4 hooks.
    Features get built and reverted because they do not fit. Establish the ceiling now.)*
    Ask it as: Is there a limit on size, gas or cost that your hook has to stay under?
    For example: "It must fit under the chain's code-size limit with at least 500 bytes to spare for future fixes, and a
        swap must cost less than 150,000 gas."
    Why the kit asks: phase 2 measures both code sizes (the deployed code and the code used to deploy it) against the
        chain's limit, and the margin you want kept goes into section 8 of the spec - a fix that does not fit is a
        finding.

## 5. Process

20. **How much compute are you willing to spend?** Light mode (about 3 adversarial rounds plus a black-box) or
    full mode (rounds until a discovery round closes clean: zero high and zero medium findings still open,
    `doctrine/LOOP.md` "Exit")? Agree a **ceiling** - the number of rounds after which you stop and
    reconsider, whatever the state - and write it down. See `doctrine/COST.md`.
    Ask it as: How much do you want to spend on AI review rounds: a light run (about 3 rounds plus one attack from
        outside) or a full run (rounds until a round that starts from scratch finds nothing serious still open - nothing
        rated high or medium)? And after how many rounds do you want us to stop and reconsider, whatever the state, so
        that we write that number down?
    For example: "Light, and a stop number of 4: 3 review rounds plus the attack from outside." Or: "Full, and stop and
        reconsider after 12 rounds."
    Choices: first, light / full / I don't know. Then the stop number (the ceiling): any whole number of rounds (if you
        think in money, say the amount and we turn it into a number of rounds), or I don't know.
    Why the kit asks: the mode sizes the route to the stakes (`doctrine/COST.md` section 1), and the ceiling is what
        the ceiling row (`doctrine/NEXT.md` row 2) fires on - no more model rounds, the route goes on to the dossier.

21. Who decides trade-offs - you, or someone you have to ask?
    Ask it as: When two good options trade one thing against another, do you decide alone, or must you ask someone?
    For example: "I decide alone." Or: "My co-founder signs off on anything that changes the fee model."
    Why the kit asks: the kit stops and asks the owner to accept, refuse or fix findings, to confirm spec changes and to
        raise the ceiling (`AGENTS.md` section 5); this answer says who the owner is for those calls.

22. Do you have a human audit lined up? Budget? Timing? *(The whole route aims at that handoff.)*
    Ask it as: Have you arranged for people to review the hook's security after this? If so, what is the budget, and
        when would it take place?
    For example: "Booked with an outside firm for March, budget 40,000." Or: "Not yet; probably after the testnet
        launch."
    Why the kit asks: the route ends in the dossier written for that review, whose scope sheet carries the prior human
        reviews and the wanted start date and deadline (`briefs/handoff-dossier.md` section 1).

22b. **Score the hook with the Uniswap Foundation's Hook Security Framework** (`doctrine/UPSTREAM.md` section 2), with
    the owner, now. Write the score per dimension, the tier, the feature triggers and the date in `DECISIONS.md`. *(It is
    the ecosystem's own yardstick for how many audits, of what kind, plus bounty and monitoring, a hook like this is
    expected to have. It sizes questions 20 and 22 with somebody else's ruler, and the dossier reports against it. If
    the idea is too young to score, say so and score it at the end of phase 1.)*
    Ask it as: Let us score your hook together against the Uniswap Foundation's Hook Security Framework, a published
        questionnaire that rates how risky a hook is and so how much outside review it should get. For each of the
        framework's dimensions you say what is true of your hook and pick the score on the framework's own scale; I write
        down the scores, the tier (the risk band they add up to), the feature triggers (features that raise the band on
        their own) and the date.
    For example: For each dimension (complexity, custom math, external dependencies, liquidity held, expected value
        locked, team maturity, upgradeability, autonomous parameters, price-impacting behaviour) you say what is true
        of your hook and choose the score; the framework's scale gives the tier. Or: "too young to score" - then we
        score it at the end of phase 1 (once the spec is written).
    Why the kit asks: it sizes questions 20 and 22 with the framework's yardstick, and the dossier reports against it
        (`doctrine/UPSTREAM.md` section 2).

23. Is any part of this confidential? Names, addresses, mechanics that must not appear in reports or briefs? If
    so, write the forbidden list now and check it before anything leaves the project (`git grep -F -f <list>` reads
    what is tracked, which is what leaves; a plain `grep -r` also reads the benches under `.gauntlet/bench/`, copies
    of the project).
    Ask it as: Is any part of this secret - names, addresses, or how something works - so that it must never appear in a
        report or in the briefs the kit writes (the instructions it hands each review round)? If so, write that list of
        words now, and the kit will check for them before anything leaves the project.
    For example: The codename of an unreleased partner, a treasury address, the name of a proprietary pricing formula.
    Why the kit asks: the list is checked before anything leaves the project, with `git grep -F -f <list>`, which reads
        exactly what is tracked.

24. Which model families are available to you? *(At least one round should run on a different vendor. If only one
    family is available, that is a stated limit of the result, not a reason to skip the round.)*
    Ask it as: Which AI models can you use for the review rounds, and are they all from one maker or from more than
        one? One maker's models are one family and share blind spots, so the kit wants at least one round on another
        maker's model.
    For example: "Two families: one maker's model for the main rounds and another maker's for the closing check." Or:
        "Only one."
    Choices: pick every one that applies: models from one maker only (say which) / models from two or more makers (name
        them) / a model running on your own computer (its maker counts as a family) / I don't know
    Why the kit asks: models of one family share blind spots, so at least one round should run on another vendor's
        model; with only one family the dossier says so as a stated limit (`briefs/handoff-dossier.md` section 7).

## What the kit will ask you to decide, later

Nothing here is for today. It is what to expect after this interview, so that none of it arrives as a surprise. Each
row names the kit's row in `doctrine/NEXT.md`, or the gate, that decides it; `NEXT.md` is the decision table that says
when each thing happens.

| moment | you will be asked to | your choices (one sentence each) | if you do not answer |
|---|---|---|---|
| read back the scope (the gate at the end of this file) and the spec (phase 1's gate) | confirm or correct what the agent read back to you | Confirm it as written, or correct it; the corrections are the valuable part. | The route continues, and nothing in phases 6-8 closes (`waiting_on_owner: read-back ...`, row 3). |
| sign a re-record of your code or your spec when you changed it (row 0 for the spec; the code is held by the record `scripts/init-state.sh --src` writes; `scripts/init-state.sh --spec ... --by "<your name>"`, or `--src`) | say whether the change is yours | Sign the re-record, or undo the change. | The route refuses to run on a changed spec or changed code. |
| triage a finding (row 9) | decide what happens to each finding a round reports | Fix it at the cause (the agent may then write the fix), refuse it in writing, accept it with a number, or hand it to the human audit by name. | The dossier lists it as `open - owner triage pending` (row 9b) and the route pauses (row 3). |
| an independent threat your list did not cover (row 4b) | decide what to do with a threat that a fresh reader of your spec thought of and your list did not | It becomes an invariant, you refuse it in writing, or you hand it to a round or to the human audit by name. | It is handed on by name: to a round, as a target in that round's brief, or to the human audit; only the second leaves it untested. |
| the ceiling is reached (row 2) | decide whether to stop at your stop number or raise it | Stop here, or raise it in writing. | No more model rounds. Every finding still open has to be triaged by you (row 9); until you do, a skeleton lists them and the route pauses (row 3); the dossier comes when nothing is open. |
| the black-box round (row 12) | decide whether an agent attacks the promises in your spec from outside, without seeing the source | Run it, or decline it in writing (`skipped_by_owner`; it goes in the dossier). | It runs when its row is reached. |
| the real pool manager (row 7b) | let the tests run against the pool manager that really exists on your chain, which needs an RPC endpoint (a web address for reading the chain) | Set `RPC_URL` in your own terminal (never in the chat), or say there is no chain yet. | The black-box round and the release freeze wait; round 1 does not. |
| freeze a release candidate (row 16: promotion, a canonical copy with a manifest of hashes so that any later change is noticed) | decide whether the code has stopped moving | Yes, or not yet. | No promotion. |

## Output of this phase

- `DECISIONS.md` with one dated entry per answered question, and one entry per **undecided** item with the date it
  was deferred.
- `STATE.md` at phase 0, listing each undecided item as a blocker for the phase that needs it (not every item blocks phase 1: `waiting_on_owner:` names them).
- A first `LOG.md` entry, with its ROUND line, for the interview itself.

**Gate to phase 1:** every question above has an answer or an explicit "undecided", and the owner has read the
scope and the non-goals back and confirmed them (owner absent: `waiting_on_owner: read-back of scope` in `STATE.md`;
the route continues, and nothing in phases 6-8 closes without it).
