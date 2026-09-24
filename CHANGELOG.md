# Changelog

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
