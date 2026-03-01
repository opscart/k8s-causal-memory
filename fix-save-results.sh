#!/bin/bash
# Run from repo root — fixes query-output.txt files by re-running queries
# using plain text output (bypasses Rich's TTY detection)

set -e
REPO_ROOT="$(pwd)"
STORAGE_DIR="$REPO_ROOT/storage"
VENV_PYTHON="$STORAGE_DIR/venv/bin/python"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

regenerate() {
  local SCENARIO="$1"
  local RUN_DIR="$2"
  local EVENTS="$RUN_DIR/events.jsonl"
  local SNAPS="$RUN_DIR/snapshots.jsonl"
  local DB="$RUN_DIR/memory.db"
  local OUT="$RUN_DIR/query-output.txt"

  echo -e "\n${CYAN}→ $SCENARIO / $(basename $RUN_DIR)${NC}"

  # Re-ingest into fresh DB
  rm -f "$DB"
  $VENV_PYTHON "$STORAGE_DIR/ingest.py" \
    --events "$EVENTS" \
    --snapshots "$SNAPS" \
    --db "$DB" 2>/dev/null

  # Find most recent OOMKill pod
  OOM_POD=$(grep '"event_type":"OOMKill"' "$EVENTS" 2>/dev/null | tail -1 | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('pod_name',''))" 2>/dev/null || echo "")
  OOM_NS=$(grep '"event_type":"OOMKill"' "$EVENTS" 2>/dev/null | tail -1 | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('namespace','default'))" 2>/dev/null || echo "default")

  {
    echo "================================================================"
    echo " k8s-causal-memory POC Results"
    echo " Scenario: $SCENARIO"
    echo " Run:      $(basename $RUN_DIR)"
    echo "================================================================"
    echo ""

    # Use sqlite3 directly for plain text — bypasses Rich entirely
    EVENT_COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM events;" 2>/dev/null || echo 0)
    EDGE_COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM causal_edges;" 2>/dev/null || echo 0)
    SNAP_COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM snapshots;" 2>/dev/null || echo 0)

    echo "=== SUMMARY ==="
    echo "Events: $EVENT_COUNT  |  Causal edges: $EDGE_COUNT  |  Snapshots: $SNAP_COUNT"
    echo ""

    echo "=== Pattern Distribution ==="
    sqlite3 "$DB" "SELECT pattern_id, COUNT(*) as count FROM events WHERE pattern_id != '' GROUP BY pattern_id ORDER BY count DESC;" 2>/dev/null | \
      while IFS='|' read pid cnt; do
        echo "  $pid : $cnt events"
      done
    echo ""

    echo "=== Top Pods ==="
    sqlite3 "$DB" "SELECT pod_name, namespace, COUNT(*) as events, MAX(timestamp) as last_seen FROM events WHERE pod_name != '' GROUP BY pod_name, namespace ORDER BY events DESC LIMIT 5;" 2>/dev/null | \
      while IFS='|' read pod ns cnt ts; do
        echo "  $pod ($ns) — $cnt events — last: $ts"
      done
    echo ""

    echo "=== Q1: Causal Chain (most recent OOMKill) ==="
    if [ -n "$OOM_POD" ]; then
      echo "  Pod: $OOM_POD  Namespace: $OOM_NS"
      echo ""
      # Anchor event
      sqlite3 "$DB" "SELECT event_type, timestamp, node_name FROM events WHERE pod_name='$OOM_POD' AND event_type='OOMKill' ORDER BY timestamp DESC LIMIT 1;" 2>/dev/null | \
        while IFS='|' read et ts node; do
          echo "  $et  $ts"
          echo "    Node: $node"
        done
      # Resource limits from payload
      sqlite3 "$DB" "SELECT payload FROM events WHERE pod_name='$OOM_POD' AND event_type='OOMKill' ORDER BY timestamp DESC LIMIT 1;" 2>/dev/null | \
        python3 -c "
import json,sys
try:
    p = json.load(sys.stdin)
    lim = p.get('resource_limits', {})
    refs = p.get('config_references', {})
    print(f'    Limits: cpu={lim.get(\"cpu\",\"none\")}  memory={lim.get(\"memory\",\"none\")}')
    print(f'    ConfigMaps in effect: {refs.get(\"configmaps\", [])}')
    print(f'    Exit code: {p.get(\"exit_code\")}  Restart count: {p.get(\"restart_count\")}')
except: pass
" 2>/dev/null
      # Causal edges
      echo ""
      echo "  Causal edges:"
      sqlite3 "$DB" "
        SELECT e.event_type, e.timestamp, ce.confidence
        FROM events e
        JOIN causal_edges ce ON e.id = ce.cause_event_id
        WHERE ce.effect_event_id = (
          SELECT id FROM events WHERE pod_name='$OOM_POD' AND event_type='OOMKill'
          ORDER BY timestamp DESC LIMIT 1
        );" 2>/dev/null | \
        while IFS='|' read et ts conf; do
          echo "    ←causes— $et  $ts  (confidence: $conf)"
        done
    else
      echo "  No OOMKill events in this run"
    fi
    echo ""

    echo "=== Q2: Pattern History P001 (OOMKill) ==="
    sqlite3 "$DB" "SELECT timestamp, pod_name, namespace, node_name, event_type FROM events WHERE pattern_id='P001' ORDER BY timestamp DESC;" 2>/dev/null | \
      while IFS='|' read ts pod ns node et; do
        echo "  $ts  $et  $pod  $ns  $node"
      done
    echo ""

    echo "=== Q2: Pattern History P002 (ConfigMap Env) ==="
    sqlite3 "$DB" "SELECT timestamp, pod_name, namespace, event_type FROM events WHERE event_type='ConfigMapChanged' ORDER BY timestamp DESC;" 2>/dev/null | \
      while IFS='|' read ts pod ns et; do
        echo "  $ts  $et  namespace=$ns"
      done
    echo ""

    echo "=== Q3: Point-in-Time Snapshots ==="
    sqlite3 "$DB" "SELECT object_kind, object_name, namespace, timestamp, trigger_event FROM snapshots ORDER BY timestamp DESC;" 2>/dev/null | \
      while IFS='|' read kind name ns ts trigger; do
        echo "  $kind/$name ($ns)  at=$ts  trigger=$trigger"
      done
    echo ""

    echo "=== Raw Causal Edges ==="
    sqlite3 "$DB" "
      SELECT c.event_type, e.event_type, ce.confidence, ce.pattern_id
      FROM causal_edges ce
      JOIN events c ON c.id = ce.cause_event_id
      JOIN events e ON e.id = ce.effect_event_id
      ORDER BY ce.created_at DESC LIMIT 20;" 2>/dev/null | \
      while IFS='|' read cause effect conf pat; do
        echo "  $cause → $effect  (conf=$conf, pattern=$pat)"
      done

  } > "$OUT"

  echo -e "${GREEN}  ✓ Regenerated: $OUT${NC}"
  echo "  $(wc -l < "$OUT") lines written"
}

# Process all poc-results
for scenario_dir in "$REPO_ROOT/docs/poc-results"/*/; do
  scenario=$(basename "$scenario_dir")
  for run_dir in "$scenario_dir"*/; do
    if [ -f "$run_dir/events.jsonl" ]; then
      regenerate "$scenario" "$run_dir"
    fi
  done
done

echo ""
echo -e "${CYAN}Done. Preview:${NC}"
find docs/poc-results -name "query-output.txt" | sort | while read f; do
  echo ""
  echo "════════════════════════════════════════"
  echo " $f"
  echo "════════════════════════════════════════"
  cat "$f"
done
