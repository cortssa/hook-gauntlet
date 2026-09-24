# Simulation: the judge that measures instead of searching

`JUDGES.md` lists ten deterministic judges and ends with what none of them can see. This page is the eleventh judge,
about one of those things -
economic attacks that break no rule - and the sandbox in `foundry-kit/v4/src/sim/` that measures them. Read the
module's README for the pieces; read this for when to run it, what its numbers mean, and how it lies.

## 1. The question, and the evidence label

A fuzz campaign searches for ONE sequence of calls that breaks a rule. A simulation measures a DISTRIBUTION: for a
population of agents, a clock with the target chain's cadence and an ordering model, who ends richer, who poorer, by
how much, and how far execution drifts from the quote. Different question, different evidence: a simulation result
is **SUPPORTED** (`EVIDENCE.md`), never PROVED, and never becomes a test that "passes".

It answers "how much does attack X earn, under assumptions Y, against this hook". It does not answer "is this hook
economically safe": it measures only the attacks somebody wrote an agent for. The dossier therefore lists the agents
that ran - so that the absence of one is visible - and the assumptions every number rests on.

## 2. When to run it

- **Phase 1, while the spec is written**, for a hook whose promise is economic: "LPs are protected from X", "the fee
  makes Y unprofitable", "quotes are honoured". Such a promise needs a NUMBER in the spec's accepted-trade-offs
  section ("an informed trader may earn up to X per unit of LP inventory per day"), and the sandbox is how the number
  is found before the code exists to defend it.
- **Before promotion**, on the release candidate, with the parameters SEALED in the spec beforehand (`VERIFY.md` 3):
  a sweep chosen after looking at results is a story.
- **Never as a gate.** Nothing in `NEXT.md` waits for it. It is a judge the owner asks for, in writing, and its
  cost (CPU time, and the time to write agents) goes in the ROUND line like any other.

Not every hook needs it. A hook that changes no price, holds no value and quotes nothing has nothing for a population
to fight over; say so in the dossier and move on (`AGENTS.md` 6b).

## 3. The rules that make a number mean something

1. **Calibration first, alone.** One honest agent, zero latency, no adversary: the quote equals the execution to the
   wei, the ledger equals the wallet (the input it counts is what the venue TOOK, `Fill.amountInUsed`, because a book refunds what it could not fill and a v4 swap leaves it unspent), nothing is refused. If this is red the sandbox is wrong and no other number
   counts. It is the sandbox's "seen red". The kit's own calibration is `test/sim/Calibration.t.sol`; a project's
   binding gets one of its own before anything else.
2. **Always one adversary.** A population of honest agents proves the plumbing and nothing else.
3. **The ordering model is named in the same sentence as the number.** FCFS (a single sequencer, no mempool) and
   BUNDLE (a public mempool or builders) are different worlds: the kit's own population shows a sandwicher earning
   nothing under one and 1.4e16 under the other. A number without its ordering model is not a number.
4. **Latency is a stated assumption**, per agent, until it is measured on the target chain. A "fast" agent at the
   first percentile of the measured distribution and a "slow" one at the ninetieth is a population; "latency 1" is a
   placeholder.
5. **Several seeds, named.** The world is seeded (`SIM_SEED`) so that a run can be replayed and so that runs differ.
   Report a range over seeds, never one line; `scripts/sim-report.sh` adds the ledger up.
6. **The numeraire is written down.** P&L is in the quote currency, currency0 valued at the main market's price. When
   both currencies move against the world, that lies a little; say which numeraire was used.
7. **A profit is not a finding by itself.** It becomes one when it exceeds what the spec accepted - which is why the
   spec needs the number first.
8. **The unit of a size belongs to the Intent, never to the binding's guess.** `Intent.amountInQuote` says whether
   `amountIn` is sized in the input currency or in the quote currency; a binding that infers the unit from context
   instead of reading the flag re-converts a size that was already right. Break this and
   `test_the_closing_leg_never_says_it_is_quote_sized` (`test/sim/IntentUnit.t.sol`) goes red. Measured, bound to a
   second system, private: an arbitrageur's closing leg was re-converted, and 40 sells of size 1e35 were refused
   where the real size should have gone through. Support the flag or refuse `QuoteSizedIntentUnsupported` - never
   guess.
9. **Gas is metered as the action's own transaction, never as a `gasleft()` window inside the test.**
   `SimGasMeter.total` is intrinsic cost (21 000) + calldata + the callee's own frame, minus a capped refund - a
   lower bound, no cold-slot cost, no L1 fee. A `gasleft()` window taken around the call, in the test's own frame,
   instead counts the TEST's memory growth, not the action's cost. Break this and `test/sim/GasMeter.t.sol`'s swap
   and liquidity cases go red once the test frame is grown by 4 MB between runs. Measured, bound to a second system,
   private: gas moved 11-18% between two runs with identical decisions and identical execution, and a product
   conclusion was drawn from the difference.
10. **A swap quoted zero is refused at decision, and never sent.** `SimEngine` marks a `KIND_SWAP` whose decision-time
    quote is 0 as `REFUSED_AT_QUOTE` before it is submitted - at zero gas, no execution order, no searcher ever
    shown the leg; the ledger's `atQuote` column counts it, and `refused` no longer does. An engine that sends it
    anyway is not measuring the hook, it is measuring the agent's own naivety. Break this and
    `test/sim/RefusedAtQuote.t.sol` (`EngineRefusesAtQuote`) goes red. Measured, bound to a second system, private:
    834 of 841 refusals a population logged were orders sent into an empty book and read back as "the market
    refused."
11. **A binding's reference price comes only from what the system could actually fill - and a precondition that
    is not met is `vm.skip`, never `return`.** Whatever the system under test calls its resting liquidity (a position,
    an order, a promise), the price an agent acts on is built from the part of it that would deliver if hit, never
    from a declared size the system could not honour. A side with nothing to deliver has NO price: the binding then
    returns the main market's price, or no quote at all - never the other side's. Break this and an agent that acts on
    the price trades into nothing; the binding's test for a side with nothing to deliver (an agent must decide zero
    trades against it) goes red. Measured, bound to a second system, private: an empty side was priced off the other
    side, and the arbitrageur bought air 834 times in three tapes. The same discipline covers the harness: a
    precondition the environment does not meet is `vm.skip(true, why)` - a skip the battery refuses unless accepted on
    purpose - never a bare `return`, which prints PASS with zero assertions reached (`EVIDENCE.md` §2). Measured: a
    fork test with a bare `return` gave 4 PASS in 966 µs without `--fork-url`.
    A venue with a bid and an ask - a book - has no single price. The binding states which one it reports (best bid,
    best ask, or the reference price when the reference sits inside the spread) and builds it from what could
    actually fill. And a fill that took nothing after a non-zero quote - the side emptied between the quote and the
    execution - is REFUSED, not executed: the binding returns `executed == false`, and the ledger counts it with the
    refusals. Two blind-test arms bound a book to the sandbox and each had to guess both.

## 4. How this judge lies

- **It only knows the agents you wrote.** An attack that needs an agent nobody wrote scores zero, which reads as
  "safe". The dossier's list of agents is the only defence.
- **The world is as real as its parameters.** Volume, depth, volatility and latency are inputs; invented ones give
  clean numbers about a market that does not exist. Read them from the target chain (a fork of its state as the main
  market, its observed volume, its measured latency) and say which were read and which were guessed.
- **"Zero latency" is not "nobody ahead of me".** An agent with latency zero next to an agent that submitted a step
  earlier gets the block's opening quote and the other agent's execution. The kit measured this by accident on its
  first run.
- **A deterministic population agrees with itself.** Three identical runs are one run. Vary the seed.
- **A number that moves when only the instrumentation moved is a defect of the meter until proven otherwise.** Four
  lies the instrument told in one week, bound to a second system (private), each now a rule above and a test:
  - **the unit lie** - a binding re-converted a size that was already in the right currency (rule 8): the
    arbitrageur's closes failed and its P&L read as a loss of the maker's making;
  - **the gas lie** - a `gasleft()` window counted the test's own memory growth as the agent's cost (rule 9): +11-18 %
    with identical decisions, and a product conclusion drawn from it before the artifact was found;
  - **the naivety lie** - agents sent swaps quoted zero and the refusals read as "the market refused" (rule 10): 834 of
    841 refusals were orders into an empty book;
  - **the declared-price lie** - an empty side priced off the other side's declared entries (rule 11): the arbitrageur
    bought air, and latency could not be read from that world.
  The symptom was the same each time: a column that changed when nothing about the hook or the population had. Treat
  that symptom as a bug in the sandbox first, and only then as a fact about the hook.
- **The sandbox's own code lies like any other.** Its quote must be the same code path as its execution; its bundle
  order must be asserted from its own execution record, not from counts. The kit's sandbox has mutants for both.

- **Recorded logs keep the logs of frames that reverted.** `vm.getRecordedLogs()` returns an event emitted inside a
  call that later reverted (forge 1.8.1, established by a three-line test, not by memory). A reading that sums a
  system's fill events over a tape therefore counts fills that a later `minOut` check undid - the kit once read 5 %
  more delivered than the wallet had authorised, by summing events, while balances said otherwise. Measure what
  STAYED: balances, allowances consumed, positions; use events for counts and names, never for amounts.

## 5. What goes in the dossier

Section 6 (what the judges said), the simulation-sandbox row: the scenarios run (agents, ordering, latency, seeds, steps),
the parameters that were read from the chain and the ones that were guessed, the ledger table over seeds, and the spec
line each number was compared against. Section 9 (what was NOT checked): the agents that were NOT written, by name,
starting with the ones `HOOK-ATTACKS.md` suggests. In `LOG.md`, one ROUND line of type `simulation` with its cost
(`state/README.md`).
