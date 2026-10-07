<!-- selftest: judge=5=false,8=false,10=false,11b=false,12=true rows=14,15 rc=0 -->
# STATE - next.sh fixture: the loop is over (a clean discovery round), the black-box never ran: row 14 is a gate, so 15 and not 12

*A fixture for scripts/next.sh (scripts/selftest.sh). The first line says how it is run and what it must give.*

```
phase:                     4
bytecode_changed_since:    last_battery=no  last_long_fuzz=no  last_other_free_judges=no  last_audit_round=no  last_promotion=n/a
battery:                   green
blackbox:                  never_run
open_findings:             high=0 medium=0 low=0 reasoned_high_or_medium=0
last_audit_round:          r04 discovery 0H 0M 1L
last_other_round:          none
ceiling:                   8 model rounds (adversarial + black-box) agreed in phase 0; 3 used
real_manager_battery:      current
waiting_on_owner:          none
location:                  .gauntlet/
dossier:                   none
rehearsal:                 n/a (no runbook)
threat_model:              diffed (1 matched, 0 new, 0 refused, 0 handed)
notes:                     fork: the battery ran against the chain's pool manager at a pinned block
```
