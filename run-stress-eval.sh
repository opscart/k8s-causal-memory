#!/bin/bash
# run-stress-eval.sh
# Stress evaluation: deploys 5, 10, 20 concurrent OOMKill pods.
# Measures event ingestion rate, edge latency, and collector resource usage.
# Usage: bash run-stress-eval.sh
# Output: docs/poc-results/stress-eval/

set -e
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$REPO_ROOT/docs/poc-results/stress-eval"
OUTPUT_DIR="$REPO_ROOT/output"
STORAGE_DIR="$REPO_ROOT/storage"
COLLECTOR_BIN="$REPO_ROOT/collector/bin/collector"
VENV_PYTHON="$STORAGE_DIR/venv/bin/python"
NAMESPACE="oma-stress-test"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'

TIMESTAMP=$(date -u +"%Y%m%d-%H%M%S")

echo ""
echo -e "${CYAN}=== OMA Stress Evaluation ===${NC}"
echo -e "  Levels: 5, 10, 20 concurrent OOMKill pods"
echo -e "  Output: $RESULTS_DIR"
echo ""

# ── Preflight ─────────────────────────────────────────────────────────────────
if [ ! -f "$COLLECTOR_BIN" ]; then
  echo -e "${RED}ERROR: Collector binary not found at $COLLECTOR_BIN${NC}"
  echo "Run: cd collector && go build -o bin/collector . && cd .."
  exit 1
fi

if [ ! -f "$VENV_PYTHON" ]; then
  echo -e "${RED}ERROR: Python venv not found${NC}"
  exit 1
fi

mkdir -p "$RESULTS_DIR"
SUMMARY_CSV="$RESULTS_DIR/stress-summary.csv"
echo "pod_count,duration_s,total_events,events_per_sec,causal_edges,edge_latency_min_ms,edge_latency_max_ms,edge_latency_mean_ms,edge_latency_stddev_ms,collector_mem_mb,collector_cpu_pct" > "$SUMMARY_CSV"

# ── Helper: deploy N OOMKill pods ────────────────────────────────────────────
deploy_pods() {
  local from=$1
  local to=$2
  echo -e "  Deploying pods $from to $to..."
  local TMPFILE=$(mktemp /tmp/oma-pod-XXXX.yaml)
  for i in $(seq $from $to); do
    cat > "$TMPFILE" << PODEOF
apiVersion: v1
kind: Pod
metadata:
  name: oom-stress-$(printf '%02d' $i)
  namespace: $NAMESPACE
spec:
  restartPolicy: Always
  containers:
  - name: stress
    image: polinux/stress
    command: ["stress", "--vm", "1", "--vm-bytes", "128M", "--vm-hang", "0"]
    resources:
      requests:
        memory: "32Mi"
        cpu: "50m"
      limits:
        memory: "64Mi"
        cpu: "100m"
PODEOF
    kubectl apply -f "$TMPFILE" 2>/dev/null
  done
  rm -f "$TMPFILE"
  echo -e "${GREEN}  ✓ Pods deployed${NC}"
}

# ── Helper: get collector resource usage ─────────────────────────────────────
get_collector_resources() {
  local pid=$1
  if [ -z "$pid" ] || ! kill -0 $pid 2>/dev/null; then
    echo "0 0"
    return
  fi
  # macOS ps syntax
  ps -p $pid -o rss=,pcpu= 2>/dev/null | awk '{printf "%.1f %.1f", $1/1024, $2}' || echo "0 0"
}

# ── Helper: compute latency stats from DB ────────────────────────────────────
compute_latency_stats() {
  local db="$1"
  sqlite3 "$db" "
    SELECT
      MIN(lat), MAX(lat), AVG(lat),
      SQRT(AVG(lat*lat) - AVG(lat)*AVG(lat))
    FROM (
      SELECT ROUND(
        (CAST(e2.id AS REAL) - CAST(e1.id AS REAL)) / 1000000.0, 3
      ) AS lat
      FROM causal_edges ce
      JOIN events e1 ON ce.cause_event_id = e1.id
      JOIN events e2 ON ce.effect_event_id = e2.id
      WHERE ce.pattern_id = 'P001' AND ce.confidence = 1.0
    )
  " 2>/dev/null || echo "0|0|0|0"
}

# ── Run each stress level ─────────────────────────────────────────────────────
for POD_COUNT in 5 10 20; do
  echo ""
  echo -e "${CYAN}--- Stress Level: ${POD_COUNT} pods ---${NC}"

  LEVEL_DIR="$RESULTS_DIR/pods-${POD_COUNT}-${TIMESTAMP}"
  mkdir -p "$LEVEL_DIR"

  # Clean namespace
  kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=true 2>/dev/null
  kubectl create namespace "$NAMESPACE"
  rm -f "$OUTPUT_DIR/events.jsonl" "$OUTPUT_DIR/snapshots.jsonl"
  pkill -f "collector.*$NAMESPACE" 2>/dev/null || true
  sleep 2

  # Start collector
  "$COLLECTOR_BIN" \
    --namespace "$NAMESPACE" \
    --output "$OUTPUT_DIR" \
    > "$LEVEL_DIR/collector.log" 2>&1 &
  COLLECTOR_PID=$!
  sleep 2

  echo -e "  Collector PID: $COLLECTOR_PID"

  # Record start time and initial line count
  START_TIME=$(date +%s)
  START_LINES=0

  # Deploy pods in batches
  deploy_pods 1 $POD_COUNT

  # Observe for 120 seconds, sampling every 30s
  echo -e "  Observing for 120 seconds..."
  for SAMPLE in 1 2 3 4; do
    sleep 30
    CURRENT_LINES=$(wc -l < "$OUTPUT_DIR/events.jsonl" 2>/dev/null | tr -d ' ' || echo 0)
    ELAPSED=$(( $(date +%s) - START_TIME ))
    RATE=$(echo "scale=2; $CURRENT_LINES / $ELAPSED" | bc 2>/dev/null || echo "0")
    READ_RESOURCES=( $(get_collector_resources $COLLECTOR_PID) )
    echo -e "  ${SAMPLE}/4 — ${ELAPSED}s elapsed — ${CURRENT_LINES} events — ${RATE} evt/s — collector mem: ${READ_RESOURCES[0]}MB cpu: ${READ_RESOURCES[1]}%"
  done

  # Final snapshot of resources before stopping
  FINAL_RESOURCES=( $(get_collector_resources $COLLECTOR_PID) )
  COLLECTOR_MEM="${FINAL_RESOURCES[0]:-0}"
  COLLECTOR_CPU="${FINAL_RESOURCES[1]:-0}"

  # Stop collector
  kill $COLLECTOR_PID 2>/dev/null || true
  wait $COLLECTOR_PID 2>/dev/null || true
  sleep 1

  # Copy results
  cp "$OUTPUT_DIR/events.jsonl" "$LEVEL_DIR/events.jsonl" 2>/dev/null || touch "$LEVEL_DIR/events.jsonl"
  cp "$OUTPUT_DIR/snapshots.jsonl" "$LEVEL_DIR/snapshots.jsonl" 2>/dev/null || touch "$LEVEL_DIR/snapshots.jsonl"

  # Ingest
  TEMP_DB="$LEVEL_DIR/memory.db"
  echo -e "  Ingesting events..."
  $VENV_PYTHON "$STORAGE_DIR/ingest.py" \
    --events "$OUTPUT_DIR/events.jsonl" \
    --snapshots "$OUTPUT_DIR/snapshots.jsonl" \
    --db "$TEMP_DB" > /dev/null 2>&1 || true

  # Compute metrics
  END_TIME=$(date +%s)
  DURATION=$(( END_TIME - START_TIME ))
  TOTAL_EVENTS=$(wc -l < "$LEVEL_DIR/events.jsonl" | tr -d ' ')
  EVENTS_PER_SEC=$(echo "scale=2; $TOTAL_EVENTS / $DURATION" | bc 2>/dev/null || echo "0")
  EDGE_COUNT=$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM causal_edges;" 2>/dev/null || echo 0)

  # Latency stats
  LATENCY_STATS=$(compute_latency_stats "$TEMP_DB")
  LAT_MIN=$(echo "$LATENCY_STATS" | cut -d'|' -f1)
  LAT_MAX=$(echo "$LATENCY_STATS" | cut -d'|' -f2)
  LAT_MEAN=$(echo "$LATENCY_STATS" | cut -d'|' -f3)
  LAT_STDDEV=$(echo "$LATENCY_STATS" | cut -d'|' -f4)

  # Write per-level summary
  cat > "$LEVEL_DIR/results.txt" << LEVELEOF
================================================================
 Stress Level: ${POD_COUNT} concurrent OOMKill pods
 Duration:     ${DURATION}s
================================================================

Events
  Total captured:    $TOTAL_EVENTS
  Rate:              $EVENTS_PER_SEC events/sec

Causal Edges
  Total built:       $EDGE_COUNT
  Latency min:       ${LAT_MIN} ms
  Latency max:       ${LAT_MAX} ms
  Latency mean:      ${LAT_MEAN} ms
  Latency stddev:    ${LAT_STDDEV} ms

Collector Resources (at 120s mark)
  Memory:            ${COLLECTOR_MEM} MB
  CPU:               ${COLLECTOR_CPU}%
================================================================
LEVELEOF

  cat "$LEVEL_DIR/results.txt"

  # Append to CSV
  echo "$POD_COUNT,$DURATION,$TOTAL_EVENTS,$EVENTS_PER_SEC,$EDGE_COUNT,$LAT_MIN,$LAT_MAX,$LAT_MEAN,$LAT_STDDEV,$COLLECTOR_MEM,$COLLECTOR_CPU" >> "$SUMMARY_CSV"

done

# ── Final summary ─────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}=== Stress Evaluation Complete ===${NC}"
echo ""
echo "Summary CSV:"
cat "$SUMMARY_CSV"
echo ""
echo -e "${GREEN}Results in: $RESULTS_DIR${NC}"
echo ""
echo "Commit with:"
echo -e "${CYAN}  git add docs/poc-results/stress-eval/${NC}"
echo -e "${CYAN}  git commit -m 'eval: stress evaluation 5/10/20 concurrent pods'${NC}"