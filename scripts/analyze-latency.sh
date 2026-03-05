#!/bin/bash
# analyze-latency.sh
# Analyzes causal edge latency distribution across all 30 latency-stats runs.
# Separates intra-cycle edges (OOMKillEvidence captured in same restart cycle)
# from cross-cycle edges (evidence linked back across restart boundaries).
#
# Usage: bash scripts/analyze-latency.sh
# Requires: docs/poc-results/latency-stats/run-*/memory.db

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS_BASE="$REPO_ROOT/docs/poc-results/latency-stats"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; NC='\033[0m'

echo ""
echo -e "${CYAN}=== OMA Causal Edge Latency Analysis ===${NC}"
echo -e "  Source: $RESULTS_BASE/run-*/memory.db"
echo ""

# ── Check runs exist ──────────────────────────────────────────────────────────
RUN_COUNT=$(ls -d "$RESULTS_BASE"/run-* 2>/dev/null | wc -l | tr -d ' ')
if [ "$RUN_COUNT" -eq 0 ]; then
  echo "ERROR: No run directories found in $RESULTS_BASE"
  echo "Run: bash run-latency-stats.sh first"
  exit 1
fi
echo -e "  Runs found: $RUN_COUNT"
echo ""

# ── Extract all latencies from all runs ───────────────────────────────────────
ALL_LATENCIES=$(for db in "$RESULTS_BASE"/run-*/memory.db; do
  sqlite3 "$db" "
    SELECT ROUND(
      (CAST(e2.id AS REAL) - CAST(e1.id AS REAL)) / 1000000.0, 3
    ) AS latency_ms
    FROM causal_edges ce
    JOIN events e1 ON ce.cause_event_id = e1.id
    JOIN events e2 ON ce.effect_event_id = e2.id
    WHERE ce.pattern_id = 'P001' AND ce.confidence = 1.0
  " 2>/dev/null
done)

if [ -z "$ALL_LATENCIES" ]; then
  echo "ERROR: No latency data found. Check that ingest.py ran correctly."
  exit 1
fi

# ── Bimodal analysis ──────────────────────────────────────────────────────────
echo -e "${CYAN}Bimodal Distribution Analysis${NC}"
echo -e "  Threshold: 100ms separates intra-cycle from cross-cycle edges"
echo ""

echo "$ALL_LATENCIES" | awk '
  BEGIN {
    ic=0; cc=0
    ic_sum=0; cc_sum=0
    ic_sumsq=0; cc_sumsq=0
    ic_min=9999999; cc_min=9999999
    ic_max=0; cc_max=0
    total=0
  }
  /^[0-9]/ {
    lat = $1+0
    total++
    if (lat < 100) {
      ic++; ic_sum+=lat; ic_sumsq+=lat*lat
      if (lat < ic_min) ic_min = lat
      if (lat > ic_max) ic_max = lat
    } else {
      cc++; cc_sum+=lat; cc_sumsq+=lat*lat
      if (lat < cc_min) cc_min = lat
      if (lat > cc_max) cc_max = lat
    }
  }
  END {
    ic_mean = ic_sum/ic
    cc_mean = cc_sum/cc
    ic_var  = (ic_sumsq/ic) - (ic_mean*ic_mean)
    cc_var  = (cc_sumsq/cc) - (cc_mean*cc_mean)
    ic_std  = sqrt(ic_var)
    cc_std  = sqrt(cc_var)

    printf "Intra-cycle edges (same restart cycle, lat < 100ms):\n"
    printf "  Count:   %d / %d total edges (%.1f%%)\n", ic, total, (ic/total)*100
    printf "  Min:     %.3f ms\n", ic_min
    printf "  Max:     %.3f ms\n", ic_max
    printf "  Mean:    %.3f ms\n", ic_mean
    printf "  StdDev:  %.3f ms\n", ic_std
    printf "  95th%%:   approx %.3f ms\n\n", ic_mean + 1.645*ic_std

    printf "Cross-cycle edges (across restart boundaries, lat >= 100ms):\n"
    printf "  Count:   %d / %d total edges (%.1f%%)\n", cc, total, (cc/total)*100
    printf "  Min:     %.3f ms\n", cc_min
    printf "  Max:     %.3f ms\n", cc_max
    printf "  Mean:    %.3f ms\n", cc_mean
    printf "  StdDev:  %.3f ms\n", cc_std
    printf "  95th%%:   approx %.3f ms\n\n", cc_mean + 1.645*cc_std

    printf "Overall:\n"
    printf "  Total edges analyzed: %d\n", total
    printf "  Across %d runs\n", NR > 0 ? NR : 0
  }
'

# ── Per-run summary ───────────────────────────────────────────────────────────
echo -e "${CYAN}Per-Run Edge Counts${NC}"
echo ""
printf "  %-8s %-12s %-12s %-12s\n" "Run" "Total edges" "Intra-cycle" "Cross-cycle"
printf "  %-8s %-12s %-12s %-12s\n" "---" "-----------" "-----------" "-----------"

for db in "$RESULTS_BASE"/run-*/memory.db; do
  RUN=$(basename "$(dirname "$db")")
  sqlite3 "$db" "
    SELECT
      COUNT(*) as total,
      SUM(CASE WHEN ((CAST(e2.id AS REAL) - CAST(e1.id AS REAL))/1000000.0) < 100 THEN 1 ELSE 0 END) as intra,
      SUM(CASE WHEN ((CAST(e2.id AS REAL) - CAST(e1.id AS REAL))/1000000.0) >= 100 THEN 1 ELSE 0 END) as cross
    FROM causal_edges ce
    JOIN events e1 ON ce.cause_event_id = e1.id
    JOIN events e2 ON ce.effect_event_id = e2.id
    WHERE ce.pattern_id = 'P001' AND ce.confidence = 1.0
  " 2>/dev/null | awk -v run="$RUN" '{printf "  %-8s %-12s %-12s %-12s\n", run, $1, $2, $3}'
done

echo ""
echo -e "${GREEN}Analysis complete.${NC}"
echo ""
