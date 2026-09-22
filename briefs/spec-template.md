# Template: the falsifiable spec (phase 1)

The spec is not documentation. It is the **contract you hand an auditor so it can try to prove you wrong**.

Three properties make it work, and dropping any one of them collapses the method:

1. **Section 3 is a table**, one row per thing a hostile actor can do, with the contract's answer. An auditor's job
   becomes falsifying rows. In the project this was distilled from, three of the five high findings of the whole
   series were "the fix is correct and the sentence that closes it is false" - a finding that only exists because
   there were sentences.
2. **Every number in it is a measured number**, corrected each revision. A wrong number here is a guaranteed
   finding next round, which is a wasted round.
3. **Section 9 aims the next round.** Write it last, and aim it at what you trust least.

Keep it in the project, next to the code, versioned per revision, with a consolidated "current" copy that ships
with the code.

The examples below use a fictional hook, `BlockCapHook`, which caps how much one address may swap in a single
block and charges a surcharge above a threshold. Replace all of it.

---

# SPEC - {{PROJECT}} {{REVISION}}

Battery: {{TESTS}} passing · size {{SIZE}} (margin {{MARGIN}}) · long fuzz {{FUZZ}} · {{N}} adversarial rounds,
{{M}} black-box rounds. **Not deployed. Not audited by humans.**

## 1. What this is, in one paragraph

{{ONE_PARAGRAPH}} - what the hook does, who uses it, and what it is for. A reader who stops here should be able to
say what would make it a failure.

## 2. The principle

The single design idea the whole contract follows. One or two sentences. If you cannot write it, the design is not
finished, and every round afterwards will be more expensive.

*Example: "Every swap is metered against a per-address per-block budget. Exceeding the budget is never a revert;
it is a surcharge, and the surcharge is paid to the liquidity providers of that pool."*

Then the **answer taxonomy**: name the classes of misbehaviour and the one answer the contract gives to each.
Doing this once, explicitly, is what stops the contract becoming a pile of special cases.

| who misbehaves | the contract's answer | why |
|---|---|---|
| {{CLASS_1}} | {{ANSWER_1}} | {{REASON_1}} |
| {{CLASS_2}} | {{ANSWER_2}} | {{REASON_2}} |

Rules of thumb when you choose the answers: a misbehaving counterparty must never be able to **deny the contract
to everybody else**; a silent block where a named error belongs makes value disappear with no public culprit; and
a revert where a graceful exclusion belongs converts one bad actor into a denial of service that everyone pays
for. Choose deliberately, write it down, and hold the line.

## 3. What a hostile actor can do -> what the contract answers

The core of the document. One row per capability, not per attack. Cover **every external entry point**, and walk
`doctrine/HOOK-ATTACKS.md`: each class there ends up here (it applies), in section 5 (prevented by an admission rule, with its
probe), in section 6 (accepted) or in section 7 (does not apply to this hook, and why).

| a hostile actor can ... | the contract answers | proved by (test, and its evidence label - `doctrine/EVIDENCE.md`) | reached in the campaign by (action in 4b, and the census boundary that shows it) | the mutant that test was seen to kill |
|---|---|---|---|---|
| *call the swap callback directly, not through the pool manager* | *reverts `NotPoolManager`* | `test_direct_callback_reverts` | *`strangerCallsCallback`; boundary "callback refused a stranger"* | *`msg.sender != manager` -> `false`* |
| *make the paired token revert inside the transfer* | *the surcharge transfer is attempted once; on failure the swap reverts with `SurchargeFailed(token)` and nothing is left in the hook* | `test_token_reverts_on_surcharge` | *`setPaused` + `swap`; boundary "swap refused: surcharge failed"* | *the revert removed* |
| *split one large swap across many addresses in one block* | *not prevented - documented trade-off, see 6* | `test_sybil_split_costs` | *`swapBurst` over several actors* | *n/a - nothing is promised* |
| {{ROW}} | {{ANSWER}} | {{TEST}} | {{ACTION_AND_BOUNDARY}} | {{MUTANT}} |

The last two columns are what makes this table checkable instead of persuasive. A row says the contract survives
something; the fourth column names the handler action that can actually PRODUCE that something, in both directions
of the call, and the boundary in the campaign census (`scripts/census.sh`) that shows it happened; the fifth names
the broken version of the code that the test was watched failing on. **An empty cell is a statement**: that row is
defended by text. This kit's own example shipped a threat-model line that no action could reach, and then a second
one whose defence did not do what the line said - both found by reviewers, both invisible in a three-column table.
Carry the table into the handoff dossier as it stands, empty cells included: it tells the auditor where not to look.

Write the **answer**, not the mechanism. "Reverts with `X`" and "the entry is removed and the transaction
continues" are answers. "The `_check` function handles it" is not.

When a fix changes the contract at the level of a cause, **walk this whole table again** and write what the
contract does now for each row. A cause-level fix always changes more rows than you expect, and the rows it
changed by accident are where the next finding lives.

## 4. Invariants, in words

ADAPT: the generic assertions that ship with the kit are the floor. Derive the ones that only make sense for this
hook, backwards from who can lose what (`doctrine/INVARIANTS.md`). Include at least one about what the contract
SAYS (quote equals execution; events rebuild the state), not only about where the money went.

Written so a human can judge them and an agent can turn each into an invariant test.

1. *No swap can leave a token balance in the hook.*
2. *The surcharge collected in a block never exceeds the sum of the surcharges owed by the swaps in that block.*
3. *No caller can reduce another caller's remaining budget.*
4. {{INVARIANT}}

For each, say **which test proves it** and whether it is checked by a unit test, by the invariant suite, or only
by reasoning. "Only by reasoning" is an honest answer and is a target for the next round.

## 4b. Fuzz actions, in words

ADAPT: list every action the handler will be able to take, before writing it (`doctrine/FUZZ-ACTIONS.md`): one per
external entry point and kind of caller; the clock, across every time boundary in this spec; each hostile-token
switch that matters here, flippable mid-campaign; the strange actors; the quotes and views, checked against what
just happened. An action that is not on this list is a behaviour the campaign can never reach.

| action | who calls it | what it must be able to reach |
|---|---|---|
| {{ACTION}} | {{CALLER}} | {{BRANCH_OR_BOUNDARY}} |

## 5. Configuration and admission rules

What must be true of a pool, an asset or an operator before this contract is used with it - and **who enforces
it**: the contract, the deployer, or a procedure in the runbook. A rule enforced by a procedure that does not
exist is not a rule.

Include: what is checked at admission, what can change **after** admission (an asset behind a proxy can gain a
fee later), and what the contract does about it.

## 5b. The assumptions this whole document stands on

Which assets matter, which actors exist, what is trusted and why, what the tokens are assumed to do, what liquidity or
price conditions are assumed. One row each, with what breaks if it is false. This table is an attack surface: a
discovery round is pointed at it (`doctrine/EVIDENCE.md` 8). It is the only defence here against proving the wrong
theorem carefully.

| assumption | why we believe it | what breaks if it is false | evidence (label) |
|---|---|---|---|
| {{ASSUMPTION}} | {{WHY}} | {{BREAKS}} | {{EVIDENCE}} |

## 6. Accepted trade-offs, each with a number

Every finding that was accepted rather than fixed. Without the numbers this section is decoration.

| id | what an attacker achieves | who loses, how much | cost to the attacker | conditions | why not fixed |
|---|---|---|---|---|---|
| {{ID}} | {{ACHIEVES}} | {{LOSS}} | {{COST}} | {{CONDITIONS}} | {{REASON}} |

## 7. Out of scope

Explicit. Everything here is a thing rounds should **not** spend budget on, and every reader should know is not
covered. Include the token behaviours marked "rejected at the door" in phase 0, the chains you are not targeting,
and the off-chain components whose failure you are not defending against.

## 8. Measured numbers

Sizes and margins, gas on a fork for the main paths, every limit and ceiling, the test count, the fuzz campaign
size. State the **margin the owner wants kept** for future fixes (`scripts/size.sh`, `MIN_MARGIN`): a fix that
does not fit is a finding. **All read from outputs this revision.** Keep a list here of every other document that repeats any of these
numbers, so the stale-number sweep in phase 6 knows where to look.

## 9. Surface for the next round

Where you have least confidence, in order. Written **after** the fixes, not before. Include what you changed
without fully understanding - being honest here is the single cheapest thing in the method.

## 10. What an outside consumer sees

Every event and every public view, and what each means to someone reconstructing state from outside. Then the
harder half: **what the log does not say**. A state change with no event, two different histories that leave
identical logs, an event that can be read backwards from what happened.

Write this section before deployment even if no indexer exists yet. On an immutable contract the shape of the
events is frozen forever, and this is the cheapest moment it will ever be.
