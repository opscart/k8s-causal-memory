# k8s-causal-memory

**Operational Memory Architecture (OMA) for Kubernetes** — an open-source system that captures, stores, and queries causal event chains in Kubernetes clusters, preserving diagnostic context that the platform's native event retention model discards within 90 seconds.

---

## The Problem

When a Kubernetes pod crashes, the platform gives you approximately **90 seconds** to capture the evidence before it's overwritten. The `LastTerminationState` field — which records the exact reason, exit code, and resource context of a container failure — is replaced the moment a new restart cycle begins.

```
T=0s    OOMKill fires      ← exit_code=137, memory=64Mi, ConfigMap=oom-app-config
T=15s   Pod restarts       ← LastTerminationState overwritten
T=90s   kubectl describe   ← Error: evidence rotated, partial data only
T+5min  On-call arrives    ← kubectl get pod: Error from server (NotFound)
```

Existing tools — Prometheus, Grafana, ELK — record *what* happened. None preserve the causal context linking *why* it happened, *which configuration was active*, or *what the cluster state was at the exact moment of failure*.

---

## What OMA Captures

Three causal patterns encoded as first-class definitions:

| Pattern | Trigger | What OMA Preserves |
|---------|---------|-------------------|
| **P001** OOMKill Chain | Container OOMKilled | Exit code, resource limits, ConfigMaps in effect, node state — frozen at kill time |
| **P002** ConfigMap Env Var Stale | ConfigMap updated | Content hash delta, changed keys, list of pods still running with old values |
| **P003** ConfigMap Mount Swap | ConfigMap updated | Kubelet symlink swap timestamp, propagation latency measurement |

---

## Architecture

OMA comprises four layers:

```
┌─────────────────────────────────────────────────────┐
│              Kubernetes API Server                   │
│        (Pod / Node / ConfigMap watch streams)        │
└──────────────┬──────────────────┬───────────────────┘
               │                  │
┌──────────────▼──────────────────▼───────────────────┐
│  Layer 1 — Go Collector (collector/)                 │
│  PodWatcher │ NodeWatcher │ ConfigMapWatcher         │
│  Captures events with full payload at moment of      │
│  occurrence → output/events.jsonl                    │
└──────────────────────────┬──────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────┐
│  Layer 2 — Operational Memory Store (storage/)       │
│  SQLite (WAL mode) — 4 tables:                       │
│  events │ causal_edges │ snapshots │ patterns        │
│  Causal edges built automatically on ingest          │
└──────────────────────────┬──────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────┐
│  Layer 3 — Query Interface (storage/query.py)        │
│  Q1: causal-chain   "What caused this failure?"      │
│  Q2: pattern-history "Has this happened before?"     │
│  Q3: state-at       "What was the state at time T?"  │
└──────────────────────────┬──────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────┐
│  Layer 4 — Integration Surface (storage/api.py)      │
│  REST API │ Alert webhooks │ AI diagnosis integrations│
└─────────────────────────────────────────────────────┘
```

---

## Quick Start

### Prerequisites

- Go 1.21+
- Python 3.11+
- kubectl configured against a cluster
- Minikube (for local testing) or any Kubernetes cluster

### Build the Collector

```bash
cd collector
go build -o bin/collector .
```

### Run a Scenario

**Terminal 1 — Start the collector:**
```bash
./collector/bin/collector --namespace oma-demo --output ./output
```

**Terminal 2 — Run a scenario:**
```bash
bash scenarios/01-oomkill/trigger.sh
```

### Ingest and Query

```bash
cd storage
pip install -r requirements.txt
python ingest.py --events ../output/events.jsonl --snapshots ../output/snapshots.jsonl
python query.py summary
python query.py causal-chain --pod <pod-name> --namespace oma-demo
python query.py pattern-history --pattern P001
```

---

## Proof of Concept Results

All results are reproducible from the JSONL files committed in `docs/poc-results/`. The collector was run on two independent cluster environments.

### Environment 1 — Minikube (local, 3 nodes)

**Scenario 01: OOMKill Causal Chain (P001)**

```
Events: 30  |  Causal edges: 13  |  Snapshots: 1
Pattern P001: 22 events across 4 restart cycles

Q1 Causal Chain:
  OOMKill  2026-02-27T00:10:48
    Node: opscart-m02
    Limits: cpu=100m  memory=64Mi
    ConfigMaps in effect: ['oom-app-config']
    Exit code: 1  Restart count: 4

⚠ Pattern P001 has fired 22 times — escalate to human review.
```

**Scenario 02: ConfigMap Env Var (P002)**

```
ConfigMapChanged  app-feature-config
  old_hash: 72f628cdff16ed24 → new_hash: 960c779cc1c53b0f
  changed_keys: [feature.flag, db.pool.size, api.timeout.ms, log.level]

Pod status after change:
  config-consumer-env-*: FEATURE_FLAG=disabled  ← STALE (ConfigMap now: enabled)
  config-consumer-env-*: FEATURE_FLAG=disabled  ← STALE
  Restart count: 0  (no restart triggered — this is the bug)
```

### Environment 2 — Azure Kubernetes Service (AKS 1.32.10, 2× Standard_B2s)

```
Events: 20  |  Causal edges: 8  |  Snapshots: 1
Node: aks-nodepool1-78296979-vmss000000

Q1 Causal Chain:
  OOMKill  2026-03-01T17:19:44
    Node: aks-nodepool1-78296979-vmss000000
    Limits: cpu=100m  memory=64Mi
    ConfigMaps in effect: ['oom-app-config']
    Exit code: 137  Restart count: 3

Raw Causal Edges (8 total, all conf=1.0):
  OOMKill → OOMKillEvidence  (0.27ms gap)
  OOMKill → OOMKillEvidence  (1.09ms gap)
  ... (6 more)

Q3 Point-in-Time Snapshot:
  Pod/oom-victim-68f4d5ffd7-bvpcv (oma-demo)
  Trigger: PodDeleted
  Limits: {'oom-victim': {'cpu': '100m', 'memory': '64Mi'}}
  ConfigMaps: ['oom-app-config']
  Phase: Failed
  ← kubectl returns 404 for this pod. OMA returns full state.
```

**All scenarios on AKS:**

| Scenario | Events | Key Metric | Result |
|----------|--------|-----------|--------|
| P001 OOMKill | 20 | Causal edges | 8 (conf=1.0), exit code 137, node aks-nodepool1-78296979-vmss000000 |
| P002 ConfigMap env | 2 | Hash delta captured | 72f628cd → 8ee0c528, 4 keys changed |
| P003 ConfigMap mount | 2 | Propagation latency | <30s symlink swap confirmed |

---

## Statistical Latency Analysis (30 Runs)

To quantify causal edge construction latency, we ran the P001 OOMKill scenario
30 independent times on Minikube, yielding 242 total causal edges.

The distribution is **bimodal**, reflecting two structurally distinct edge types:

| Edge Class | Count | Min | Mean | Max |
|------------|-------|-----|------|-----|
| Intra-cycle (<100ms) — same restart cycle | 88 | 0.089ms | **0.702ms** | 2.607ms |
| Cross-cycle (≥100ms) — across restart boundaries | 154 | 903ms | 12,708ms | 31,454ms |

- **Intra-cycle edges**: OOMKillEvidence captured within the same restart cycle — sub-millisecond latency confirms synchronous evidence capture before rotation
- **Cross-cycle edges**: OOMKillEvidence events linked back to OOMKill events from prior restart cycles — latency reflects actual restart interval timing (10–30s), not processing delay

Run the full breakdown across all 30 runs:

```bash
bash scripts/analyze-latency.sh
```

---

## Stress Evaluation (Concurrent OOMKill Pods)

We deployed 5, 10, and 20 simultaneous crash-looping pods on Minikube for 120 seconds each:

| Pods | Events | Events/sec | Edges | Collector RAM | Collector CPU |
|------|--------|-----------|-------|--------------|--------------|
| 5    | 95     | 0.77      | 51    | 7.9 MB       | <0.1%        |
| 10   | 175    | 1.43      | 90    | 8.2 MB       | <0.1%        |
| 20   | 355    | 2.86      | 197   | 8.8 MB       | <0.1%        |

Event ingestion scales **linearly** with pod count. Collector memory stays flat at
8–9 MB regardless of load — the streaming JSONL model accumulates no in-memory state.

---

## What kubectl Cannot Do

| Capability | kubectl | OMA |
|-----------|---------|-----|
| OOMKill evidence after restart | Lost in <90s | Preserved indefinitely |
| Resource limits at kill time | Lost with pod | Frozen in snapshot |
| ConfigMap in effect at failure | Not available | Captured with refs |
| Stale env var detection | Not possible | P002 pattern |
| State of deleted objects | `Error (NotFound)` | Q3 state-at query |
| Causal chain reconstruction | Not possible | Q1 with edges |
| Pattern recurrence detection | Not possible | Q2 with escalation |

---

## Repository Structure

```
k8s-causal-memory/
├── collector/              # Go Kubernetes event collector
│   ├── main.go
│   ├── watcher/            # Pod, Node, ConfigMap watchers
│   ├── patterns/           # P001, P002, P003 encoders
│   └── emitter/            # JSONL output
├── storage/                # Python storage and query layer
│   ├── schema.sql          # SQLite schema (4 tables)
│   ├── ingest.py           # JSONL → SQLite + causal edge construction
│   ├── query.py            # Q1 / Q2 / Q3 canonical queries
│   └── api.py              # REST API (Layer 4)
├── scenarios/
│   ├── 01-oomkill/         # P001: OOMKill causal chain
│   ├── 02-configmap-env/   # P002: Env var silent misconfiguration
│   └── 03-configmap-mount/ # P003: Volume mount symlink swap
├── scripts/
│   └── analyze-latency.sh  # Bimodal latency breakdown across 30 runs
├── docs/
│   ├── architecture.md
│   └── poc-results/        # Committed JSONL + query outputs (reproducible)
│       ├── 01-oomkill/
│       ├── 02-configmap-env/
│       ├── 03-configmap-mount/
│       ├── aks-final/      # AKS 1.32.10 run
│       ├── latency-stats/  # 30-run statistical latency analysis
│       └── stress-eval/    # 5/10/20 pod concurrent stress evaluation
├── run-latency-stats.sh    # Automates 30-run latency collection
├── run-stress-eval.sh      # Automates stress evaluation
└── save-results.sh         # Preserve run output to docs/poc-results/
```

---

## Scenarios

### Scenario 01: OOMKill (P001)

Deploys a pod with a 64Mi memory limit configured to allocate 128Mi. Captures the full OOMKill causal chain before the 90-second evidence horizon.

```bash
bash scenarios/01-oomkill/trigger.sh
```

### Scenario 02: ConfigMap Env Var Stale Config (P002)

Deploys 2 pods consuming a ConfigMap as environment variables. Updates the ConfigMap and proves pods continue running with stale values — zero restarts, zero awareness.

```bash
bash scenarios/02-configmap-env/trigger.sh
```

### Scenario 03: ConfigMap Volume Mount Propagation (P003)

Deploys a pod consuming a ConfigMap as a volume mount. Measures kubelet symlink swap propagation latency after a ConfigMap update.

```bash
bash scenarios/03-configmap-mount/trigger.sh
```

---

## Canonical Queries

```bash
# Q1: What caused this OOMKill? (causal chain reconstruction)
python query.py causal-chain --pod <pod-name> --namespace oma-demo

# Q2: Has this pattern occurred before? (recurrence detection)
python query.py pattern-history --pattern P001  # or P002, P003

# Q3: What was the cluster state at time T? (point-in-time, even after deletion)
python query.py state-at --kind Pod --name <pod-name> --namespace oma-demo --at "2026-03-01T17:19:44"
```

---

## Contributing

Additional pattern encoders, storage backends, and integration adapters are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

Pattern contributions should follow the existing structure in `collector/patterns/` and include:
- A causal pattern definition (trigger, evidence, effect, temporal windows)
- A scenario trigger script in `scenarios/`
- Expected output in `scenarios/<n>/expected-output.json`

---

## License

MIT License — see [LICENSE](LICENSE).

---

*Built and validated on Minikube and Azure Kubernetes Service 1.32.10.*