# Simulation: the judge that measures instead of searching

`JUDGES.md` lists ten judges and ends with what none of them can see. This page is about one of those things -
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
- **The sandbox's own code lies like any other.** Its quote must be the same code path as its execution; its bundle
  order must be asserted from its own execution record, not from counts. The kit's sandbox has mutants for both.

- **Recorded logs keep the logs of frames that reverted.** `vm.getRecordedLogs()` returns an event emitted inside a
  call that later reverted (forge 1.8.1, established by a three-line test, not by memory). A reading that sums a
  venue's fill events over a tape therefore counts fills the router then undid on `minOut` - the kit measured 126
  pulled on an allowance of 120 that way. Measure what STAYED: balances, allowances consumed, positions; use events
  for counts and names, never for amounts.

## 5. What goes in the dossier

Section 5, one row: the scenarios run (agents, ordering, latency, seeds, steps), the parameters that were read from
the chain and the ones that were guessed, the ledger table over seeds, and the spec line each number was compared
against. Section 8: the agents that were NOT written, by name, starting with the ones `HOOK-ATTACKS.md` suggests.
