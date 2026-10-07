<!-- selftest: judge=5=false,8=false,9=false,10=false,11b=false rows=STOP rc=0 -->
# STATE - next.sh fixture: the owner away after round 1, a medium and a low open, the skeleton written naming both (2 open) and the triage asked: row 9b is quiet, nothing else stands - the route is PAUSED on the owner (STOP), not at a hole

*A fixture for scripts/next.sh (scripts/selftest.sh). The first line says how it is run and what it must give.*

```
phase:                     4
bytecode_changed_since:    last_battery=no  last_long_fuzz=no  last_other_free_judges=no  last_audit_round=no  last_promotion=n/a
battery:                   green
blackbox:                  current
open_findings:             high=0 medium=1 low=1 reasoned_high_or_medium=0
last_audit_round:          r01 discovery 0H 1M 1L
last_other_round:          b1 black-box no divergence
ceiling:                   4 model rounds (light mode) agreed in phase 0; 2 used
real_manager_battery:      current
waiting_on_owner:          triage of F-1, F-2
location:                  .gauntlet/
dossier:                   skeleton (2 open, 1 judge not done)
rehearsal:                 n/a (no runbook)
threat_model:              diffed (1 matched, 0 new, 0 refused, 0 handed)
notes:                     fork: the battery ran against the chain's pool manager at a pinned block
```
