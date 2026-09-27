<!-- selftest: judge=5=false,8=false,9=false,9b=true rows=9b rc=0 -->
# STATE - next.sh fixture: the same pause, then round 2 opened a third finding: the skeleton names 2, open_findings says 3 - row 9b stands again (the skeleton is stale)

*A fixture for scripts/next.sh (scripts/selftest.sh). The first line says how it is run and what it must give.*

```
phase:                     4
bytecode_changed_since:    last_battery=no  last_long_fuzz=no  last_other_free_judges=no  last_audit_round=no  last_promotion=n/a
battery:                   green
blackbox:                  current
open_findings:             high=0 medium=1 low=2 reasoned_high_or_medium=0
last_audit_round:          r02 regression 0H 0M 1L
last_other_round:          b1 black-box no divergence
ceiling:                   4 model rounds (light mode) agreed in phase 0; 2 used
real_manager_battery:      current
waiting_on_owner:          triage of F-1, F-2
location:                  .gauntlet/
dossier:                   skeleton (2 open, 1 judge not done)
rehearsal:                 n/a (no runbook)
notes:                     fork: the battery ran against the chain's pool manager at a pinned block
```
