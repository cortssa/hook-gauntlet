# v4 module

The Uniswap v4 half of the foundry kit: a harness that gives a hook a PoolManager to be tested against, a
salt miner for the flag bits, two deliberately stupid fixtures to trade through (ETH on either side too), a hostile
hook, a hostile native counterparty, the other end of a token's transfer callback pointed at the manager, and three
worked examples with their unit tests and invariant suites: a hook that
returns no delta, one that does, and one that keeps what it takes as ERC-6909 claims.

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

**Offline**, from clones you already have (another checkout's `foundry-kit/v4/lib`, say):
`V4_LOCAL_SRC=<dir holding v4-core/> scripts/install-v4.sh foundry-kit/v4`. Nothing is fetched. The clone is checked
BEFORE anything is copied - at the pin, no local changes - and the copy is checked again by the same line that checks a
fetched one (HEAD == pin, each submodule == what v4-core's tree pins); a clone at another commit is refused by name.
`scripts/selftest.sh` holds it to the refusal; the success path was run by hand (2026-09-23, from a clone at the pin).

`forge` is not on the `PATH` of a non-interactive shell on most machines (`foundryup` installs it into
`~/.foundry/bin` and adds that to your shell's rc file, which a script or an agent's shell does not read): a script
that says `forge: command not found` needs `export PATH="$HOME/.foundry/bin:$PATH"` first.

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
BENCH_ROOT=$HOME scripts/bench.sh mybench foundry-kit      # links foundry-kit/lib AND foundry-kit/v4/lib
SRC_DIRS="src test ../src" scripts/battery.sh ~/mybench/v4
```

Three details that are not obvious. The bench copies **`foundry-kit`**, not `foundry-kit/v4`, because the v4
project remaps `gauntlet-kit/` to `../src` and a bench of the subdirectory alone has no parent to remap to
(`scripts/fuzz-long.sh foundry-kit/v4` knows this and benches `foundry-kit` by itself). The dependency directories are
`lib/` at the root and `lib/` beside every nested `foundry.toml`, found and linked one by one - and nothing else called
`lib`: `scripts/lib/` is source and is copied (an rsync `--exclude=lib` used to drop both it and `v4/lib`, and every
v4 bench then needed a network install). `SRC_DIRS` on the battery adds the root kit's sources to the freshness check's
EVIDENCE (the list of sources that changed since the last build), which otherwise only hashes this project's own; the
verdict is forge's own build, which follows the imports into `../src` without being told. `src` and `test` cover the
example too, since it lives inside them.

A project with **no `lib/` of its own** (forge-std installed somewhere else) gets nothing linked, and `bench.sh` says so
in one line: `the project has no lib/: nothing linked; set LINK_FROM=<dir with forge-std>`. `LINK_FROM=<dir>` makes
`<dir>` the bench's `lib/` - linked, or copied through its links in a bench that withholds (`BENCH_EXCLUDE`); the root
`lib/` only, never over a `lib/` directory the bench already has, and ignored with a note when the project has a `lib/`.

A bench that must keep what was fetched INTO it (a manager fixture, a `v4/lib` installed there because the project
has none): `BENCH_EXCLUDE="*.hex *.json"`. A matching path the project does not have is the bench's own and survives
every refresh; one the project does have is withheld. The bench directory itself is never deleted - it used to be, on
every refresh with `BENCH_EXCLUDE` set, and the fixtures this paragraph promised to keep went with it
(`scripts/selftest.sh` plants `fixtures/PROBE.hex` and a bench-installed `v4/lib`, refreshes, and checks both).

### The long fuzz on the example

```sh
BENCH_ROOT=$HOME/mybenches scripts/fuzz-long.sh foundry-kit/v4        # the `long` profile: 1000 runs x 128 depth
CORE="swap swapBurst dustAheadOfVictim" REACH="fee at the cap;victim traded after dust in its block" \
  scripts/census.sh --aggregate $HOME/mybenches/fuzz-long-v4-*/v4/census/long.tsv foundry-kit/v4   # the gate: record in .gauntlet/reports/06-census-gate.txt, verdict on the last line; fuzz-long only prints the table
```

What a stranger hits, measured on 2026-09-23 (forge 1.8.1, `src/examples/SPEC.md` section 7 has the numbers). It
takes about **two and a half minutes** here (134 s, one worker at about 900 calls a second), not a night. It benches
`foundry-kit`, not `foundry-kit/v4` (the parent it remaps to), into `$BENCH_ROOT/fuzz-long-v4-<hash>`; `BENCH_ROOT`
defaults to `~/.gauntlet/bench`, so set it if your benches live elsewhere. The log and the census table land in YOUR
tree, `foundry-kit/v4/.gauntlet/reports/05-fuzz-long.txt` and `06-census-long.txt` (the everyday `census.sh` writes `06-census.txt`, so neither overwrites the other); the census file and the corpus stay in the
BENCH (`<bench>/v4/census/long.tsv`, `<bench>/v4/corpus/invariant`). **The next run keeps both directories**: the
bench's refresh never deletes `corpus/` or `census/` (`fuzz-long.sh` passes them to `bench.sh` as `BENCH_KEEP`), and a
`corpus/` the project has of its own is merged in, never replacing the bench's entries - so the first run's corpus is
there for the second (that forge then replays it is forge's behaviour, not measured here). Until 2026-09-23 the
refresh's `rsync --delete` removed both (measured then: 34 corpus files and 1 001 census lines before a refresh, none
after); `scripts/selftest.sh` now plants a corpus file and a census file in a long-fuzz bench, runs again, and checks
both survive and a project corpus file arrives. `census/long.tsv` itself is THIS run's census and starts empty (a stale
line would be added to the new table); copy it out, or set `GAUNTLET_CENSUS=census/<name>.tsv`, to keep a run's census
next to the next one's. The table it prints is not a gate (`CORE` is empty inside the script); the second command
above is. The census has 1 001 lines for 1 000 runs (the root README says
why), and the block forge prints at `-vv` is one run of them.

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
| `src/V4Harness.sol` | the base your tests inherit: **both** managers, currencies, routers, pool helpers, and `_deployHook` - a hook at a mined address in one call (overlaps `v4-core/test/utils/Deployers.sol`) |
| `src/HookMiner.sol` | CREATE2 salt search for an address carrying **exactly** the declared flags (overlaps `v4-periphery/src/utils/HookMiner.sol`) |
| `src/MinimalRouter.sol` | the dumbest swap router that can settle its own deltas, ETH included: `msg.value` in, the rest refunded after the unlock (overlaps `v4-core/src/test/PoolSwapTest.sol`) |
| `src/LiquidityHelper.sol` | adds and removes liquidity inside its own unlock callback, ETH included (overlaps `PoolModifyLiquidityTest.sol`). Positions are PER CALLER: the manager is given the salt `positionSalt(msg.sender, salt)`, so a hook that reads `params.salt` in a liquidity callback sees that derived salt, never the caller's |
| `src/HostileHook.sol` | a hook that lies on demand, and declares nothing, so it can be mined to a WRONG address; since K13 it also returns deltas on demand, settles them or not (in ETH too), and re-enters while holding one; it records the last swap's `sender` |
| `src/HostileNativeActor.sol` | a swapper or provider that is a contract, whose `receive()` accepts, reverts, re-enters or burns all its gas: the counterparty on every ETH payment |
| `src/TokenCallbackActor.sol` | the target of a `HostileERC20` transfer callback, pointed at the MANAGER: from inside a payment's transfer (between the payer's `sync` and its `settle`) it syncs, settles, settles and takes, settles and mints, takes, mints, swaps or unlocks, in its own name, and records what it saw |
| `src/SwapEventReader.sol` | reads the fee, and the POOL's delta, off the manager's own `Swap` event |
| `src/examples/CappedDynamicFeeHook.sol` | the worked toy: a congestion fee with a hard cap |
| `src/examples/SPEC.md` | its spec: the rule, the hostile-actor table, and what a discovery round found on it (F1, fixed at the cause; F2, decided) |
| `src/examples/MUTANTS.md` | its mutation survivors: four real gaps, six equivalents argued one by one |
| `test/examples/CappedDynamicFeeHook.t.sol` | its unit tests, one per line of its threat model |
| `test/examples/CappedDynamicFeeHook.invariants.t.sol` | its handler, its invariants, its non-vacuity smoke test |
| `test/examples/CappedDynamicFeeHook.r01.t.sol` | what round r01 found, kept as tests: F1 (seen red on the old rule), its residual, F2 on a real native pool |
| `src/examples/DeltaFeeHook.sol` | the worked DELTA toy: a fee on the unspecified side, a rebate on the specified side, a per-block cap, all kept per pool; its promises P1-P13 and one measured limit in the file header |
| `test/examples/DeltaFeeHook.t.sol` | its unit tests: all four orientations, a price far from 1, the cap, no free rebate, the partial fill (P9, P11), the payment in flight (P7), a currency that re-syncs mid-rebate (P12), and `TwoSwaps` - a helper that makes two swaps in ONE transaction |
| `test/examples/DeltaFeeHook.multipool.t.sol` | two pools on the delta toy sharing a currency: a pool nobody approved draining another's rebates, the cap per pool, and a two-pool campaign with invariants per pool AND per currency |
| `test/examples/DeltaFeeHook.invariants.t.sol` | its handler (per-swap books from three sources), its invariants, its smoke test |
| `test/examples/PrepayRouter.sol` | a router that pays FIRST (sync, transfer, swap, settle): the payment in flight a delta hook must not clobber |
| `test/examples/DeltaFeeHook.native.t.sol` | the delta example on an ETH / 6-decimal-token pool at 3 000 per ETH: the four orientations with ETH specified and unspecified, the rebate paid in ETH, the cap in ETH, a payment in flight in the fee currency, a second pool sharing ETH |
| `test/examples/Edges.t.sol` | the three examples and the harness at the edges: tick spacing 1 and 32 767, prices near and at the ends of the range, an LP fee of 0 and of 100 %, a dynamic fee at the cap, a cap above 2^96, a fee the manager does not hold yet |
| `src/examples/ClaimsFeeHook.sol` | the worked CLAIMS toy: a fee kept as an ERC-6909 claim (`mint`), withdrawn by a treasury (`burn` + `take`); its promises C1-C5 in the file header |
| `test/examples/ClaimsFeeHook.t.sol` | its unit tests: the four orientations counted by balance and by party, the withdrawal in both currencies, a treasury that refuses ETH |
| `test/examples/ClaimsFeeHook.invariants.t.sol` | its campaign on an ETH / token pool: every party's ETH, token and claims per swap, three naive invariants kept next to the per-party ones |
| `test/NativeHarness.t.sol` | the harness on a native pool: four orientations hookless and with a delta hook settling in ETH, refunds, too little ETH, liquidity |
| `test/NativeCounterparty.t.sol` | `HostileNativeActor` in every mode, as swapper and provider, at both receipts (inside the unlock, after it) |
| `test/DeltaAccounting.t.sol` | the harness against a hook that returns deltas: every party's books in the four orientations, and a router that pays the pool's delta, refused |
| `test/HostileDeltaHook.t.sol` | `HostileHook` re-entering `unlock`, `take`, `swap` and `settle` while HOLDING a delta; `TopUpPrepayRouter` - a router that pays first and then pays whatever its books still show owing |
| `test/TokenReentry.t.sol` | a currency's own transfer hook re-entering the manager DURING SETTLEMENT (`TokenCallbackActor`): every door before and after the balances move, a topping-up payer, a hook paying its own delta, a stale synced slot |
| `test/ManagerSelection.t.sol` | tests of the harness's own decision about which manager |
| `test/HookFlags.t.sol` | the mining, and the two different refusals of a wrong address |
| `test/HostileHook.t.sol` | one test per switch on the hostile hook, plus all ten entry points driven once |
| `test/Harness.t.sol` | the fixtures' own smoke test |
| `STATIC-TRIAGE.md` | the example hook's `forge lint` warnings (5 `unsafe-typecast`), each answered with a verdict and a test |
| `fixtures/` | where fetched bytecode lands. Empty in git, on purpose |

**Coverage of YOUR project counts files that are not yours unless you keep them out.** forge reports a file by the
path it was reached through: from the project's root when it is inside (`src/Gate.sol`, `vendor/kit/InvariantBase.sol`),
absolute or `../...` when a remapping or a `libs` entry reaches outside. Measured (forge 1.8.1, 2026-09-23, a toy gate on
forge's defaults with a `HandlerBase` handler, seven layouts): with forge-std reached through a `libs` entry outside the
project and the kit remapped by its path, the table listed `InvariantBase.sol` and eleven forge-std files and the total
read 4.24 % of branches (18/425), where `src/` and `test/` make 81.82 % (9/11). `--no-match-coverage 'foundry-kit/'`
only drops a path that contains that name: with the kit copied to a directory of another name it dropped nothing
(36.36 %), and it dropped forge-std only where forge-std happened to sit under a `foundry-kit/`. forge 1.8.1 has no
`--match-coverage` (rc 2, "unexpected argument"). What keeps everything outside your `src/` and `test/` out, wherever
the kit and forge-std live:

```sh
forge coverage --report summary --no-match-coverage '^([^st]|s($|[^r])|sr($|[^c])|src($|[^/])|t($|[^e])|te($|[^s])|tes($|[^t])|test($|[^/]))'
```

(forge's regex has no look-ahead, so "not under `src/` or `test/`" is spelled out letter by letter.) Measured on all
seven layouts - forge-std and the kit outside by absolute paths, by relative paths, both through `lib/`, the kit copied
INSIDE the project under `vendor/`, a `script/` contract next to them, and under `--ir-minimum` - the table held
`src/Gate.sol` and the handler and nothing else, 81.82 % of branches (63.64 % under `--ir-minimum`). A project whose
code lives in other directories writes their names into the same pattern. The shorter `'^(/|\.\./)'` keeps out only
what lies outside the project: it let `vendor/kit/InvariantBase.sol` in. **A handler counts as your code**, wherever in
`test/` it is: in a file of its own (`test/GateHandler.sol`, 75 % of branches) and also INSIDE a `*.t.sol` file - moved
into `test/Gate.invariants.t.sol`, that file got a row of its own (68.75 % of lines, 3/4 branches); forge leaves out
only the test contracts themselves. The sandbox in the step 0 layout never enters the default profile's coverage
(measured: identical before and after).

**A hook compiled next to the PoolManager's IR restriction: add `--ir-minimum`, or the numbers are not about what ran.**
The layout of QUICKSTART step 7b (and of this module): `compilation_restrictions` puts `PoolManager.sol` under the
`manager` profile, via IR at 44 444 444 runs. Every file that creates the PoolManager - `V4Harness`, so every test that
inherits it - is then compiled ONLY under that profile, and the hook they `new` is the hook's `.manager` build. Measured
(forge 1.8.1, 2026-09-24, on a copy of a stranger's real v4 hook, `ReferralSkimHook`): in `out/`, the tests, the handler
and `V4Harness` carry `viaIR: true`, the hook has two artefacts (`ReferralSkimHook.json`, 4 779 bytes, no IR;
`ReferralSkimHook.manager.json`, 4 698 bytes, IR), and the hook a test deploys is 4 698 bytes under `forge test` AND under
plain `forge coverage`. `forge coverage` turns the optimizer and IR off for the default build only ("optimizer settings
and `viaIR` have been disabled"), while the restricted build keeps both, and the report maps hits on optimized IR code
back to source lines. What it said: `src/` 59.18 % of lines, 4/5 branches, 6/14 functions; the lines of `claim` at 357,
357, **0**, 81, **0**, 73 - the line that zeroes the credit never run, next to the one after it run 81 times, while
`test_claim_pays_exactly_the_credit_and_zeroes_it` asserts that it did; `skimOf`'s return line 0 of 2 467 calls; 1 of the
9 entry points that `test_every_undeclared_entry_point_reverts` calls; the empty-`hookData` branch 0, which
`test_no_referrer_pays_nothing` takes. **Not a coverage of anything.** With `--ir-minimum` there is ONE build (83 files
compiled once, not 83 + 19; the deployed hook is 7 741 bytes, the build coverage reads), and every line that execution
ties together agrees: `claim` 366, 366, 77, 77, 77, 77 (366 calls, 289 refused as nothing owed), `skimOf` 2 652 on every
line, all 9 entry points hit, the empty-`hookData` branch 304 - `src/` 100 % of lines, 5/5 branches, 14/14 functions.
Removing the restriction under a profile of its own does not work (plain coverage stops at "Stack too deep" in the
PoolManager with the optimizer off). So, on this layout:

```sh
forge coverage --ir-minimum --report summary --no-match-coverage '^([^st]|s($|[^r])|sr($|[^c])|src($|[^/])|t($|[^e])|te($|[^s])|tes($|[^t])|test($|[^/]))'
```

forge warns that `--ir-minimum` "can result in inaccurate source mappings"; on this hook they were checked against
execution line by line as above and agreed. Check yours the same way before you cite a number: pick a function a named
test runs whole, and see that every line of it has the same count. A line at 0 inside a function whose test passes is a
mapping error, not a gap. This module itself needs `--ir-minimum` anyway: plain `forge coverage`, even with
`--match-path test/HostileHook.t.sol`, compiles the whole module and stops at "Stack too deep" (measured the same day;
with `--ir-minimum`, `src/HostileHook.sol` 86.67 % of lines, 5/5 branches, from that one test file).

Re-measured after the file grew (deltas, ETH settlement, the swap's `sender`; forge 1.8.1, 2026-09-24): the command
above on the WHOLE module, `src/HostileHook.sol` **90.76 % of lines (108/119), 12/13 branches, 32/32 functions**; from
`test/HostileHook.t.sol` alone 63.87 % (76/119), 4/13. The sanity check does not pass on this file, and says why: every
one of the 11 lines at 0 in the whole-module run is a call to a private function (`_enter();` in ten entry points,
`_reenter();` once) inside a function that ran - `_enter`'s own body has 34 hits in the single-file run - so by
execution every line ran, and the 90.76 % is the mapping's number, not a gap. And the command is itself a gate on the
test code: with `--ir-minimum` the optimizer is minimal, and a test helper with too many locals stops the WHOLE build
at "stack too deep" (a K14 test did, until its locals became a struct; the module before it compiled). Run it once
after adding a test file.

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

**In a test, let the harness do it.** `V4Harness` owns the order and the mining; a test says which hook:

```solidity
function setUp() public {
    _setUpV4();   // the manager, the two currencies, the routers - in that order, which is not taste (below)
    hook = MyHook(_deployHook(type(MyHook).creationCode, abi.encode(manager), Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG));
    key = _initPool(IHooks(address(hook)), 3000, 60, SQRT_PRICE_1_1);
    _fundAndApprove(provider, 1_000_000e18);
    _addFullRangeLiquidity(key, provider, 100e18);
}
```

`_deployHook(creationCode, constructorArgs, flags)` runs `HookMiner.find` for THIS contract, CREATE2s the hook, and
checks it landed where it was mined: the same address, code and nonce afterwards as the hand-written pair
`HookMiner.find(address(this), ...)` + `new MyHook{salt: salt}(...)` (`test/HookFlags.t.sol` compares them), a
constructor's revert passed through as it is. It refuses to run before the routers exist (`HookBeforeRouters`): until
then `abi.encode(manager)` encodes address zero and the miner would mine for a hook bound to no manager, and a hook
created before the routers bumps this contract's nonce and moves them. The order inside `_setUpV4()` matters for the same
reason - everything is created by the test contract at an address its nonce picks, and the currencies' addresses decide
which one is `token0`. A test ABOUT the mining (the salt, the predicted address, a wrong address on purpose) keeps
`HookMiner.find` and `new` by hand, as `test/HookFlags.t.sol` does. What it costs a test that deploys a hook inside the
test function rather than in `setUp`: measured on this module (forge 1.8.1, 2026-09-25), the seven tests that deploy a
hook in their own body went up by 5 550 to 67 112 gas each against the hand-written pair (the initcode is built once more
in memory, and memory costs more the more a test already holds); a test that deploys nothing moved by -12 to +88 (its
contract's own bytecode changed). `setUp` is not in a test's gas.

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
`(1 − 2⁻¹⁴)²⁰⁰⁰⁰⁰ = e⁻¹²·²`, about **5 in a million**. Measured on the example hook's 5 360-byte initcode (the build the TESTS hash: they import the manager, so they get
the `CappedDynamicFeeHook.manager` row of `forge build --sizes`; the default-profile row of the same table says 5 636),
2026-09-23, with a `gasleft()` window around `HookMiner.find` in a test: 2 660 tries cost 1 101 991 gas, ≈414 gas a
try, so an average search is ≈7 M gas — under a second. (The figure this line gave before, 1 239 tries for 1 752 012
gas on the first rule's 5 322-byte initcode, ≈1 414 a try, was taken by a method nobody wrote down; the two are not
comparable, and the new one says how it was taken.)
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

## Hooks that return deltas

Until 2026-09-24 this module's example declared no delta permission and the harness had never met a hook that moves
value through the manager's books. Now it has: `HostileHook` returns any `BeforeSwapDelta` and after-swap delta a test
sets (`setDeltas(specified, unspecified, afterUnspecified)`), settles it or not (`setSquareOwnDelta`), and
`test/DeltaAccounting.t.sol` reads every party's books around one swap, each from its own source
(`V4Harness._swapWithBooks`): the delta the manager returned to the router, the POOL's delta off the `Swap` event
(`SwapEventReader.lastSwapDelta`), and the true balances of swapper, hook and manager.

**Which router, and why no new one.** `MinimalRouter` needed no change for delta hooks (it was changed later, for ETH
and for `msg.value` counted - "Native currency" below) and settles them correctly in all four orientations, because it
settles the delta the manager RETURNS, and the manager has already moved that by the hook's delta. The hook's own delta is the hook's to settle, inside its own callback: nobody else can clear a positive hook
delta (`take`, `mint` and `clear` all act on `msg.sender`), so "the router settles the hook's delta" is not something a
router can do, and a harness that tried would be hiding the hook's bug. What the kit needed was the measurement, not a
router. (The sandbox also meters `MinimalRouter`, through `ExampleScenario`; a router with more work in it would have
moved every gas figure in the sandbox section.)

Measured (forge 1.8.1, source manager, 2026-09-24): full range, 100e18 of liquidity at 1:1, LP fee 0.30 %, a swap of
1e18, and a hook that PAYS 2e14 on the specified side before the swap and TAKES 1e14 + 3e14 on the unspecified side
(signed from each party's side; negative = paid):

| orientation | swapper c0 / c1 | pool delta (event) c0 / c1 | hook c0 / c1 | manager c0 / c1 |
| --- | --- | --- | --- | --- |
| exact-in, zeroForOne | -1e18 / +986 953 516 656 027 196 | -1.0002e18 / +987 353 516 656 027 196 | -2e14 / +4e14 | +1.0002e18 / -987 353 516 656 027 196 |
| exact-in, oneForZero | +986 953 516 656 027 196 / -1e18 | +987 353 516 656 027 196 / -1.0002e18 | +4e14 / -2e14 | -987 353 516 656 027 196 / +1.0002e18 |
| exact-out, zeroForOne | -1 013 335 756 974 054 076 / +1e18 | -1 012 935 756 974 054 076 / +0.9998e18 | +4e14 / -2e14 | +1 012 935 756 974 054 076 / -0.9998e18 |
| exact-out, oneForZero | +1e18 / -1 013 335 756 974 054 076 | +0.9998e18 / -1 012 935 756 974 054 076 | -2e14 / +4e14 | -0.9998e18 / +1 012 935 756 974 054 076 |

Read it as the manager's rule, `caller = pool - hook` per currency, and as conservation, `swapper + hook + manager = 0`
per currency: both asserted to the wei in every row. The specified half of the hook's delta moved the POOL (it swapped
1.0002e18 in, or delivered 0.9998e18 out) and never the swapper (exactly `amountSpecified` on its specified side); the
unspecified half is the sum of what `beforeSwap` and `afterSwap` returned, in the other currency. The `Swap` event is
the pool's delta, emitted before `afterSwap`: for a delta hook it is NOT what the swapper paid.

**Red first.** A router that pays the pool's delta instead - the amounts a hookless quote, or a simulation of "the
pool", gives (`PoolQuoteRouter`, in the test file) - is refused in all four orientations; the same router with the
hook's deltas at zero passes. With the expectation of the refusal removed, the four tests read:

```
[FAIL: CurrencyNotSettled()] test_red_a_router_that_pays_the_pools_delta_is_refused_exact_in_one_for_zero() (gas: 732890)
[FAIL: CurrencyNotSettled()] test_red_a_router_that_pays_the_pools_delta_is_refused_exact_in_zero_for_one() (gas: 744177)
[FAIL: CurrencyNotSettled()] test_red_a_router_that_pays_the_pools_delta_is_refused_exact_out_one_for_zero() (gas: 827093)
[FAIL: CurrencyNotSettled()] test_red_a_router_that_pays_the_pools_delta_is_refused_exact_out_zero_for_one() (gas: 833940)
```

Two more facts the tests pin: a hook that returns a delta and does not settle it kills the swap at the outer
`unlock` (`CurrencyNotSettled`) whatever the router pays; and a delta returned by a hook whose ADDRESS lacks the
`*_RETURNS_DELTA` flag is discarded, so a hook that took its fee as if it had the flag is left owing it and the swap
dies (`test_deltas_without_the_return_delta_flags_are_discarded_and_a_squaring_hook_is_left_owing`).

**What the harness of a delta hook needs** (the layout of QUICKSTART step 7b, and this module's):

1. **Mine for the returns-delta flags as well as the action flags**, and check them in the constructor: without the
   flag a returned delta vanishes silently (`doctrine/V4-ACCOUNTING.md` item 5).
2. **Settle inside the hook; test the swapper through the unchanged router.** `MinimalRouter` is correct; a test
   router that pays a quote is the counter-example, not the harness.
3. **Read the books from three sources on every swap** - the returned delta, the `Swap` event, true balances - and
   DERIVE the hook's delta as `pool - caller`. Never ask the hook what it took.
4. **Put the hook in the conservation holder list.** A delta hook holds value; an invariant over the actors and the
   manager only reports the hook's whole balance as tokens destroyed.
5. **All four orientations, a price far from 1, and a FUNDED hook** before any test that expects a payment from the
   hook: a fresh hook holds nothing, and a sign bug in a payment it never makes never runs.
6. **A price limit, and a router that pays first**, as actions: the partial fill and the payment in flight are where a
   delta hook's arithmetic meets the manager's (`V4-ACCOUNTING.md` items 13 and 14).
7. **Classify the hook's own guards in the handler.** A guard can hide a bug: with the example's partial-fill refusal
   filed as "expected", a sign-flipped rebate tripped it on every swap and the whole campaign stayed green (below).
8. **Two swaps in ONE transaction, if the hook keeps anything in transient storage.** forge clears transient storage
   between the top-level calls of a test, so a unit test whose swaps are separate calls never sees what one swap leaves
   for the next; a helper contract that swaps twice in one call does (`TwoSwaps` in `test/examples/DeltaFeeHook.t.sol`,
   below). A handler that makes several swaps in one call - the example's smoke test - sees it too, by chance.
9. **A second pool on the same hook, sharing a currency - and one created by a stranger.** A hook serves every pool
   that names it; nobody asks it first. Give the harness two pools with one currency in common (ERC-20, and ETH if the
   hook takes ETH) and a third made by an attacker with a token of its own, and book every swap to (pool, currency) from
   the manager's side. Then hold the hook's state to invariants PER POOL as well as per currency: a conservation per
   currency passed while one pool paid out of another's fees ("Two pools, one currency", below).
10. **A currency with transfer hooks, pointed at the manager.** If the hook pays the manager (sync + transfer + settle),
   point `TokenCallbackActor` at that transfer: the hook must refuse, or at least not lose, when the checkpoint moves
   under it ("Re-entrancy through a currency's transfer hook", below).
11. **The edges, once per example:** spacing 1 and the maximum, a price near each end, fees of 0 and 100 %, and amounts
   of 1 wei and the largest the pool holds - and the hook's own narrow casts at a reserve above 2^96 ("At the edges").

## Re-entrancy through a hook that HOLDS A DELTA

`HostileHook` re-enters from inside `afterSwap` AFTER it has taken its fee (`setReenterWhileHolding`), so at the moment
it calls out the manager's books show it owing that fee back (`heldAtReentry1 == -1e15`, read through `exttload`), and
before it returns the delta that cancels it. `test/HostileDeltaHook.t.sol`, source manager:

| the door, while holding | what the manager does | `reentriesSucceeded` after the transaction |
| --- | --- | --- |
| `unlock` | **refused**, `AlreadyUnlocked`; the swap stands and the hook keeps exactly its fee | 0 |
| `take` 1e16 of currency0 | **allowed**: a flash loan out of the manager's reserves, mid-swap. It stands only if the hook reads its own open delta afterwards and repays (`setCheckOwnDelta`); otherwise the manager refuses the WHOLE swap, the swapper's included | 1, with the check |
| `swap` 1e17 on its own pool | **allowed, and the hook is not called** (`calls` stays 2: the manager skips a hook's callbacks when the hook is the caller). The hook traded on the pool it guards, inside the swapper's transaction, with none of its own fees or checks; it stands only with the same check | 1, with the check |

**Red first, on a hook that forgets to check** (the same two tests with `setCheckOwnDelta(true)` removed):

```
[FAIL: CurrencyNotSettled()] test_swap_on_its_own_pool_while_holding_is_allowed_and_skips_the_hook() (gas: 881518)
[FAIL: CurrencyNotSettled()] test_take_while_holding_is_a_flash_loan_that_stands_only_if_the_hook_checks_its_own_delta() (gas: 713113)
```

The lesson for a hook that calls out while its delta is open: its own arithmetic ("I hold exactly my fee") is not its
books. Read `TransientStateLibrary.currencyDelta(manager, address(this), currency)` after anything that can move them,
and square what it says. And `reentriesSucceeded` counts only re-entries in a transaction that STOOD: every "allowed"
above is one the hook also squared, because an allowed re-entry followed by a dead transaction leaves the counter at 0.

**`settle()` while a router's payment is in flight** (added 2026-09-24, K13b, from the verifier V13). A router that
pays FIRST (`PrepayRouter`: `sync`, transfer 1e18 of currency0, swap, `settle`) has its transfer synced and unpaid
while the hook runs. The hook's bare `settle()` from `afterSwap` is allowed and credits that transfer to the HOOK
(read inside the router's callback by a probe outside the repo: hook +1e18, router still -1e18 after its own `settle`
credited 0). What happens next depends on the ROUTER:

| the router | hook without the own-delta check | hook with it (it takes the credit it was handed) |
| --- | --- | --- |
| settles once (`PrepayRouter`) | **refused**, `CurrencyNotSettled`: a denial of service | **refused** the same way: the router still owes |
| then pays whatever its books still show owing (`TopUpPrepayRouter`, in the test file) | **refused**: the hook's credit is left open | **stands**: the swapper pays 2e18 for a 1e18 swap and the hook keeps 1e18 - a theft |

Controls in the same tests: the prepaid swap with the hook not re-entering stands, and the same `settle()` against
`MinimalRouter` (nothing in flight) credits 0 and the swap stands. Red first, each test with its precondition removed
(the re-entry not armed; the check not set):

```
[FAIL: next call did not revert as expected] test_settle_while_a_router_payment_is_in_flight_kills_the_transaction() (gas: 1570454)
[FAIL: CurrencyNotSettled()] test_settle_while_a_topping_up_router_payment_is_in_flight_takes_the_first_payment() (gas: 2059229)
```

`V4-ACCOUNTING.md` item 16. In the theft row the unlock CLOSED - the manager's own check was satisfied - so only a
per-party book (the swapper paid twice its `amountSpecified`) shows it.

## Native currency

Until 2026-09-24 `MinimalRouter` and `LiquidityHelper` refused a pool whose `currency0` is the zero address. They accept
it now, with the rules in their headers: the swapper (or provider) sends ETH with the call, the fixture pays the manager
exactly what the RETURNED delta says (`settle{value: owed}`, no `sync`, as v4-core's `CurrencySettler` does), refuses
too little by name (`InsufficientValue(owed, value)`, before anything is paid) and refunds the rest AFTER the unlock
(`RefundFailed(to, reason)` if it cannot). ETH owed to the caller is sent by the manager's own `take`, inside the unlock.
`V4Harness` counts ETH wherever it counts a token: `_trueBalance(currency, who)` is `who.balance` for the zero address,
`_swapWithBooks` sends the value (exact-in: `|amountSpecified|`; exact-out: the swapper's whole balance, the router
refunds the rest; an overload takes the value) and reads the swapper's ETH net of the refund, and `_initNativePool`,
`_fundNative` and `_addFullRangeLiquidity` (which sends the provider's balance on a native pool) do the rest.

Two rules added the same day, after the verifier V14 broke the first version. **The ETH a fixture pays and refunds is
the call's `msg.value`, counted** - never its own balance. ETH that reaches the router or the helper any other way (a
selfdestruct, a coinbase reward) is nobody's payment and stays there; the first version paid the next caller's input
with it and refunded the rest to that caller (V14: a swap sent with no value was refunded 9e17). Red against the old
accounting put back: `[FAIL: next call did not revert as expected] test_stray_eth_in_the_router_pays_for_nobodys_swap()`,
and the helper's twin, `test_stray_eth_in_the_helper_pays_for_nobodys_deposit`. **Positions are the caller's.** To the
manager every position is the helper's, and the helper pays whoever calls it, so the first version let anybody remove
anybody's position and keep what it paid out; the helper now hands the manager the salt `positionSalt(caller, salt)`, so
the same pool, range and salt from two callers are two positions and a caller can only ever touch its own
(`test_two_callers_with_the_same_salt_hold_two_positions`; a hook sees that derived salt in its liquidity callbacks).

Measured (forge 1.8.1, source manager, 2026-09-24; `test/NativeHarness.t.sol`): ETH / token at 1:1, 100e18 of
liquidity, a swap of 1e18. On a hookless pool the four orientations close to the wei - swapper, manager, router - with
the swapper's ETH equal to the returned delta whatever it sent (exact-out ETH in sent 1 000 ETH and paid
1 013 140 431 395 195 690 wei). With `HostileHook` returning the deltas of the table in "Hooks that return deltas" and
settling them in ETH (`settle{value}` for what it owes, `take` into its `receive()` for what it is owed), the four rows
are that table's rows to the wei, with ETH as currency0: e.g. exact-out, ETH in: swapper -1 013 335 756 974 054 076 ETH
/ +1e18, pool -1 012 935 756 974 054 076 / +0.9998e18, hook +4e14 ETH / -2e14. The router ends every test holding no
ETH; ETH sent to a swap with no ETH input (or to an all-ERC-20 pool) comes back whole; a liquidity round trip returns
the provider's ETH to within 2 wei.

**Red first.** The same file against the router with its old refusal put back:

```
[FAIL: NativeCurrencyNotSupported()] test_native_plain_exact_in_eth_in() (gas: 89123)
[FAIL: NativeCurrencyNotSupported()] test_native_hook_deltas_exact_out_eth_in() (gas: 92244)
[FAIL: NativeCurrencyNotSupported()] test_excess_eth_on_an_exact_in_swap_is_refunded() (gas: 88642)
```

(11 of 14 red; the helper's refusal put back fails the `setUp`). Without the refund, 5 red
(`the swapper paid other than its input: the excess was kept: -3000000000000000000 != -1000000000000000000`); without the
value check, the named refusal becomes `call reverted as expected, but without data` (the EVM's out-of-funds).

### A hostile native counterparty

ETH is the one currency whose every delivery runs the recipient's code. `src/HostileNativeActor.sol` is a swapper or
provider that is a contract and whose `receive()` accepts, reverts, re-enters (any call, or a swap in its own name with
its own delta squared), or burns every unit of gas it is given; it records whether the manager was unlocked at each
receipt. `test/NativeCounterparty.t.sol`, a native pool with `HostileHook` as an observer (`swapsSeen`,
`lastSwapSender`):

| `receive()` | ETH OUT: the manager's `take`, inside the unlock | a REFUND: the router, after the unlock |
| --- | --- | --- |
| reverts | swap refused: `WrappedError(actor, 0x00000000, Refused(), NativeTransferFailed())` from the manager's transfer; nothing moved, the hook's record of the swap rolled back | `RefundFailed(actor, Refused())`, the whole swap rolled back. With EXACTLY the input sent there is no refund, and the swap stands |
| `unlock` | refused, `AlreadyUnlocked`; the actor swallows it, the swap stands | - (manager locked: its own `unlock` is the way in, row 4) |
| `take` 1 ETH | **allowed**, and the transaction dies at the outer unlock (`CurrencyNotSettled`) | refused, `ManagerLocked` |
| a swap in its own name, delta squared | **stands**: the hook sees a second swap, from the actor, after the first swap's `afterSwap` and before the router has finished settling | **stands**, through a lock of its own: the hook sees two swaps in one transaction |
| `settle{value}` 1e17, then `mint` of the ETH claim to itself | **stands**: its ETH turned into a claim in the middle of somebody else's swap - the manager's ETH and the claims it issued both up 1e17. Either half alone leaves its own delta open: `CurrencyNotSettled` | refused, `ManagerLocked` (the verifier V14's run; not in this suite) |
| burns all gas | 4 664 718 of 5 000 000 gas gone, `WrappedError` with an empty reason | 4 884 379 of 5 000 000, `RefundFailed(actor, "")` |

(The gas row read 4 664 701 and 4 884 372 before the fixtures began counting `msg.value`, above.)

As a PROVIDER, a contract that cannot receive ETH can add liquidity only by sending exactly what is charged (one wei
more and the refund fails), and can never remove it: `NativeTransferFailed` on every attempt, the position untouched,
removable again the moment its `receive()` accepts - and nobody else can remove it in the meantime. That half was
FALSE until 2026-09-24: the helper owned every position and paid whoever called, and the verifier V14 had a stranger with
no approvals name the provider's pool, range and salt, remove the position and keep its ETH and token. With positions
kept per caller the stranger reaches its own, empty position and the manager refuses (`SafeCastOverflow()`); against
the old helper the same test is red (`[FAIL: next call did not revert as expected]
test_reverting_provider_can_add_exactly_and_can_never_remove()`). Stuck, not lost - for a position manager that lets
only the owner touch a position. What that means for a hook: on a native pool the recipient of every
ETH payment runs code in the middle of somebody else's settlement, and a hook that assumes one swap per unlock, or a
`sender` it knows, is wrong there (`doctrine/V4-ACCOUNTING.md` items 17-20).

**Red first**, each test against a mutant of what it measures: the router refunding INSIDE the unlock - invisible to
`NativeHarness.t.sol`, all 14 green - is caught here twice
(`the refund was delivered while the manager was unlocked`, and the `take` during the refund then allowed:
`CurrencyNotSettled()`); no refund, 5 red; a zero refund still sent (`if (left == 0) return;` removed), 4 red, among them the contract that cannot receive swapping ETH in with exactly its input
(`RefundFailed(actor, 0x8ac5ff0b)` - `Refused()` - for a refund of zero);
and the double itself disarmed - `receive()` that does not revert (3 red, `next call did not revert as expected`), does
not burn gas (2 red), does not re-enter (5 red). Re-run on the files as they are after the `msg.value` accounting (each
mutant on a bench re-synced from the tree): refund inside the unlock, `NativeHarness.t.sol` 16 green and here 2 red, the
same two; no refund, 6 red there and 5 here; a zero refund still sent, 5 red here; the old balance accounting put back
in the router or in the helper, the stray-ETH test red; positions no longer kept per caller, 2 red
(`the second caller's position, as the manager books it: 0 != 1000000000000000000`); the double's `mint` never made,
both settle-and-mint tests red (`[FAIL: CurrencyNotSettled()]
test_reentry_by_settle_and_mint_during_take_stands_and_turns_eth_into_a_claim()`).

### The delta example on an ETH / USD-like pool

`DeltaFeeHook` refused native pools at initialisation until 2026-09-24 (its P8). It accepts them now (P10 in its header):
the fee in ETH arrives through the manager's `take` into a `receive()` that accepts ETH from the manager only, a rebate
in ETH is paid with `settle{value}` and no `sync`, P7 still applies, and both ledgers read the hook's ETH balance around
each move. It no longer declares `beforeInitialize` (the refusal was all it did), so its address carries four flags.
`test/examples/DeltaFeeHook.native.t.sol`: ETH (18 decimals) against a 6-decimal token at 3 000 per ETH - a raw price of
3e-9, so a fee or a rebate on the wrong side is off by about 3e8, not by rounding - reserves filled, a new block, then
one swap of 0.1 ETH or 300 of the token:

| orientation | ETH is | hook delta specified / unspecified | swapper ETH / USDL | hook ETH / USDL |
| --- | --- | --- | --- | --- |
| exact-in, zeroForOne | specified (in) | -1e14 wei / +898 150 | -1e17 / +298 485 217 | **-1e14** / +898 150 |
| exact-out, oneForZero | specified (out) | -1e14 wei / +901 856 | +1e17 / -301 520 746 | **-1e14** / +901 856 |
| exact-in, oneForZero | unspecified (out) | -300 000 / +299 382 102 680 327 wei | +99 494 652 124 095 390 / -300e6 | **+299 382 102 680 327** / -300 000 |
| exact-out, zeroForOne | unspecified (in) | -300 000 / +300 617 619 549 609 wei | -100 506 490 802 752 695 / +300e6 | **+300 617 619 549 609** / -300 000 |

Every row asserted to the wei against the manager's books, ETH included (swapper + hook + manager = 0 per currency; the
hook's ETH balance equal to its ledger), and the per-block cap in ETH spent to the wei. Mutants (each on a fresh bench):
`receive()` removed - all 5 native tests of the time red (`WrappedError(hook, afterSwap, ...)`: a hook that cannot take ETH kills
every swap that owes it ETH), while the two-ERC-20 campaign stays green; the ETH branch of the rebate removed - the 3
ETH-rebate tests red, everything else green; `receive()` open to anyone - red only in the unit test that sends it ETH
from a stranger. K13's nine mutants, re-run on the hook as it is now (same lines, same edits): all nine
still killed by the unit suite and by the campaign (one draw of 64 x 64 each, fresh corpus); the native file alone kills
six of them - not the rebate returned as meant (K13's M5), the P9 check removed (M6) or the P7 check removed (M7), which
need a short-delivering token, a price limit and a prepaying router, none of which it has.

**A limit, measured: P7 covers the rebate, not the fee** (`V4-ACCOUNTING.md` item 14, the fee side; found by the verifier
V14). A payer with a payment in flight syncs a currency, swaps, and settles after. P7 sees the synced slot and pays no
rebate - but the fee is still taken, and when the synced currency IS the pool's token and the fee is taken in it (ETH
in, exact-in: the fee is USDL), the hook's `take` moves the manager's USDL after the payer's checkpoint. With nothing
sent yet the payer's `settle()` underflows (`Panic(0x11)`, no name); with 1 USDL sent it is credited 1 USDL less the fee
and dies `CurrencyNotSettled`. A denial of service of that payer, not a theft
(`test_a_payment_in_flight_in_the_fee_currency_dies_on_the_fee_take`; its control, an ERC-20 that is not in the pool
synced, stands with the rebate skipped - item 19's ETH case, run). Skipping the `take` alone would leave the hook's own
delta open; keeping the fee as a claim while its currency is synced would move no balance, but changes the example's
ledger, and it is not tried here.

**The shared ETH reserve** (K14 stated it; K15 measured and removed it). The hook's reserve and its per-block cap were per
CURRENCY and hook-wide, and with ETH, which is on one side of almost every pool a hook is attached to, that was the
common case: fees taken in ETH by one pool paid ETH rebates in another. Both are per pool now (P13, "Two pools, one
currency" below): `test_the_eth_reserve_of_one_pool_pays_no_eth_rebate_on_another` has an ETH / token1 pool next to
this one, and a swap on it with ETH specified is paid nothing out of this pool's ETH (red with the rebate funded
hook-wide: `pool B was paid an ETH rebate out of pool A's ETH fees: -100000000000000 != 0`), and later its own. The
native file has 7 tests now, all green.

## ERC-6909 claims

The manager's claims are a second way to hold value: `mint(to, id, amount)` debits the caller's delta and gives `to` a
claim on tokens the manager keeps; `burn` is the reverse. `src/examples/ClaimsFeeHook.sol` is the worked toy: a fee of
0.30 % of the pool's unspecified amount, returned from `afterSwap` and squared by `mint(address(this), ...)` - kept as a
claim, never taken - and a treasury that withdraws (`burn`, then `take` of the currency) inside the hook's own unlock.
Its promises C1-C5 are in its header. `_swapWithBooks` reads the hook's claims (`hookClaims0/1`) next to its balances.

Measured on an ETH / token pool at 1:1, a swap of 1e18 (`test/examples/ClaimsFeeHook.t.sol`):

| orientation | swapper ETH / token | hook BALANCES | hook CLAIMS ETH / token | manager ETH / token |
| --- | --- | --- | --- | --- |
| exact-in, ETH in | -1e18 / +984 196 560 293 870 115 | 0 / 0 | 0 / **+2 961 474 103 191 183** | +1e18 / -984 196 560 293 870 115 |
| exact-in, ETH out | +984 196 560 293 870 115 / -1e18 | 0 / 0 | **+2 961 474 103 191 183** / 0 | -984 196 560 293 870 115 / +1e18 |
| exact-out, ETH in | -1 016 179 852 689 381 277 / +1e18 | 0 / 0 | **+3 039 421 294 185 587** / 0 | +1 016 179 852 689 381 277 / -1e18 |
| exact-out, ETH out | +1e18 / -1 016 179 852 689 381 277 | 0 / 0 | 0 / **+3 039 421 294 185 587** | -1e18 / +1 016 179 852 689 381 277 |

Read the rows twice. By BALANCES, swapper + hook + manager = 0 in every row, and the hook got nothing: its fee is in no
`balanceOf`. By PARTY, claims counted, the hook got exactly its booked delta (`pool - caller`) as a claim and the
manager's NET - its balance minus the claims it issued - moved by exactly the pool's delta. Both are asserted.

**The README's old sentence, made a test.** "An invariant that counts only ERC-20 balances will report a leak as
conservation." `test/examples/ClaimsFeeHook.invariants.t.sol` runs the campaign on the ETH / token pool (every party's
ETH, token and claims per swap; a treasury withdrawing ETH and token; a swapper whose `receive()` reverts; ETH pushed
at the manager; a fee-on-transfer switch; since 2026-09-24 a third party with claims of its own) with eleven invariants
(nine until the section below), three of them deliberately NAIVE: ETH conserved over
the holders, the token conserved, and every swap's books closed over balances alone. The mutant that leaks into 6909 -
the fee claim minted to the swap's `sender` (the router) instead of the hook, one line - on a fresh corpus, one draw of
64 x 64:

| invariant | fee claim to the router (C1) | to an unlisted address (C2) |
| --- | --- | --- |
| ETH conserved over every holder | **passed** | **passed** |
| token conserved over every holder | **passed** | **passed** |
| every swap closes in balances alone | **passed** | **passed** |
| the manager's net (balance - claims issued) is the pool's delta | **passed** | failed |
| every party counted with its claims (C1, C3) | failed | failed |
| the hook's claims = fees booked - withdrawn; nobody else holds one | failed | failed |
| the router and the helper hold nothing - claims included | failed (`the router holds claims: 25 != 0`) | passed |

(That table is the nine-invariant suite's draw, before C3 was scoped below; the scoped suite still kills C1, below.)

Four invariants that a reader would call "conservation" pass with the fee in the wrong hands; the claim summed over
everybody cancels against the manager's debt for it. What kills the leak is the books PER PARTY against the manager's
own numbers, and a holder list that names every contract that can receive a claim. The unit suite kills both mutants too
(the four orientation tests: `the hook's token1 claims are not its booked delta: 0 != 2961474103191183`). Two more
mutants: a withdrawal paid in claims (`mint` to the treasury instead of `take`) is killed by the unit suite and the
campaign (`C4: a withdrawal paid other than it burned, or paid in claims`); the fee taken as the token instead of
minted is killed by both (`C2: the hook's balance moved in a swap`). Census of the campaign (`scripts/census.sh foundry-kit/v4`, ONE draw, 2026-09-24, re-run by K15 on the suite as K14b left
it, 65 runs, fresh corpus): no unexplained revert; a fee claimed in ETH in 61 runs and in the token in 65; a withdrawal
of ETH in 59 and of the token in 61; an exact-out swap with ETH in, refunded, in 55; the swapper that cannot receive
refused ETH out in 61 runs and swapping ETH in with its exact input in 65; a third party holding ETH claims in 53 and
token claims in 62. (K14's draw, which this line gave before: 62, 65, 45, 60, 61, 61, 62.)

**Operators, allowances, and other people's claims** (2026-09-24, after the verifier V14). An operator moves every claim
the hook holds with `transferFrom`, outside any swap, and nothing in the campaign calls `transferFrom`: V14's mutant W4 -
`setOperator(0xBAD, true)` in the constructor - passed the unit suite and all nine invariants. Now the unit test
`test_the_hook_grants_nobody_an_operator_or_an_allowance` counts every `OperatorSet` and `Approval` event the manager
emits with the hook as owner (its constructor, a swap in each orientation, a withdrawal of each currency) and asks the
manager about every party; the campaign counts the same events (constructor, every swap and withdrawal) and asks about
every holder (`invariant_the_hook_grants_nobody_its_claims`); and `invariant_the_hooks_claims_move_only_in_its_swaps_and_withdrawals`
holds the hook's claims between actions to what its last swap or withdrawal left. W4, and the same with a listed spender
(`approve(treasury, ETH, 1)` in the constructor), are red in the unit test (`the hook granted an operator or an allowance
on its claims: 1 != 0`) and, in the campaign, in ONE invariant of eleven - `the_hook_grants_nobody_its_claims` (`C3: the
hook's constructor granted an operator or an allowance: 1 != 0`; re-measured by the verifier V15 and again by K15b). A
grant nobody uses moves nothing, so no other invariant has anything to see. What fails TWO invariants is the grant
USED: 1 wei of the hook's ETH claim moved by an operator outside a swap, where it failed one
(`test_a_claim_moved_by_an_operator_outside_a_swap_is_caught_twice`).

**The unit test was blind inside a swap** (the verifier V15, 2026-09-24). `V4Harness._swapWithBooks` reads the `Swap`
event with `vm.recordLogs()` / `vm.getRecordedLogs()`, and those CONSUME the recorder: a test that records logs around
`_swapWithBooks` loses what it recorded before the swap and every event of the swap itself. V15's mutant VC1 -
`approve(0xBEEF, id, 1)` after every fee mint, a grant made inside `afterSwap` - passed the unit suite 11 of 11 (the
campaign's invariant caught it). Now the harness keeps a swap's logs when asked (`_keepSwapLogs`, `_takeKeptSwapLogs()`),
the test reads them there, and it counts the four `Swap` events so it cannot go blind that way unnoticed. Red on the
fixed test: VC1 `the hook granted an operator or an allowance on its claims: 4 != 0`; the same grant as an operator
(VC1b) the same; the harness not keeping the logs (H0) `test setup: the swaps' own events were not read: 0 != 4`; W4 and
V15's VC2 (the treasury made operator inside a withdrawal) still red. A test of your own that records logs around
`_swapWithBooks` has the same blindness: keep the logs, or record around the router's call yourself.

The other half: the campaign's world was CLOSED -
"nobody but the hook holds a claim" - so a third party depositing ETH as a claim of its own and passing it to an actor
tripped C3 (V14). C3 is now about the hook's claims: the campaign has such a third party (`thirdPartyClaims`, ETH and
the token, half sent to an actor), and no invariant calls it a leak (`test_a_third_party_moving_its_own_claims_trips_nothing`,
red on the closed world: `an invariant called it a leak: 1 != 0`, `C3: somebody other than the hook holds claims`). That
is a third party using its OWN claims. A claim a third party PUSHES INTO the hook (`transfer` to it, outside any swap)
trips two invariants, by design - the hook's claims are then no longer its fees less its withdrawals, and they moved
outside its own actions (`test_a_third_partys_claim_pushed_into_the_hook_trips_two_invariants`; the verifier V15 measured
the same, 2 of 11). A third party that makes the hook its operator, or gives it an allowance, trips none. A
claim that reaches anybody else FROM A SWAP is still caught per swap and per party: the scoped suite, one draw of 64 x 64
on a fresh corpus each, kills C1 in three invariants (per party, fees less withdrawals, the router holding claims) and
V14's W3 - 1 wei of every fee claim passed on to the treasury inside `afterSwap` - in two (per party, fees less
withdrawals); ETH and token conservation, the balance-only books and the manager's net pass both, as before.

**What the harness of a native pool, or a claims hook, needs** (on top of the eleven points for a delta hook above):

1. **Count ETH where you count tokens**: `_trueBalance` for every party, the swapper's ETH net of the refund, the router
   and the helper in the holder list and asserted empty of ETH after every action.
2. **Send value the way a user does**: exactly the input on exact-in, more than enough on exact-out (and read the
   refund), too little once (the named refusal).
3. **A contract counterparty in every mode** - accept, revert, re-enter, burn gas - as swapper AND as provider, at both
   receipts: inside the unlock (ETH out) and after it (a refund). `HostileNativeActor` does all of it.
4. **A hook that takes ETH has a `receive()`**, accepts from the manager only, and has a mutant that removes it.
5. **Price far from 1 with unequal decimals** (ETH against a 6-decimal token): side confusion is then eight orders of
   magnitude, not a factor of four.
6. **Claims per party, never summed**: each party's balance + claims against what the manager booked for it, the
   manager's net as balance minus claims issued, and every contract that can receive a claim (router, helper,
   treasury) in the holder list with "holds no claim" asserted. A conservation over balances, or over everybody's
   claims, passes when a claim goes to the wrong party (table above).
7. **Withdraw both currencies, and to a recipient that cannot receive ETH** - the claim must survive the refusal.
8. **Grants, and claims that are not the hook's.** Assert the hook grants no operator and no allowance (count the
   manager's `OperatorSet` / `Approval` events with the hook as owner - an operator can be anybody, so a holder list is
   not enough), hold the hook's claims between actions to what its own last action left, and let a third party hold
   and move claims of its own: a closed world ("nobody but the hook holds a claim") calls a legitimate user a leak.
9. **Count the fixture's own ETH, not its balance.** A router or helper that pays out of `address(this).balance` spends
   ETH that is nobody's payment; one that owns every position and pays its caller lets anybody remove anybody's.

## Re-entrancy through a currency's transfer hook, during settlement

A payment to the manager is three calls: `sync(c)` (the manager writes down its balance of `c`), a transfer of `c`,
`settle()` (the manager credits the payer with its balance now less that checkpoint). The transfer runs the
currency's own code, and a currency with transfer hooks (`HostileERC20`'s send and receive callbacks: nothing had to be
added to the root kit) runs it INSIDE the payment, with the manager mid-accounting for it. `src/TokenCallbackActor.sol`
is that code pointed at the manager; `test/TokenReentry.t.sol` arms it on the next transfer that pays the manager, before
the balances move (the payer's send callback) or after (the manager's receive callback), and every door is the actor's,
in its own name, its failure swallowed - so what happens to the payer is the manager's doing.

**The door table** (source manager, forge 1.8.1, 2026-09-24; `MinimalRouter` paying the currency0 of a 1e18 exact-in swap
on a hookless pool, i.e. a payer that settles ONCE):

| the callback, in the middle of the payer's transfer | before the move | after the move |
| --- | --- | --- |
| `sync` of another currency | dies | dies |
| `sync` of the zero address (clears the slot) | dies | dies |
| `sync` of the SAME currency | **stands** (the checkpoint does not change) | dies (the checkpoint now includes the payment) |
| a bare `settle()` (takes the payer's credit, resets the slot) | dies | dies |
| `settle()` + `take` of what it was credited | dies | dies |
| `settle()` + `mint` of it as a claim | dies | dies |
| `take` of 1 wei, `mint` of 1 wei (a delta left open) | dies | dies |
| `take` of x paid with x of its OWN claims (`burn`: its books square; V15) | dies | dies |
| `unlock` | **stands** (`AlreadyUnlocked`, swallowed) | **stands** |
| a swap in its own name, squared (squaring takes a `sync` of its own) | dies | dies |
| `settleFor(the payer)` (V15) | dies (credits it 0, resets the slot) | **stands**, harmless: the payer is credited its own payment, its own `settle` then 0 |

Every death is the manager's `CurrencyNotSettled` at the outer unlock - the payer's books did not close - never a
refusal of the door itself: `sync`, `settle`, `take` and `mint` were all allowed. So against a payer that settles once,
a token's callback can DENY the payment by any of eight doors and take nothing. Hijacking `sync` is that, and nothing more,
against such a payer. (The two rows marked V15 are the verifier's, added 2026-09-24 with
`test_two_more_doors_a_take_paid_with_own_claims_and_settle_for_the_payer`: 1e17 taken and burned, both moments, dies
`CurrencyNotSettled` with the callback's claims back where they were; `settleFor(router)` after the move credits the
router 1e18, the swapper pays exactly its input and the router ends with nothing.) Three things change the answer:

* **A payer that tops up** (`TopUpPrepayRouter`: after its own `settle` it pays whatever its books still show owing):
  `settle` + `take` from the callback is a THEFT - the unlock closes, the swapper pays 2e18 for a 1e18 swap, the callback
  keeps 1e18 (`test_a_topping_up_payer_pays_twice_and_the_tokens_callback_keeps_one_payment`). K13b's finding about a
  hook's `settle()`, with the token as the thief.
* **A hook that pays its own delta** (`HostileHook`, a negative delta of 1e15 squared by sync + transfer + settle from
  `afterSwap`), with `settle` + `take` on the hook's transfer: the hook's own `settle` credits nothing. A hook that trusts
  its arithmetic leaves its delta open and the SWAPPER's transaction dies; a hook that reads its own delta afterwards
  (`setCheckOwnDelta`, `V4-ACCOUNTING.md` item 16's advice) pays again and the swap stands - the hook paid 2e15 for a
  1e15 delta and the callback kept 1e15. With a `sync` of another currency instead, the same check pays again and the
  first 1e15 sits in the manager as nobody's (`b.manager0 == -b.pool0 + 1e15`). Reading your own delta turns this denial
  of service into a loss: check the checkpoint BEFORE settling, as below.
* **What a hook that reads the synced slot believes.** `DeltaFeeHook`'s P7 reads `getSyncedCurrency` and takes "set" to
  mean "a payment is in flight". A callback that clears the slot during a prepaying router's transfer makes the hook
  believe nothing is in flight; the payer dies either way (`test_a_token_that_resyncs_during_a_prepayment_kills_the_payer`).
  And a callback on a DELIVERY - the manager's `take` to the swapper, not a payment - leaves its `sync` behind: the
  synced slot outlives the unlock inside the transaction (`test_a_callback_on_a_delivery_leaves_the_synced_slot_behind`),
  so a later swap in the same transaction finds a "payment" that nobody is making (P7 would then pay no rebate:
  reasoned, not run). Harmless to the next payer, measured: `MinimalRouter` syncs before it pays, and its swap stands.

**`DeltaFeeHook` pays its rebate the same way, and it was the victim** (P12 in its header). On the hook as it was, with
the callback on the hook's own rebate transfer (a 1e17 exact-in swap, the rebate cut to the block's budget,
89 828 095 180 378): `sync` of another currency, of the zero address or of the same currency after the move - the swap
STOOD, the hook's `settle` credited 0, the swapper got no rebate, the hook's reserve fell by the rebate (its ledger still
equal to its balance: it counts what left) and the rebate sat in the manager as nobody's; `settle` + `take` and `settle` +
`mint` - the swap STOOD and the callback KEPT the 89 828 095 180 378 (as token0, or as a claim); a bare `settle` and a
`take` died. Now the hook reads the synced currency and the checkpoint after its transfer and refuses the swap if either
moved (`SettlementHijacked`). Red first, the new test on the hook before the check:
`[FAIL: next call did not revert as expected] test_P12_a_currency_that_moves_the_checkpoint_mid_rebate_is_refused()`.
Mutants (each on a bench re-synced from the tree): the check removed (M12), and only the currency checked, not the
checkpoint (M12b) - both red on the same test; the callback
disarmed (A0) - all 7 tests of `TokenReentry.t.sol` red and both P12 tests
(`sync(another currency) (before the move): true != false`, `the swapper did not pay its input twice: 1000000000000000000
!= 2000000000000000000`). The control, a `sync` of the same currency BEFORE the move, stands with the rebate paid in full
(`test_P12_a_resync_of_the_same_currency_before_the_move_is_harmless`). The token can still refuse service - it can
revert its own transfer any time - it can no longer take the rebate. A swap NESTED in the rebate's transfer, on the
hook's own pool, is refused the same way (the nested swapper's own `sync`), the last case of the P12 test; that case
was not run alone against M12.

**P12 was not the whole payment** (the verifier V15, 2026-09-24). The slot and the checkpoint are what a `sync` moves;
the payment is what the manager CREDITS. A callback that `take`s x of the currency and pays for it with x of its own
claims (`burn`) squares its own books and leaves the slot and the checkpoint alone - and the hook's `settle` then reads a
balance x short. Measured on the hook with P12's first check only (V15's `test_v15_take_burn_leaves_the_rebate_nobodys`,
x = the rebate, after the move): the swap stood, the pool's reserve fell by the rebate (100 000 000 000 000), the
hook's booked delta was 0, `rebatesPaid` rose by 0, the swapper got nothing and the callback gained nothing (claims for
tokens, 1:1) - a loss with no beneficiary, still a loss (`doctrine/SEVERITY.md`). Now, after settling, the hook compares
what the manager credited it (`settle`'s return, exactly what the manager added to the hook's own delta) with what left
its balance, and refuses the swap if the credit is short (`RebateNotCredited(sent, credited)`). Red first, on the hook
before the check: `[FAIL: next call did not revert as expected]
test_P12_a_take_paid_with_the_callbacks_own_claims_mid_rebate_is_refused()` (both moments, x the whole rebate and half
of it); V15's own test, on the hook after it, now meets the refusal (`RebateNotCredited(100000000000000, 0)`). Mutants:
the check removed (P12b) and weakened to "credited nothing" (P12c) - red on both new tests; P12's FIRST check removed
(M12) - the P12 test red on the error (the second check refuses the same swaps under its own name, every door and the
nested swap: probed with the expected error loosened). The PRICE, stated in the header and in
`test_P12_price_a_rebate_in_a_currency_that_charges_on_transfer_is_refused`: the hook cannot tell a callback that took
part of its payment from a currency that charges a fee on the transfer, so a rebate in a fee-on-transfer currency is
refused whole - on the exact-out swap whose OUTPUT is that currency (a swap whose input is that currency already dies on
the router's own short payment), while the pool's budget in that currency lasts; before the check that swap stood with
the rebate less the token's fee. The cost in gas: +71 to +93 per unit test of seven swaps.

## Two pools, one currency

A hook serves every pool that names it, and nobody asks it first. `test/examples/DeltaFeeHook.multipool.t.sol` puts two
pools on one `DeltaFeeHook` - A = token0 / token1, B = token0 / token2 - and a third made by a stranger. Until K15 the
hook kept its reserve and its per-block cap per CURRENCY, hook-wide. Measured on that hook (red, then fixed):

| test | on the hook-wide reserve and cap |
| --- | --- |
| a swap on B (which has earned nothing) specifying token0, after A earned token0 | `pool B was paid a rebate out of pool A's fees: 100000000000000 != 0` |
| B's swaps spend B's block cap; then a swap on A in the same block | `pool B's swaps spent pool A's block cap: 0 != 100000000000000` |
| **a pool nobody approved**: a stranger creates token0 / EVIL (a token it mints), is its only provider, swaps token0 in twelve times in one block and withdraws | `a pool nobody approved drained the rebates pool A earned: 906067445652208 > 0` - the block's whole token0 cap (906 067 445 652 210, 10 % of what A had earned) less 2 wei of rounding, in one block; each block renews the cap (not run over several) |

The drain in words: the rebate is paid in token0 out of A's fees, the hook's fee on the swap is paid in EVIL, the swap's
input and the rebate both end in the stranger's pool, and the stranger, its only provider, takes them back out. That is
"what does the hook believe about a pool it has never seen": `DeltaFeeHook` has no `UnknownPool` check at all (it
declares no initialisation hook), and a "known pool" check would not have helped - the stranger's pool is initialised
through the manager like any other (reasoned; `CappedDynamicFeeHook` records every pool that way).

**Decided, with the measurement: per pool** (P13 in the header). The reserve and the cap are kept per (pool, currency);
`reserveOf`, `feesBooked` and `rebatesPaid` stay hook-wide (the ledger against the hook's balance, their sum);
`poolReserveOf(id, c)` is new; `rebateBudgetLeft` and `budgetOf` take the pool's id (an incompatible change of two views,
callers updated). All three tests green; a pool's rebates now come out of its own fees, and the stranger ends the block
with at most what it started with.

**The campaign** (`DeltaFeeHookMultiPoolInvariants`): three actors swapping on both pools, bursts to reach a pool's cap,
new blocks; every swap booked to (pool, currency) from the hook's TRUE balances (honest tokens), never from its ledger.
Invariants per pool - no pool pays rebates beyond the fees IT earned; no pool's rebates in a block exceed 10 % of what
IT had earned - and per currency - the hook holds exactly what its pools left it, and its hook-wide ledger agrees -
and, since the fix, the hook's own per-pool ledger against each pool's books. On the hook-wide reserve, one draw of
64 x 64: `invariant_per_pool_no_rebate_beyond_its_own_fees` and `invariant_per_pool_block_cap` red (`pool 1 paid
3477930474135999 of token0 in a block whose cap, from its own books, is 1044022763866543`), and **the per-currency
invariant passed**: the hook held exactly what its pools, summed, left it, while one pool paid out of another's fees.
Conservation per currency cannot see a pool mixing; only books per pool can. Mutants on the fixed hook: the rebate
funded from the hook-wide reserve (M13a) - the drain and the "paid out of another's reserve" unit tests red, both per-pool
invariants red, the ETH test red (`pool B was paid an ETH rebate out of pool A's ETH fees: -100000000000000 != 0`), the
single-pool unit suite GREEN (21 of 21: one pool cannot tell); the budget shared by every pool (M13b) - the cap test red,
`invariant_per_pool_block_cap` red, and two single-pool unit tests red. Census of the fixed hook's two-pool campaign (`scripts/census.sh foundry-kit/v4`, ONE draw, 2026-09-24, 65 runs, fresh
corpus): no unexplained revert; every action succeeded in every run; a rebate paid on pool A in 65 runs (3 745 times),
on pool B in 65 (2 130), cut by a pool's own cap in 65 (784).

**The other two examples.** `CappedDynamicFeeHook` keys everything by `PoolId` and refuses a pool its `afterInitialize`
never recorded: ten swaps on a second pool of the same pair congest THAT pool's next block to the cap and leave the
first at the base, quoted and charged (`test_congestion_on_one_pool_does_not_move_another_pools_fee`; red with the
state keyed by currency0 alone, mutant K1: `pool B's congestion moved pool A's quote: 5000 != 500`). `ClaimsFeeHook` pays
nothing back per pool, so nothing can be drained across pools, but the manager keeps claims per (owner, currency): the
ETH fees of two ETH pools on the hook are ONE claim, `feesBooked` is per currency, and only the hook's
`FeeClaimed(poolId, ...)` events say which pool a claim came from - they add up to it exactly
(`test_two_pools_fees_in_one_currency_are_one_claim_and_only_the_events_split_it`; a statement of the design, no red).

## At the edges

A deposit that a reader's handler made after driving an emptied pool to an end of the price range failed with
`SafeCastOverflow()`: at the edge the full-range liquidity's token amount does not fit the manager's `int128` casts. Classify it
as the manager refusing an impossible position, not as the hook's revert, and bound the handler's deposits away from the ends.

`test/examples/Edges.t.sol` runs each example through a fixed grid: five edges (spacing 1 with the price 100 ticks from
each end, spacing 1 AT `MIN_SQRT_PRICE` and at `MAX_SQRT_PRICE - 1`, spacing 32 767 at price 1), amounts of 1 wei, 1e6 and
1e18, the four orientations - 60 swaps per hook, each one either standing with its books closed per party to the wei
(swapper + hook + manager = 0 per currency, the hook's claims counted, the hook's delta exactly its rule) or refused for a
reason the test names:

| hook | stood, books closed | the manager's `PriceLimitAlreadyExceeded` (a price AT an end, a swap into it) | refused by the hook's fee `take` |
| --- | --- | --- | --- |
| `DeltaFeeHook` | 48 | 4 | **8** |
| `ClaimsFeeHook` | 56 | 4 | 0 |
| `CappedDynamicFeeHook` | 56 | 4 | 0 |

**The 8: a fee taken before its currency arrives** (a LIMIT of `DeltaFeeHook`, measured, not fixed). On an exact-out swap
the hook's fee is in the INPUT currency, which the swapper pays after the swap returns; `take` is a transfer out of what
the manager holds now. Near an end of the range an exact-out swap's input can exceed everything the manager holds of it,
and the swap dies in the hook's `take` (`WrappedError(hook, afterSwap, WrappedError(token, transfer,
InsufficientBalance(manager), ERC20TransferFailed()), HookCallFailed())`). It is not only an edge: a pool whose liquidity
is all on one side (a range above the price) on a manager that holds none of the other currency refuses its first
exact-out swap the same way, and the same swap stands once an exact-in swap has brought the currency in
(`test_the_fee_on_an_input_the_manager_does_not_hold_yet_kills_an_exact_out_swap`). `ClaimsFeeHook` mints its fee and never
meets it. The general rule is `V4-ACCOUNTING.md` item 24.

**Arithmetic that broke: the block cap above 2^96.** `DeltaFeeHook` stored the cap as `uint96(reserve * 10 %)`, a cast
that truncates silently. 100 ticks from the low end one unit of currency1 is worth about 1e32 of currency0, and one
exact-in swap of 1e6 units left the hook a fee of 5.5e34: the next block's cap read 17 430 635 726 297 566 524 129 938 969
where 10 % of the reserve is 5 506 216 269 052 069 231 642 641 590 390 297, and a rebate of 1e30 was cut to it. Red:
`[FAIL: the rebate was cut by a truncated cap: 17430635726297566524129938969 != 1000000000000000000000000000000]
test_the_block_cap_holds_above_2_to_the_96()`. The budget's fields are uint256 now; the mutant that puts the cast back
(MU96) is red on that test and green on the whole unit suite. An 18-decimal token with a trillion-token supply has 1e30
units: at ANY price its reserve passes 7.9e29, where the old cast began to truncate.

**Spacing, fees, the harness.** `_fullRange` computes the range from the spacing (it never assumed 60): at spacing 1 it is
`MIN_TICK..MAX_TICK`; at 32 767 it is +-884 709, 2 563 ticks short of each end, so a pool priced near an end is OUTSIDE
the widest position that spacing allows and a swap there fills nothing (measured: 0 / 0,
`test_the_harness_full_range_at_spacing_1_and_at_the_maximum`; a swap the other way moves the price into the position,
and swaps after it fill). An LP fee of 0 changes nothing for the fee-taking examples; at 100 %
(`MAX_LP_FEE`, the most a static pool may have) an exact-in swap is all LP fee - the pool delivers nothing and the hook's
fee on nothing is 0 - and an exact-out swap is refused by the manager (`InvalidFeeForExactOut`), for either hook
(`test_an_lp_fee_of_zero_and_of_one_hundred_percent`). A DYNAMIC fee at the manager's cap (a hook overriding with exactly
`MAX_LP_FEE`) behaves the same, and one more is `LPFeeTooLarge` (`test/HostileHook.t.sol`); `CappedDynamicFeeHook` at its
OWN cap on a spacing-32 767 pool charged exactly `MAX_FEE`, read off the manager's `Swap` event
(`test_a_dynamic_fee_at_the_cap`). None of these is red on the current code except the cap above 2^96: they are pinned,
and a change to what they measure has to be re-measured.

---

## The worked example

Three of them (the third, `ClaimsFeeHook`, is in "ERC-6909 claims" above). `CappedDynamicFeeHook`, below, returns no delta and holds nothing; `DeltaFeeHook`, at the end of this
section, returns deltas on both sides and holds what it takes.

`CappedDynamicFeeHook` raises the pool's LP fee with congestion, one block late — every swap of a block pays the
base fee plus one step for each swap the PREVIOUS block saw, hard cap, back to the base after a quiet block — and takes
no delta, holds no token, has no owner. It is small on purpose. Its value is the threat model written at the top of the
file **before** any test: six things it claims to survive, two it declares it does not defend, and one named defence
per line. Its spec is `src/examples/SPEC.md`.

### What a discovery round found on this hook

The rule used to be "the n-th swap of a block pays n steps". A fresh-context auditor (round r01, 2026-09-23, about five
minutes of its own time) read the spec, the hook and the two test files, and wrote nine tests. One of them passed while
asserting the harmful behaviour: **after a victim read `quoteNextFee` = 500, nine 1-wei swaps placed ahead of it in the
same block pushed its fee to 5 000** - 0.372 % less output on a 10-token swap into 100e18 of liquidity, for 1 349 046
gas of dust. The spec said "charged == quoted"; the invariant `invariant_every_quote_matched_the_execution` said so
too, and it was green, because it compared every swap with the quote read immediately before it - the one comparison
under which a within-block fee is always right. The campaign produced the harmful ordering all the time (`swapBurst` is
up to fourteen swaps in one block); nothing compared a swap with a quote read EARLIER in its block, so nobody asked.
Medium: a third party loses value in a case the spec claims to handle, bounded by the victim's own slippage limit.

The triage was **fix it at the cause**, not document it. The cause is that swaps inside a block move that block's fee.
So the fee of a block is now fixed by the block before it: whatever is placed ahead of a victim, the fee its block
charges was set before the block began. The order it was done in, each step seen:

1. the round's own test, reproduced unchanged: it passed (the bug is real) - `victim out ... 9086776671666893949` alone,
   `9049567985447930877` after the dust;
2. the same test with its last assertion turned the right way up (`test/examples/CappedDynamicFeeHook.r01.t.sol`):
   **red** on the old rule, `5000 != 500`;
3. **the growth rule** (`doctrine/FUZZ-ACTIONS.md`): the invariant that would have caught it -
   `invariant_the_fee_never_moves_inside_a_block`, every quote and every charge of a block equal to the block's first
   quote - **red** on the old rule (`the fee moved inside a block ... 1 != 0` in the campaign, `57 != 0` in the smoke
   test), over the actions that were already there; and the action with F1's exact shape, `dustAheadOfVictim` (a
   victim reads its quote, somebody else places 1-12 dust swaps, the victim swaps and is compared with the quote IT
   read), so the victim's own check is in the census as a boundary ("victim traded after dust in its block");
4. the hook changed (`_feeOfThisBlock`, `blockFee`); all three green, and the unit tests rewritten to the new rule;
5. the old behaviour put back into the new hook as a one-line mutant (`return s.blockFee;` ->
   `return feeForCongestion(s.swapsInBlock);`): KILLED by the round's test, by the campaign alone (`17 != 0`), and by
   the unit suite; forge's own mutation pass on the new hook: 98 of 104 killed, the six survivors the same six
   equivalents as before (`src/examples/MUTANTS.md`).

What it does NOT fix, and the tests say so: the congestion signal can still be inflated - for the NEXT block, in the
open (`test_r01_F1_residual_...`: nine dust swaps set the next block at the cap, and every swap of that block pays
the quote it could read before trading). And the fix has a price, measured by the sandbox on the ordering population
below: the fee now stays up after a busy block, so the honest victim pays more on FCFS too - same seeded world,
seeds 1-3, first rule vs this one: victim P&L per run `+1.16e15` -> `-1.23e15` under FCFS, `-4.65e16` -> `-5.08e16`
under BUNDLE; and the sandwicher, which earned `+8.9e15` a run on the first rule (its front-run paid the base and the
victim paid the steps), loses `-2.5e16` a run on this one, on every seed. A different hook, not a free improvement: the
spec says which trade was made (`SPEC.md`, section 6).

F2 (low), from the same round: the hook accepts native-currency pools and the spec left it undecided. Decided in
`SPEC.md`: accepted - the hook moves no value and reads no currency - and held to it by a real native swap each way
through v4-core's own test routers (`test_r01_F2_...`); a mutant that refuses native pools is KILLED by it.

Two things in its suite are worth stealing whatever your hook does.

**Compare what the hook SAID with what the pool DID.** The hook exposes `quoteNextFee(key)`. Every swap in
the campaign reads the quote first, swaps, and then reads the fee off the **manager's own `Swap` event**.
Asserting on the hook's stored `blockFee` would be asking the hook whether the hook was right. A suite
that only follows the money passes while the quote lies, and the quote is the part other people's software
trusts. (This holds because no protocol fee is ever set here, so the event's `fee` is the LP fee. Turn
protocol fees on and the assertion has to be rewritten, not deleted.)

**`swapBurst`, and why it exists.** With one swap per action, a 4 096-call campaign spread over fifteen
actions almost never produced ten swaps between two block rolls — so the fee never approached its cap, and
`invariant_the_pool_never_charged_more_than_the_cap` passed without ever being near the thing it guards. A
mutant that removed the cap entirely still went **green in the fuzz run**; only the hand-written smoke test
caught it. That is the vacuous pass from `doctrine/INVARIANTS.md`, caught in the act.

The fix was not a bigger campaign. It was an action that reaches the state: one call, many swaps, no block
change in between - and, since the rule became one block late, one block step after them, where they are charged.
Ask of your own hook: **which of my rules only bites after N things happen in a row, and does my handler have an
action that does N things in a row - and reaches the place where they are paid for?**

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
bursts long enough to actually reach the cap — the rule needs nine swaps in a block, and a uniform 2..14
burst is long enough about a third of the time. With both, the cap was reached in roughly **a third to a half of
the 65 runs** on the first rule, and in **about half to three quarters** on the one-block-late rule (the measured
draws are in `foundry-kit/README.md`, the one place they live); the no-cap mutant died by the campaign alone in 10
campaigns out of 10 for an independent verifier (on the first rule).

Say "in most runs", or give a range over several campaigns. Fixing `--fuzz-seed` does not pin the draw when a
corpus is on: a reviewer ran the same seed twice and got 19 and 17.

---

The fix is not free, and the spec says so (T2): with the same constants the pool's mean fee rises about 60-70 % for
everyone, because a busy block now raises the whole next block instead of resetting. A verifier measured it on the
sandbox's ordering population; the honest trader's loss in that table is that higher fee level, not a targeted one.

### The delta example: `DeltaFeeHook`

The second worked toy (2026-09-24) is the one a hook that holds tokens needs: it returns deltas on both sides, holds
what it takes as ERC-20, and pays some of it back out. A FEE of 0.30 % of the pool's unspecified amount, returned from
`afterSwap` as a positive delta and taken in the same call; a REBATE of 0.10 % of `|amountSpecified|`, paid out of what
it already holds in the specified currency, returned from `beforeSwap` as a negative specified delta and settled in the
same call; a CAP on rebates of 10 % of the reserve per currency and block. Its promises, P1-P11, are in the file header
(the SPEC, written before the tests; P9-P13 were added after, each says when); each has a named test or invariant. Measured,
source manager: unit suite 23 of 23 (15 at first; the test that it refused a native pool became a test that it refuses
ETH from anyone but the manager, 14; K13b added five: P11, the reserve under a fee-on-transfer currency, and three with
two swaps in one transaction; K15 two, P12; K15b two, P12's second half and its price), 7 of 7 on an ETH / USD-like pool (P10, "Native currency" above; 5 at
first), 3 of 3 multi-pool unit tests and a two-pool campaign (P13), campaign 64 x 64 green, smoke test green. The reach, from `scripts/census.sh foundry-kit/v4` (ONE draw, 2026-09-24,
after P12 and P13, 65 runs, a fresh corpus): the fee taken in 61 runs, a rebate paid in 35, a rebate cut by the block cap
in 30, on an exact-out swap in 24, a partial fill refused in 41, a prepaid swap with a rebate budget in 19, and no
unexplained revert (K13's draw read 62, 34, 31, 25, 49, 26; K13b's another). Half the runs
never see a rebate: a fresh hook has to earn a reserve before it can pay one, which is the point of the rebate reach
lines and a reason to set `REACH="rebate paid"` in a gate.

What its tests found in it before it was finished, in the order it happened:

1. **P9, the rebate for a swap that did not happen** (`V4-ACCOUNTING.md` item 13). A specified delta is committed in
   `beforeSwap`, before the pool knows its fill, and the swapper's specified side is `pool - hook`. The test
   `test_a_swap_the_pool_does_not_fill_earns_no_rebate` (a swap of 1e18 limited one step from the pool's price) went
   **red** on the first version:
   `[FAIL: the swapper was PAID in the currency it was selling: a rebate for nothing: 906067445652208 > 0]` - the whole
   block's rebate budget (906 067 445 652 210) less the 2 wei of currency0 the pool swapped, and no currency1 at all
   (re-measured with the check removed, 2026-09-24). Fixed at the cause: the rebate is carried to `afterSwap`
   in transient storage, and a swap whose pool fill is not exactly `amountSpecified - rebate` is refused
   (`RebateOnPartialFill`); a partial fill with no rebate still goes through (`test_a_partial_fill_without_a_rebate_is_allowed`).
2. **The handler hid a sign bug behind that guard.** With every `RebateOnPartialFill` filed as "expected", a mutant
   that flipped the rebate's sign (and one that put it in the unspecified slot) moved the pool's fill on every swap with
   a rebate, tripped P9, and the campaign stayed green in all nine invariants - only the smoke test's census
   (`action barely exercised: swap`) said anything. Now a P9 refusal on a swap with no price limit, in a pool no single
   swap can exhaust, is a surprise: both mutants die in the campaign
   (`P9 refused an UNLIMITED swap in a liquid pool - the hook's own delta moved the fill`). "A pool no single swap can
   exhaust" was measured by liquidity (>= 1e18), and that was the handler's second false premise - see "the handler's
   own forecast" below; the check is now P9's own arithmetic, and the tables below keep the message as it was measured.

**P11, the price of P9: liveness** (a limit, stated in the hook's header; found by the verifier V13, 2026-09-24).
"A partial fill with no rebate still goes through" is true and it is the small half. While the rebate budget of the
specified currency lasts (and no payment is in flight, P7), EVERY swap the pool does not fill completely is refused
whole. V13's sweep, on a funded hook at 1:1 with 100e18 of liquidity - 160 swaps of 1e16 to 4.9e18 in all four
orientations, with price limits 0.0025 % to 1 % of the sqrt price away:

| outcome | swaps |
| --- | --- |
| filled completely, with the rebate | 17 |
| refused `RebateOnPartialFill` | 143 |
| stood without a rebate | 0 |
| any other revert | 0 |
| paid a rebate on a partial fill | 0 |

A limit quoted for the plain swap does not fit the swap with the rebate (the rebate makes the pool swap more input, or
deliver less output), so a router that quotes without the hook is refused too (V13 measured that case). The unit test
`test_P11_with_a_rebate_budget_every_partial_fill_is_refused` limits the same swap at 1/4, 1/2, 3/4 and 999/1000 of
the way to its full fill's end price in each orientation: refused every time; AT the end price it fills with the
rebate. One sqrt-price unit short of the end price is not always partial: the step that reaches the limit rounds the
amount it needs, and in both exact-in orientations it needed the whole amount - a full fill, which stood (the test
accepts either, never a partial fill with a rebate). Once the block's budget is spent, a partial fill stands again,
also as the second swap of a transaction (`test_two_swaps_in_one_transaction_a_partial_second_with_no_rebate_left_stands`).

**The sign-convention trap, measured.** Nine one-line mutants, each run against a NAIVE suite (kept outside the repo,
a naive suite (kept out of the kit on purpose): exact-in only, 1:1, a fresh hook per test, the fee checked to within 5 %, total supply
conserved), the unit suite and the campaign (fresh corpus):

| mutant (one line of `DeltaFeeHook.sol`) | naive suite | unit suite (15) | campaign, first invariant red |
| --- | --- | --- | --- |
| M1 specified currency chosen by `zeroForOne` alone (exact-out forgotten) | **survived** | killed, 4 red (`test_exact_out_*`, ...) | `CurrencyNotSettled with every switch off` |
| M2 fee computed on the pool's SPECIFIED amount | **survived** | killed, 6 red (`3000000000000000 != 2961474103191183`) | `P2: the fee is not 0.30 % of the pool's unspecified amount` |
| M3 rebate returned with its sign flipped (`+paid`) | **survived** | killed, 10 red | `P9 refused an UNLIMITED swap in a liquid pool` |
| M4 rebate returned in the UNSPECIFIED slot | **survived** | killed, 10 red | `P9 refused an UNLIMITED swap in a liquid pool` |
| M5 rebate returned as what was MEANT, not what the manager credited | **survived** | killed, 1 red (`..._what_the_manager_credited_not_what_was_meant`) | `P9 refused an UNLIMITED swap in a liquid pool` |
| M6 the partial-fill check (P9) removed | **survived** | killed, 1 red (`a rebate for nothing: 906067445652208 > 0`) | `P9: a rebate was paid on a swap the pool did not fill` |
| M7 the synced-currency check (P7) removed | **survived** | killed, 1 red (`CurrencyNotSettled`, the prepaying router) | `CurrencyNotSettled with every switch off` |
| M8 the per-block cap removed | **survived** | killed, 1 red (`7068793114650906 > 706879311465090`) | `P5: rebates in one block exceeded the cap` |
| M9 fee returned with its sign flipped (`-fee`) | killed | killed, 12 red | `CurrencyNotSettled with every switch off` |

(forge 1.8.1, source manager, 2026-09-24; each campaign is ONE draw of 64 x 64 on a fresh corpus)

**Two mutants the unit suite missed, now killed by it** (the verifier V13's own, 2026-09-24; K13b wrote the tests):

| mutant | unit suite before (15) | campaign | unit suite now (19) |
| --- | --- | --- | --- |
| X1 the reserve counts what was BOOKED (`reserveOf[unspecified] += fee`, not `received`) | survived | killed (`the hook holds other than its ledger plus donations`) | killed, 1 red |
| X2 the transient slot not cleared after P9 reads it (`tstore(slot, 0)` removed) | survived | killed by the smoke test only (`P9 refused an UNLIMITED swap in a liquid pool`) | killed, 2 red |

X1 differs from the original only when the fee ARRIVES short, so the test that kills it takes the fee in a currency
that charges 1 % on transfer; with honest tokens `fee == received` and no test can tell them apart. X2 differs only on
the SECOND swap of a transaction, and forge clears transient storage between the top-level calls of a test (measured:
a slot written in one call reads 0 in the next), so a unit suite whose every swap is its own call cannot see it. The
tests use `TwoSwaps`, a helper in the test file that makes two swaps through `MinimalRouter` in one call - what a
multicall or an aggregator does. Red, on the mutants:

```
[FAIL: the reserve is not what arrived: 2961474103191183 != 2931859362159272] test_the_reserve_is_what_arrived_not_what_the_manager_booked() (gas: 601006)
[FAIL: WrappedError(0x3b387cA0D1A6Bbe2e1A2ec9A69E09Ffc02fD80Cc, 0xb47b2fb1, 0xedb7c647, 0xa9e35b2f)] test_two_swaps_in_one_transaction_a_partial_second_with_no_rebate_left_stands() (gas: 3234114)
[FAIL: WrappedError(0x3b387cA0D1A6Bbe2e1A2ec9A69E09Ffc02fD80Cc, 0xb47b2fb1, 0xedb7c647, 0xa9e35b2f)] test_two_swaps_in_one_transaction_the_second_with_no_rebate_left() (gas: 2902906)
```

(`0xedb7c647` is `RebateOnPartialFill`: the second swap read the first one's rebate.) M6 (P9 removed) now turns 3 unit
tests red, not 1.

The naive suite let eight of nine through. What the unit suite has that it lacks is written in `V4-ACCOUNTING.md`,
"Sign and side, measured": the four orientations, a price far from 1 (at price 4 a fee on the wrong side is four times
off), a funded hook, and equality with the manager's own numbers. The class is `HOOK-ATTACKS.md` class 5 (delta
accounting); class 36 (gate unit-confusion) is its neighbour.

**What the campaign found after the example was finished: its own test router** (CI, 2026-09-24). The same tree went
green in one CI run and red in the next, twice; seeds are random per run on purpose, so this was the campaign drawing a
sequence no local draw had. Every invariant failed on `swap: CurrencyNotSettled with every switch off - somebody's delta
was left open`, and both runs shrank to the same three calls: `removeLiquidity` takes the only provider's WHOLE position
out, `fund` gives another actor tokens, `swapPrepaid` sends a small exact-in swap through `PrepayRouter`. Replayed as
unit tests (`test_ci_replay_a_prepaid_swap_on_a_pool_emptied_of_liquidity`, and `..._second_run` with the other run's
numbers), red:

```
[FAIL: the handler met a failure it did not predict: swap: CurrencyNotSettled with every switch off - somebody's delta was left open: 1 != 0] test_ci_replay_a_prepaid_swap_on_a_pool_emptied_of_liquidity() (gas: 1470626)
```

The trace names the culprit, and it was not the hook: on a pool with no liquidity the swap fills nothing (`Swap` with
`amount0: 0, amount1: 0`), the hook returns 0 from both callbacks and books nothing, and the router's `settle()` credits
it the 128 wei it had prepaid - a credit nobody takes back, so `unlock` refuses the whole transaction. A router that
pays BEFORE the swap pays for the swap it asked for, not the one the pool filled; `PrepayRouter` now takes back
`settle`'s credit plus the pool's `amount0` when that is positive (a price limit fills short the same way). The
handler's premise - with every switch off, `CurrencyNotSettled` can only be the hook - holds only while both routers
close their own books, and its comment now says so; a prepaid swap that fills short is a named boundary
(`prepaid swap filled short, the unused prepayment returned`) and P1 checks the refund from the payer's true balance.
Not a limit of the hook, so nothing is added to its header. Measured after the fix, forge 1.8.1, source manager, fresh
corpus per seed: ten pinned seeds of the campaign green, among them seed 1337, which was red on the old router with
the same shape (whole position out, then a prepaid swap); the two CI seeds did not reproduce the failure locally on
either router, which is why the replays exist.

**Then the handler's own forecast** (the verifier, on the tree with the router fixed, 2026-09-24). A second red, as
deterministic as the first, and again not the hook: `swap: P9 refused an UNLIMITED swap in a liquid pool - the hook's
own delta moved the fill`. The handler filed a P9 refusal on a swap with no price limit as a surprise whenever the
pool's liquidity was >= 1e18 - the check that kills a hook whose rebate moves the pool's fill (item 2 above). But
liquidity does not say how much of ONE currency the pool holds. Both shrunk sequences drain the pool to almost nothing,
push the price far to one side with a burst, bring liquidity back, and send a burst of exact-out swaps for the scarce
currency: with a liquidity of 1 000 999 000 000 008 189 the whole range could deliver 189 548 627 326 005 160 of
currency0, and each swap of the burst asked for more. The pool fills short, the hook refuses the rebated swap -
correctly - and the handler went red. Pinned as `test_replay_P9_an_unlimited_exact_out_the_pool_cannot_fill_is_a_predicted_refusal`
(seven calls) and `test_replay_P9_the_same_refusal_after_the_router_fix` (nine), red on the old handler:

```
[FAIL: an earlier handler call met a failure nothing predicted: swap: P9 refused an UNLIMITED swap in a liquid pool - the hook's own delta moved the fill] test_replay_P9_an_unlimited_exact_out_the_pool_cannot_fill_is_a_predicted_refusal() (gas: 8225625)
```

The forecast is now P9's own arithmetic, made before each swap (`_forecastFill`): the rebate the hook will pay, the
amount the pool must then fill, and what the pool's one range can fill from the price now to its end in the swap's
direction. A refusal it predicted is expected and counted (`P9 refused an unlimited swap: predicted`); one within 1 000
wei of the capacity, where the pool's step-by-step rounding decides, is expected and counted separately (`... at the
pool's edge (within rounding)`); a refusal where the range could fill the swap whole, or where no rebate was due, is
still a surprise. And the forecast is held to every swap that STOOD (`forecastWrong`, asserted in
`invariant_no_unexplained_reverts`): a swap it called short must not stand, and the rebate paid must be the one it
computed - otherwise "predicted" could grow into the blanket excuse item 2 removed. Measured with the new handler: the
rebate-sign mutant and the wrong-slot mutant (M3 and M4 of the table below) still die in the campaign, two seeds each,
on `P9 refused an UNLIMITED swap the pool could fill whole`, and turn the smoke test red.

The same verifier found a mutant of the router fix that survived: hand back `settle`'s whole credit instead of the
unused part. Every prepaid swap in the campaign was unlimited, so the pool used all of the prepayment or none of it,
and there the two answers coincide. `swapPrepaidLimited` sends the prepaid swap with a price limit 0.4 % to 6e-8 of the
sqrt price below the pool's, the pool uses PART of it (`prepaid swap stopped by its price limit: part used, exactly the
rest returned`), and the mutant now dies in the campaign (`CurrencyNotSettled with every switch off`, two seeds, the
shrunk sequence starts with `swapPrepaidLimited`) and in a unit test:

```
[FAIL: CurrencyNotSettled()] test_a_prepaid_swap_stopped_by_its_price_limit_pays_exactly_what_the_pool_used() (gas: 1272618)
```

---

## Measured on this machine

forge 1.8.1, solc 0.8.26, `evm_version = cancun`. Numbers, not adjectives:

| | |
| --- | --- |
| module's own tests | all passed, 0 failed, **0 skipped**, the same count on both managers, and under `--brutalize`. The count is whatever `scripts/battery.sh` prints today: it was copied here twice and was stale both times |
| native mutation on the example hook | in `src/examples/MUTANTS.md`, which is the only place that number lives |
| `forge coverage --ir-minimum`, whole module, `src/HostileHook.sol` | **90.76 % of lines** (108/119), 12/13 branches (2026-09-24, after the file grew; the 11 lines at 0 are mapping errors, see the coverage paragraph above). From `test/HostileHook.t.sol` alone 63.87 %; the 86.67 % given here before was that measurement on the smaller file, and the 72.97 % before it was taken without `--ir-minimum` and mapped the wrong build |
| invariant campaign | 64 runs × 64 depth, 4 096 calls; the census, not `reverts:` — see the root README |
| clean build | about 25 s |
| `PoolManager` from source | **24 050 B**, 526 under the EIP-170 limit |
| `PoolManager` etched from mainnet | **24 009 B**, keccak `0x785f1014…c7ce1293`, chain id 1 |
| `CappedDynamicFeeHook` (one-block-late rule, 2026-09-23) | runtime **4 881 B** / initcode **5 636 B** in the default-profile build, **4 697 B** / **5 360 B** in the build the tests deploy (`address(hook).code.length` and `creationCode.length` in a test) - margins 19 695 / 43 516 and 19 879 / 43 792, `scripts/size.sh`. See below |

Two notes on that last row, because it was wrong here for a whole revision and the reason is a trap.

`forge build --sizes` prints TWO rows for this hook (on the first rule, 4 874 B and 4 659 B; now 4 881 B and 4 697 B,
`CappedDynamicFeeHook.manager`). The
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
| `src/sim/SimEngine.sol` | the engine, with no opinion about the hook: the loop, the clock, FCFS ordering, the queue, the books - and five verbs a project binds (`_quote`, `_execute`, `_sqrtPriceNow`, `_balances`, `_referencePriceX96`). A swap whose own quote at decision time is 0 is NOT SENT: no `_execute`, no gas, settled at once with `executed == false` and `REFUSED_AT_QUOTE`, counted in `refusedAtQuote` (the dump line's last column), never in `refused`; other kinds untouched. The refused swap is kept in the queue for the record, marked done, never in the execution order, never shown to a searcher: `queueLength()` counts it, `executedOrderOf` is 0 for it (`test/sim/RefusedAtQuote.t.sol`, which proves the engine's policy on a stub market, not that a binding's quote of 0 is right) |
| `src/sim/ExampleScenario.sol` | the engine bound to the example hook: the quote is a snapshot-and-revert of the real swap (the same code path as the execution), `minOut` enforced as a router would, gas metered with `SimGasMeter`. A project with its own router or quoter copies this file and binds its own |
| `src/sim/SimGasMeter.sol` | what one action would cost as its OWN transaction: 21 000 intrinsic + calldata (16 / 4 gas a byte) + the callee's own gas from forge's record of the last frame, less the refund capped at a fifth; several calls of one transaction are added into one `Tx`. Not a `gasleft()` window in the test frame: that charges the agent the test's own memory growth (a run never frees memory; measured +17 % on identical decisions in a downstream binding). A lower bound for the EVM costs it counts (warm slots), not a bound on any chain's total fee (no L1 data fee, no priority fee). forge's record is read only in the two layouts the meter was written against (160 or 192 bytes); any other length reverts `FrameGasLayoutUnknown(length)` - supported versions in `../README.md`. `test/sim/GasMeter.t.sol` |
| `src/sim/agents/HonestTrader.sol` | the population's floor: fixed size every N steps, alternating, a slippage rule, a latency |
| `test/sim/Calibration.t.sol` | THE MANDATORY FIRST RUN: one honest agent, zero latency, alone - quote equals execution to the wei, ledger equals wallet, nothing refused. If this is red the sandbox is wrong and no number it produces counts |
| `test/sim/PartialFill.t.sol` | the calibration's blind spot: all the liquidity in one narrow range, so a swap bigger than the range walks out of it and the pool takes LESS than the input offered. The ledger must charge `Fill.amountInUsed`, not `Intent.amountIn`. Written because a mutant that charged the offered input SURVIVED the calibration - on a full-range pool every swap takes its whole input |
| `test/sim/FilledNothing.t.sol` | a side that EMPTIES between the quote and the fill: on a scripted book two agents are quoted the whole side and the second takes nothing - recorded `executed == false`, `FILLED_NOTHING`, in `refused`, gas charged, not a revert; the same on a v4 pool whose only range is withdrawn after the quote; and a binding that reports nothing taken as executed gets `FillWithoutInput(i, rule)`, compared byte for byte |
| `test/sim/LedgerWritable.t.sol` | a `GAUNTLET_SIM` path the project may not write is named at `_initEngine()` (`LedgerNotWritable(path)`), a writable one passes and the probe leaves no file |
| `scripts/sim-report.sh` | adds the ledger lines up over runs: a result is "over N runs", never one line read off a log |

What a binding must do (a project's own copy of `ExampleScenario.sol`), in order:

0. **Bring the sandbox in - into its own directory and its own forge profile, never the default one.** The sandbox
   needs the optimizer (with forge's defaults the engine stops at `Stack too deep`), and the optimizer changes YOUR
   hook's bytecode: a fresh reader who put the sandbox under `test/sim/` and `optimizer = true` in `[profile.default]`
   saw the hook's runtime go from 1 374 to 727 bytes with no edit under `src/`, six sandbox contracts in the sizes table,
   plain `forge coverage` stop at "stack too deep" and `--ir-minimum` coverage fall to 13.5 %. So:

   - copy the engine, the ledger, the clock, `ISimAgent.sol`, the gas meter and `agents/` (without `JitLP.sol` in a
     project with no v4-core) into **`<project>/sim/`** - not `src/`, not `test/`. Your scenario (a copy of
     `ExampleScenario.sol` rewritten for your venue, or one of your own) and its tests live there too;
   - give the project's `foundry.toml` a profile of its own, which only the sandbox runs under:

     ```toml
     [profile.sim]
     test = "sim"
     out = "out-sim"            # its own artifacts and cache: sharing out/ overwrites the default build's artifacts
     cache_path = "cache-sim"
     optimizer = true           # or via_ir = true
     fs_permissions = [{ access = "read-write", path = "./census" }]
     ```

   - run it as `mkdir -p census && FOUNDRY_PROFILE=sim GAUNTLET_SIM=census/sim.tsv forge test`, and read it with
     the kit's `scripts/sim-report.sh census/sim.tsv` (neither needs anything else for this layout).

   Measured on forge 1.8.1 (2026-09-23) on a toy project with forge's defaults (a 2 632-byte gate, one unit test, the
   sandbox with a binding and a calibration test in `sim/`): the default profile's `forge build --sizes` lists the gate
   alone, 2 632 B runtime, identical (bytes and hash) before and after `sim/` and `[profile.sim]` were added, and after a
   sandbox run; `forge coverage` identical line for line; `forge lint`, `forge fmt --check` and `scripts/battery.sh` do
   not see `sim/` (battery PASSED before and after); forge compiles nothing from `sim/` under the default profile. Under
   `[profile.sim]` the gate is 1 428 B and the calibration passes. Without `out`/`cache_path` the sim build wrote its
   1 428 B gate over the default's `out/`, where anything that reads the artifact without rebuilding would take it for
   yours. `[profile.sim]` with no optimizer and no IR: `Stack too deep`; with `via_ir = true` instead: builds, calibrates.
   `fs_permissions` under `[profile.default]` is inherited by `[profile.sim]` and works too; in neither, `_initEngine()`
   stops at `LedgerNotWritable` and says where the line goes.

   **What the sandbox measures is the hook compiled under `[profile.sim]`, whose bytecode is not the one you audit.**
   Its numbers are ECONOMICS - who gains, who loses, how far execution drifts from the quote - and never the gas of the
   audited artefact: `SimGasMeter` already reports a lower bound, and here it is a lower bound of another compilation of
   your code. Gas and size of the audited hook come from the default profile only (`forge build --sizes`, the battery).

   The sandbox tests this module ships (`test/sim/*.t.sol`) all target `ExampleScenario` - the example hook on a v4
   pool - and prove the ENGINE, not your binding: none of them runs against your hook. Binding means writing your own
   scenario, steps 1-7 below, in `sim/`, and **the calibration test first** (`test/sim/Calibration.t.sol` is the model:
   one honest agent, latency 0, alone - quote equals execution to the wei, ledger equals wallet). Until it is green no
   number the sandbox gives you counts.

1. Override the five verbs: `_quote`, `_execute`, `_sqrtPriceNow`, `_balances`, `_referencePriceX96`.
2. Call `_initEngine()` once its system is deployed (on v4: `_setUpV4()`, then the hook with `_deployHook(...)`, as
   `ExampleScenario._setUpScenario` does - "Address mining for the flag bits" above).
3. **Price gas: `ledger.setGasPrice(quotePerGasE18)`** right after `_initEngine()` - raw quote per unit of gas x 1e18,
   0 for a chain whose gas nobody pays, but SAID. `run` refuses to start (`SimLedger.GasUnpriced`) until it is.
4. Report `Fill.amountInUsed` on every executed swap (the engine refuses a fill without it). A swap that was SENT and
   **took nothing** - the side it was quoted against emptied before it arrived: another order took the book, a maker
   cancelled, a range was withdrawn - did not execute: report `executed = false` with `revertSelector = FILLED_NOTHING`
   (`ISimAgent.sol`) and the gas it paid. The ledger counts it in `refused`, and the run goes on. Reported as executed
   with nothing taken, it stops the run with `FillWithoutInput(i, rule)`, whose `rule` says exactly this.
   `ExampleScenario` does it for a v4 pool emptied between quote and fill, and rolls the empty swap's price move back
   (`test/sim/FilledNothing.t.sol`: a scripted book whose side two agents are quoted, and the pool case).
5. Honour `Intent.amountInQuote` - convert a quote-sized currency0 input at its reference price - or refuse it loudly.
   The four cases, normative (currency1 is the quote; the same table is next to the field in `ISimAgent.sol`, and
   `test/sim/BindingContract.t.sol` holds the example binding to every row):

   | `amountInQuote` | `zeroForOne` | input currency | `amountIn` is in | the binding |
   | --- | --- | --- | --- | --- |
   | false | true | currency0 | currency0 | uses it as is |
   | false | false | currency1 | currency1 | uses it as is |
   | true | false | currency1 | currency1 | uses it as is (quote-sized and quote-input are the same thing) |
   | true | true | currency0 | currency1 | **converts** at its reference price, or **refuses** the intent loudly - never uses it as is |

6. **Report `Fill.gasUsed` as what this action would cost as its own transaction** - a warm-slot lower bound, no L1 data
   fee: call `SimGasMeter.lastCall(calldata)` right after the call (or `addLastFrame` per call and `total` once, for
   several calls sent as one transaction), before any other external call. Never `gasleft()` before and after the call:
   in the test frame that window grows with the test's memory, not with the action. What the number leaves out is in
   `SimGasMeter.sol` (cold first touches: forge 1.8.1's `vm.cool` is not usable for it; the L1 fee; storage priced
   against the test's start). On forge 1.8.1 the typed `vm.lastCallGas()` REVERTS against forge-std 1.16.2 (forge
   returns five words, forge-std's `Gas` declares six): the library reads the record by a raw call, and so must a test.
7. **Let the ledger write.** The project's own `foundry.toml` needs, under `[profile.sim]` (step 0; `[profile.default]`
   works too, since a profile inherits it):

   ```toml
   fs_permissions = [{ access = "read-write", path = "./census" }]
   ```

   (or that entry added to the `fs_permissions` list it already has), `GAUNTLET_SIM` pointing inside it
   (`GAUNTLET_SIM=census/sim.tsv`), and the directory made (`mkdir -p census`; forge does not create it). This module's
   `foundry.toml` has the line, so everything here works; a binding in ANOTHER project does not inherit it. When
   `GAUNTLET_SIM` is set, `_initEngine()` probes the path once and reverts `SimLedger.LedgerNotWritable(path)`, with forge's
   reason and this line logged (at `-vv`), before the first step - it used to run the whole scenario and fail at the last write
   with forge's generic "not allowed to be accessed for write operations" (`test/sim/LedgerWritable.t.sol`).

**A venue with a bid and an ask has no single price.** `_sqrtPriceNow` returns one number per venue and `_quote` one
amount per intent; a pool has one price, a book has two sides and a gap between them. The binding of a book says,
in its own documentation and in the dossier, WHICH price `_sqrtPriceNow` reports - the best bid, the best ask, or the
reference price when that lies inside the spread - and it quotes and fills only against what could actually fill: the
resting size on the side the intent takes, at the prices it rests at, never a midpoint nobody offers and never size
beyond the top of the book that is not there. An agent that reads the venue price and a ledger that values holdings at
`_referencePriceX96()` then mean something the reader can check; a binding that reports the mid as "the price" and
fills at it invents liquidity. A side that empties between quote and fill is step 4's `FILLED_NOTHING`, not a revert.

**What a binding of a different manager reuses.** Arm A of the second blind run bound a hook that ran on its own mock
manager, not on v4's. The sandbox splits along that line, and in the step 0 layout everything below goes into
`<project>/sim/`, flat (`sim/SimEngine.sol`, `sim/agents/...`), so the copies import each other by `./` exactly as they
do here:

- **Venue-agnostic - copy as is:** `SimEngine.sol` (the loop, the queue, FCFS / BUNDLE, refused-at-quote, the five
  verbs as the only contact with a venue), `SimLedger.sol` (books, gas, P&L, the dump line, `sim-report.sh`),
  `SimClock.sol`, `ISimAgent.sol` (`Intent`, `Fill`, the markers), and `SimGasMeter.sol` (it meters whatever call you
  name). Measured (2026-09-23, forge 1.8.1): these five and the agents below, in `sim/` of a project with no v4-core
  and only forge-std, next to a binding of a toy constant-product gate of about 50 lines, compile under `[profile.sim]` and
  its calibration passes (40 of 40 executed, quote equal to execution, ledger equal to wallet). The engine's own tests
  run on stub markets, never on v4 - `RefusedAtQuote.t.sol`, `LedgerWritable.t.sol`, and `EngineFilledNothing` in
  `FilledNothing.t.sol` (whose other half needs `ExampleScenario`) - and their imports name this module's
  `../../src/sim/`: copied into `sim/` those become `./`. Not measured in that layout.
- **Assume the v4 manager - rewrite for yours:** `ExampleScenario.sol` (the pool keys, `MinimalRouter`,
  `LiquidityHelper`, the snapshot-and-revert quote through the v4 swap, the `Swap` event read for the fee, the
  `sqrtPriceX96` read from the manager's slot0, `V4Harness`) and the venues it builds - the hook's v4 pool and the main
  market (`_addMainMarket`, a hookless v4 pool). The agents in `agents/` speak `Intent` and `Fill`, and all but one
  compile with nothing but `ISimAgent.sol` and forge-std: **`JitLP.sol` imports v4-core** (`TickMath.getTickAtSqrtPrice`,
  to place its narrow range around the price), so it does not compile - and does not run - on a binding whose project
  has no v4-core. Measured on forge 1.8.1, each agent alone with `ISimAgent.sol` against forge-std only, with and without
  the optimizer: `Arbitrageur`, `HonestTrader`, `PassiveLP`, `RandomTrader`, `Sandwicher` build; `JitLP` stops at
  `Source "v4-core/src/libraries/TickMath.sol" not found`. Leave `JitLP.sol` out of such a project (or install v4-core
  for it). The liquidity agents (`PassiveLP`, `JitLP`) also emit v4-shaped liquidity intents (ticks and a liquidity
  delta): a manager with another liquidity model maps those in its `_execute` or does not use them.
- **Written against `ExampleScenario` - a model, not a test of your hook:** `Calibration.t.sol`, `BindingContract.t.sol`,
  `PartialFill.t.sol`, `Ordering.t.sol`, `Liquidity.t.sol` and the other scenario tests of `test/sim/`. Nothing shipped
  runs against your binding: you write its tests in `sim/`, on your scenario, with these as the model - the calibration
  first.

**Incompatible change (2026-09-23).** `SimEngine.FillWithoutInput` has a second field (`rule`), so a test that matched
the old one-field error no longer matches; `_initEngine()` reverts `LedgerNotWritable` when `GAUNTLET_SIM` names a path
the project cannot write, where it used to fail at the end of the run. Nothing else changes for a binding.

**Incompatible change (2026-09-22).** A binding written before this date stops at its first `run` with
`GasUnpriced` until it adds step 3; the ledger's dump line has two more columns at the end (`gasCost`, `pnlNet`), which
`sim-report.sh` reads; and `Intent` has a new field (`amountInQuote`), so an `Intent(...)` written positionally no longer
compiles (named fields and `Intent memory it; it.x = ...` are unaffected). Later the same day the dump line gained a
16th column at the end (`atQuote`, swaps quoted 0 and never sent), and `refused` stopped counting them: a reading of
`refused` taken before that change includes them. Nothing changes for a binding.

### Running the example scenarios, and reading the ledger

Every number below comes from these commands, run from `foundry-kit/v4` on forge 1.8.1 (2026-09-23, the
one-block-late example hook). The ledger file has to be under `census/`, the one directory `foundry.toml` lets a test
write to:

```sh
cd foundry-kit/v4 && mkdir -p census && rm -f census/sim.tsv
GAUNTLET_SIM=census/sim.tsv forge test --match-path test/sim/Calibration.t.sol                    # deterministic: 1 run
for s in 1 2 3 4 5; do SIM_SEED=$s GAUNTLET_SIM=census/sim.tsv forge test --match-path test/sim/Ordering.t.sol; done
GAUNTLET_SIM=census/sim.tsv forge test --match-path test/sim/Liquidity.t.sol --match-test over_seeds -vv  # seeds 1-5
../../scripts/sim-report.sh census/sim.tsv
```

`sim-report.sh` adds the lines up per scenario and agent: `runs` is the number of lines, so it is the number of SEEDS
only for a population that reads `SIM_SEED` (the ordering and the liquidity ones do; the calibration's single honest
agent has nothing to seed, and running it five times gives five identical lines, which the report would call "5 runs").
Amounts are raw units of the quote currency (18 decimals); `gas/run` is metered per action (`SimGasMeter`).

Step 1, the calibration and the stale quote (deterministic, one run each):

```
scenario       agent         runs   decided  executed  refused  shortfall/run   windfall/run     worst ever      gas/run    pnl/run  priced  gasCost/run    net/run atQ runs atQuote/run
calibration-gas-priced honest           1      40.0      40.0      0.0              0              0              0      8505526 -3950038008590954       1 25516578000000000000 -25520528038008590336        1         0.0
calibration    honest           1      40.0      40.0      0.0              0              0              0      8505526 -3950038008590954       1            0 -3950038008590954        1         0.0
latency-one    honest           1      41.0      41.0      0.0              0 7968272823946840              0      8693265 -1917594464333915       1            0 -1917594464333915        1         0.0
latency-one    late             1      41.0      40.0      0.0 310652317197111  3483779825495 249003066423052      8322417 -9936354757654142       1            0 -9936354757654142        1         0.0
```

(Re-run 2026-09-24 when `MinimalRouter` learned ETH, same commands: `gas/run` of `calibration` 8 685 446 before the change
and 8 687 406 after - 49 gas a swap for `payable` and the refund check. The gas columns of `calibration-gas-priced` move
with it: `gasCost/run` 26 056 338 000 000 000 000 -> 26 062 218 000 000 000 000 and `net/run` -26 060 288 038 008 590 336 ->
-26 066 168 038 008 590 336 as printed; `latency-one` gas/run 8 877 683 / 8 502 337 -> 8 879 692 / 8 504 297 (measured by
the verifier V14). Every other column - decided, executed, refused, shortfall, windfall, worst, `pnl/run` - identical to
the wei. Re-run again the same day when the router and the helper started paying out of `msg.value` counted, same
commands: `calibration` 8 687 406 -> 8 698 106 gas/run, 267.5 gas a swap; `gasCost/run` 26 094 318 000 000 000 000,
`net/run` -26 098 268 038 008 590 336 as printed; `latency-one` 8 890 612 / 8 514 997; the other columns again identical
to the wei. The 8 505 526 above was already stale before the first change; nobody re-measured this table in between.)

That is the report as the kit's `scripts/sim-report.sh` printed it (forge 1.8.1, 2026-09-23, from the first command
above alone): rows in the order the ledger received them, whole numbers through awk's `%.0f`, so a value beyond 2^53
keeps only its leading digits exact (the gas-priced `net/run` is -25 520 528 038 008 590 954 raw units, printed
...590336).

`calibration-gas-priced` is the one example whose ledger charges gas (`test_calibration_with_gas_priced_charges_every_fill`):
the same forty swaps at a price the test states as an assumption - 1 gwei, and 3 000 quote units per ETH, so
`setGasPrice(3e30)` - cost 2.55e19, about 25.5 quote tokens for 8.5 M gas, against a gross P&L of -3.95e15. Every other
example says `setGasPrice(0)` out loud, because nobody pays for the gas of a local manager; a binding of a real chain
prices it, and this line is what its report then looks like.

Two things the first run taught, both now asserted in the test file:

1. **On this hook a stale quote costs money even with nobody hostile around.** The fee of a block is set by how many
   swaps the block before it saw, so a quote taken in one block and executed in the next is a different fee (and the
   price has moved). The `late` agent (latency 1) pays about 3.1e14 over the run for it; the same agent at latency 0,
   alone, pays nothing.
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

The same population, 60 steps, run under each ordering, seeds 1-5 (the two world traders draw from `SIM_SEED`; the
victim, the arbitrageur and the sandwicher react to them). Means per run over the five, from the commands above:

```
                        decided  executed  shortfall/run    pnl/run
population-fcfs   victim   30.0      29.0        3.36e15   -8.46e14
population-fcfs   arb      50.0      49.2        1.42e16   +1.24e17
population-fcfs   sandwich  0.0       0.0              0          0
population-bundle victim   30.0      29.0        3.71e16   -5.03e16
population-bundle arb      49.6      48.8        2.84e16   +9.84e16
population-bundle sandwich 155.6    155.6              0   -2.52e16
```

Read across the two blocks and the ordering model is still the first result: under FCFS the sandwicher is never asked;
under BUNDLE it wraps about 78 intents a run (the arbitrageur's too - a searcher does not care whose) and the victim's
cost goes from 8.5e14 to 5.0e16 - inside its 2 % slippage rule every time, which is how a sandwich is sized. The
second result is the hook's: on the one-block-late rule the sandwicher LOSES, 2.5e16 a run, on every one of the five
seeds; on the first rule, same seeded world, it earned 8.9e15 a run on seeds 1-3 (the rule is the only difference; the
comparison was run once, by hand, on the previous commit). A block that holds a sandwich is a busy block, and the next
one charges everybody for it, the sandwicher included. The number a hook author wants is the front-run size at which
the sandwich stops paying, and that is a sweep, not an assertion.

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
| `test/sim/Liquidity.t.sol` | the same population under both orderings, from one snapshot per seed, so the two ledgers are directly comparable: one test on `SIM_SEED` that asserts only what holds on every seed, and one over seeds 1-5 that asserts the counts below |

Measured (60 steps, raw quote units, `--match-test over_seeds -vv`; the JIT LP wraps 29 swaps on every seed):

```
seed   passive LP, FCFS   passive LP, BUNDLE   JIT LP, BUNDLE
1           +8.56e15            +2.44e15           +1.63e16
2           -9.17e15            -2.81e15           -1.87e16
3           -6.58e15            -2.04e15           -1.36e16
4           -6.00e15            -1.87e15           -1.25e16
5           -2.05e15            -7.04e14           -4.70e15
```

This section used to give seed 1 alone as "the whole JIT story" - the JIT LP takes the passive LP's fees - and the test
asserted it. A fresh reader ran seed 2 and the test went red. Over five seeds the passive LP is worse off with the JIT
LP in the world on **1 of 5**, and the JIT LP profits on **1 of 5**, the same one. On this population the JIT LP takes
a share of the pool's fortune, whichever way the world moved it - fees on seed 1, losses to price moves on the other
four. The test asserts those two counts (`1`, `1`), so a change that moves the distribution goes red and has to be
re-measured; the `SIM_SEED` test asserts only what holds on every seed. A third count - the JIT LP's P&L and the change
in the passive LP's have opposite signs, 5 of 5 - is asserted too, but as a **sanity check, not evidence**: it sits
next to an accounting identity (what one LP gains the other gives) and it stayed 5/5 under both mutants that turn the
first two red (a verifier's measurement, 2026-09-23); nothing here rests on it. Mutants: liquidity changes that
never execute, a JIT position of 1 wei, a world that ignores its seed - each seen red by these tests (on the
single-seed version; the count test was seen red by its own first run, which measured the counts).

What is NOT here yet: a fork of the real target chain as the main market (needs the owner's `RPC_URL`), the LP's
allowance as a parameter (it means something on a hook that pulls by allowance, not on a v4 position - the
binding for such a hook adds it), latency drawn from a measured distribution, and an agent for the dust-ahead-of-a-
victim ordering of round r01 (the invariant campaign has one, `dustAheadOfVictim`; the sandbox does not). Listed so
that nobody reads them as present. When to run any of this, and the rules its numbers answer to, is
`doctrine/SIMULATE.md`.

Mutation, by hand (`scripts/mutate.sh`): a quote off by one wei kills the calibration ("the quoter is not the
executor: 40 != 0"). `executeAtStep > s` -> `!= s` in the FCFS loop SURVIVES, and is equivalent by construction:
the loop never skips a step, so no intent is ever due in the past. If a scenario ever calls `run` twice, that
equivalence ends - a limit, written here so it is not rediscovered.

---

## What this module still does not do

Written down because a list of gaps is the only honest end to a README.

* **What is left of native currency and claims** (both left this list on 2026-09-24: "Native currency" and
  "ERC-6909 claims", above). Not run: `DeltaFeeHook`'s campaign on a native pool (its native pool has unit tests; the
  campaign on ETH is `ClaimsFeeHook`'s); P7 with ETH (a payment in flight while the hook pays an ETH rebate - the
  kit's `PrepayRouter` prepays currency0, which is ETH there); a hook that pays ETH to a THIRD party (a referrer, a
  treasury in the swap path), whose `receive()` would then be able to refuse or grief every swap; claims moved with
  the ERC-6909 `transfer` / operator approvals, a router that settles WITH claims (`burn`) or takes them (`mint`), and
  WETH / wrapped-native pools. The fixture manager has not run the new files.
* **What is left of the four areas that left this list on 2026-09-24** (K15: "Re-entrancy through a currency's
  transfer hook", "Two pools, one currency", "At the edges", above). Not run: a token callback re-entering from a
  DELIVERY in the middle of a multi-hop (only the stale slot it leaves was measured), a callback on the payment of a
  `modifyLiquidity` or a `donate`, a native pool's campaign with two pools, the edges under a campaign (the battery is
  a fixed grid of 60 swaps per hook), the protocol fee at any edge, and `DeltaFeeHook`'s limit on a fee taken before
  the input arrives (measured and stated, not fixed).
* **Deltas beyond the swap.** `afterAddLiquidityReturnDelta` / `afterRemoveLiquidityReturnDelta` and a hook that takes
  the WHOLE swap (a custom curve, `HOOK-ATTACKS.md` class 35) have no test. Nor has `DeltaFeeHook` a fixture-manager
  run, a long campaign or a native mutation pass: see "Hooks that return deltas".
* **Fork tests.** Everything here is local. There is no test that runs against a live fork.
* **A block-pinned fixture.** `fetch-bytecode.sh` reads the latest block; it does not pin one.
* **`v4-periphery` is optional and untested.** `V4_WITH_PERIPHERY=1` installs it; nothing in this module compiles
  against it.

The attack list this module was written from — re-entrancy through `unlock`, hijacking `sync`, `hookData` as
attacker input, read order, delta accounting, ERC-6909 claims, native currency, fee and tick edges,
initialisation and permissions — is still the right list. Several rows of it now have code. The ones above
do not, and no green run in here should be read as covering them.

## What it must NOT contain

No deployment scripts, no broadcast, no addresses beyond the fixture needed to etch a manager under test.
The gauntlet ends at a dossier for human auditors, and this module is part of the evidence, not part of a
release.
