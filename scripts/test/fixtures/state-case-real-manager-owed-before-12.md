<!-- selftest: judge=3=false,5=false,8=false,10=false,11b=false,12=true rows=13b rc=0 -->
# STATE - next.sh fixture: the chain known, the real manager never run, 7b silenced by the wait for RPC_URL: row 12 (the black-box) is off until 7b has run - the next row that stands is 13b

*A fixture for scripts/next.sh (scripts/selftest.sh). The first line says how it is run and what it must give.*

```
phase:                     5
bytecode_changed_since:    last_battery=no  last_long_fuzz=no  last_other_free_judges=no  last_audit_round=no  last_promotion=n/a
battery:                   green
blackbox:                  never_run
open_findings:             high=0 medium=0 low=0 reasoned_high_or_medium=0
last_audit_round:          r01 regression 0H 0M 0L
last_other_round:          none
ceiling:                   8 model rounds (adversarial + black-box) agreed in phase 0; 3 used
real_manager_battery:      never
waiting_on_owner:          RPC_URL for the real-manager battery
location:                  .gauntlet/
dossier:                   none
rehearsal:                 n/a (no runbook)
notes:                     fork: ran on a fork
```
