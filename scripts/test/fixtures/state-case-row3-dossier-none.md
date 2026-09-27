<!-- selftest: judge=5=false,8=false,9=false,9b=true rows=2,9b rc=0 -->
# STATE - next.sh fixture: the owner away after round 1, a high (recorded to tell) and a medium open, NO dossier yet: row 3 is true, and row 9b below it stands (judged) - it is given; row 3 is never answered (V26b: `--judge 3=true` gave the pause over it)

*A fixture for scripts/next.sh (scripts/selftest.sh). The first line says how it is run and what it must give.*

```
phase:                     4
bytecode_changed_since:    last_battery=no  last_long_fuzz=no  last_other_free_judges=no  last_audit_round=no  last_promotion=n/a
battery:                   green
blackbox:                  never_run
open_findings:             high=1 medium=1 low=0 reasoned_high_or_medium=0
last_audit_round:          r01 discovery 1H 1M 0L
last_other_round:          none
ceiling:                   1 model rounds agreed; 1 used
real_manager_battery:      n/a (chain not chosen)
waiting_on_owner:          high F-1 - to tell · triage of F-1 M-1
rehearsal:                 n/a (no runbook)
location:                  .gauntlet/
dossier:                   none
notes:                     the fixture of V26b's probe d3
```
