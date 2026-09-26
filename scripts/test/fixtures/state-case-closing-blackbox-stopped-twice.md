<!-- selftest: judge=5=false,8=false,10=false,11b=false,16=true rows=14,16 rc=0 -->
# STATE - next.sh fixture: the closing black-box was stopped twice by the environment (blackbox: stopped (b1)): row 15 no longer fires, the owner wants to freeze - row 16

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
