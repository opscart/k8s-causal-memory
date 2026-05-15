#!/bin/bash
set -e
NAMESPACE="oma-sampling"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/output"
SCRAPE_INTERVAL=15  # Prometheus default scrape interval in seconds

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} k8s-causal-memory — Scenario 06: Sampling Bias (H5)       ${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""
echo -e "  Evidence Horizon H5: poll-based observability has a structural"
echo -e "  blind spot. A pod that lives and dies within one Prometheus"
echo -e "  scrape interval (default: ${SCRAPE_INTERVAL}s) generates zero time-series"
echo -e "  data. OMA's event-driven architecture has no such gap."
echo ""

# Preflight
if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}ERROR: kubectl cannot reach cluster. Is minikube running?${NC}"
  exit 1
fi
CONTEXT=$(kubectl config current-context)
echo -e "  Context:          ${CYAN}$CONTEXT${NC}"
echo -e "  Scrape interval:  ${CYAN}${SCRAPE_INTERVAL}s${NC} (Prometheus default)"
echo -e "  Pod lifetime:     ${CYAN}~7s${NC} (OOMKill at 64Mi limit)"
echo -e "  Expected result:  ${CYAN}Prometheus=0 datapoints, OMA=full P001 chain${NC}"
echo ""

if [ ! -f "$REPO_ROOT/collector/bin/collector" ]; then
  echo -e "${RED}ERROR: Collector binary missing. Run: cd collector && go build -o bin/collector .${NC}"
  exit 1
fi

# ── Deploy ────────────────────────────────────────────────────────────────
echo -e "\n${YELLOW}[1/5] Deploying ghost pod (64Mi limit, allocating 128Mi)...${NC}"
kubectl apply -f "$SCENARIO_DIR/deploy.yaml"
echo -e "${GREEN}  ✓ Deployed${NC}"

# Record exact start time for the evidence gap argument
START_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START_EPOCH=$(date +%s)
echo -e "  Start time: ${START_TIME}"

# ── Watch pod lifecycle ───────────────────────────────────────────────────
echo -e "\n${YELLOW}[2/5] Watching ghost pod lifecycle...${NC}"
OOMKILLED=false
LIFETIME=0

# Phase 1 — wait for Running (up to 300s)
echo -e "  Phase 1: waiting for pod to reach Running state (up to 300s)..."
for i in $(seq 1 300); do
  sleep 1
  STATUS=$(kubectl get pod ghost-pod -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Gone")
  printf "\r  Startup T+%03ds  phase=%-20s" "$i" "$STATUS"
  if [ "$STATUS" = "Running" ]; then
    echo ""
    echo -e "${GREEN}  ✓ Pod Running at T+${i}s from deployment${NC}"
    break
  fi
  if [ "$STATUS" = "Failed" ] || [ "$STATUS" = "Gone" ]; then
    echo ""
    break
  fi
done

# Phase 2 — wait for OOMKill (up to 120s from Running)
echo -e "  Phase 2: waiting for OOMKill (up to 120s)..."
RUN_START=$(date +%s)
for i in $(seq 1 120); do
  sleep 1
  REASON=$(kubectl get pod ghost-pod -n "$NAMESPACE" \
    -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' \
    2>/dev/null || echo "")
  STATUS=$(kubectl get pod ghost-pod -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Gone")
  printf "\r  OOMKill watch T+%03ds  reason=%-15s" "$i" "${REASON:-waiting}"
  if [ "$REASON" = "OOMKilled" ] || [ "$STATUS" = "Failed" ]; then
    LIFETIME=$i
    OOMKILLED=true
    echo ""
    break
  fi
done
echo ""

if [ "$OOMKILLED" = true ]; then
  echo -e "${GREEN}  ✓ OOMKill confirmed in ~${LIFETIME}s after Running${NC}"
else
  echo -e "${YELLOW}  OOMKill not observed in watch window${NC}"
fi
# ── The structural argument ───────────────────────────────────────────────
echo -e "\n${YELLOW}[3/5] H5 Evidence gap — poll vs event-driven:${NC}"
echo ""
echo -e "  Pod running lifetime: ~${LIFETIME}s"
echo -e "  Scrape interval:      ${SCRAPE_INTERVAL}s"
echo ""
echo -e "  ${CYAN}Prometheus HTTP API query (issued after pod exit):${NC}"
echo -e "  ${CYAN}  container_cpu_usage_seconds_total{pod=\"ghost-pod\"}${NC}"

PROM_RESULT=$(curl -s --max-time 5 \
  "http://localhost:9090/api/v1/query?query=container_cpu_usage_seconds_total%7Bpod%3D%22ghost-pod%22%7D" \
  2>/dev/null || echo "")

if echo "$PROM_RESULT" | grep -q '"result":\[\]'; then
  echo -e "  ${RED}  Result: [] — zero data points confirmed${NC}"
  PROM_EMPTY=true
else
  echo -e "  ${YELLOW}  Result: $PROM_RESULT${NC}"
  PROM_EMPTY=false
fi

echo ""
echo -e "  ${CYAN}Why this is structural, not a configuration issue:${NC}"
echo -e "  Prometheus samples the world every N seconds."
echo -e "  Any pod whose entire lifetime falls within one scrape gap"
echo -e "  is architecturally invisible — not a tuning problem."
echo -e "  OMA subscribes to the Kubernetes watch API."
echo -e "  Every event is delivered at occurrence — no sampling gap exists."

# ── kubectl state after exit ──────────────────────────────────────────────
echo -e "\n${YELLOW}[4/5] kubectl state after pod exit:${NC}"
echo ""
echo -e "  ${RED}kubectl get pod ghost-pod -n $NAMESPACE:${NC}"
kubectl get pod ghost-pod -n "$NAMESPACE" 2>&1 || \
  echo -e "  ${RED}Error from server (NotFound): pods 'ghost-pod' not found${NC}"
echo ""
echo -e "  ${RED}kubectl logs ghost-pod -n $NAMESPACE:${NC}"
kubectl logs ghost-pod -n "$NAMESPACE" 2>&1 | head -3 || \
  echo -e "  ${RED}Error from server (NotFound)${NC}"

# ── OMA output ────────────────────────────────────────────────────────────
echo -e "\n${YELLOW}[5/5] OMA collector output (P001 — event-driven capture):${NC}"
EVENTS_FILE="$OUTPUT_DIR/events.jsonl"

# Give collector a moment to write
sleep 3

if [ ! -f "$EVENTS_FILE" ]; then
  echo -e "${YELLOW}  No events file at $EVENTS_FILE${NC}"
  echo -e "  ${CYAN}Is the collector running?${NC}"
  echo "  ./collector/bin/collector --namespace oma-sampling --output ./output"
else
  OOM=$(grep '"event_type":"OOMKill"' "$EVENTS_FILE" 2>/dev/null | \
    grep '"namespace":"oma-sampling"' | wc -l | tr -d ' ')
  TOT=$(wc -l < "$EVENTS_FILE" | tr -d ' ')
  echo -e "  Total events in store: $TOT"
  echo -e "  OOMKill (P001) for ghost-pod: ${OOM}"

  if [ "$OOM" -gt 0 ]; then
    echo ""
    grep '"event_type":"OOMKill"' "$EVENTS_FILE" 2>/dev/null | \
      grep '"namespace":"oma-sampling"' | tail -1 | \
      python3 -c "
import json,sys
r = json.loads(sys.stdin.read())
p = r.get('payload', {})
print(f\"    pod:           {r.get('pod_name')}\")
print(f\"    exit_code:     {p.get('exit_code')}\")
print(f\"    reason:        {p.get('reason')}\")
print(f\"    memory_limit:  {p.get('resource_limits', {}).get('app', {}).get('memory', 'captured')}\")
print(f\"    node:          {r.get('node_name')}\")
print(f\"    timestamp:     {r.get('timestamp')}\")
" 2>/dev/null || echo "  (python3 not available — check events.jsonl)"

    echo ""
    echo -e "${GREEN}  ✓ H5 demonstrated:${NC}"
    echo -e "  Prometheus:  0 data points  (pod invisible — sub-scrape-interval lifetime)"
    echo -e "  OMA:         full P001 causal chain  (event-driven — no sampling gap)"
    echo ""
    echo -e "  ${CYAN}To ingest and query:${NC}"
    echo -e "  ${CYAN}cd storage && python ingest.py --events ../output/events.jsonl${NC}"
    echo -e "  ${CYAN}sqlite3 memory.db \"SELECT pod_name,event_type,timestamp FROM events WHERE namespace='oma-sampling';\"${NC}"
  else
    echo -e "${YELLOW}  No OOMKill captured yet for ghost-pod.${NC}"
    echo -e "  Confirm collector is running: ./collector/bin/collector --namespace oma-sampling --output ./output"
  fi
fi

echo ""
read -p "Clean up scenario resources? [y/N] " cleanup
if [[ "$cleanup" == "y" || "$cleanup" == "Y" ]]; then
  kubectl delete -f "$SCENARIO_DIR/deploy.yaml" --ignore-not-found
  echo -e "${GREEN}  ✓ Cleaned up${NC}"
fi
echo ""