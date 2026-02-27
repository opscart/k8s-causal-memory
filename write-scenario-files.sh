#!/bin/bash
# Run from k8s-causal-memory repo root
# Writes all scenario deploy.yaml files

set -e
REPO_ROOT="$(pwd)"
echo "Writing scenario files to: $REPO_ROOT"

# ── Scenario 02 deploy.yaml ───────────────────────────────────────────────────
cat > "$REPO_ROOT/scenarios/02-configmap-env/deploy.yaml" << 'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: oma-demo
  labels:
    purpose: k8s-causal-memory-poc
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-feature-config
  namespace: oma-demo
data:
  feature.flag: "disabled"
  db.pool.size: "10"
  log.level: "info"
  api.timeout.ms: "3000"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: config-consumer-env
  namespace: oma-demo
  labels:
    app: config-consumer-env
    scenario: "02-configmap-env"
spec:
  replicas: 2
  selector:
    matchLabels:
      app: config-consumer-env
  template:
    metadata:
      labels:
        app: config-consumer-env
    spec:
      containers:
      - name: app
        image: busybox
        command:
        - sh
        - -c
        - |
          echo "=== Pod started at $(date) ==="
          echo "FEATURE_FLAG=$FEATURE_FLAG  DB_POOL_SIZE=$DB_POOL_SIZE"
          while true; do
            echo "[$(date)] Running: feature=$FEATURE_FLAG pool=$DB_POOL_SIZE"
            sleep 30
          done
        env:
        - name: FEATURE_FLAG
          valueFrom:
            configMapKeyRef:
              name: app-feature-config
              key: feature.flag
        - name: DB_POOL_SIZE
          valueFrom:
            configMapKeyRef:
              name: app-feature-config
              key: db.pool.size
        - name: LOG_LEVEL
          valueFrom:
            configMapKeyRef:
              name: app-feature-config
              key: log.level
        - name: API_TIMEOUT_MS
          valueFrom:
            configMapKeyRef:
              name: app-feature-config
              key: api.timeout.ms
        resources:
          requests:
            memory: "16Mi"
            cpu: "10m"
          limits:
            memory: "32Mi"
            cpu: "50m"
YAML
echo "✓ scenarios/02-configmap-env/deploy.yaml"

# ── Scenario 03 deploy.yaml ───────────────────────────────────────────────────
cat > "$REPO_ROOT/scenarios/03-configmap-mount/deploy.yaml" << 'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: oma-demo
  labels:
    purpose: k8s-causal-memory-poc
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-mount-config
  namespace: oma-demo
data:
  config.yaml: |
    server:
      port: 8080
      timeout: 30s
    database:
      pool_size: 10
      max_idle: 5
    feature_flags:
      new_ui: false
      dark_mode: false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: config-consumer-mount
  namespace: oma-demo
  labels:
    app: config-consumer-mount
    scenario: "03-configmap-mount"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: config-consumer-mount
  template:
    metadata:
      labels:
        app: config-consumer-mount
    spec:
      containers:
      - name: app
        image: busybox
        command:
        - sh
        - -c
        - |
          echo "=== Pod started at $(date) ==="
          echo "=== Config mounted at /etc/app-config ==="
          ls -la /etc/app-config/
          echo ""
          echo "=== Initial config.yaml ==="
          cat /etc/app-config/config.yaml
          echo ""
          echo "=== Watching for kubelet symlink swap ==="
          PREV=$(cat /etc/app-config/config.yaml)
          while true; do
            CURR=$(cat /etc/app-config/config.yaml)
            if [ "$CURR" != "$PREV" ]; then
              echo "[$(date)] CONFIG CHANGED via symlink swap!"
              echo "New content:"
              cat /etc/app-config/config.yaml
              PREV=$CURR
            fi
            sleep 5
          done
        volumeMounts:
        - name: config-volume
          mountPath: /etc/app-config
          readOnly: true
        resources:
          requests:
            memory: "16Mi"
            cpu: "10m"
          limits:
            memory: "32Mi"
            cpu: "50m"
      volumes:
      - name: config-volume
        configMap:
          name: app-mount-config
YAML
echo "✓ scenarios/03-configmap-mount/deploy.yaml"

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
echo "Line counts:"
for f in \
  scenarios/02-configmap-env/deploy.yaml \
  scenarios/02-configmap-env/trigger.sh \
  scenarios/03-configmap-mount/deploy.yaml \
  scenarios/03-configmap-mount/trigger.sh; do
  if [ -f "$REPO_ROOT/$f" ]; then
    printf "  %4d lines  %s\n" "$(wc -l < "$REPO_ROOT/$f")" "$f"
  else
    echo "  MISSING: $f"
  fi
done

echo ""
echo "Done. Now run:"
echo "  bash scenarios/02-configmap-env/trigger.sh"
echo "  bash scenarios/03-configmap-mount/trigger.sh"