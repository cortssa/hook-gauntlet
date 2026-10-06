<!-- selftest: judge=5=false,8=false,9=false,10=false rows=2,STOP rc=0 -->
# STATE - next.sh fixture: the end of a real walk with the owner absent (its flag block as written): one discovery round, the operator's ceiling of 1 reached, four phase-3 findings in pending/ and six from the round, the three highs recorded to tell, the skeleton written naming the 10 open - row 10 is false (only the route's own files changed since the round: the skeleton, STATE.md, LOG.md), and the route PAUSES on the owner (STOP)


*A fixture for scripts/next.sh (scripts/selftest.sh). The first line says how it is run and what it must give. The
selftest also runs it as `.gauntlet/STATE.md` of a project whose `pending/` holds the four tests its notes name.*

```
phase:                     4
bytecode_changed_since:    last_battery=no  last_long_fuzz=no  last_other_free_judges=no  last_audit_round=no  last_promotion=n/a
battery:                   green
blackbox:                  never_run
open_findings:             high=3 (F-2, F-3, F-4) medium=5 low=2 reasoned_high_or_medium=0
last_audit_round:          r01 discovery 3H 5M 2L
last_other_round:          none
ceiling:                   1 model rounds, set by the operator (owner absent); 1 used
real_manager_battery:      n/a (chain not chosen)
waiting_on_owner:          triage of F-1, F-2, F-3, F-4, r01-N1, r01-N2, r01-N3, r01-N5, r01-N4, r01-R2 · high F-2, F-3, F-4 - to tell · read-back of scope and spec · chain · who decides trade-offs · reason for symbolic not run · reason for reference model not run · reason for second engine not run · framework self-score
location:                  .gauntlet/
dossier:                   skeleton (10 open, 6 judges not done)
rehearsal:                 n/a (no runbook)
threat_model:              diffed (1 matched, 0 new, 0 refused)
notes:                     static triage: forge lint only, Slither not installed
                           fork: n/a - no chain chosen (D-17), no endpoint; not done
                           pending: F-1 - promise 2 (epoch 0 starts at initialization), owner undecided
                           pending: F-2 - "Who" two-step handover / promise 7, owner undecided
                           pending: F-3 - promise 3 (volume in currency0), owner undecided
                           pending: F-4 - promises 5, 6 (nothing paid after the sweep), owner undecided
```
