#!/bin/bash
# Scenario 03: ConfigMap Volume Mount Symlink Swap (P003)
set -e
NAMESPACE="oma-demo"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/output"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

echo ""
echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN} k8s-causal-memory — Scenario 03: ConfigMap Mount Swap (P003)  ${NC}"
echo -e "${CYAN}================================================================${NC}"
echo ""

if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}ERROR: kubectl cannot reach cluster.${NC}"
  exit 1
fi
CONTEXT=$(kubectl config current-context)
echo -e "  Context: ${CYAN}$CONTEXT${NC}"

# Deploy
echo -e "\n${YELLOW}[1/7] Deploying config-consumer-mount...${NC}"
kubectl apply -f "$SCENARIO_DIR/deploy.yaml"

echo -e "\n${YELLOW}[2/7] Waiting for pod to be Ready...${NC}"
kubectl wait --for=condition=Ready pod \
  -l app=config-consumer-mount \
  -n "$NAMESPACE" \
  --timeout=90s

POD=$(kubectl get pod -n "$NAMESPACE" -l app=config-consumer-mount \
  -o jsonpath='{.items[0].metadata.name}')
echo -e "${GREEN}  ✓ Pod: $POD${NC}"

# Show symlink structure
echo -e "\n${YELLOW}[3/7] Inspecting kubelet symlink structure in pod:${NC}"
kubectl exec "$POD" -n "$NAMESPACE" -- sh -c 'ls -la /etc/app-config/' 2>/dev/null || true
kubectl exec "$POD" -n "$NAMESPACE" -- sh -c \
  'find /etc/app-config -maxdepth 1 -type l | while read f; do echo "  $f -> $(readlink $f)"; done' 2>/dev/null || true

# Record pre-change state
echo -e "\n${YELLOW}[4/7] Recording pre-change state:${NC}"
PRE_CONTENT=$(kubectl exec "$POD" -n "$NAMESPACE" -- cat /etc/app-config/config.yaml 2>/dev/null || echo "error")
PRE_HASH=$(echo "$PRE_CONTENT" | md5sum | cut -d' ' -f1)
echo -e "  Pre-change hash: ${CYAN}$PRE_HASH${NC}"
echo -e "  feature_flags.new_ui: $(echo "$PRE_CONTENT" | grep new_ui || echo 'not found')"

CHANGE_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo -e "  Change timestamp: ${CYAN}$CHANGE_TIME${NC}"

# Update ConfigMap
echo -e "\n${YELLOW}[5/7] Updating ConfigMap (collector captures immediately)...${NC}"
echo -e "  Changing: new_ui=false → new_ui=true, pool_size=10 → pool_size=50"

kubectl patch configmap app-mount-config -n "$NAMESPACE" \
  --type merge \
  -p '{
    "data": {
      "config.yaml": "server:\n  port: 8080\n  timeout: 30s\ndatabase:\n  pool_size: 50\n  max_idle: 10\nfeature_flags:\n  new_ui: true\n  dark_mode: true\n"
    }
  }'

echo -e "${GREEN}  ✓ ConfigMap updated at $CHANGE_TIME${NC}"
echo -e "  ${YELLOW}Collector emits: ConfigMapChanged with content hash delta${NC}"

# Wait for kubelet symlink swap
echo -e "\n${YELLOW}[6/7] Waiting for kubelet symlink swap to propagate (~10-90s)...${NC}"
echo -e "  ${CYAN}This propagation delay is a key P003 data point for the arXiv paper${NC}"

PROPAGATED=false
ELAPSED=0
for i in $(seq 1 30); do
  sleep 3
  CURR=$(kubectl exec "$POD" -n "$NAMESPACE" -- cat /etc/app-config/config.yaml 2>/dev/null || echo "")
  if echo "$CURR" | grep -q "new_ui: true"; then
    PROP_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    PROPAGATED=true
    ELAPSED=$((i * 3))
    break
  fi
  echo -ne "  Waiting for kubelet symlink swap... ${i}/30 (~$((i*3))s elapsed)\r"
done
echo ""

if [ "$PROPAGATED" = true ]; then
  echo -e "${GREEN}  ✓ Symlink swap complete! Propagated in ~${ELAPSED}s${NC}"
  echo ""
  echo -e "  Current config.yaml in pod (updated WITHOUT restart):"
  kubectl exec "$POD" -n "$NAMESPACE" -- cat /etc/app-config/config.yaml 2>/dev/null | sed 's/^/    /'
  echo ""
  echo -e "  ${YELLOW}P003 Propagation window:${NC}"
  echo -e "    ConfigMap changed:   $CHANGE_TIME"
  echo -e "    File updated in pod: $PROP_TIME"
  echo -e "    Delay:               ~${ELAPSED} seconds"
  echo -e "  ${CYAN}OMA captures both timestamps. kubectl captures neither.${NC}"
else
  echo -e "${YELLOW}  Symlink swap not yet detected after 90s${NC}"
fi

# Check collector output
echo -e "\n${YELLOW}[7/7] Collector output:${NC}"
EVENTS_FILE="$OUTPUT_DIR/events.jsonl"
if [ ! -f "$EVENTS_FILE" ]; then
  echo -e "${YELLOW}  No events file. Is the collector running?${NC}"
  echo "  ./collector/bin/collector --namespace oma-demo --output ./output"
else
  CM_EVENTS=$(grep -c '"event_type":"ConfigMapChanged"' "$EVENTS_FILE" 2>/dev/null || echo 0)
  TOTAL=$(wc -l < "$EVENTS_FILE" | tr -d ' ')
  echo -e "  Total events:     $TOTAL"
  echo -e "  ConfigMapChanged: ${CM_EVENTS}"

  if [ "$CM_EVENTS" -gt 0 ]; then
    echo ""
    echo -e "${GREEN}  ✓ P003 pattern captured.${NC}"
    echo ""
    echo -e "  ${CYAN}Content hash delta:${NC}"
    grep '"event_type":"ConfigMapChanged"' "$EVENTS_FILE" | \
      grep 'app-mount-config' | tail -1 | \
      python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    p = d['payload']
    print(f'  configmap:    {p[\"configmap_name\"]}')
    print(f'  old_hash:     {p[\"old_content_hash\"]}')
    print(f'  new_hash:     {p[\"new_content_hash\"]}')
    print(f'  changed_keys: {p[\"changed_keys\"]}')
    print(f'  captured_at:  {d[\"timestamp\"]}')
except Exception as e:
    print(f'  (parse error: {e})')
" 2>/dev/null || echo "  (check events.jsonl directly)"
    echo ""
    echo -e "  ${CYAN}Run queries:${NC}"
    echo -e "  ${CYAN}cd storage && source venv/bin/activate${NC}"
    echo -e "  ${CYAN}python ingest.py --events ../output/events.jsonl --snapshots ../output/snapshots.jsonl${NC}"
    echo -e "  ${CYAN}python query.py pattern-history --pattern P003${NC}"
  fi
fi

# Save results
echo ""
bash "$REPO_ROOT/save-results.sh" "03-configmap-mount"

echo ""
read -p "Clean up scenario resources? [y/N] " cleanup
if [[ "$cleanup" == "y" || "$cleanup" == "Y" ]]; then
  kubectl delete -f "$SCENARIO_DIR/deploy.yaml" --ignore-not-found
  echo -e "${GREEN}  ✓ Cleaned up${NC}"
fi
echo ""