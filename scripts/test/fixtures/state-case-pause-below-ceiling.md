<!-- selftest: judge=none rows=5,8,9,10,11b,12,STOP? rc=3 -->
# STATE - next.sh fixture: the same, BELOW the ceiling (2 of 4): the black-box (row 12) and a retry (11b) still to judge - the conditional STOP line, never "because: no row below row 3 stands" while one may

*A fixture for scripts/next.sh (scripts/selftest.sh). The first line says how it is run and what it must give.*

```
phase:                     4
bytecode_changed_since:    last_battery=no  last_long_fuzz=no  last_other_free_judges=no  last_audit_round=no  last_promotion=n/a
battery:                   green
blackbox:                  never_run
open_findings:             high=1 (F-1) medium=1 low=0 reasoned_high_or_medium=0
last_audit_round:          r02 discovery 1H 1M 0L
last_other_round:          none
ceiling:                   4 model rounds agreed; 2 used
real_manager_battery:      n/a (chain not chosen)
waiting_on_owner:          high F-1 - to tell · triage of F-1 F-2
location:                  .gauntlet/
dossier:                   skeleton (2 open, 3 judges not done)
rehearsal:                 n/a (no runbook)
threat_model:              diffed (1 matched, 0 new, 0 refused)
notes:                     static triage: forge lint only, Slither not installed · fork: n/a - no chain
```
