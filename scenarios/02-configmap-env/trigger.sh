#!/bin/bash
# Scenario 02: ConfigMap Env Var Silent Misconfiguration (P002)
#
# What this proves:
#   - Collector captures ConfigMap change with content hash
#   - Pods consuming env vars show NO restart — absence is itself a signal
#   - Old env var value remains active in running pods
#   - kubectl cannot tell you "which pods are running stale config"
#   - OMA can: ConfigMapChanged event + no corresponding pod restart = P002

set -e
NAMESPACE="oma-demo"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCENARIO_DIR/../.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/output"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

echo ""
echo -e "${CYAN}===========================================================${NC}"
echo -e "${CYAN} k8s-causal-memory — Scenario 02: ConfigMap Env Var (P002) ${NC}"
echo -e "${CYAN}===========================================================${NC}"
echo ""

# Preflight
if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}ERROR: kubectl cannot reach cluster.${NC}"
  exit 1
fi
CONTEXT=$(kubectl config current-context)
echo -e "  Context: ${CYAN}$CONTEXT${NC}"

# Deploy
echo -e "\n${YELLOW}[1/6] Deploying config-consumer-env (2 replicas)...${NC}"
kubectl apply -f "$SCENARIO_DIR/deploy.yaml"

echo -e "\n${YELLOW}[2/6] Waiting for pods to be Ready...${NC}"
kubectl wait --for=condition=Ready pod \
  -l app=config-consumer-env \
  -n "$NAMESPACE" \
  --timeout=90s

PODS=$(kubectl get pods -n "$NAMESPACE" -l app=config-consumer-env \
  -o jsonpath='{.items[*].metadata.name}')
echo -e "${GREEN}  ✓ Pods running: $PODS${NC}"

# Show current env var values baked into pods
echo -e "\n${YELLOW}[3/6] Current env var in running pods (baked at startup):${NC}"
for POD in $PODS; do
  VAL=$(kubectl exec "$POD" -n "$NAMESPACE" -- sh -c 'echo $FEATURE_FLAG' 2>/dev/null || echo "error")
  echo -e "  ${CYAN}$POD${NC}: FEATURE_FLAG=${VAL}"
done

# Now update the ConfigMap — collector should capture this
echo -e "\n${YELLOW}[4/6] Updating ConfigMap (simulating ops team config change)...${NC}"
echo -e "  ${CYAN}Before:${NC} feature.flag=disabled"
echo -e "  ${CYAN}After: ${NC} feature.flag=enabled  ← this is the change"
echo ""

kubectl patch configmap app-feature-config -n "$NAMESPACE" \
  --type merge \
  -p '{"data":{"feature.flag":"enabled","db.pool.size":"25","api.timeout.ms":"5000"}}'

echo -e "${GREEN}  ✓ ConfigMap updated${NC}"
echo -e "  ${YELLOW}Collector should now emit: ConfigMapChanged (P002)${NC}"

# Wait and show pods have NOT restarted
echo -e "\n${YELLOW}[5/6] Waiting 20s — pods should NOT restart (that's the bug)...${NC}"
sleep 20

echo ""
echo -e "  Pod restart counts after ConfigMap change:"
kubectl get pods -n "$NAMESPACE" -l app=config-consumer-env \
  -o custom-columns="NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,STATUS:.status.phase"

echo ""
echo -e "  ${YELLOW}Env var still showing OLD value in running pods:${NC}"
for POD in $PODS; do
  VAL=$(kubectl exec "$POD" -n "$NAMESPACE" -- sh -c 'echo $FEATURE_FLAG' 2>/dev/null || echo "pod-gone")
  if [ "$VAL" = "enabled" ]; then
    echo -e "  ${GREEN}$POD: FEATURE_FLAG=${VAL} (updated — pod was restarted)${NC}"
  else
    echo -e "  ${RED}$POD: FEATURE_FLAG=${VAL} (STALE — ConfigMap changed but env not updated)${NC}"
  fi
done

echo ""
echo -e "  ${CYAN}This is P002: ConfigMap changed, pod not restarted, stale config in effect.${NC}"
echo -e "  ${CYAN}kubectl cannot detect this. OMA captures it as a causal event.${NC}"

# Check collector output
echo -e "\n${YELLOW}[6/6] Collector output:${NC}"
EVENTS_FILE="$OUTPUT_DIR/events.jsonl"
if [ ! -f "$EVENTS_FILE" ]; then
  echo -e "${YELLOW}  No events file. Is the collector running?${NC}"
  echo "  ./collector/bin/collector --namespace oma-demo --output ./output"
else
  CM_EVENTS=$(grep -c '"event_type":"ConfigMapChanged"' "$EVENTS_FILE" 2>/dev/null || echo 0)
  TOTAL=$(wc -l < "$EVENTS_FILE" | tr -d ' ')
  echo -e "  Total events:       $TOTAL"
  echo -e "  ConfigMapChanged:   ${CM_EVENTS}"

  if [ "$CM_EVENTS" -gt 0 ]; then
    echo ""
    echo -e "${GREEN}  ✓ P002 pattern captured. Run queries:${NC}"
    echo ""
    echo -e "  ${CYAN}cd storage && source venv/bin/activate${NC}"
    echo -e "  ${CYAN}python ingest.py --events ../output/events.jsonl --snapshots ../output/snapshots.jsonl${NC}"
    echo -e "  ${CYAN}python query.py pattern-history --pattern P002${NC}"
    echo ""
    # Show the raw ConfigMapChanged event for the article
    echo -e "  ${CYAN}Raw captured event:${NC}"
    grep '"event_type":"ConfigMapChanged"' "$EVENTS_FILE" | tail -1 | \
      python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps({
        'event_type': d['event_type'],
        'namespace': d['namespace'],
        'timestamp': d['timestamp'],
        'configmap': d['payload']['configmap_name'],
        'old_hash': d['payload']['old_content_hash'],
        'new_hash': d['payload']['new_content_hash'],
        'changed_keys': d['payload']['changed_keys']
      }, indent=2))" 2>/dev/null || echo "  (parse error — check events.jsonl directly)"
  fi
fi

echo ""
bash "$REPO_ROOT/save-results.sh" "02-configmap-env"

read -p "Clean up scenario resources? [y/N] " cleanup
if [[ "$cleanup" == "y" || "$cleanup" == "Y" ]]; then
  kubectl delete -f "$SCENARIO_DIR/deploy.yaml" --ignore-not-found
  echo -e "${GREEN}  ✓ Cleaned up${NC}"
fi
echo ""