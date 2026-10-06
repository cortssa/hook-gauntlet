<!-- selftest: judge=5=false,8=false,9=false,10=false rows=none rc=2 refused=not-an-id -->
# STATE - next.sh fixture: V26b's probe a4 (row 1 was quiet by an id that is not an open high): 'high 1 - to tell' (the count written as an id), F-1 the open high: refused - not an id (an id has a letter and a digit, K29; before K29, refused as a recorded high that is not open)

*A fixture for scripts/next.sh (scripts/selftest.sh). The first line says how it is run and what it must give. The
selftest runs it a second time with the ids after `high=N` taken out of `open_findings`: refused (a count needs its ids).*

```
phase:                     4
bytecode_changed_since:    last_battery=no  last_long_fuzz=no  last_other_free_judges=no  last_audit_round=no  last_promotion=n/a
battery:                   green
blackbox:                  never_run
open_findings:             high=1 (F-1) medium=1 low=0 reasoned_high_or_medium=0
last_audit_round:          r01 discovery 1H 1M 0L
last_other_round:          none
ceiling:                   1 model rounds agreed; 1 used
real_manager_battery:      n/a (chain not chosen)
waiting_on_owner:          high 1 - to tell · triage of F-1 M-1
rehearsal:                 n/a (no runbook)
threat_model:              diffed (1 matched, 0 new, 0 refused)
location:                  .gauntlet/
dossier:                   skeleton (2 open, 2 judges not done)
notes:                     fork: n/a - a next.sh fixture, no chain
```
