# STATE - BlockCapHook

*Example file. The project is fictional. Delete this and start yours.*

**Phase 4 of 9** - adversarial loop. Revision r05. Updated 2026-03-14.

```
phase:                     4          (sketch | 0-8)
bytecode_changed_since:    last_battery=no  last_long_fuzz=no  last_other_free_judges=no  last_audit_round=yes  last_promotion=n/a
battery:                   green
blackbox:                  never_run
open_findings:             high=0 medium=0 low=1 reasoned_high_or_medium=0   (the low is F-24: waiting on the owner, see below)
last_audit_round:          r05 regression 0H 1M 4L
last_other_round:          none
real_manager_battery:      n/a        (n/a | never | stale | current)
ceiling:                   8 model rounds (adversarial + black-box) agreed in phase 0; 5 used
waiting_on_owner:          F-24, accept or fix (does not block round 6)
```

*These lines are what `doctrine/NEXT.md` reads. With them as they stand: row 1 is false (no high is waiting); row 2 is false (5 of 8 used); row 3 is true (F-24 is with the owner) but nothing below depends on that answer; the next true row is the black-box round (row
12): a round has run, the battery is green, and it has never been run. It goes before round 6.*

## Where we are

Round 5 closed: 0 high, 1 medium, 4 low, 7 informational. The medium (`F-21`) is fixed at the cause; the four lows
are fixed; one informational is refused and written into the spec. The exit criterion is **not** met: the black-box round comes
first (it has never run), then round 6.

Battery: 88 passing (84 unit + 2 fork + 2 invariant). Hook runtime 21 104 bytes, margin 3 472. Long fuzz
1000 x 128; census: every core action succeeded in at least 700 of the 1000 runs, 0 runs with an unexplained revert. All read from `runs/r05/battery.txt` this session.

## Open, blocking

1. **Owner decision needed on `F-24`** (low, accepted or fixed). Charging the surcharge when the budget is
   exceeded by less than one wei costs every ordinary swap 210 gas. Fixing it costs 118 bytes. Asked 2026-03-14,
   not answered. *Blocks: nothing. Round 6 can run either way.*
2. **A second-vendor round is still owed.** Rounds 1-5 all ran on one model family. The plan is for the black-box
   round (phase 5) to run elsewhere. Availability not yet confirmed with the owner.

## Open, not blocking

3. The invariant suite does not yet exercise the surcharge path with a token that has 6 decimals. Noted in round
   4, still true.
4. `SPEC.md` section 8 repeats the sizes in three places; add them to the stale-number list before phase 6.

## Next

The black-box round (row 12). After it, round 6 - a regression round aimed at: the r05 cause-level fix to the budget accounting (a new guard on the hot path), and the
Sybil-split trade-off, which round 3 measured and nobody has re-measured since.

## Not verified

The fork test runs against a single pinned block. Nobody has checked behaviour across a block where the base fee
moves sharply. Noted since round 2.
