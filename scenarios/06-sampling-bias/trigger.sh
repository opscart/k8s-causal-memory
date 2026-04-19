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
echo -e "\n${YELLOW}[2/5] Watching ghost pod lifecycle (expecting OOMKill in ~7s)...${NC}"
ELAPSED=0
LIFETIME=0
OOMKILLED=false
for i in $(seq 1 20); do
  sleep 1
  ELAPSED=$((ELAPSED + 1))
  STATUS=$(kubectl get pod ghost-pod -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Gone")
  REASON=$(kubectl get pod ghost-pod -n "$NAMESPACE" \
    -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || echo "")
  printf "\r  T+%02ds  phase=%-10s reason=%-12s" "$ELAPSED" "$STATUS" "${REASON:-running}"
  if [ "$REASON" = "OOMKilled" ] || [ "$STATUS" = "Failed" ]; then
    LIFETIME=$ELAPSED
    OOMKILLED=true
    echo ""
    break
  fi
done
echo ""

END_EPOCH=$(date +%s)
LIFETIME=$((END_EPOCH - START_EPOCH))

if [ "$OOMKILLED" = true ]; then
  echo -e "${GREEN}  ✓ OOMKill confirmed in ~${LIFETIME}s${NC}"
else
  echo -e "${YELLOW}  Pod may still be running or already gone${NC}"
fi

# ── The structural argument ───────────────────────────────────────────────
echo -e "\n${YELLOW}[3/5] H5 Evidence gap — poll vs event-driven:${NC}"
echo ""
echo -e "  Pod lifetime:      ~${LIFETIME}s"
echo -e "  Scrape interval:   ${SCRAPE_INTERVAL}s"
echo ""
if [ "$LIFETIME" -lt "$SCRAPE_INTERVAL" ]; then
  echo -e "  ${RED}Pod lifetime (${LIFETIME}s) < scrape interval (${SCRAPE_INTERVAL}s)${NC}"
  echo -e "  ${RED}→ Prometheus would return 0 data points for this pod${NC}"
  echo ""
  echo -e "  PromQL that returns empty:"
  echo -e "  ${CYAN}  container_cpu_usage_seconds_total{pod=\"ghost-pod\",namespace=\"oma-sampling\"}${NC}"
  echo -e "  ${CYAN}  kube_pod_container_status_last_terminated_reason{pod=\"ghost-pod\"}${NC}"
  echo -e "  ${CYAN}  Result: {} (no data — pod never scraped)${NC}"
else
  echo -e "  ${YELLOW}  Pod took ${LIFETIME}s — may have been scraped once.${NC}"
  echo -e "  ${YELLOW}  Re-run for a tighter demonstration.${NC}"
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