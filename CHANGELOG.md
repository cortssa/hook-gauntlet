# Changelog

## v0.2 - 2026-09-28 - the kit against the chain that exists, and against itself

- **A mainnet fork at a pinned block** (`V4_MANAGER=fork`, `FOUNDRY_PROFILE=fork`): the deployed PoolManager, real
  USDC / WETH / ETH, the USDC blocklist and pause measured on the example hooks (`doctrine/V4-ACCOUNTING.md` 28-29);
  a block-pinned fixture; `FORK_BLOCK` read strictly.
- **Uniswap's real periphery** (`V4_WITH_PERIPHERY=1`, profiles `periphery` and `periphery-fork`): the example hooks
  through PositionManager, V4Router and Permit2, on the source manager and on the fork; what `sender`, `msgSender()` and
  `hookData` are there (items 30-32); the deployed UniversalRouter reads an older swap layout than the pinned periphery
  - on a native pool the hook gets empty `hookData`.
- **Who was paid, not only how much:** `JitRecipient` (a position exactly around the price just before a payout, out
  right after; after a push; as the trader too), `InRangeLedger` (a reference model of who was entitled), an example
  hook that donates to in-range liquidity and defends by paying before anything can change who is in range - with its
  residuals named (R1-R4), one of them the entitlement rule itself being exploitable. `doctrine/INVARIANTS.md`, "Who
  was paid".
- **No false green from behind forge's back:** the judging scripts strip forge's environment variables, refuse a
  project `.env` that sets one and a global `~/.foundry/foundry.toml` filter, rebuild from scratch on a build cache
  from another path or a source forge's incremental build misses (a remapping, a symlink), redact secrets in
  `FORGE_FLAGS`, and never call a failed test a pass whatever forge exited with. The selftest refuses a CI workflow
  that does not parse (four pushes ran no job over one unquoted colon).
- **The decision table closes:** `scripts/next.sh` reads `STATE.md` and names the row (rows as data, a drift guard
  with a hash of each condition); rows 2 and 14 are gates; a `rehearsal` flag; the ceiling as a gate, not a stop, and a
  ceiling the operator may set with the owner absent; the route ENDS with the owner absent - the skeleton names the open
  findings and `next.sh` answers `STOP - paused, waiting on the owner`; row 1 quiet only when every open high is
  recorded to tell, by id; one exit criterion everywhere (zero high and zero medium still OPEN); a phase-3 bug with the
  owner absent goes to `pending/`, the owner decides; benches live in `<project>/.gauntlet/bench`, never `$HOME`, and
  no script writes into an owner's tree without the convention installed.
- `scripts/doctor.sh` (checks, never installs), a one-page entry to the dossier, the forbidden words, issue forms for a
  stuck step and for what the kit missed; the v4 clean build measured at about 200 s and 9 GB, not 26 s and 1.3 GB.
- Known gaps, each written where it lives: the source record is a CRC; the black-box bench refusal reads the word
  `src`; a non-id written as an open high and as told still quiets row 1; the "through the periphery" check can be
  fooled by a handler that pranks as the router; a treasury skim below 3 wei per donation passes the campaign.

## v0.1.1 - 2026-09-25 - the dossier as a PDF, and what a handoff must be

- `scripts/dossier-pdf.py` renders the handoff dossier as a PDF for the human auditor (status lines boxed first,
  tables with wrapped cells and repeated headers, nothing dropped); QUICKSTART step 10 hands over `DOSSIER.md` and
  `DOSSIER.pdf`, the Markdown being the record. Needs `reportlab` (optional); CI renders the template on every push.
- A handoff, as opposed to an exercise, now requires a git repository with its commit on the dossier's first line,
  every judge output cited from inside the project, and section 10 runnable on a clean machine (the kit vendored into
  the project with relative remappings).
- The DeltaFeeHook campaign's intermittent red in CI was the test harness, not the hook: a test router that kept an
  unused prepayment, and a handler that misread a correct refusal. Both fixed, pinned as replays, verified.

## v0.1 - 2026-09-24 - pre-audit workflow for Uniswap v4 hooks

First public release. Measured on one model family (Claude) inside one agent harness (Claude Code): two blind runs on one
small planted-defect target, twelve walks of the route by agents that had never seen it, each on a hook nobody had seen,
and a v4 module closed one area at a time with a second agent verifying each area. Numbers and limits: `README.md`, *Status*.

Worked examples in `foundry-kit/v4/`, each with unit, invariant, mutant and edge tests:

- an ordinary before/after hook with a capped dynamic fee (`CappedDynamicFeeHook`);
- a hook that returns deltas - fee on the unspecified side, rebate on the specified side, a per-pool cap (`DeltaFeeHook`);
- native-currency pools in the router and the liquidity helper, with a hostile native counterparty;
- a hook that keeps its fee as ERC-6909 claims, with conservation per party (`ClaimsFeeHook`);
- settlement re-entrancy through a token's own transfer, every manager door (`TokenCallbackActor`);
- a second pool sharing a currency, and state per pool;
- a 60-swap edge grid per hook at tick spacing 1 and 32 767 and at the price limits.

Not covered, said in the README and in the module's own gap list: fork tests and a block-pinned fixture; a JIT-recipient
actor for hooks that pay "whoever is in range"; v4-periphery; the token behaviours `foundry-kit/README.md` lists.

The route ends at audit-ready. It never deploys, never broadcasts, never handles a key, and never calls a hook safe.
