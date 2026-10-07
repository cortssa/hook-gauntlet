<!-- selftest: judge=5=false,8=false,10=false,16=false,18b=true rows=2,14,18b rc=0 -->
# STATE - next.sh fixture: full mode at the ceiling (8 of 8), every finding triaged, the black-box never run, the owner declines promotion in writing: row 18b in full mode too

*A fixture for scripts/next.sh (scripts/selftest.sh). The first line says how it is run and what it must give.*

```
phase:                     4
bytecode_changed_since:    last_battery=no  last_long_fuzz=no  last_other_free_judges=no  last_audit_round=no  last_promotion=n/a
battery:                   green
blackbox:                  never_run
open_findings:             high=0 medium=0 low=0 reasoned_high_or_medium=0
last_audit_round:          r08 regression 0H 1M 0L
last_other_round:          none
ceiling:                   8 model rounds (full mode) agreed in phase 0; 8 used
real_manager_battery:      current
waiting_on_owner:          none
location:                  .gauntlet/
dossier:                   none
rehearsal:                 n/a (no runbook)
threat_model:              diffed (1 matched, 0 new, 0 refused, 0 handed)
notes:                     fork: the battery ran against the chain's pool manager at a pinned block
```
