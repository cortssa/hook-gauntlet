<!-- selftest: judge=5=false,8=false,9=false,10=false,11b=false rows=STOP rc=0 -->
# STATE - next.sh fixture: row 3 - waiting on the owner, no row below standing on the flags and every row below that needs judgement answered false: the pause, STOP (decided by the flags; row 3 itself is never answered)

*A fixture for scripts/next.sh (scripts/selftest.sh). The first line says how it is run and what it must give.*

```
phase:                     4
bytecode_changed_since:    last_battery=no  last_long_fuzz=no  last_other_free_judges=no  last_audit_round=no  last_promotion=n/a
battery:                   green
blackbox:                  current
open_findings:             high=0 medium=1 low=0 reasoned_high_or_medium=0
last_audit_round:          r03 regression 0H 1M 0L
last_other_round:          none
ceiling:                   8 model rounds (adversarial + black-box) agreed in phase 0; 3 used
real_manager_battery:      current
waiting_on_owner:          triage of F-9 · chain - which one?
location:                  .gauntlet/
dossier:                   skeleton (1 open, 1 judge not done)
rehearsal:                 n/a (no runbook)
threat_model:              diffed (1 matched, 0 new, 0 refused, 0 handed)
notes:                     fork: the battery ran against the chain's pool manager at a pinned block
```
