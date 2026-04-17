#!/bin/bash
set -e
NAMESPACE="oma-scheduler"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/output"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} k8s-causal-memory — Scenario 04: Scheduler Pruning (H2)   ${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""
echo -e "  Evidence Horizon H2: kube-apiserver prunes scheduler Events"
echo -e "  at 1hr TTL (demo: 2m). OMA captures FailedScheduling and"
echo -e "  Scheduled decisions before they are permanently deleted."
echo ""

# Preflight
if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}ERROR: kubectl cannot reach cluster. Is minikube running?${NC}"
  exit 1
fi
CONTEXT=$(kubectl config current-context)
echo -e "  Context: ${CYAN}$CONTEXT${NC}"

if [ ! -f "$REPO_ROOT/collector/bin/collector" ]; then
  echo -e "${RED}ERROR: Collector binary missing. Run: cd collector && go build -o bin/collector .${NC}"
  exit 1
fi

# ── Phase 1: Unschedulable pod ───────────────────────────────────────────
echo -e "\n${YELLOW}[1/6] Deploying unschedulable pod (999Gi request — will never schedule)...${NC}"
kubectl apply -f "$SCENARIO_DIR/deploy.yaml"
echo -e "${GREEN}  ✓ Deployed${NC}"

echo -e "\n${YELLOW}[2/6] Waiting 20s for FailedScheduling events...${NC}"
sleep 20

echo -e "\n${YELLOW}[3/6] kubectl events visible NOW (will be gone after TTL):${NC}"
FAIL_COUNT=$(kubectl get events -n "$NAMESPACE" \
  --field-selector reason=FailedScheduling \
  --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo -e "  FailedScheduling events in kubectl: ${CYAN}$FAIL_COUNT${NC}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  kubectl get events -n "$NAMESPACE" \
    --field-selector reason=FailedScheduling \
    -o custom-columns="TIME:.firstTimestamp,REASON:.reason,MESSAGE:.message" \
    2>/dev/null | head -5
fi

# ── Phase 2: Schedulable victim → OOMKill (cross-pattern P004→P001) ─────
echo -e "\n${YELLOW}[4/6] Scheduler victim is already deployed — watching for OOMKill...${NC}"
echo -e "  (victim pod has 64Mi limit, allocating 128Mi → OOMKill expected)"
DETECTED=false
for i in $(seq 1 30); do
  sleep 2
  REASON=$(kubectl get pod scheduler-victim -n "$NAMESPACE" \
    -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || echo "")
  RESTARTS=$(kubectl get pod scheduler-victim -n "$NAMESPACE" \
    -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
  if [ "$REASON" = "OOMKilled" ] || [ "${RESTARTS:-0}" -gt "0" ]; then
    DETECTED=true; break
  fi
  echo -ne "  Elapsed: $((i*2))s — restarts=${RESTARTS:-0}\r"
done
echo ""

if [ "$DETECTED" = true ]; then
  echo -e "${GREEN}  ✓ OOMKill detected! P004→P001 cross-pattern chain active.${NC}"
  kubectl get pod scheduler-victim -n "$NAMESPACE" \
    -o custom-columns="NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,LAST-REASON:.status.containerStatuses[0].lastState.terminated.reason"
else
  echo -e "${YELLOW}  OOMKill not yet confirmed — collector may still capture it.${NC}"
fi

echo -e "\n${YELLOW}[5/6] Waiting 10s for collector to capture events...${NC}"
sleep 10

# ── Check OMA output ─────────────────────────────────────────────────────
echo -e "\n${YELLOW}[6/6] OMA collector output:${NC}"
EVENTS_FILE="$OUTPUT_DIR/events.jsonl"
if [ ! -f "$EVENTS_FILE" ]; then
  echo -e "${YELLOW}  No events file at $EVENTS_FILE${NC}"
  echo -e "  ${CYAN}Is the collector running?${NC}"
  echo "  ./collector/bin/collector --namespace oma-scheduler --output ./output"
else
  P004=$(grep -c '"pattern_id":"P004"' "$EVENTS_FILE" 2>/dev/null || echo 0)
  SCHED=$(grep -c '"event_type":"SchedulerEvent"' "$EVENTS_FILE" 2>/dev/null || echo 0)
  OOM=$(grep -c '"event_type":"OOMKill"' "$EVENTS_FILE" 2>/dev/null || echo 0)
  TOT=$(wc -l < "$EVENTS_FILE" | tr -d ' ')
  echo -e "  Total events:     $TOT"
  echo -e "  SchedulerEvents:  ${SCHED}  (P004)"
  echo -e "  OOMKill:          ${OOM}   (P001)"

  if [ "$SCHED" -gt 0 ]; then
    echo ""
    echo -e "${GREEN}  ✓ H2 evidence captured. Sample P004 record:${NC}"
    echo ""
    grep '"pattern_id":"P004"' "$EVENTS_FILE" 2>/dev/null | head -1 | \
      python3 -c "
import json,sys
r = json.loads(sys.stdin.read())
p = r.get('payload', {})
print(f\"    reason:       {p.get('reason')}\")
print(f\"    pod:          {r.get('pod_name')}\")
print(f\"    message:      {p.get('message','')[:80]}\")
print(f\"    pruning_risk: {p.get('pruning_risk')}\")
print(f\"    age_seconds:  {p.get('age_seconds'):.1f}\")
print(f\"    expires:      {p.get('evidence_expires')}\")
" 2>/dev/null || echo "  (python3 not available for pretty print — check events.jsonl directly)"
    echo ""
    echo -e "${GREEN}  ✓ Key finding:${NC}"
    echo -e "  After event TTL expires, kubectl returns:"
    echo -e "  ${RED}  kubectl get events -n oma-scheduler → No resources found${NC}"
    echo -e "  OMA still returns the full scheduler decision chain."
    echo ""
    echo -e "  ${CYAN}To query:${NC}"
    echo -e "  ${CYAN}cd storage && python ingest.py --events ../output/events.jsonl${NC}"
    echo -e "  ${CYAN}sqlite3 memory.db 'SELECT reason, message, pruning_risk FROM scheduler_events;'${NC}"
  else
    echo -e "${YELLOW}  No P004 events yet — confirm collector is running:${NC}"
    echo -e "  ${CYAN}./collector/bin/collector --namespace oma-scheduler --output ./output${NC}"
  fi
fi

echo ""
read -p "Clean up scenario resources? [y/N] " cleanup
if [[ "$cleanup" == "y" || "$cleanup" == "Y" ]]; then
  kubectl delete -f "$SCENARIO_DIR/deploy.yaml" --ignore-not-found
  echo -e "${GREEN}  ✓ Cleaned up${NC}"
fi
echo ""