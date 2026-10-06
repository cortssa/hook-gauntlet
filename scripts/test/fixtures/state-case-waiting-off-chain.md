<!-- selftest: judge=5=false rows=7b rc=0 -->
# STATE - next.sh fixture: before round 1, the chain known, the real manager never run; the owner is asked for an off-chain keeper address - not the chain, not RPC_URL: row 7b does not wait on that answer, it stands (a verifier's G03)

*A fixture for scripts/next.sh (scripts/selftest.sh). The first line says how it is run and what it must give.*

```
phase:                     4
bytecode_changed_since:    last_battery=no  last_long_fuzz=no  last_other_free_judges=no  last_audit_round=yes  last_promotion=n/a
battery:                   green
blackbox:                  never_run
open_findings:             high=0 medium=0 low=0 reasoned_high_or_medium=0
last_audit_round:          none
last_other_round:          none
ceiling:                   8 model rounds agreed; 0 used
real_manager_battery:      never
waiting_on_owner:          off-chain keeper address for spec row 4
location:                  root
dossier:                   none
rehearsal:                 n/a (no runbook)
notes:                     fork: n/a - a next.sh fixture, no chain
```
