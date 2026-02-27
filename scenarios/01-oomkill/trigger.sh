#!/bin/bash
set -e
NAMESPACE="oma-demo"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/output"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

echo ""
echo -e "${CYAN}================================================${NC}"
echo -e "${CYAN} k8s-causal-memory — Scenario 01: OOMKill     ${NC}"
echo -e "${CYAN}================================================${NC}"
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

# Deploy
echo -e "\n${YELLOW}[1/5] Deploying oom-victim (limit: 64Mi, allocating: 128Mi)...${NC}"
kubectl apply -f "$SCENARIO_DIR/deploy.yaml"
echo -e "${GREEN}  ✓ Deployed${NC}"

# Wait for pod
echo -e "\n${YELLOW}[2/5] Waiting for pod...${NC}"
sleep 5
POD=$(kubectl get pod -n "$NAMESPACE" -l app=oom-victim -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
echo -e "${GREEN}  ✓ Pod: $POD${NC}"

# Watch for OOMKill
echo -e "\n${YELLOW}[3/5] Watching for OOMKill (~5-15 seconds)...${NC}"
DETECTED=false
for i in $(seq 1 30); do
  sleep 2
  REASON=$(kubectl get pod "$POD" -n "$NAMESPACE" \
    -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || echo "")
  RESTARTS=$(kubectl get pod "$POD" -n "$NAMESPACE" \
    -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
  if [ "$REASON" = "OOMKilled" ] || [ "${RESTARTS:-0}" -gt "0" ]; then
    DETECTED=true; break
  fi
  echo -ne "  Elapsed: $((i*2))s — restarts=${RESTARTS:-0}\r"
done
echo ""

if [ "$DETECTED" = true ]; then
  echo -e "${GREEN}  ✓ OOMKill detected! restarts=$RESTARTS${NC}"
  kubectl get pod "$POD" -n "$NAMESPACE" \
    -o custom-columns="NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,LAST-REASON:.status.containerStatuses[0].lastState.terminated.reason"
else
  echo -e "${YELLOW}  OOMKill not yet confirmed — collector should still capture it.${NC}"
fi

# Evidence window
echo -e "\n${YELLOW}[4/5] Waiting 15s for collector to capture LastTerminationState (90s window)...${NC}"
sleep 15

# Check output
echo -e "\n${YELLOW}[5/5] Collector output:${NC}"
EVENTS_FILE="$OUTPUT_DIR/events.jsonl"
if [ ! -f "$EVENTS_FILE" ]; then
  echo -e "${YELLOW}  No events file at $EVENTS_FILE${NC}"
  echo -e "  ${CYAN}Is the collector running?${NC}"
  echo "  ./collector/bin/collector --namespace oma-demo --output ./output"
else
  OOM=$(grep -c '"event_type":"OOMKill"' "$EVENTS_FILE" 2>/dev/null || echo 0)
  EVI=$(grep -c '"event_type":"OOMKillEvidence"' "$EVENTS_FILE" 2>/dev/null || echo 0)
  TOT=$(wc -l < "$EVENTS_FILE" | tr -d ' ')
  echo -e "  Total events:    $TOT"
  echo -e "  OOMKill:         ${OOM}"
  echo -e "  OOMKillEvidence: ${EVI}"
  if [ "$OOM" -gt 0 ]; then
    echo ""
    echo -e "${GREEN}  ✓ Causal memory captured. Now run:${NC}"
    echo ""
    echo -e "  ${CYAN}cd storage && source venv/bin/activate${NC}"
    echo -e "  ${CYAN}python ingest.py --events ../output/events.jsonl --snapshots ../output/snapshots.jsonl${NC}"
    echo -e "  ${CYAN}python query.py causal-chain --pod $POD --namespace $NAMESPACE${NC}"
  fi
fi

echo ""
read -p "Clean up scenario resources? [y/N] " cleanup
if [[ "$cleanup" == "y" || "$cleanup" == "Y" ]]; then
  kubectl delete -f "$SCENARIO_DIR/deploy.yaml" --ignore-not-found
  echo -e "${GREEN}  ✓ Cleaned up${NC}"
fi
echo ""
