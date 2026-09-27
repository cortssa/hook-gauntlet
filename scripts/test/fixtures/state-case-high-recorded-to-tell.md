<!-- selftest: judge=5=false,8=false,9=false,10=false,11b=false rows=STOP rc=0 -->
# STATE - next.sh fixture: a high open, the owner away: it is recorded as high F-1 - to tell in waiting_on_owner, and the skeleton names it - row 1 is quiet by the flags, row 9b too: paused on the owner (STOP)

*A fixture for scripts/next.sh (scripts/selftest.sh). The first line says how it is run and what it must give.*

```
phase:                     4
bytecode_changed_since:    last_battery=no  last_long_fuzz=no  last_other_free_judges=no  last_audit_round=no  last_promotion=n/a
battery:                   green
blackbox:                  current
open_findings:             high=1 medium=0 low=0 reasoned_high_or_medium=0
last_audit_round:          r01 discovery 1H 0M 0L
last_other_round:          b1 black-box no divergence
ceiling:                   4 model rounds (light mode) agreed in phase 0; 2 used
real_manager_battery:      current
waiting_on_owner:          high F-1 - to tell · triage of F-1
location:                  .gauntlet/
dossier:                   skeleton (1 open, 1 judge not done)
rehearsal:                 n/a (no runbook)
notes:                     fork: the battery ran against the chain's pool manager at a pinned block
```
