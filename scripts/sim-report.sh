#!/usr/bin/env bash
#
# sim-report.sh - add up the lines the simulation ledger wrote, over as many runs as were made.
#
# The problem it solves: one scenario run is one draw. `SimLedger.write` appends one line per agent per run to the
# file named by GAUNTLET_SIM; this prints, per scenario label and agent, the number of runs and the per-run mean of
# every column - so that a result is reported as "over N runs" and never as a single line read off a log.
#
# Usage:   scripts/sim-report.sh <file>          (the file GAUNTLET_SIM pointed at; census/sim.tsv by convention)
# Exit:    0 printed; 2 the file is empty or missing (NOTHING MEASURED).
#
# Columns of a line (tab separated, written by SimLedger.line):
#   label  agent  decided  executed  refused  in  out  quoted  shortfall  worst  windfall  gas  pnl  gasCost  pnlNet
# `pnl` is gross; `gasCost` is the gas at the scenario's price in raw quote units, and `pnlNet` = pnl - gasCost.
# Lines from a ledger that did not price gas have 13 fields: they still count in every other column, their gas
# columns are left out of the gasCost and net means, and a NOTE says how many. So every mean says what it is over:
# `runs` for the columns up to pnl/run, `priced` for gasCost/run and net/run. When the two differ (a group that mixes
# priced and unpriced lines) pnl/run - net/run is NOT gasCost/run, and a NOTE names the group. A group with no priced
# line prints "-" for both: an unpriced run is not a free one.

set -uo pipefail
[ -s "${1:-}" ] || { echo "sim-report: ${1:-<no file>} is empty or missing. NOTHING MEASURED."; exit 2; }
awk -F '\t' '
  { sub(/\r$/, ""); if (NF < 13) { bad++; next }
    k = $1 SUBSEP $2; if (!(k in n)) order[++m] = k
    n[k]++; for (i = 3; i <= 13; i++) sum[k, i] += $i
    if (NF >= 15) { priced[k]++; sum[k, 14] += $14; sum[k, 15] += $15 } else old++
    if ($10 + 0 > worst[k]) worst[k] = $10 + 0 }
  END {
    printf "%-14s %-12s %5s %9s %9s %8s %14s %14s %14s %12s %10s %7s %12s %10s\n", "scenario", "agent", "runs", "decided", "executed", "refused", "shortfall/run", "windfall/run", "worst ever", "gas/run", "pnl/run", "priced", "gasCost/run", "net/run"
    for (j = 1; j <= m; j++) { k = order[j]; split(k, p, SUBSEP)
      np = (k in priced) ? priced[k] : 0
      gc = np ? sprintf("%.0f", sum[k,14]/np) : "-"
      nt = np ? sprintf("%.0f", sum[k,15]/np) : "-"
      if (np && np < n[k]) mixed[++nm] = sprintf("%s %s: pnl/run is over %d runs, gasCost/run and net/run over %d - pnl/run - net/run is not gasCost/run", p[1], p[2], n[k], np)
      printf "%-14s %-12s %5d %9.1f %9.1f %8.1f %14.0f %14.0f %14.0f %12.0f %10.0f %7d %12s %10s\n", p[1], p[2], n[k], sum[k,3]/n[k], sum[k,4]/n[k], sum[k,5]/n[k], sum[k,9]/n[k], sum[k,11]/n[k], worst[k], sum[k,12]/n[k], sum[k,13]/n[k], np, gc, nt }
    for (j = 1; j <= nm; j++) printf "NOTE: mixed group, %s\n", mixed[j]
    if (bad) printf "NOTE: %d line(s) ignored (fewer than 13 fields)\n", bad
    if (old) printf "NOTE: %d line(s) from a ledger that did not price gas (13 fields): not in the gasCost and net means\n", old
  }' "$1"
