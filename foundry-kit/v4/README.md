# v4 module

The Uniswap v4 half of the foundry kit: a harness that gives a hook a PoolManager to be tested against, a
salt miner for the flag bits, two deliberately stupid fixtures to trade through, a hostile hook, and one
worked example with its unit tests and its invariant suite.

It is a **separate Foundry project** from the kit's root, at `foundry-kit/v4`. The root kit's only dependency
is `forge-std`, and nobody who is not writing a v4 hook should have to compile a PoolManager to run it.

It contains **no Uniswap source and no Uniswap bytecode**. `PoolManager` is BUSL-1.1; `lib/` and
`fixtures/*.hex` are git-ignored and two scripts fetch them.

---

## Getting it running

```sh
scripts/install-v4.sh foundry-kit/v4      # clones the pinned commits into foundry-kit/v4/lib
cd foundry-kit/v4
forge test
```

Pins, printed on every install and recorded here so a reader does not have to run anything to see them:

| what | commit |
| --- | --- |
| `Uniswap/v4-core` | `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc` (the commit `v4-periphery` pins as its submodule) |
| ↳ `forge-std` | `1de6eecf821de7fe2c908cc48d3ab3dced20717f` |
| ↳ `solmate` | `4b47a19038b798b4a33d9749d25e570443520647` |
| `Uniswap/v4-periphery` (optional, `V4_WITH_PERIPHERY=1`) | `9969eec44cfdf07e24b41de47f40276a58401976` |

The harness needs only `v4-core`. `v4-periphery` is there for hooks that import the position manager, the
quoter or the routers; it is not installed by default, and nothing in this module depends on it.

The v4 API moves. The structs for swapping and modifying liquidity left `IPoolManager` for
`types/PoolOperation.sol`, `BaseHook` and `HookMiner` left `v4-periphery/src`, and the `v4.0.0` tag of
`v4-core` is an older API than the commit above. That is why everything is a hash and not a branch. Moving a
pin is a decision somebody makes on purpose, in `scripts/install-v4.sh`, and re-runs the battery after.

**The example lives in the standard directories**, `src/examples/` and `test/examples/`, not in an
`examples/` tree of its own. `forge` compiles `src`, `test` and `script` only, and Foundry's `--mutate` and
`--brutalize` copy only those into their temporary workspace: an example kept outside them is either not
built at all or mutated into 100 % invalid mutants with exit code 0. See the root kit's README, "Native
mutation, measured".

### Running it on a bench

```sh
BENCH_ROOT=$HOME BENCH_EXCLUDE="*.hex *.json" scripts/bench.sh mybench foundry-kit
scripts/install-v4.sh ~/mybench/v4
SRC_DIRS="src test ../src" scripts/battery.sh ~/mybench/v4
```

Two details that are not obvious. The bench copies **`foundry-kit`**, not `foundry-kit/v4`, because the v4
project remaps `gauntlet-kit/` to `../src` and a bench of the subdirectory alone has no parent to remap to.
And `BENCH_EXCLUDE="*.hex *.json"` keeps `bench.sh --delete` from removing fixtures you fetched into the
bench, which are the one thing in there that is expensive to get back. `SRC_DIRS` on the battery adds the
root kit's sources to the freshness check, which otherwise only watches this project's own; `src` and `test`
now cover the example too, since it lives inside them.

---

## What is in here

Four of these overlap with utilities upstream ships, and the kit's own rule is that upstream wins - so here is why each
one exists anyway. `HookMiner`: upstream's lives in `v4-periphery`, which this module does not install by default (the
harness needs only `v4-core`); ours is the same search, and the flag mask is read from `Hooks.sol` of the pinned core,
not copied, so a change in the mask's width is picked up on the next pin. `MinimalRouter` and `LiquidityHelper`: `v4-core`
ships `PoolSwapTest` and `PoolModifyLiquidityTest`; ours are deliberately dumber (no hook-data plumbing, no take/settle
options) so that a failure in a test is the hook's or the manager's, never the fixture's. `V4Harness` overlaps with
`Deployers.sol`, which does not know about an etched manager. If any of these ever disagrees with its upstream twin on
behaviour, the upstream one is right.

| file | what it is |
| --- | --- |
| `src/V4Harness.sol` | the base your tests inherit: **both** managers, currencies, routers, pool helpers (overlaps `v4-core/test/utils/Deployers.sol`) |
| `src/HookMiner.sol` | CREATE2 salt search for an address carrying **exactly** the declared flags (overlaps `v4-periphery/src/utils/HookMiner.sol`) |
| `src/MinimalRouter.sol` | the dumbest swap router that can settle its own deltas (overlaps `v4-core/src/test/PoolSwapTest.sol`) |
| `src/LiquidityHelper.sol` | adds and removes liquidity inside its own unlock callback (overlaps `PoolModifyLiquidityTest.sol`) |
| `src/HostileHook.sol` | a hook that lies on demand, and declares nothing, so it can be mined to a WRONG address |
| `src/SwapEventReader.sol` | reads the fee the manager's own `Swap` event reports |
| `src/examples/CappedDynamicFeeHook.sol` | the worked toy: a congestion fee with a hard cap |
| `src/examples/MUTANTS.md` | its mutation survivors: four real gaps, six equivalents argued one by one |
| `test/examples/CappedDynamicFeeHook.t.sol` | its unit tests, one per line of its threat model |
| `test/examples/CappedDynamicFeeHook.invariants.t.sol` | its handler, its invariants, its non-vacuity smoke test |
| `test/ManagerSelection.t.sol` | tests of the harness's own decision about which manager |
| `test/HookFlags.t.sol` | the mining, and the two different refusals of a wrong address |
| `test/HostileHook.t.sol` | one test per switch on the hostile hook, plus all ten entry points driven once |
| `test/Harness.t.sol` | the fixtures' own smoke test |
| `fixtures/` | where fetched bytecode lands. Empty in git, on purpose |

---

## The two managers

`V4Harness` gives you a choice, because the two fail differently, and it **says which one ran** on every run:

```
---------------------------------------------------------------
V4 MANAGER: real bytecode (etched fixture)
  address      0x000000000004444c5dc75cB358380D2e3dE08A90
  runtime size 24009
  fixture chain id 1
  code hash    0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293
---------------------------------------------------------------
```

**`V4_MANAGER=source`** (the default). `new PoolManager(...)` from `lib/v4-core`. Fast, hermetic, debuggable,
and it tests the manager you *read*.

**`V4_MANAGER=fixture`**. The runtime code of a manager that actually exists, `vm.etch`-ed **at the address it
lives at**. That last part is not cosmetic: v4's `NoDelegateCall` bakes its own address into the code as an
immutable, so a manager etched anywhere else refuses every call that reaches it. The address comes from the
fixture's `.json`, which is why the harness needs both files and refuses half an installation.

Two things the etched manager does not carry, and you should know both before you read anything into a green
run against it: its **storage is empty**, so it has no owner, no protocol fees and no pools until your tests
make them; and `block.chainid` is still the test chain, not the fixture's. The harness prints both numbers.
If your hook reads `block.chainid`, call `vm.chainId(...)` yourself.

`V4_MANAGER` takes **exactly two values**, `source` and `fixture`. Anything else — `fixtrue`, `FIXTURE`, an
empty string — reverts with `UnknownManagerMode`. It used to mean "source", which is the same silent
fallback as the one below, reached by a transposed letter instead of a missing file: an audit typed
`V4_MANAGER=fixtrue` and watched the suite print "compiled from source, 5 passed" while the operator
believed they were testing the real bytecode.

### When the fixture is missing, it SKIPS — loudly

```
[SKIP: skipped: V4_MANAGER=fixture but fixtures/PoolManager.hex (and fixtures/PoolManager.json) is
 missing. NOTHING WAS TESTED. Fetch it: RPC_URL=... scripts/fetch-bytecode.sh <manager address> ...]
```

It does not fall back to the source manager. A silent fallback is the worst outcome available here: the run
is green, the log says nothing, and everybody downstream believes the real bytecode was tested. The reason
travels **inside the skip** rather than in a `console2.log`, because forge does not print a skipped `setUp`'s
logs at any verbosity, and a skip nobody can see is one line away from the pass it exists to prevent.

The decision is a plain function, `managerPlanFor(mode, path)`, so that it can be tested without environment
variables: see `test_missing_fixture_is_a_skip_and_never_a_silent_fallback_to_source`.

---

## Get the manager that actually exists

**When to do this.** Not on day one. The source manager is the right one while the hook is still moving.
Fetch the real one:

* as soon as the **target chain is decided** — that is the moment "a v4 manager" becomes "*that* manager";
* **before phase 5 (black-box)**, so the attacker is attacking the deployment, not a source build;
* **always before promotion (phase 6)** and before any dossier is handed to a human. A gate passed only
  against a source build is a gate passed against something nobody will ever deploy;
* whenever the pin in `install-v4.sh` moves, or the chain does an upgrade.

**How.**

```sh
export RPC_URL='https://<endpoint>'          # in YOUR OWN terminal, see the key rule below
scripts/fetch-bytecode.sh 0x<manager address> foundry-kit/v4/fixtures/PoolManager.hex
V4_MANAGER=fixture scripts/battery.sh foundry-kit/v4
# or by hand - and then the corpus directory is YOURS to set:
cd foundry-kit/v4 && V4_MANAGER=fixture FOUNDRY_INVARIANT_CORPUS_DIR=corpus/invariant-fixture forge test -vv
```

The fixture run gets **its own corpus directory** on purpose (`battery.sh` and `fuzz-long.sh` pick
`corpus/invariant-$V4_MANAGER` by themselves; a bare `forge test` does not). The two managers deploy everything at different
addresses, a fuzz corpus stores raw addresses, and a corpus replayed against the other layout calls whatever now lives
at the old ones - a red campaign that has nothing to do with your hook (`doctrine/JUDGES.md`). If you ever see a sequence
step whose `addr` is not the handler, delete `corpus/` and `cache/invariant/` and run again.

`fetch-bytecode.sh` prints the chain id, the code size and the keccak of the code, and refuses an address
with no code — which is what a wrong chain, a wrong address or a stale endpoint looks like. Writing a
zero-byte fixture and etching it produces a "manager" that accepts every call and answers nothing, and a
whole suite passes against a contract that is not there.

**Where the address comes from.** Uniswap's own deployments page, which at the time of writing lists the
Ethereum mainnet `PoolManager` at `0x000000000004444c5dc75cB358380D2e3dE08A90`. Three rules:

1. **Identify the contract by its ADDRESS, never by a name somebody typed**, including a name in this file.
   Addresses in documentation go stale and this one may have.
2. **Verify the chain id** that `fetch-bytecode.sh` prints against the chain you are actually targeting. A
   manager fetched from the wrong chain etches perfectly and tests nothing.
3. **Write the address, the chain id and the code hash into `DECISIONS.md`.** It is the identity of the thing
   your whole suite was run against.

### The RPC key rule

**Never ask the owner for an endpoint in the chat, and never accept one there.** A URL pasted into a
conversation is in a transcript, a log and a history forever, and the key is usually in the URL.

`fetch-bytecode.sh` reads `RPC_URL` from the environment and from nowhere else. It is not an argument, so it
cannot reach a shell history or a process list; it is never printed; and the error output of the underlying
tool is scrubbed of anything shaped like a URL before you are shown it.

If you are an agent and you need one: tell the owner to run `export RPC_URL=...` **in their own terminal**,
or to put it in a git-ignored `.env` and source it, and then **stop until `fetch-bytecode.sh` works**. Do
not carry on with the source manager and mention it in a footnote.

A **public keyless endpoint is fine** for `eth_getCode`, and is the better choice: no key means no key to
leak. This module's own fixture was fetched through one.

---

## Address mining for the flag bits

A v4 hook's permissions are the low fourteen bits of its own address. `HookMiner.find(deployer, flags,
creationCode, constructorArgs)` searches for a salt whose CREATE2 address carries **exactly** those bits.

**Equality, not containment.** The naive search — "keep going until the address has at least the bits I
want" — accepts an address carrying extra flags, because every extra bit is free. The manager will then call
the hook in a place the hook has no code for. Mining for equality is the whole difference between this
library and a for-loop written in a hurry.

**Mine in `setUp`, every run.** The address is `keccak(0xff, deployer, salt, keccak(initcode))`, so a salt is
only valid for one deployer, one creation code and one set of constructor arguments. Change the hook by a
character and yesterday's salt points somewhere else. Never hard-code one.

### Which refusal catches what

This is the part that is easy to get wrong, so the tests state both halves:

| wrong address | what refuses it | test |
| --- | --- | --- |
| a "returns delta" bit with no matching action bit | **the manager**, at `initialize` | `test_manager_refuses_a_delta_flag_with_no_action_flag` |
| no flag bits at all, on a static-fee pool | **the manager**, at `initialize` | `test_manager_refuses_a_flagless_hook_on_a_static_fee_pool` |
| an EXTRA action flag the hook did not declare | **the hook's own constructor**, via `Hooks.validateHookPermissions` | `test_an_address_with_one_extra_flag_is_refused_by_the_hooks_constructor` |

The third row is why every hook should call `validateHookPermissions` in its constructor: the manager does
**not** check it. `test_manager_accepts_an_extra_action_flag_which_is_why_the_constructor_check_matters`
exists so that nobody reads the first two rows and concludes the manager is checking their work.

**What the search costs, as a number and not an adjective.** One address in 2¹⁴ carries a given exact flag
set, so the expected number of tries is 16 384 and the chance that 200 000 consecutive tries all miss is
`(1 − 2⁻¹⁴)²⁰⁰⁰⁰⁰ = e⁻¹²·²`, about **5 in a million**. Measured on the example hook's 5 322-byte initcode (the build the TESTS hash: they import the manager, so they get
the `CappedDynamicFeeHook.manager` row of `forge build --sizes`; the default-profile row of the same table says 5 629):
1 239 tries cost 1 752 012 gas, so ≈1 414 gas a try, and an average search is ≈23 M gas — under a second.
(`MAX_TRIES` used to be justified with "astronomically unlikely". If you hit it, the explanation is a flag
set no address can carry, not bad luck.)

---

## The hostile hook, and a counter that could not go up

`reentriesSucceeded` was the number `test/HostileHook.t.sol` told you to make an invariant. For a while it
could not be anything but zero, against any manager at all, because `HostileHook` had no `unlockCallback`:
a permissive manager's call back into it reverted, and the counter recorded **this repository's own missing
function** as the manager's refusal. An audit built a "manager" with no lock whatsoever and the counter
still said "refused".

It now has one, and the switch takes a target and calldata instead of only `manager.unlock`, with setters
for the three cases worth asking about. Three measurements came straight out of that, and the third is the
one to take away:

| what the hook does from inside `beforeSwap` | what the manager under test does |
| --- | --- |
| `unlock`, with nobody holding the lock | **allowed** — that is not re-entrancy, it is opening a transaction |
| `unlock`, inside somebody else's swap | **refused** — and now that refusal means something |
| `take`, inside somebody else's swap | **allowed as a call**, and the whole transaction then dies at the outer `unlock`, which cannot close its books |

"The manager refused it" and "the manager allowed it and the transaction died afterwards" are different
facts, and only one of them is a defence. A counter that cannot go up is not evidence: give it a control
that makes it move before you build an invariant on it.

---

## The worked example

`CappedDynamicFeeHook` raises the pool's LP fee with congestion — base fee for the first swap of a block, one
step more for each further swap, hard cap, reset next block — and takes no delta, holds no token, has no
owner. It is small on purpose. Its value is the threat model written at the top of the file **before** any
test: six things it claims to survive, two it declares it does not defend, and one named defence per line.

Two things in its suite are worth stealing whatever your hook does.

**Compare what the hook SAID with what the pool DID.** The hook exposes `quoteNextFee(key)`. Every swap in
the campaign reads the quote first, swaps, and then reads the fee off the **manager's own `Swap` event**.
Asserting on the hook's stored `lastQuotedFee` would be asking the hook whether the hook was right. A suite
that only follows the money passes while the quote lies, and the quote is the part other people's software
trusts. (This holds because no protocol fee is ever set here, so the event's `fee` is the LP fee. Turn
protocol fees on and the assertion has to be rewritten, not deleted.)

**`swapBurst`, and why it exists.** With one swap per action, a 4 096-call campaign spread over fifteen
actions almost never produced ten swaps between two block rolls — so the fee never approached its cap, and
`invariant_the_pool_never_charged_more_than_the_cap` passed without ever being near the thing it guards. A
mutant that removed the cap entirely still went **green in the fuzz run**; only the hand-written smoke test
caught it. That is the vacuous pass from `doctrine/INVARIANTS.md`, caught in the act.

The fix was not a bigger campaign. It was an action that reaches the state: one call, many swaps, no block
change in between. Ask of your own hook: **which of my rules only bites after N things happen in a row, and
does my handler have an action that does N things in a row?**

**And then check that it really does N.** This file used to say, flatly, that with `swapBurst` in the handler
the same mutant makes the invariant go red. An independent audit ran the campaign against that mutant three
times on a fresh corpus and got KILLED, KILLED, **SURVIVED**. The sentence was a single observation written
as a certainty, and the campaign takes a random fuzz seed unless you give it one, so a single observation is
one draw.

Measured afterwards, per run, with the census below: the campaign reached the fee cap in **22 of 65 runs on
one draw and 3 of 65 on the next**, and a campaign that never reaches the cap cannot tell a capped hook from
an uncapped one. Two things came out of that, and both are in the handler now: the hostile switches are
biased toward their honest values and there is a `calmDown()` action that clears them (a sticky switch that
is on half the time parks the campaign in a world where nothing settles), and `swapBurst` makes half its
bursts long enough to actually reach the cap — the rule needs ten swaps in a block, and a uniform 2..14
burst is long enough about a third of the time. With both, the cap is reached in roughly **a third to a half of
the 65 runs** (the measured draws are in `foundry-kit/README.md`, the one place they live), and the no-cap mutant
died by the campaign alone in 10 campaigns out of 10 for an independent verifier.

Say "in most runs", or give a range over several campaigns. Fixing `--fuzz-seed` does not pin the draw when a
corpus is on: a reviewer ran the same seed twice and got 19 and 17.

---

## Measured on this machine

forge 1.8.1, solc 0.8.26, `evm_version = cancun`. Numbers, not adjectives:

| | |
| --- | --- |
| module's own tests | all passed, 0 failed, **0 skipped**, the same count on both managers, and under `--brutalize`. The count is whatever `scripts/battery.sh` prints today: it was copied here twice and was stale both times |
| native mutation on the example hook | in `src/examples/MUTANTS.md`, which is the only place that number lives |
| `forge coverage`, `src/HostileHook.sol` | **72.97 % of lines** (54/74), up from 3.70 % when it had no tests of its own |
| invariant campaign | 64 runs × 64 depth, 4 096 calls; the census, not `reverts:` — see the root README |
| clean build | about 25 s |
| `PoolManager` from source | **24 050 B**, 526 under the EIP-170 limit |
| `PoolManager` etched from mainnet | **24 009 B**, keccak `0x785f1014…c7ce1293`, chain id 1 |
| `CappedDynamicFeeHook` | **4 874 B** in the default-profile build, **4 659 B** in the build the tests deploy - see below |

Two notes on that last row, because it was wrong here for a whole revision and the reason is a trap.

`forge build --sizes` prints TWO rows for this hook, 4 874 B and 4 659 B (`CappedDynamicFeeHook.manager`). The
`compilation_restrictions` that compile `PoolManager.sol` through the IR pipeline create a second compilation
profile, and every contract compiled together with the manager is listed a second time under that profile's name.

This paragraph has now been wrong in BOTH directions. First the table said 4 659 B with no explanation. Then it said
4 874 B and asserted that "the artifact the tests actually deploy is the default-profile one" - which nobody had
measured. Measured from inside a test that inherits `V4Harness` (so it imports the manager):
`type(CappedDynamicFeeHook).creationCode.length` is **5 322** and the deployed `code.length` is **4 659** - the
`.manager` row. The tests deploy the IR-profile build; a deployment script that does not import the manager gets
the other one. **When `--sizes` prints two rows for one contract they are two different builds: find out which one
each of your programs uses by asking the program (`address(hook).code.length`), and report the size margin against
the LARGER of the two.**

And the root kit's own numbers are not repeated here any more. They live in `../README.md`; a number copied
into a second file is a number that will disagree with the first one within a revision, which is exactly what
happened to the row that used to say "root kit | 61 passed".

The whole suite has been run both ways: against the source manager, and against the mainnet manager fetched
through a public keyless endpoint. Both are green, and each run says which one it was.

**A note on the build settings.** At `optimizer_runs = 44444444` with the IR pipeline off, `PoolManager`
compiles to 26 988 bytes — 2 412 **over** EIP-170, a manager that could not be deployed on any chain. Uniswap
compiles it through the IR pipeline, so `foundry.toml` does the same for that one file, via a compilation
restriction. It costs about three seconds of the build. Without it `forge build --sizes`, and therefore
`scripts/battery.sh`, fails, and it is right to.

---

## The simulation sandbox

When to run it, the rules that make its numbers mean something, and how it lies: `doctrine/SIMULATE.md`. The pieces:

### Step 1: engine and calibration

`src/sim/` is a different kind of judge from everything above. A fuzz campaign searches for ONE sequence that breaks
a rule. A simulation measures a DISTRIBUTION: given a population of agents, a clock with the target chain's cadence
and an ordering model, who ends richer, who poorer, and how far execution drifts from the quote. Its evidence label
is SUPPORTED (`doctrine/EVIDENCE.md`) and never more: it only measures the attacks somebody wrote an agent for.

| file | what it is |
| --- | --- |
| `src/sim/ISimAgent.sol` | an agent is a contract with a wallet and three verbs: `observe`, `decide`, `settle`; an `Intent` is quoted when decided and executed `latency` steps later |
| `src/sim/SimClock.sol` | the chain's cadence as parameters: L2 block time, and whether `block.number` is an L1 estimate (it is, on Arbitrum-style chains: one hook "block" spans ~120 sequencer blocks) |
| `src/sim/SimLedger.sol` | per-agent books: decided / executed / refused, in / out / quoted, shortfall and windfall against the quote, gas, P&L in the quote currency - gross (`pnl`) and net of gas (`pnlNetOfGas`, at the price of gas the SCENARIO sets with `setGasPrice`, in raw quote per gas x 1e18; 0 is allowed but must be said, or the net P&L and the dump line refuse to run); one line per agent per run to `GAUNTLET_SIM`, ending `pnl  gasCost  pnlNet  atQuote`. `test/sim/LedgerGas.t.sol` holds it to that |
| `src/sim/SimEngine.sol` | the engine, with no opinion about the hook: the loop, the clock, FCFS ordering, the queue, the books - and four verbs a project binds (`_quote`, `_execute`, `_sqrtPriceNow`, `_balances`). A swap whose own quote at decision time is 0 is NOT SENT: no `_execute`, no gas, settled at once with `executed == false` and `REFUSED_AT_QUOTE`, counted in `refusedAtQuote` (the dump line's last column), never in `refused`; other kinds untouched (`test/sim/RefusedAtQuote.t.sol`) |
| `src/sim/ExampleScenario.sol` | the engine bound to the example hook: the quote is a snapshot-and-revert of the real swap (the same code path as the execution), `minOut` enforced as a router would, gas metered with `SimGasMeter`. A project with its own router or quoter copies this file and binds its own |
| `src/sim/SimGasMeter.sol` | what one action would cost as its OWN transaction: 21 000 intrinsic + calldata (16 / 4 gas a byte) + the callee's own gas from forge's record of the last frame, less the refund capped at a fifth; several calls of one transaction are added into one `Tx`. Not a `gasleft()` window in the test frame: that charges the agent the test's own memory growth (a run never frees memory; measured +17 % on identical decisions in a downstream binding). A warm-slot LOWER bound, no L1 data fee. `test/sim/GasMeter.t.sol` |
| `src/sim/agents/HonestTrader.sol` | the population's floor: fixed size every N steps, alternating, a slippage rule, a latency |
| `test/sim/Calibration.t.sol` | THE MANDATORY FIRST RUN: one honest agent, zero latency, alone - quote equals execution to the wei, ledger equals wallet, nothing refused. If this is red the sandbox is wrong and no number it produces counts |
| `test/sim/PartialFill.t.sol` | the calibration's blind spot: all the liquidity in one narrow range, so a swap bigger than the range walks out of it and the pool takes LESS than the input offered. The ledger must charge `Fill.amountInUsed`, not `Intent.amountIn`. Written because a mutant that charged the offered input SURVIVED the calibration - on a full-range pool every swap takes its whole input |
| `scripts/sim-report.sh` | adds the ledger lines up over runs: a result is "over N runs", never one line read off a log |

What a binding must do (a project's own copy of `ExampleScenario.sol`), in order:

1. Override the five verbs: `_quote`, `_execute`, `_sqrtPriceNow`, `_balances`, `_referencePriceX96`.
2. Call `_initEngine()` once its system is deployed.
3. **Price gas: `ledger.setGasPrice(quotePerGasE18)`** right after `_initEngine()` - raw quote per unit of gas x 1e18,
   0 for a chain whose gas nobody pays, but SAID. `run` refuses to start (`SimLedger.GasUnpriced`) until it is.
4. Report `Fill.amountInUsed` on every executed swap (the engine refuses a fill without it).
5. Honour `Intent.amountInQuote` - convert a quote-sized currency0 input at its reference price - or refuse it loudly.
6. **Report `Fill.gasUsed` as what this action would cost as its own transaction** - a warm-slot lower bound, no L1 data
   fee: call `SimGasMeter.lastCall(calldata)` right after the call (or `addLastFrame` per call and `total` once, for
   several calls sent as one transaction), before any other external call. Never `gasleft()` before and after the call:
   in the test frame that window grows with the test's memory, not with the action. What the number leaves out is in
   `SimGasMeter.sol` (cold first touches: forge 1.8.1's `vm.cool` is not usable for it; the L1 fee; storage priced
   against the test's start). On forge 1.8.1 the typed `vm.lastCallGas()` REVERTS against forge-std 1.16.2 (forge
   returns five words, forge-std's `Gas` declares six): the library reads the record by a raw call, and so must a test.

**Incompatible change (2026-09-22).** A binding written before this date stops at its first `run` with
`GasUnpriced` until it adds step 3; the ledger's dump line has two more columns at the end (`gasCost`, `pnlNet`), which
`sim-report.sh` reads; and `Intent` has a new field (`amountInQuote`), so an `Intent(...)` written positionally no longer
compiles (named fields and `Intent memory it; it.x = ...` are unaffected). Later the same day the dump line gained a
16th column at the end (`atQuote`, swaps quoted 0 and never sent), and `refused` stopped counting them: a reading of
`refused` taken before that change includes them. Nothing changes for a binding.

Measured on the example hook, three runs each, fresh state (the numbers are one machine's draws, in wei of the
quote currency, and they are here to show the SHAPE, not to be quoted):

```
scenario       agent    runs  decided  executed  refused  shortfall/run  windfall/run  worst ever
calibration    honest      3     40.0      40.0      0.0              0             0           0
latency-one    honest      3     41.0      41.0      0.0              0   5.98e15               0
latency-one    late        3     41.0      40.0      0.0   2.09e14         5.38e12       1.99e14
```

Two things the first run taught, both now asserted in the test file:

1. **On this hook a stale quote costs money even with nobody hostile around.** The fee depends on how many swaps the
   block has already seen, so a quote taken in one block and executed in the next is a different fee. The `late`
   agent (latency 1) pays about 2e14 per run for it; the same agent at latency 0, alone, pays nothing.
2. **"Zero latency" is not "nobody ahead of me".** Put the late agent in the world and the honest agent at latency 0
   starts showing a gap too: its quote is of the block's opening state, and an intent submitted a step earlier is
   ahead of it in the FCFS queue. The calibration therefore runs ALONE, and the test says why.

### Step 2: the ordering model as a parameter, a main market, and two adversaries

| file | what it is |
| --- | --- |
| `SimEngine.ordering` | `FCFS` (a single sequencer, no mempool: nobody sees a pending intent, nobody buys position) or `BUNDLE` (every intent about to execute is shown to the searchers, who place their own before and after it: a chain with a public mempool or builder bundles) |
| `ISimSearcher` | the capability that only exists under BUNDLE: `wrap(victim)` before, `unwind(victim, fill)` after - by then the searcher knows what its front-run bought |
| `ExampleScenario._addMainMarket` | a second, hookless v4 pool on the same currencies: the market where the token "really" trades, pushed by world traders. Real AMM math in the same EVM - no price stub. The ledger values P&L at ITS price |
| `agents/Arbitrageur.sol` | the stale-quote extractor: trades on the venue under test whenever it lags the main market by more than a PRICE threshold in bps (set it above the round trip's cost, or it measures itself), and with `closeOnMain` realises every fill on the main market at its own latency. The attack that exists on an FCFS chain |
| `agents/Sandwicher.sol` | the classic sandwich as a searcher: front-run at a multiple of the victim's size, back-run selling what the front-run bought. Only exists under BUNDLE |
| `test/sim/Ordering.t.sol` | the SAME population (two world traders on the main market, a stream of honest swaps on the venue, an arbitrageur, a sandwicher) under both orderings; under BUNDLE the engine's own execution record is walked to assert front-run, victim, back-run, in that order, for every wrap |

The same population, 60 steps, run under each ordering (three runs each; this population is deterministic, so the
three agree - variation will come with a seeded price process and the fork of a real market):

```
                        decided  executed  shortfall/run   pnl/run
population-fcfs   victim     30        29              0   -2.3e15
population-fcfs   arb        31        30        5.4e15   -2.5e15
population-fcfs   sandwich    0         0              0         0
population-bundle victim     30        29        4.3e16   -5.1e16
population-bundle arb        31        30        1.7e16   -1.7e16
population-bundle sandwich  118       118              0   +1.4e16
```

Read across the two blocks and the ordering model is the whole result: under FCFS the sandwicher is never asked and
earns nothing; under BUNDLE it wraps 59 intents (the arbitrageur's too - a searcher does not care whose), earns
1.4e16, and the victim's cost goes from 2.3e15 to 5.1e16 - inside its 2 % slippage rule every time, which is how a
sandwich is sized. On THIS hook the fee that rises with same-block volume did not stop it at these sizes; the
number a hook author wants is the front-run size at which it does, and that is a sweep, not an assertion.

Mutants, by hand: the front-run never executed -> "one front-run and one back-run per wrap: 59 != 118" (no fill, so
no unwind - the shape check behind it is the second line of defence); a searcher intent left
for the FCFS scan to execute again -> the bundle test dies (re-execution without end); searchers asked under FCFS ->
"under FCFS nobody sees a pending intent: 118 != 0".

### Step 3: the liquidity side, and a seeded world

| file | what it is |
| --- | --- |
| `Intent.kind` | a swap, or a liquidity change (add / remove, with ticks and a delta): no quote, no slippage rule, executed as given in the agent's own position |
| `Intent.amountInQuote` | the UNIT of `amountIn`: false (default) = the input currency; true = the agent sized the swap in currency1 (quote), and a binding that supports it converts a currency0 input at its reference price - one that does not refuses the intent (`ExampleScenario` does). Only the agent knows the unit, so a binding never guesses it: `HonestTrader`, `RandomTrader` and the `Arbitrageur`'s OPENING leg set it from `setSizeInQuote`; the arbitrageur's CLOSING leg never does, because it sells what the opening leg delivered. `test/sim/IntentUnit.t.sol` |
| `agents/PassiveLP.sol` | the LP who is not watching: a position on at the start, off at `exitStep`. Its P&L is the number every other agent's profit is ultimately taken from |
| `agents/JitLP.sol` | just-in-time liquidity as a searcher: a narrow position around the price in front of each swap, off behind it. Only exists under BUNDLE |
| `agents/RandomTrader.sol` | the world, SEEDED: sizes and directions from a pseudo-random stream keyed by `SIM_SEED`. The same seed replays the same tape; a different seed gives a different one - both asserted |
| `test/sim/Liquidity.t.sol` | the same population under both orderings inside ONE test, from one snapshot, so the two ledgers are directly comparable |

Measured (seed 1, 60 steps, wei of the quote currency): the passive LP earns **1.39e16 under FCFS and 4.0e15 under
BUNDLE** - the JIT LP, asked 29 times, took the rest and ended at **+2.67e16**; the victim's execution improved
(more liquidity in front of it) and its P&L barely moved. That is the whole JIT story in three numbers, and the
test asserts only its shape: the passive LP is worse off with the JIT LP in the world than without, on the same
tape. Mutants: liquidity changes that never execute, a JIT position of 1 wei, a world that ignores its seed - each
seen red by these tests.

What is NOT here yet: a fork of the real target chain as the main market (needs the owner's `RPC_URL`), the LP's
allowance as a parameter (it means something on a hook that pulls by allowance, not on a v4 position - the
binding for such a hook adds it), latency drawn from a measured distribution, and the doctrine page that says when
to run any of this. Listed so that nobody reads them as present.

Mutation, by hand (`scripts/mutate.sh`): a quote off by one wei kills the calibration ("the quoter is not the
executor: 40 != 0"). `executeAtStep > s` -> `!= s` in the FCFS loop SURVIVES, and is equivalent by construction:
the loop never skips a step, so no intent is ever due in the past. If a scenario ever calls `run` twice, that
equivalence ends - a limit, written here so it is not rediscovered.

---

## What this module still does not do

Written down because a list of gaps is the only honest end to a README.

* **Native currency.** The router and the liquidity helper refuse a pool whose `currency0` is the zero
  address. ETH changes settlement, refunds and re-entrancy at once, and a hook tested only on two ERC-20s
  has not been tested on the most common pair on the chain. This is the biggest gap.
* **Hooks that return deltas.** The example declares no delta permissions, so the harness has never had to
  settle a hook's own delta. `BeforeSwapDelta`, the specified and unspecified sides, exact-in against
  exact-out and the sign conventions are where most hook arithmetic bugs live, and there is no worked
  example of them here.
* **ERC-6909 claims.** The manager's internal balances are a second way to hold value. Nothing here uses
  them, and an invariant that counts only ERC-20 balances will report a leak as conservation.
* **Re-entrancy through a hook that HOLDS A DELTA, and through a currency's own transfer hook during
  settlement**, where the manager is mid-accounting. `HostileHook` can now re-enter through `unlock`,
  through `swap` and `take` — the doors that are OPEN while a hook runs — and through any target and
  calldata you hand it, and `reentriesSucceeded` is observable at last (see below). What is still missing
  is a hook with delta permissions to do it from.
* **Hijacking `sync`**, and a currency re-synced by a token's own transfer hook mid-settlement.
* **Fork tests.** Everything here is local. There is no test that runs against a live fork.
* **A second pool sharing a currency with the first**, which is where "what does the hook believe about a
  pool it has never seen" gets interesting beyond the single `UnknownPool` check.
* **Tick-spacing and price edges**, and unusual fees. The example is exercised at spacing 60 and 1:1.
* **A block-pinned fixture.** `fetch-bytecode.sh` reads the latest block; it does not pin one.
* **`v4-periphery` is installed but untested.** Nothing in this module compiles against it.

The attack list this module was written from — re-entrancy through `unlock`, hijacking `sync`, `hookData` as
attacker input, read order, delta accounting, ERC-6909 claims, native currency, fee and tick edges,
initialisation and permissions — is still the right list. Several rows of it now have code. The ones above
do not, and no green run in here should be read as covering them.

## What it must NOT contain

No deployment scripts, no broadcast, no addresses beyond the fixture needed to etch a manager under test.
The gauntlet ends at a dossier for human auditors, and this module is part of the evidence, not part of a
release.
