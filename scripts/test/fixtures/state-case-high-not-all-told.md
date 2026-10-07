<!-- selftest: judge=1=true rows=1 rc=0 -->
# STATE - next.sh fixture: two highs open, only one recorded to tell: the flags cannot quiet row 1 (F-1 recorded, F-2 open and not), so it is asked - answered true, row 1

*A fixture for scripts/next.sh (scripts/selftest.sh). The first line says how it is run and what it must give.*

```
phase:                     4
bytecode_changed_since:    last_battery=no  last_long_fuzz=no  last_other_free_judges=no  last_audit_round=no  last_promotion=n/a
battery:                   green
blackbox:                  current
open_findings:             high=2 (F-1, F-2) medium=0 low=0 reasoned_high_or_medium=0
last_audit_round:          r01 discovery 2H 0M 0L
last_other_round:          b1 black-box no divergence
ceiling:                   4 model rounds (light mode) agreed in phase 0; 2 used
real_manager_battery:      current
waiting_on_owner:          high F-1 - to tell
location:                  .gauntlet/
dossier:                   none
rehearsal:                 n/a (no runbook)
threat_model:              diffed (1 matched, 0 new, 0 refused, 0 handed)
notes:                     fork: the battery ran against the chain's pool manager at a pinned block
```
