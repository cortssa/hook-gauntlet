# DECISIONS - BlockCapHook

*Example file. The project is fictional. Delete this and start yours.*

Append only. One entry per decision the **owner** made. An agent never DECIDES here on the owner's behalf; it writes
the question in `STATE.md` and waits. Three kinds of entry that are not the owner's are written here too: an answer
read from the owner's own files when the interview is played from them, marked `source: <file>`; an assumption the
route makes when the owner is absent (light mode and its ceiling), marked `source: assumed, owner absent`; and a
ceiling the operator set in full mode with the owner absent, marked `source: operator (owner absent)`, with the reason
for its number (`doctrine/COST.md` 1). The operator is the person running the kit - in a run with no human, the
harness prompt that set the number, quoted in the entry. All three are the owner's to overturn.

---

## D-01 · 2026-02-27 · Scope: one pool per deployment

**Decision:** one hook instance serves one pool. No shared state between pools.
**Reason:** the owner does not want cross-pool accounting in v0, and shared balances were where they expected the
hard bugs to be.
**Consequence:** out of scope in `SPEC.md` section 7. Rounds should not spend budget on cross-pool interference.

## D-02 · 2026-02-27 · Assets: curated, by the owner, no registry contract

**Decision:** the paired asset is chosen by the owner at deployment. No on-chain admission logic.
**Reason:** an admission contract is more code than the hook itself.
**Consequence:** the runbook carries the admission checklist instead, and it is a **procedure**, not a guarantee.
Fee-on-transfer and rebasing assets are rejected at the door. An asset behind a proxy can gain a fee later; the
only defence is the owner noticing. Written into `SPEC.md` section 5 in those words.

## D-03 · 2026-03-02 · Immutable after deployment

**Decision:** no upgrade path, no pause.
**Reason:** the owner would rather have a contract that cannot be changed than a key that can change it.
**Consequence:** the shape of every event is frozen at deployment. Section 10 of the spec has to be right
**before** phase 6, not after. This is the reason the black-box round was moved earlier.

## D-04 · 2026-03-04 · threat T-9 refused: the surcharge is paid to the pool in the same swap, so the hook never holds a balance for a flash loan to take

**Decision:** the independent threat model's T-9 (a flash-loan borrower drains the surcharges the hook holds between
swaps) is refused, not turned into an invariant.
**Reason:** the surcharge is donated to the pool inside the swap that pays it; `SPEC.md` section 3 row 4 and
invariant 1 ("no swap can leave a token balance in the hook") already cover what T-9 assumed.
**Consequence:** `.gauntlet/reports/06-threats.txt` lists T-9 as refused, with this line. Of the other 14 independent
threats, 11 matched the walker's list and 3 were new to it, each now an invariant (`/// @custom:threat T-<n>`).

## D-05 · 2026-03-08 · `F-14` accepted as a trade-off

**Decision:** an address that splits one large swap across many addresses in the same block avoids the surcharge.
Accepted, not fixed.
**Number:** the attacker pays 41 900 gas per extra address, so avoiding a surcharge of *S* costs about
*S / 0.006* at the median gas price used in `runs/r03/gas.txt`; it stops being worth it below about 7 addresses.
LPs lose the avoided surcharge, nothing else.
**Reason:** the only fix the owner would accept is an allowlist, which contradicts D-02.
**Consequence:** row in `SPEC.md` section 6. Rounds re-measure it, they do not re-report it. If a round measures
it as **worse** than this, that is a finding.

## D-06 · 2026-03-11 · Compute: full mode

**Decision:** rounds continue until a DISCOVERY round closes with zero high and zero medium findings still open (not yet fixed, refused in writing, accepted by the owner with a number, or handed to the human audit by name), and no REASONED high or medium is left open.
**Reason:** the owner has a human audit booked for May and wants the time used.
**Consequence:** budget reviewed after every third round, from the ROUND lines of `LOG.md`.

## D-07 · 2026-03-14 · UNDECIDED: `F-24`

Whether to fix the sub-wei surcharge rounding (118 bytes) or accept 210 gas on every ordinary swap. Asked
2026-03-14. Deferred by the owner pending the round 6 gas numbers. Recorded here so it is not silently dropped.
