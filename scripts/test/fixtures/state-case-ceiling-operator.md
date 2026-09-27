<!-- selftest: judge=5=false,8=false,9=false,9b=true rows=2,9b rc=0 -->
# STATE - next.sh fixture: full mode, the owner absent, the ceiling SET BY THE OPERATOR (6 of 6 used), a medium open after r06: row 2 fires on the operator's ceiling, the owner is not there to triage - row 9b

*A fixture for scripts/next.sh (scripts/selftest.sh). The first line says how it is run and what it must give.*

```
phase:                     4
bytecode_changed_since:    last_battery=no  last_long_fuzz=no  last_other_free_judges=no  last_audit_round=no  last_promotion=n/a
battery:                   green
blackbox:                  never_run
open_findings:             high=0 medium=1 low=0 reasoned_high_or_medium=0
last_audit_round:          r06 regression 0H 1M 0L
last_other_round:          none
ceiling:                   6 model rounds, set by the operator (owner absent); 6 used
real_manager_battery:      current
waiting_on_owner:          none
location:                  .gauntlet/
dossier:                   none
rehearsal:                 n/a (no runbook)
notes:                     fork: the battery ran against the chain's pool manager at a pinned block
```
