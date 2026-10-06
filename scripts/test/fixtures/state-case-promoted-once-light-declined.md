<!-- selftest: judge=5=false,8=false,10=false,11b=false,16=false,18b=true rows=14,18b rc=0 -->
# STATE - next.sh fixture: light mode, promoted once for an early release, the source changed since (last_promotion=yes), the loop over again, the owner declines a new promotion in writing: row 18b

*A fixture for scripts/next.sh (scripts/selftest.sh). The first line says how it is run and what it must give.*

```
phase:                     4
bytecode_changed_since:    last_battery=no  last_long_fuzz=no  last_other_free_judges=no  last_audit_round=no  last_promotion=yes
battery:                   green
blackbox:                  current
open_findings:             high=0 medium=0 low=0 reasoned_high_or_medium=0
last_audit_round:          r06 discovery 0H 0M 1L
last_other_round:          b1 black-box no divergence
ceiling:                   4 model rounds (light mode: 3 + 1 black-box) agreed in phase 0; 3 used
real_manager_battery:      current
waiting_on_owner:          none
location:                  .gauntlet/
dossier:                   none
rehearsal:                 done (2026-03-22)
threat_model:              diffed (1 matched, 0 new, 0 refused)
notes:                     fork: the battery ran against the chain's pool manager at a pinned block
```
