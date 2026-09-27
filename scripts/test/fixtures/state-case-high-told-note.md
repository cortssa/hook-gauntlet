<!-- selftest: judge=1=false,5=false,8=false,9=true rows=9 rc=0 -->
# STATE - next.sh fixture: a high open, the owner present and told (a told: note says so): the note is NOT read - row 1 asks, and the agent answers 1=false; row 9 triages it

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
waiting_on_owner:          none
location:                  .gauntlet/
dossier:                   none
rehearsal:                 n/a (no runbook)
notes:                     fork: the battery ran against the chain's pool manager at a pinned block
                           told: F-1 (2026-09-27, with its test)
```
