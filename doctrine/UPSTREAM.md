# Upstream first - what to read before you believe this kit

This kit is a METHOD. It is not the documentation of Uniswap v4, it is not a hook library, and it is not the ecosystem's
security standard. All three exist, are maintained by the people who own the protocol, and change. **Read them first,
and when they disagree with anything in this repository, they win**: follow upstream, write the disagreement in
`DECISIONS.md`, and open an issue here.

Links were opened and read on 2026-09-22. A documentation site moves (this one did, while this file was being written:
`docs.uniswap.org` now redirects to `developers.uniswap.org`), so if a link is dead, search for the title - do not skip
the reading.

## 1. The protocol, from the people who wrote it

| what | where | when in the route |
|---|---|---|
| Uniswap v4 developer documentation - overview, *Concepts: Hooks*, *Guides: Build Your First Hook* | <https://developers.uniswap.org/docs/protocols/v4/overview> | before phase 0: you cannot interview an owner about a hook if you do not know what a hook can and cannot do |
| **`v4-template`** (Uniswap Foundation, MIT) - the project layout, the test utilities, the deployment scripts, and its own notes on why a hook deployment fails (wrong flags, wrong deployer in `HookMiner.find`) | <https://github.com/uniswapfoundation/v4-template> | phase 2 starts FROM it. If the template's layout and this kit's examples differ, follow the template |
| `v4-core` and `v4-periphery`, at the commits `scripts/install-v4.sh` pins | fetched by the script, never vendored here (`PoolManager` is BUSL-1.1) | the final authority on behaviour. `doctrine/V4-ACCOUNTING.md` was checked against the pinned `v4-core`; when the pin moves, that file is stale until somebody re-checks it |

## 1b. By topic: where the fact lives

**The rule: never state a fact about the protocol, the toolchain or the compiler from memory.** A model's memory of v4 is
a blend of pre-release designs, blog posts and three API generations, delivered with full confidence. Fetch the page,
cite it with the date, and when it matters read the code at the pinned commit. "I recall that..." is UNVERIFIED in the
sense of `doctrine/EVIDENCE.md`, whoever says it.

Two of these sites publish an index MADE FOR AGENTS (the `llms.txt` convention). Start there: it lists every page, and
each page is available as plain Markdown.

- Uniswap: <https://developers.uniswap.org/llms.txt> - per-page Markdown at `/docs/<path>.md`, or with the header
  `Accept: text/markdown`.
- Foundry: <https://getfoundry.sh/llms.txt>

| you need to know | read (all under `https://developers.uniswap.org/docs/protocols/v4/` unless a full URL is given) | and in this kit |
|---|---|---|
| what a hook is, which callbacks exist, what the permission bits in the address mean | `concepts/hooks`, `guides/hooks/getting-started`, `guides/hooks/your-first-hook` | `foundry-kit/v4/README.md` (mining, and the two different refusals of a wrong address) |
| deltas, `unlock`, settling, why a transaction reverts with a non-zero delta | `concepts/flash-accounting`, `guides/unlock-callback-and-deltas`, `guides/flash-accounting`, `concepts/poolmanager` | `doctrine/V4-ACCOUNTING.md` - checked against the pinned code, operation by operation |
| hooks that return deltas, custom curves, custom accounting, async swaps | `guides/custom-accounting`, `guides/hooks/async-swap` | `HOOK-ATTACKS.md`; the kit has NO worked example of this class yet - say so in your dossier |
| dynamic fees: who may set them, the override flag, the maximum | `concepts/dynamic-fees`, `guides/hooks/swap-hooks` | the worked hook in `foundry-kit/v4/src/examples/` |
| liquidity hooks | `guides/hooks/liquidity-hooks` | |
| who `msg.sender` / `sender` is inside a hook (the hook sees the router, not the end user) | `guides/hooks/accessing-msg.sender` | `HOOK-ATTACKS.md`, the "layer in front of the hook" class; the dossier's "trusted periphery" row |
| deploying a hook, CREATE2, why the deployer address matters | `guides/hooks/hook-deployment`, and the `v4-template` README | `foundry-kit/v4/src/HookMiner.sol` |
| ERC-6909 claims | `concepts/erc-6909`, `guides/erc-6909` | not covered by the kit's examples |
| whether routers and aggregators will route through a pool with your hook | `concepts/hook-routing` | the owner interview: who is expected to trade here? |
| positions, the position manager, subscribers | `guides/position-manager`, `concepts/subscribers`, `guides/subscriber` | |
| reading pool state from outside | `guides/read-pool-state`, `guides/state-view` | the views other software will trust are entry points too (`FUZZ-ACTIONS.md`) |
| **the address of the pool manager on your chain** | `deployments` - take it from THERE (or from the chain's own documentation), never from memory and never from a search result | `scripts/fetch-bytecode.sh`, `NEXT.md` row 7b |
| common failures | `guides/troubleshooting` | |
| invariant testing, the fuzz corpus, mutation testing, coverage, lints, inline test configuration | <https://getfoundry.sh/guides/invariant-testing>, `/guides/fuzz-corpus`, `/guides/mutation-testing`, `/reference/forge/coverage`, `/reference/forge/lint`, `/config/reference/testing`, `/config/reference/inline-test-config`, `/reference/cheatcodes/overview` | `doctrine/JUDGES.md` (how each of these lies), `foundry-kit/README.md` (what they measured here) |
| known bugs of the compiler version you build with | <https://docs.soliditylang.org/en/latest/bugs.html> (and the machine-readable `bugs_by_version.json` it points to) | the dossier's scope sheet asks for it |
| token behaviours that break integrations | <https://github.com/d-xo/weird-erc20> - a longer catalogue than this kit's hostile token | `foundry-kit/README.md`, "Not covered yet" |
| the error a manager wraps a hook's revert in | ERC-7751, <https://eips.ethereum.org/EIPS/eip-7751> | the example handlers, `_classifyPoolFailure` |
| how your target chain orders transactions, what `block.number` and `block.timestamp` mean there, its block time | **the chain's own documentation.** On an Arbitrum-style L2, for instance, `block.number` is an estimate of the L1 block and the sequencer is first-come-first-served; a hook with a "per block" rule, or a threat model that assumes a public mempool, means something different there | `HOOK-ATTACKS.md`, the class "What your CHAIN changes"; the spec's assumptions table |

**When you cannot fetch** (no network, a sandbox, an endpoint the owner has not set): do not answer from memory
instead. Label the claim UNVERIFIED, mark the judge that needed it "not done", carry both to the dossier's "not
checked" section, and ask the owner for the page or the endpoint (`NEXT.md` row 7b is the model: ask, and wait).

If a page in this table has moved, fix the table in your copy and tell us. If a page CONTRADICTS this kit, the page
wins (and tell us).

## 2. The ecosystem's own security standard

**The Uniswap Foundation's Hook Security Framework** - <https://developers.uniswap.org/docs/protocols/v4/security>, and
its repository <https://github.com/uniswapfoundation/security-framework>.

It is self-directed (the Foundation says it neither reviews nor certifies anybody's result) and it answers a question
this kit deliberately does not: **how much outside assurance does THIS hook need?** The owner scores the hook on a set of
risk dimensions (complexity, custom math, external dependencies, liquidity held, expected value locked, team maturity,
upgradeability, autonomous parameters, price-impacting behaviour), the score gives a risk tier, and the tier - plus
feature triggers that override it, such as custom curves or a hook that holds liquidity - gives the expected minimum:
how many audits and of what kind, whether a bug bounty and monitoring are expected, when formal verification is
recommended. It also carries an operational-security section and a best-practices checklist.

Where it plugs into this route:

- **Phase 0.** The owner self-scores with the framework. The score, the tier and the feature triggers go in
  `DECISIONS.md`. It sizes the route (light or full, the ceiling) with somebody else's yardstick instead of a feeling.
- **Phase 1.** Each triggered feature is a prompt for the spec, next to `doctrine/HOOK-ATTACKS.md`.
- **Phase 8.** The dossier states the score and the tier, and which of the framework's recommendations for that tier are
  met, which are not, and which are outside this kit entirely (audits by named firms, a bounty, production monitoring,
  operational security). This kit produces the evidence a reviewer working to that framework will ask for; it does not
  replace one line of it.

Do not copy the framework's numbers into your documents: link it, and record the version or date you scored against.

## 3. A maintained base to inherit from

**OpenZeppelin `uniswap-hooks`** (MIT) - <https://github.com/OpenZeppelin/uniswap-hooks>, with a contract wizard at
<https://wizard.openzeppelin.com/uniswap-hooks>. The Foundation's checklist says to prefer maintained libraries over
hand-written foundations, and `doctrine/HOOK-ATTACKS.md` notes which classes a maintained base answers for you.
**Read the library's own README for its current audit status before you lean on it** - at the time of writing it
describes itself as experimental - and remember that inheriting a base moves a risk, it does not remove it: the classes
it covers become "covered by the base at version X", which is a line in the spec, with the version.

## 4. Tools the ecosystem lists that this kit has not evaluated

The framework's resource list names, among others, Echidna, Halmos, Certora, the Solidity SMTChecker, Scribble, and a
hook-specific checker by Hacken (<https://github.com/hknio/uni-v4-hooks-checker>). `doctrine/JUDGES.md` says which
QUESTION each kind of tool answers and how each kind lies; it has measured only the ones it names as measured. Using
another tool is a divergence of the welcome kind (`AGENTS.md` 6b): say which question it answers, and put it in the
dossier.

## 5. What this kit adds, so that you know what you are NOT getting from upstream

A route with gates, written for an agent; the adversarial loop and its stop rule; the rule that a test counts only once
seen red, and the scripts that enforce it on themselves; a hostile token and a hostile hook; one suite against both the
source manager and your chain's real manager; and a dossier that says what was not checked. None of that is a reason to
read less of the above.
