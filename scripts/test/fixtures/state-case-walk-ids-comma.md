<!-- selftest: judge=none rows=2,5,8,9,9b,10,STOP? rc=3 -->
# STATE - next.sh fixture: a real walk's last STATE.md (an A/B run, owner absent, ceiling 1 of 1): four highs recorded to tell in ONE item, ids between commas - row 1 is quiet (each of the 4 open highs named in open_findings is recorded; the walk wrote open_findings without ids - K28 added them from its own comment); the skeleton counted informational findings in K (8, not the 6 open), so row 9b still asks; rows still to judge: no STOP line yet, the conditional one

*A fixture for scripts/next.sh (scripts/selftest.sh). The first line says how it is run and what it must give.*

```
phase:                     4
bytecode_changed_since:    last_battery=no  last_long_fuzz=no  last_other_free_judges=no  last_audit_round=no  last_promotion=n/a
battery:                   green
blackbox:                  never_run
open_findings:             high=4 (F-P2, F-P3, F-P4, r01-A1) medium=1 low=1 reasoned_high_or_medium=0   (F-P2 F-P3 F-P4 r01-A1 high; F-P1 medium; r01-A3 low - severities as r01 classified them; owner triage pending)
last_audit_round:          r01 discovery 4H 1M 1L
last_other_round:          none
ceiling:                   1 model rounds (session instruction, owner absent: DECISIONS D-03); 1 used
real_manager_battery:      n/a (chain not chosen)
waiting_on_owner:          high F-P2, F-P3, F-P4, r01-A1 - to tell · triage of F-P1 F-P2 F-P3 F-P4 r01-A1 r01-A2 r01-A3 r01-A4 · read-back of scope · Q0 still moving? · chain · the undecided interview items D-01, D-04..D-10 · raise the ceiling?
rehearsal:                 n/a (no runbook)
threat_model:              diffed (1 matched, 0 new, 0 refused, 0 handed)
location:                  .gauntlet/
dossier:                   skeleton (8 open, 5 judges not done)
notes:                     static triage: forge lint only, Slither not installed · pending: F-P1 - promise 2, owner undecided · pending: F-P2 - handover, owner undecided · pending: F-P3 - promises 5/6, owner undecided · pending: F-P4 - promise 3, owner undecided · not fuzzable: constructor/flags - deployment · fork: n/a - no chain chosen, no endpoint · real manager: n/a, chain not chosen
```
