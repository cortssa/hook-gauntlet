# Fuzz actions: if it is not in the handler, it is never tested

The fuzzer only generates random numbers. The **handler** turns them into legal actions - "actor 16 places an
order at price level 3 for X". The list of actions in your handler is the complete list of things your campaign
can ever do. Anything that is not there is not rare, it is impossible.

**ADAPT: the example handler in `foundry-kit/test/examples/` is a toy. Yours is derived from your hook, by the five
questions below.** Write the list in `SPEC.md` before you write the code.

## The five questions

1. **Every external function, from every kind of caller.** One action per entry point: the ones users call, the
   ones only the owner calls, and the ones "anyone" can call (sweeps, evictions, pokes). Include the calls that
   should be refused - the refusal is behaviour too.
2. **Time.** If anything in the hook depends on a timestamp or a block number - expiry, idleness, decay, TWAP
   windows, epochs - you need an action that moves the clock, by amounts that land **on both sides of every
   boundary**. A seven-day rule is tested at six days, seven, eight, and at the wrap-around if the counter is small.
3. **The token misbehaving, mid-campaign.** Wire the `HostileERC20` switches into actions, so that a token can
   start lying about a balance, charging a fee, short-delivering or burning gas **between** two honest actions,
   for one wallet or for all. A hostile mode that is only ever set in `setUp` tests one ordering out of millions.
   Wire them even when the owner has not decided which token behaviours the hook must survive: a promise that breaks
   under one of them is a FINDING (`NEXT.md` 6b says where the failing invariant waits), not a reason to leave the
   action out - two of a blind round's findings, one high, sat exactly where a reader had left the switches out.
4. **The strange actors.** Someone who donates tokens straight to the hook, to the router, to the pool manager.
   Someone who is a contract, not a wallet. Someone who re-enters from inside a transfer callback. Someone who
   is both sides of the same trade. Two operations inside one `unlock`.
5. **The reads.** Quotes and views are entry points. After a state-changing action, call the quote and the view
   and check them against what just happened. They are the part of the contract that other people's software
   will trust, and they are usually the part nobody fuzzes.

## Make the actions land

A random `uint256` is almost never a legal amount, a legal price level or a funded wallet. Unbounded inputs mean
almost every call reverts, and you are back at the vacuous pass.

- **Actions take full words only** - `uint256`, `bytes32` - and derive flags, indexes and addresses inside
  (`_bit(word)`, `actors[word % actors.length]`). A coverage-guided fuzzer sends malformed narrow types, the ABI
  decoder reverts before your code runs, and the campaign fails for a reason that is not the contract's. `JUDGES.md`.
- `bound()` every input into its legal range, and make the range include the **edges**: zero, one, the maximum,
  one below and one above every threshold in the spec.
- Fund and approve the actor inside the action when the point of the action is the contract's logic, not the
  approval. Keep a separate action that revokes approvals and drains wallets, because that is a real thing
  wallets do.
- Keep a small, fixed cast of actors (a dozen or two). Interesting bugs need the **same** wallet to do several
  things in a row; with thousands of actors that never happens.
- Wrap every call into the contract in `try/catch`, and sort the failures: `_expectedRevert()` for a refusal
  the spec predicts, `_unexpectedRevert(why)` for anything else - it RECORDS the surprise (count and reason) where an
  invariant can read it; it does not revert, because a revert would undo its own record. Run with `fail_on_revert = true`. A campaign
  that swallows surprises in silence will report green over hundreds of hidden failures.

## Measure that the campaign is working

After a long run, read the census (`scripts/census.sh`, fed by `writeCensus()`): calls and **successes** per action, and
in how many RUNS each action succeeded at least once.

| what you see | what it means |
|---|---|
| an action with ~0 successes | it is not being tested; fix the bounds or the funding |
| hostile switches never on while trades succeed | the hostile paths are not being mixed with the honest ones |
| one action dominating | the others are starved; split it or re-weight |
| `reverts unexpected` above zero | stop; that is a finding or a handler bug, and either way it is next |

Write the census from `afterInvariant()` - `handler.writeCensus("<name>")`, one line per run, added up by
`scripts/census.sh` - so that it describes the CAMPAIGN, and read it after every long run. `afterInvariant()` runs after
every run but forge PRINTS the logs of one: a `printCallSummary()` block on the screen is a sample of 1 run in 64, and it
has been seen to say "0 withdrawals" over a campaign with more than a hundred. Hostile switches are sticky: once one is on, most later actions fail, and a campaign can be green with a
third of its runs never completing the action that matters. Bias switches toward the honest value (`_bitOneIn`), give the
handler an action that clears them, and look at the share of runs with zero successes of each core action.

Read the `reverts:` line of the fuzzer's own output too, but know what it is: with `fail_on_revert = true` and every call
wrapped it is 0 by construction. "ok" with a non-zero revert count
and `fail_on_revert = false` is how a suite lies to you.

## Depth, runs, and cost

- **Depth** (actions per sequence) finds bugs that need history: fill, partially drain, move time, fill again.
  Start at 64.
- **Runs** (sequences) finds bugs that need an unlucky combination. A few dozen for the everyday battery (the kit's `foundry.toml` uses 64;
  forge's own defaults are 256 runs x 500 depth = 128 000 calls, which is already a long campaign by this page's numbers), 1000 for the
  long campaign you run before a gate.
- **The long campaign must be larger than YOUR everyday one**, whatever that is: `scripts/fuzz-long.sh` measures both
  budgets (runs x depth) and refuses a `long` profile that is not larger, printing the block to paste. A project on
  forge's defaults needs a `long` profile above 128 000 calls (the script prints the block: 1024 x 500 for forge's defaults); the kit's own 1000 x 128 is sized
  for the kit's 64 x 64 everyday battery, not for yours.
- Seeds are random per run on purpose. A failure that appears on the sixth long campaign was there during the
  first five; keep running the long campaign after every change, not once.
- **STOP and tell the owner** before a campaign you expect to take more than a few minutes of their machine.

## The growth rule, again

Every finding that came from outside the fuzzer ends with two questions: which **invariant** would have caught
it (`INVARIANTS.md`), and which **action** would have had to exist for the fuzzer to reach it. Add both. A missing
action is the more common answer.
