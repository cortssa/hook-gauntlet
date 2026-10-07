<!-- selftest: judge=5=false,8=false,10=false,11b=false,16=true,18b=false rows=14,STOP rc=0 -->
# STATE - next.sh fixture: the loop is over, the owner wants to freeze, but the real manager never ran and 7b waits on RPC_URL: row 16 is off until 7b has run, nothing else stands - row 3 pauses the route (STOP) and says what is waiting

*A fixture for scripts/next.sh (scripts/selftest.sh). The first line says how it is run and what it must give.*

```
phase:                     5
bytecode_changed_since:    last_battery=no  last_long_fuzz=no  last_other_free_judges=no  last_audit_round=no  last_promotion=n/a
battery:                   green
blackbox:                  current
open_findings:             high=0 medium=0 low=0 reasoned_high_or_medium=0
last_audit_round:          r01 discovery 0H 0M 0L
last_other_round:          b1 black-box no divergence
ceiling:                   8 model rounds (adversarial + black-box) agreed in phase 0; 3 used
real_manager_battery:      never
waiting_on_owner:          RPC_URL for the real-manager battery
location:                  .gauntlet/
dossier:                   none
rehearsal:                 n/a (no runbook)
threat_model:              diffed (1 matched, 0 new, 0 refused, 0 handed)
notes:                     fork: ran on a fork
```
