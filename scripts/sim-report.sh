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
#   label  agent  decided  executed  refused  in  out  quoted  shortfall  worst  windfall  gas  pnl  gasCost  pnlNet  atQuote
# `pnl` is gross; `gasCost` is the gas at the scenario's price in raw quote units, and `pnlNet` = pnl - gasCost.
# `atQuote` counts the swaps the engine did NOT send because their own quote at decision time was 0 (no gas, and not in
# `refused`, which is what was sent and came back empty). Lines written before it have 15 fields (or 13): they are left
# out of the atQuote mean, which is over `atQ runs` and prints "-" for a group with none; a NOTE names a group that
# mixes the two, and says how many lines lack the column.
# Lines from a ledger that did not price gas have 13 fields: they still count in every other column, their gas
# columns are left out of the gasCost and net means, and a NOTE says how many. So every mean says what it is over:
# `runs` for the columns up to pnl/run, `priced` for gasCost/run and net/run. When the two differ (a group that mixes
# priced and unpriced lines) pnl/run - net/run is NOT gasCost/run, and a NOTE names the group. A group with no priced
# line prints "-" for both: an unpriced run is not a free one.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/parse.sh
. "$HERE/lib/parse.sh" || { echo "sim-report: $HERE/lib/parse.sh is missing"; exit 2; }
[ -s "${1:-}" ] || { echo "sim-report: ${1:-<no file>} is empty or missing. NOTHING MEASURED."; exit 2; }
# A line with fewer than 13 fields, or with a field in columns 3-16 that is not an integer, is MALFORMED: counted and
# named below, never added up (awk reads "12a" as 12 and "-" as 0). `scripts/lib/parse.sh`, `sim_ledger_filter`.
bad="$(sim_ledger_malformed "$1")"
good="$(sim_ledger_filter "$1")"
if [ -z "$good" ]; then
  echo "sim-report: $1 has no well-formed line ($bad malformed). NOTHING MEASURED."; exit 2
fi
printf '%s\n' "$good" | awk -F '\t' -v bad="$bad" '
  { k = $1 SUBSEP $2; if (!(k in n)) order[++m] = k
    n[k]++; for (i = 3; i <= 13; i++) sum[k, i] += $i
    if (NF >= 15) { priced[k]++; sum[k, 14] += $14; sum[k, 15] += $15 } else old++
    if (NF >= 16) { aq[k]++; sum[k, 16] += $16 } else noaq++
    if ($10 + 0 > worst[k]) worst[k] = $10 + 0 }
  END {
    printf "%-14s %-12s %5s %9s %9s %8s %14s %14s %14s %12s %10s %7s %12s %10s %8s %11s\n", "scenario", "agent", "runs", "decided", "executed", "refused", "shortfall/run", "windfall/run", "worst ever", "gas/run", "pnl/run", "priced", "gasCost/run", "net/run", "atQ runs", "atQuote/run"
    for (j = 1; j <= m; j++) { k = order[j]; split(k, p, SUBSEP)
      np = (k in priced) ? priced[k] : 0
      gc = np ? sprintf("%.0f", sum[k,14]/np) : "-"
      nt = np ? sprintf("%.0f", sum[k,15]/np) : "-"
      na = (k in aq) ? aq[k] : 0
      aqm = na ? sprintf("%.1f", sum[k,16]/na) : "-"
      if (na && na < n[k]) mixed[++nm] = sprintf("%s %s: atQuote/run is over %d runs of %d - the others were written before the column", p[1], p[2], na, n[k])
      if (np && np < n[k]) mixed[++nm] = sprintf("%s %s: pnl/run is over %d runs, gasCost/run and net/run over %d - pnl/run - net/run is not gasCost/run", p[1], p[2], n[k], np)
      printf "%-14s %-12s %5d %9.1f %9.1f %8.1f %14.0f %14.0f %14.0f %12.0f %10.0f %7d %12s %10s %8d %11s\n", p[1], p[2], n[k], sum[k,3]/n[k], sum[k,4]/n[k], sum[k,5]/n[k], sum[k,9]/n[k], sum[k,11]/n[k], worst[k], sum[k,12]/n[k], sum[k,13]/n[k], np, gc, nt, na, aqm }
    for (j = 1; j <= nm; j++) printf "NOTE: mixed group, %s\n", mixed[j]
    if (bad) printf "NOTE: %d line(s) ignored (malformed: fewer than 13 fields, or a field in columns 3-16 that is not an integer)\n", bad
    if (old) printf "NOTE: %d line(s) from a ledger that did not price gas (13 fields): not in the gasCost and net means\n", old
    if (noaq) printf "NOTE: %d line(s) from a ledger without the atQuote column (fewer than 16 fields): not in the atQuote mean\n", noaq
  }'
