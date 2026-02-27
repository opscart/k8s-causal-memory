#!/bin/bash
# save-results.sh
# Preserves POC scenario output as timestamped arXiv evidence.
# Run after each scenario completes — before cleanup.
#
# Saves to: docs/poc-results/<scenario>/<timestamp>/
#   - events.jsonl        (raw collector output)
#   - snapshots.jsonl     (point-in-time snapshots)
#   - memory.db           (SQLite memory store)
#   - query-output.txt    (all three canonical queries)
#   - run-metadata.json   (cluster info, timing, event counts)

set -e
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
SCENARIO="${1:-scenario-unknown}"
TIMESTAMP=$(date -u +"%Y%m%d-%H%M%S")
RESULTS_DIR="$REPO_ROOT/docs/poc-results/${SCENARIO}/${TIMESTAMP}"
OUTPUT_DIR="$REPO_ROOT/output"
STORAGE_DIR="$REPO_ROOT/storage"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

echo ""
echo -e "${CYAN}=== Saving POC results ===${NC}"
echo -e "  Scenario:  $SCENARIO"
echo -e "  Timestamp: $TIMESTAMP"
echo -e "  Saving to: $RESULTS_DIR"
echo ""

mkdir -p "$RESULTS_DIR"

# ── Copy raw collector output ─────────────────────────────────────────────────
if [ -f "$OUTPUT_DIR/events.jsonl" ]; then
  cp "$OUTPUT_DIR/events.jsonl" "$RESULTS_DIR/events.jsonl"
  EVENT_COUNT=$(wc -l < "$OUTPUT_DIR/events.jsonl" | tr -d ' ')
  echo -e "${GREEN}  ✓ events.jsonl ($EVENT_COUNT events)${NC}"
else
  echo -e "${YELLOW}  ⚠ No events.jsonl found${NC}"
  EVENT_COUNT=0
fi

if [ -f "$OUTPUT_DIR/snapshots.jsonl" ]; then
  cp "$OUTPUT_DIR/snapshots.jsonl" "$RESULTS_DIR/snapshots.jsonl"
  SNAP_COUNT=$(wc -l < "$OUTPUT_DIR/snapshots.jsonl" | tr -d ' ')
  echo -e "${GREEN}  ✓ snapshots.jsonl ($SNAP_COUNT snapshots)${NC}"
else
  SNAP_COUNT=0
fi

# ── Run ingest + queries, capture output ──────────────────────────────────────
cd "$STORAGE_DIR"
VENV_PYTHON="$STORAGE_DIR/venv/bin/python"

if [ -f "$VENV_PYTHON" ]; then
  # Fresh DB for this run
  TEMP_DB="$RESULTS_DIR/memory.db"

  echo -e "\n  Ingesting events..."
  $VENV_PYTHON ingest.py \
    --events "$OUTPUT_DIR/events.jsonl" \
    --snapshots "$OUTPUT_DIR/snapshots.jsonl" \
    --db "$TEMP_DB" 2>&1 | grep -v "^$" | sed 's/^/    /'

  # Capture all query output
  QUERY_OUTPUT="$RESULTS_DIR/query-output.txt"
  {
    echo "================================================================"
    echo " k8s-causal-memory POC Results"
    echo " Scenario: $SCENARIO"
    echo " Run:      $TIMESTAMP"
    echo " Cluster:  $(kubectl config current-context 2>/dev/null || echo 'unknown')"
    echo "================================================================"
    echo ""

    echo "=== SUMMARY ==="
    $VENV_PYTHON query.py summary --db "$TEMP_DB" 2>/dev/null || true
    echo ""

    echo "=== Q1: CAUSAL CHAIN (most recent OOMKill) ==="
    # Find most recent OOMKill pod
    OOM_POD=$(grep '"event_type":"OOMKill"' "$OUTPUT_DIR/events.jsonl" 2>/dev/null | \
      tail -1 | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('pod_name',''))" 2>/dev/null || echo "")
    OOM_NS=$(grep '"event_type":"OOMKill"' "$OUTPUT_DIR/events.jsonl" 2>/dev/null | \
      tail -1 | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('namespace','default'))" 2>/dev/null || echo "default")
    if [ -n "$OOM_POD" ]; then
      $VENV_PYTHON query.py causal-chain --pod "$OOM_POD" --namespace "$OOM_NS" --db "$TEMP_DB" 2>/dev/null || true
    else
      echo "(No OOMKill events in this run)"
    fi
    echo ""

    echo "=== Q2: PATTERN HISTORY P001 ==="
    $VENV_PYTHON query.py pattern-history --pattern P001 --db "$TEMP_DB" 2>/dev/null || true
    echo ""

    echo "=== Q2: PATTERN HISTORY P002 ==="
    $VENV_PYTHON query.py pattern-history --pattern P002 --db "$TEMP_DB" 2>/dev/null || true
    echo ""

    echo "=== Q2: PATTERN HISTORY P003 ==="
    $VENV_PYTHON query.py pattern-history --pattern P003 --db "$TEMP_DB" 2>/dev/null || true
    echo ""

  } > "$QUERY_OUTPUT" 2>&1
  echo -e "${GREEN}  ✓ query-output.txt${NC}"
  cp "$TEMP_DB" "$RESULTS_DIR/memory.db"
  echo -e "${GREEN}  ✓ memory.db${NC}"
else
  echo -e "${YELLOW}  ⚠ venv not found — skipping queries (run: make setup)${NC}"
fi

# ── Write run metadata ────────────────────────────────────────────────────────
cd "$REPO_ROOT"
EDGE_COUNT=$(sqlite3 "$RESULTS_DIR/memory.db" "SELECT COUNT(*) FROM causal_edges;" 2>/dev/null || echo 0)
SNAP_DB_COUNT=$(sqlite3 "$RESULTS_DIR/memory.db" "SELECT COUNT(*) FROM snapshots;" 2>/dev/null || echo 0)

cat > "$RESULTS_DIR/run-metadata.json" << METAEOF
{
  "scenario": "$SCENARIO",
  "timestamp": "$TIMESTAMP",
  "cluster": {
    "context": "$(kubectl config current-context 2>/dev/null || echo 'unknown')",
    "server": "$(kubectl cluster-info 2>/dev/null | head -1 | grep -o 'https://[^ ]*' || echo 'unknown')"
  },
  "results": {
    "events_captured": $EVENT_COUNT,
    "snapshots_captured": $SNAP_COUNT,
    "causal_edges_built": $EDGE_COUNT,
    "snapshots_in_db": $SNAP_DB_COUNT
  },
  "collector_version": "$(cd collector && git log -1 --format='%h' 2>/dev/null || echo 'unknown')",
  "run_by": "$(whoami)"
}
METAEOF
echo -e "${GREEN}  ✓ run-metadata.json${NC}"

# ── Write README for this run ─────────────────────────────────────────────────
cat > "$RESULTS_DIR/README.md" << READMEEOF
# POC Run: $SCENARIO — $TIMESTAMP

## Results

| Metric | Value |
|---|---|
| Events captured | $EVENT_COUNT |
| Causal edges built | $EDGE_COUNT |
| Point-in-time snapshots | $SNAP_COUNT |
| Cluster context | $(kubectl config current-context 2>/dev/null || echo 'unknown') |

## Files

- \`events.jsonl\` — Raw collector output (arXiv evidence)
- \`snapshots.jsonl\` — Point-in-time object snapshots
- \`memory.db\` — SQLite operational memory store
- \`query-output.txt\` — Q1/Q2/Q3 canonical query results
- \`run-metadata.json\` — Run context and counts

## Reproduce

\`\`\`bash
# Start collector
./collector/bin/collector --namespace oma-demo --output ./output

# Run scenario
bash scenarios/$SCENARIO/trigger.sh

# Save results
bash save-results.sh $SCENARIO
\`\`\`
READMEEOF
echo -e "${GREEN}  ✓ README.md${NC}"

echo ""
echo -e "${CYAN}Results saved to: docs/poc-results/${SCENARIO}/${TIMESTAMP}/${NC}"
echo ""
echo -e "  Commit with:"
echo -e "  ${CYAN}git add docs/poc-results/ output/${NC}"
echo -e "  ${CYAN}git commit -m 'poc: $SCENARIO results - ${EVENT_COUNT} events, ${EDGE_COUNT} causal edges'${NC}"
echo -e "  ${CYAN}git push${NC}"
echo ""