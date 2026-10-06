<!-- selftest: judge=5=false,11b=false rows=11 rc=0 -->
# STATE - next.sh fixture: a phase-3 pending medium before round 1: no triage is asked before a round (rows 9 and 9b are off), it rides into round 1 (row 11)

*A fixture for scripts/next.sh (scripts/selftest.sh). The first line says how it is run and what it must give.*

```
phase:                     4
bytecode_changed_since:    last_battery=no  last_long_fuzz=no  last_other_free_judges=no  last_audit_round=yes  last_promotion=n/a
battery:                   green
blackbox:                  never_run
open_findings:             high=0 medium=1 low=0 reasoned_high_or_medium=0
last_audit_round:          none
last_other_round:          none
ceiling:                   8 model rounds (adversarial + black-box) agreed in phase 0; 0 used
real_manager_battery:      current
waiting_on_owner:          none
location:                  .gauntlet/
dossier:                   none
rehearsal:                 n/a (no runbook)
threat_model:              diffed (1 matched, 0 new, 0 refused)
notes:                     fork: the battery ran against the chain's pool manager at a pinned block
                           pending: P-1 - the fee never exceeds the cap under a fee-on-transfer token, owner undecided
```
