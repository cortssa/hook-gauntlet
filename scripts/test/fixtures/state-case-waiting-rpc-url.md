<!-- selftest: judge=3=false,5=false,11b=false rows=11 rc=0 -->
# STATE - next.sh fixture: before round 1, the chain known, the real manager never run, the owner asked for RPC_URL: row 7b waits on the owner, so row 3 skips it and round 1 goes on (row 11)

*A fixture for scripts/next.sh (scripts/selftest.sh). The first line says how it is run and what it must give.*

```
phase:                     4
bytecode_changed_since:    last_battery=no  last_long_fuzz=no  last_other_free_judges=no  last_audit_round=yes  last_promotion=n/a
battery:                   green
blackbox:                  never_run
open_findings:             high=0 medium=0 low=0 reasoned_high_or_medium=0
last_audit_round:          none
last_other_round:          none
ceiling:                   8 model rounds (adversarial + black-box) agreed in phase 0; 0 used
real_manager_battery:      never
waiting_on_owner:          RPC_URL for the real-manager battery (row 7b), asked 2026-09-20
location:                  .gauntlet/
dossier:                   none
rehearsal:                 n/a (no runbook)
notes:                     fork: the invariant suite ran on a fork of the target chain
```
