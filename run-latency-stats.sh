#!/bin/bash
# run-latency-stats.sh
# Runs OOMKill scenario 30 times and collects edge construction latency stats.
# Usage: bash run-latency-stats.sh
# Output: docs/poc-results/latency-stats/summary.csv + summary.txt

set -e
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
RESULTS_BASE="$REPO_ROOT/docs/poc-results/latency-stats"
OUTPUT_DIR="$REPO_ROOT/output"
STORAGE_DIR="$REPO_ROOT/storage"
COLLECTOR_BIN="$REPO_ROOT/collector/bin/collector"
VENV_PYTHON="$STORAGE_DIR/venv/bin/python"
NAMESPACE="oma-latency-test"
TOTAL_RUNS=30
SCENARIO_DIR="$REPO_ROOT/scenarios/01-oomkill"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'

# ── Preflight checks ──────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}=== OMA Latency Statistics Collection (${TOTAL_RUNS} runs) ===${NC}"
echo ""

if [ ! -f "$COLLECTOR_BIN" ]; then
  echo -e "${RED}ERROR: Collector binary not found at $COLLECTOR_BIN${NC}"
  echo "Run: cd collector && go build -o bin/collector . && cd .."
  exit 1
fi

if [ ! -f "$VENV_PYTHON" ]; then
  echo -e "${RED}ERROR: Python venv not found at $VENV_PYTHON${NC}"
  echo "Run: make setup"
  exit 1
fi

mkdir -p "$RESULTS_BASE"
CSV_FILE="$RESULTS_BASE/summary.csv"
echo "run,events,edges,latency_min_ms,latency_max_ms,latency_mean_ms" > "$CSV_FILE"

# ── Helper: clean slate ───────────────────────────────────────────────────────
clean_run() {
  # Kill any running collector
  pkill -f "collector.*oma-demo" 2>/dev/null || true
  sleep 1
  # Clean namespace
  kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=true 2>/dev/null
  kubectl create namespace "$NAMESPACE"
  # Clean output dir
  rm -f "$OUTPUT_DIR/events.jsonl" "$OUTPUT_DIR/snapshots.jsonl"
}

# ── Helper: extract edge latencies from DB ────────────────────────────────────
get_latencies() {
  local db="$1"
  sqlite3 "$db" "
    SELECT ROUND(
      (CAST(e2.id AS REAL) - CAST(e1.id AS REAL)) / 1000000.0, 3
    ) AS latency_ms
    FROM causal_edges ce
    JOIN events e1 ON ce.cause_event_id = e1.id
    JOIN events e2 ON ce.effect_event_id = e2.id
    WHERE ce.pattern_id = 'P001' AND ce.confidence = 1.0
    ORDER BY latency_ms;
  " 2>/dev/null || echo ""
}

# ── Main loop ─────────────────────────────────────────────────────────────────
LATENCIES_ALL=()

for RUN in $(seq 1 $TOTAL_RUNS); do
  echo -e "\n${CYAN}--- Run ${RUN}/${TOTAL_RUNS} ---${NC}"

  # Clean state
  clean_run

  # Start collector in background
  "$COLLECTOR_BIN" \
    --namespace "$NAMESPACE" \
    --output "$OUTPUT_DIR" \
    > /tmp/collector-run-$RUN.log 2>&1 &
  COLLECTOR_PID=$!
  sleep 2  # give collector time to connect

  # Deploy OOMKill pod — substitute namespace in manifest on the fly
  sed -e "s/name: oma-demo/name: $NAMESPACE/g" \
      -e "s/namespace: oma-demo/namespace: $NAMESPACE/g" \
      "$SCENARIO_DIR/deploy.yaml" | kubectl apply -f -

  # Wait for 3+ restart cycles
  sleep 75

  # Stop collector
  kill $COLLECTOR_PID 2>/dev/null || true
  wait $COLLECTOR_PID 2>/dev/null || true
  sleep 1

  # Ingest into temp DB
  RUN_DIR="$RESULTS_BASE/run-$(printf '%02d' $RUN)"
  mkdir -p "$RUN_DIR"
  TEMP_DB="$RUN_DIR/memory.db"

  cp "$OUTPUT_DIR/events.jsonl" "$RUN_DIR/events.jsonl" 2>/dev/null || touch "$RUN_DIR/events.jsonl"

  $VENV_PYTHON "$STORAGE_DIR/ingest.py" \
    --events "$OUTPUT_DIR/events.jsonl" \
    --snapshots "$OUTPUT_DIR/snapshots.jsonl" \
    --db "$TEMP_DB" > /dev/null 2>&1 || true

  # Extract metrics
  EVENT_COUNT=$(wc -l < "$RUN_DIR/events.jsonl" | tr -d ' ')
  EDGE_COUNT=$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM causal_edges;" 2>/dev/null || echo 0)

  # Get latencies for this run
  LATENCIES=$(get_latencies "$TEMP_DB")

  if [ -n "$LATENCIES" ]; then
    LAT_MIN=$(echo "$LATENCIES" | sort -n | head -1)
    LAT_MAX=$(echo "$LATENCIES" | sort -n | tail -1)
    LAT_COUNT=$(echo "$LATENCIES" | wc -l | tr -d ' ')
    LAT_SUM=$(echo "$LATENCIES" | awk '{s+=$1} END {print s}')
    LAT_MEAN=$(echo "scale=3; $LAT_SUM / $LAT_COUNT" | bc)

    # Collect all latencies for global stats
    while IFS= read -r lat; do
      LATENCIES_ALL+=("$lat")
    done <<< "$LATENCIES"
  else
    LAT_MIN="N/A"; LAT_MAX="N/A"; LAT_MEAN="N/A"
    echo -e "${YELLOW}  ⚠ No causal edges found in run $RUN${NC}"
  fi

  echo "  events=$EVENT_COUNT  edges=$EDGE_COUNT  latency=${LAT_MIN}–${LAT_MAX}ms  mean=${LAT_MEAN}ms"
  echo "$RUN,$EVENT_COUNT,$EDGE_COUNT,$LAT_MIN,$LAT_MAX,$LAT_MEAN" >> "$CSV_FILE"
done

# ── Compute global statistics ─────────────────────────────────────────────────
echo ""
echo -e "${CYAN}=== Computing global statistics ===${NC}"

# Write all latencies to temp file for awk processing
LAT_FILE="$RESULTS_BASE/all-latencies.txt"
printf '%s\n' "${LATENCIES_ALL[@]}" > "$LAT_FILE"

SUMMARY="$RESULTS_BASE/summary.txt"
{
  echo "================================================================"
  echo " OMA Latency Statistics — ${TOTAL_RUNS} Runs"
  echo " Scenario: 01-oomkill (P001)"
  echo " Cluster:  $(kubectl config current-context 2>/dev/null || echo 'minikube')"
  echo " Date:     $(date -u)"
  echo "================================================================"
  echo ""
  echo "Per-run results: see summary.csv"
  echo ""
  echo "Global edge construction latency (ms):"
  awk '
    BEGIN { min=9999999; max=-1; sum=0; count=0; sumsq=0 }
    /^[0-9]/ {
      val = $1+0
      if (val < min) min = val
      if (val > max) max = val
      sum += val
      sumsq += val*val
      count++
    }
    END {
      mean = sum/count
      variance = (sumsq/count) - (mean*mean)
      stddev = sqrt(variance)
      printf "  Count:  %d observations\n", count
      printf "  Min:    %.3f ms\n", min
      printf "  Max:    %.3f ms\n", max
      printf "  Mean:   %.3f ms\n", mean
      printf "  StdDev: %.3f ms\n", stddev
      printf "  95th%%:  approx %.3f ms\n", mean + 1.645*stddev
    }
  ' "$LAT_FILE"
  echo ""
  echo "================================================================"
} | tee "$SUMMARY"

echo ""
echo -e "${GREEN}Done. Results in: $RESULTS_BASE${NC}"
echo -e "  CSV:     summary.csv"
echo -e "  Summary: summary.txt"
echo ""
echo -e "Commit with:"
echo -e "${CYAN}  git add docs/poc-results/latency-stats/${NC}"
echo -e "${CYAN}  git commit -m 'eval: 30-run latency statistics for P001 OOMKill scenario'${NC}"