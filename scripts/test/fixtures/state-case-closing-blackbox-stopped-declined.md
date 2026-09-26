<!-- selftest: judge=5=false,8=false,10=false,11b=false,16=false,18b=true rows=14,18b rc=0 -->
# STATE - next.sh fixture: the same stopped closing black-box, the owner declined promotion in writing: row 18b, the dossier says black-box: stopped at step 2

*A fixture for scripts/next.sh (scripts/selftest.sh). The first line says how it is run and what it must give.*

```
phase:                     4
bytecode_changed_since:    last_battery=no  last_long_fuzz=no  last_other_free_judges=no  last_audit_round=no  last_promotion=n/a
battery:                   green
blackbox:                  stopped (b1)
open_findings:             high=0 medium=0 low=0 reasoned_high_or_medium=0
last_audit_round:          r02 discovery 0H 0M 0L
last_other_round:          none
ceiling:                   8 model rounds (adversarial + black-box) agreed in phase 0; 4 used
real_manager_battery:      current
waiting_on_owner:          none
location:                  .gauntlet/
dossier:                   skeleton
rehearsal:                 n/a (no runbook)
notes:                     fork: the battery ran against the chain's pool manager at a pinned block; round b1 stopped (retried once, stopped again at step 2; counts as spent)
```
