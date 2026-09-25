<!-- selftest: judge=5=false,8=false,10=false,11b=false,16=false,18b=false rows=none rc=1 -->
# STATE - next.sh fixture: no row is true (full mode: loop over, the owner does not want to freeze, not light mode)

*A fixture for scripts/next.sh (scripts/selftest.sh). The first line says how it is run and what it must give.*

```
phase:                     4
bytecode_changed_since:    last_battery=no  last_long_fuzz=no  last_other_free_judges=no  last_audit_round=no  last_promotion=n/a
battery:                   green
blackbox:                  current
open_findings:             high=0 medium=0 low=0 reasoned_high_or_medium=0
last_audit_round:          r04 discovery 0H 0M 1L
last_other_round:          none
ceiling:                   8 model rounds (adversarial + black-box) agreed in phase 0; 3 used
real_manager_battery:      current
waiting_on_owner:          none
location:                  .gauntlet/
dossier:                   none
notes:                     fork: the battery ran against the chain's pool manager at a pinned block
```
