#!/bin/bash
set -e
NAMESPACE="oma-ephemeral"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/output"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} k8s-causal-memory — Scenario 05: Ephemeral Exit (H3)      ${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""
echo -e "  Evidence Horizon H3: EphemeralContainerStatus has no lastState"
echo -e "  field (Kubernetes API spec exclusion). When kubectl debug exits,"
echo -e "  the platform preserves nothing. OMA captures the full record."
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

# ── Deploy target pod ────────────────────────────────────────────────────
echo -e "\n${YELLOW}[1/6] Deploying target pod...${NC}"
kubectl apply -f "$SCENARIO_DIR/deploy.yaml"
echo -e "${GREEN}  ✓ Deployed${NC}"

echo -e "\n${YELLOW}[2/6] Waiting for target pod to be Running...${NC}"
kubectl wait pod ephemeral-target \
  --namespace="$NAMESPACE" \
  --for=condition=Ready \
  --timeout=60s
NODE=$(kubectl get pod ephemeral-target -n "$NAMESPACE" \
  -o jsonpath='{.spec.nodeName}')
echo -e "${GREEN}  ✓ Running on node: $NODE${NC}"

# ── Show pre-debug state ─────────────────────────────────────────────────
echo -e "\n${YELLOW}[3/6] Ephemeral containers BEFORE debug session:${NC}"
kubectl describe pod ephemeral-target -n "$NAMESPACE" | \
  grep -A 3 "Ephemeral Containers:" || \
  echo -e "  ${CYAN}Ephemeral Containers: <none>${NC}"

# ── Attach ephemeral debug container ────────────────────────────────────
DEBUG_CONTAINER="oma-debug-$(date +%s)"
echo -e "\n${YELLOW}[4/6] Attaching ephemeral debug container: $DEBUG_CONTAINER${NC}"
echo -e "  image=busybox:1.36  target=app  exit_code=42 (distinctive)"
echo -e "  Session will run ~10 seconds then exit..."

# Use kubectl debug without -it for scripted execution.
# The container runs, exits with code 42, then OMA captures the state.
kubectl debug ephemeral-target \
  --namespace="$NAMESPACE" \
  --image=busybox:1.36 \
  --target=app \
  --container="$DEBUG_CONTAINER" \
  -- sh -c 'echo "[debug] session started"; sleep 10; echo "[debug] exiting with 42"; exit 42' \
  2>/dev/null &

DEBUG_PID=$!
echo -e "  Debug session running (PID $DEBUG_PID)..."

# Wait for session to complete
echo -e "  Waiting 20s for session to exit..."
sleep 20
wait "$DEBUG_PID" 2>/dev/null || true
echo -e "${GREEN}  ✓ Debug session exited${NC}"

# Wait for collector to detect the Terminated transition
echo -e "\n${YELLOW}[5/6] Waiting 5s for collector to capture EphemeralContainerTerminated...${NC}"
sleep 5

# ── Show post-debug kubectl state (evidence gap) ─────────────────────────
echo -e "\n${YELLOW}[6/6] Evidence gap — what kubectl sees vs what OMA captured:${NC}"
echo ""
echo -e "${RED}  [kubectl — nothing preserved after exit]:${NC}"
echo -e "  kubectl logs ephemeral-target -c $DEBUG_CONTAINER -n $NAMESPACE:"
kubectl logs ephemeral-target \
  --container="$DEBUG_CONTAINER" \
  --namespace="$NAMESPACE" 2>&1 | head -3 || \
  echo -e "  ${RED}  Error: container not found (already exited)${NC}"

echo ""
echo -e "  kubectl describe pod (lastState for ephemeral container):"
kubectl describe pod ephemeral-target -n "$NAMESPACE" | \
  grep -A 15 "Ephemeral Containers:" | \
  grep -E "(State|Exit Code|Reason|Last State)" || \
  echo -e "  ${RED}  No lastState field — excluded by Kubernetes API spec${NC}"

# ── Check OMA output ─────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}  [OMA — full record preserved]:${NC}"
EVENTS_FILE="$OUTPUT_DIR/events.jsonl"
if [ ! -f "$EVENTS_FILE" ]; then
  echo -e "${YELLOW}  No events file at $EVENTS_FILE${NC}"
  echo -e "  ${CYAN}Is the collector running?${NC}"
  echo "  ./collector/bin/collector --namespace oma-ephemeral --output ./output"
else
  P005=$(grep -c '"pattern_id":"P005"' "$EVENTS_FILE" 2>/dev/null || echo 0)
  echo -e "  P005 events captured: ${P005}"

  if [ "$P005" -gt 0 ]; then
    echo ""
    grep '"pattern_id":"P005"' "$EVENTS_FILE" 2>/dev/null | tail -1 | \
      python3 -c "
import json,sys
r = json.loads(sys.stdin.read())
p = r.get('payload', {})
print(f\"    container:        {p.get('container_name')}\")
print(f\"    target_container: {p.get('target_container')}\")
print(f\"    exit_code:        {p.get('exit_code')}\")
print(f\"    exit_class:       {p.get('exit_class')}\")
print(f\"    duration_seconds: {p.get('duration_seconds'):.1f}\")
print(f\"    node:             {r.get('node_name')}\")
print(f\"    log_content:      {p.get('log_content')}\")
print(f\"    horizon:          {p.get('horizon')}\")
" 2>/dev/null || echo "  (python3 not available — check events.jsonl)"

    echo ""
    echo -e "${GREEN}  ✓ H3 evidence captured.${NC}"
    echo -e "  ${CYAN}To query:${NC}"
    echo -e "  ${CYAN}cd storage && python ingest.py --events ../output/events.jsonl${NC}"
    echo -e "  ${CYAN}sqlite3 memory.db 'SELECT container_name, target_container, exit_code, exit_class, duration_seconds FROM ephemeral_exits;'${NC}"
  else
    echo -e "${YELLOW}  No P005 events yet.${NC}"
    echo -e "  Confirm collector is running with --namespace oma-ephemeral"
    echo -e "  and that ephemeral containers are supported (k8s >= 1.25):"
    echo -e "  ${CYAN}kubectl version --short${NC}"
  fi
fi

echo ""
read -p "Clean up scenario resources? [y/N] " cleanup
if [[ "$cleanup" == "y" || "$cleanup" == "Y" ]]; then
  kubectl delete -f "$SCENARIO_DIR/deploy.yaml" --ignore-not-found
  echo -e "${GREEN}  ✓ Cleaned up${NC}"
fi
echo ""