# k8s-causal-memory

**Operational Memory Architecture (OMA) for Kubernetes** — an open-source system that captures, stores, and queries causal event chains in Kubernetes clusters, preserving diagnostic context that the platform's native evidence retention model discards on deterministic schedules.

---

## The Problem

Kubernetes operates multiple evidence destruction mechanisms simultaneously. When a pod crashes, the platform gives you approximately **90 seconds** to capture the evidence before `LastTerminationState` is overwritten. Scheduler placement decisions are pruned within **1 hour**. Ephemeral debug container state is discarded the moment the session ends — with no `lastState` field in the API spec. Sub-scrape-interval pods are invisible to poll-based observability tools entirely.

```
T=0s    OOMKill fires         ← exit_code=137, memory=64Mi, ConfigMap=oom-app-config
T=15s   Pod restarts          ← LastTerminationState overwritten
T=90s   kubectl describe      ← Error: evidence rotated, partial data only
T+5min  On-call arrives       ← kubectl get pod: Error from server (NotFound)

T=0m    FailedScheduling      ← "0/3 nodes available: 3 Insufficient memory"
T+1hr   kubectl get events    ← No resources found in namespace

T=0s    kubectl debug starts  ← ephemeral container attached
T=10s   Debug session exits   ← exit_code=42, duration=10s
T=10s   kubectl describe pod  ← no lastState field (excluded by API spec)
```

Existing tools — Prometheus, Grafana, ELK — record *what* happened. None preserve the causal context linking *why* it happened, *which configuration was active*, *what the scheduler decided*, or *what a debug session found* at the exact moment of failure.

---

## Research & Coverage

| Resource | Link |
|---|---|
| Research preprint (V1 — H1) | [Zenodo DOI: 10.5281/zenodo.19685352](https://doi.org/10.5281/zenodo.19685352) |
| Extended paper (H1–H5) | [arXiv submit/7506671](https://arxiv.org/abs/submit/7506671) |
| OpsCart canonical article | [Beyond the 90-Second Gap](https://opscart.com/kubernetes-evidence-horizons-h2-h3-h4-h5/) |
| OpsCart H1 article | [The 90-Second Evidence Gap](https://opscart.com/when-kubernetes-forgets-the-90-second-evidence-gap/) |
| DZone article (H5) | [The Pod Prometheus Never Saw](https://dzone.com/articles/k8s-sampling-blind-spot) |
| CNCF Blog (H3) | Pending publication |

---

## Evidence Horizon Taxonomy

OMA formalises five distinct evidence destruction mechanisms as **evidence horizons** — deterministic points after which diagnostic context becomes unrecoverable from the Kubernetes API:

| Horizon | TTL | Mechanism | Data Lost | OMA Coverage |
|---------|-----|-----------|-----------|--------------|
| **H1** LastTerminationState | ~90s per restart | Pod restart overwrites field | Exit code, limits, ConfigMaps at kill time, node state | P001–P003 — full capture |
| **H2** Scheduler Events | 1hr / 1000 cluster events | kube-apiserver TTL pruning | Placement decisions, predicate failures, node rejection reasons | P004 — full capture |
| **H3** Ephemeral Container | Immediate on exit | API spec: no `lastState` field | Debug session exit code, duration, target container context | P005 — full capture |
| **H4** Kubelet Restart Gap | Node restart duration | In-memory state not persisted | Pending volume ops, probe state, image pull progress | Theoretical — future work |
| **H5** Scrape Interval Blind Spot | Per scrape interval | Poll-based collection architecture | Sub-interval pod lifetimes invisible to Prometheus | P001 (existing) — architectural distinction |

### H3 Precise Claim

The H3 claim is structural, not temporal. `EphemeralContainerStatus` has no `lastState` field by Kubernetes API spec (v1.32). A regular container's `ContainerStatus.lastState` records the prior termination and survives across restarts — this is how P001 captures OOMKill evidence. Ephemeral containers have no equivalent mechanism. Once a second debug session is attached, or the pod is rescheduled, the prior session's exit code, duration, and target container context are unrecoverable from the API.

### H4 Scope

H4 identifies the kubelet reconciliation gap as a fifth evidence horizon. When a kubelet restarts, it re-discovers running pods from the container runtime (CRI) but loses all transient in-memory state. Full causal capture requires a kubelet-level integration outside the current OMA architecture. H4 is documented as a theoretical horizon and identified as future work.

### H5 Architectural Distinction

H5 is not a new OMA pattern — it demonstrates OMA's existing structural advantage. Prometheus samples the world every N seconds; any pod whose entire lifetime falls within one scrape gap is architecturally invisible. OMA subscribes to the Kubernetes watch API; every event is delivered at occurrence with no sampling gap. This is a property of architecture, not configuration.

---

## What OMA Captures

Five causal patterns encoded as first-class definitions:

| Pattern | Trigger | What OMA Preserves |
|---------|---------|-------------------|
| **P001** OOMKill Chain | Container OOMKilled | Exit code, resource limits, ConfigMaps in effect, node state — frozen at kill time |
| **P002** ConfigMap Env Var Stale | ConfigMap updated | Content hash delta, changed keys, list of pods still running with old values |
| **P003** ConfigMap Mount Swap | ConfigMap updated | Kubelet symlink swap timestamp, propagation latency measurement |
| **P004** Scheduler Provenance | Pod scheduling | FailedScheduling predicate failures, placement decision — before 1hr kube-apiserver TTL |
| **P005** Ephemeral Exit | kubectl debug session ends | Exit code, duration, target container — `EphemeralContainerStatus` has no `lastState` field by API spec |

---

## Architecture

OMA comprises four layers:

```
┌─────────────────────────────────────────────────────────┐
│                Kubernetes API Server                     │
│   (Pod / Node / ConfigMap / Event watch streams)         │
└──────────┬───────────────────────────┬───────────────────┘
           │                           │
┌──────────▼───────────────────────────▼───────────────────┐
│  Layer 1 — Go Collector (collector/)                      │
│  PodWatcher     │ NodeWatcher    │ ConfigMapWatcher        │
│  EventWatcher (H2) │ EphemeralWatcher (H3)                │
│  Captures events with full payload at moment of           │
│  occurrence → output/events.jsonl                         │
└──────────────────────────┬────────────────────────────────┘
                           │
┌──────────────────────────▼────────────────────────────────┐
│  Layer 2 — Operational Memory Store (storage/)            │
│  SQLite (WAL mode) — 6 tables:                            │
│  events │ causal_edges │ snapshots │ patterns             │
│  scheduler_events (H2) │ ephemeral_exits (H3)             │
│  Causal edges built automatically on ingest               │
└──────────────────────────┬────────────────────────────────┘
                           │
┌──────────────────────────▼────────────────────────────────┐
│  Layer 3 — Query Interface (storage/query.py)             │
│  Q1: causal-chain    "What caused this failure?"          │
│  Q2: pattern-history "Has this happened before?"          │
│  Q3: state-at        "What was the state at time T?"      │
└──────────────────────────┬────────────────────────────────┘
                           │
┌──────────────────────────▼────────────────────────────────┐
│  Layer 4 — Integration Surface (storage/api.py)           │
│  REST API │ Alert webhooks │ AI diagnosis integrations     │
└────────────────────────────────────────────────────────────┘
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

### Apply Storage Schema

```bash
sqlite3 storage/memory.db < storage/schema.sql     # base schema
sqlite3 storage/memory.db < storage/schema_v2.sql  # H2: scheduler_events table
sqlite3 storage/memory.db < storage/schema_v3.sql  # H3: ephemeral_exits table
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
python query.py causal-chain --pod <pod-name> --namespace oma-demo
python query.py pattern-history --pattern P001
```

---

## Proof of Concept Results

All results are reproducible from the JSONL files committed in `docs/poc-results/`. The collector was run across two independent cluster environments.

### Environment 1 — Minikube (local, 3 nodes: opscart, opscart-m02, opscart-m03)

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
  Restart count: 0  (no restart triggered — this is the bug)
```

**Scenario 04: Scheduler Decision Provenance (P004) — H2**

```
SchedulerEvents captured: 2  |  Cross-pattern edges: 1 (P004→P001, conf=0.8)

FailedScheduling  2026-04-17T16:29:01Z
  Message: 0/3 nodes are available: 3 Insufficient memory.
           preemption: 0/3 nodes are available: 3 Preemption is not helpful.
  pruning_risk: LOW
  evidence_expires: 2026-04-17T17:29:01Z

Scheduled  2026-04-17T16:29:01Z → opscart-m02

OOMKill (P001)  2026-04-17T16:29:31Z  ← cross-pattern P004→P001, conf=0.8
  exit_code=137  memory_limit=64Mi  node=opscart-m02

After 2min TTL:
  kubectl get events -n oma-scheduler → No resources found
  OMA scheduler_events table          → full chain preserved
```

**Scenario 05: Ephemeral Container Evidence Loss (P005) — H3**

```
EphemeralContainerTerminated  2026-04-17T16:43:46Z
  container:        oma-debug-1776446626
  target_container: app
  exit_code:        42
  exit_class:       ERROR
  duration_seconds: 10.0
  node:             opscart-m02
  log_content:      NOT_CAPTURABLE_VIA_API

kubectl describe pod | grep lastState → (empty — no lastState field in spec)
OMA ephemeral_exits table            → full record preserved
```

**Scenario 06: Sampling Bias — H5**

```
Pod lifetime: 6s  |  Prometheus scrape interval: 15s

ghost-pod OOMKilled at T+5s (exit_code=137, node=opscart-m03)

Prometheus (poll-based):
  container_cpu_usage_seconds_total{pod="ghost-pod"} → {} (0 data points)
  Pod never scraped — lifetime < scrape interval

OMA (event-driven):
  OOMKill P001 captured at occurrence
  exit_code=137  node=opscart-m03
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

To quantify causal edge construction latency, we ran the P001 OOMKill scenario 30 independent times on Minikube, yielding 242 total causal edges.

The distribution is **bimodal**, reflecting two structurally distinct edge types:

| Edge Class | Count | Min | Mean | Max |
|------------|-------|-----|------|-----|
| Intra-cycle (<100ms) — same restart cycle | 88 | 0.089ms | **0.702ms** | 2.607ms |
| Cross-cycle (≥100ms) — across restart boundaries | 154 | 903ms | 12,708ms | 31,454ms |

- **Intra-cycle edges**: OOMKillEvidence captured within the same restart cycle — sub-millisecond latency confirms synchronous evidence capture before rotation
- **Cross-cycle edges**: OOMKillEvidence events linked back to OOMKill events from prior restart cycles — latency reflects actual restart interval timing (10–30s), not processing delay

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

Event ingestion scales **linearly** with pod count. Collector memory stays flat at 8–9 MB regardless of load — the streaming JSONL model accumulates no in-memory state.

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
| Scheduler placement rationale | Lost after 1hr TTL | P004 — predicate failures and placement decision preserved |
| Ephemeral container exit code | No `lastState` field by API spec | P005 — exit code, duration, target container captured at termination |
| Sub-scrape-interval pod data | Never scraped by Prometheus | P001 — watch-based, no polling gap |

---

## Repository Structure

```
k8s-causal-memory/
├── collector/                    # Go Kubernetes event collector
│   ├── main.go
│   ├── watcher/
│   │   ├── pod_watcher.go        # P001–P003: pod lifecycle
│   │   ├── node_watcher.go       # node state snapshots
│   │   ├── configmap_watcher.go  # P002–P003: ConfigMap changes
│   │   ├── event_watcher.go      # P004: scheduler event pruning (H2)
│   │   └── ephemeral_watcher.go  # P005: ephemeral container exit (H3)
│   ├── patterns/
│   │   ├── patterns.go           # CausalPattern / PatternStep types
│   │   ├── oomkill.go            # P001
│   │   ├── configmap_env.go      # P002
│   │   ├── configmap_mount.go    # P003
│   │   ├── p004_scheduler.go     # P004 (H2)
│   │   └── p005_ephemeral.go     # P005 (H3)
│   └── emitter/
│       └── json_emitter.go       # thread-safe JSONL output
├── storage/                      # Python storage and query layer
│   ├── schema.sql                # Base schema (events, causal_edges, snapshots, patterns)
│   ├── schema_v2.sql             # H2 migration: scheduler_events table
│   ├── schema_v3.sql             # H3 migration: ephemeral_exits table
│   ├── ingest.py                 # JSONL → SQLite + causal edge construction
│   ├── ingest_v2.py              # P004 and P005 extended ingestion
│   ├── query.py                  # Q1 / Q2 / Q3 canonical queries
│   └── api.py                    # REST API (Layer 4)
├── scenarios/
│   ├── 01-oomkill/               # P001: OOMKill causal chain (H1)
│   ├── 02-configmap-env/         # P002: Env var silent misconfiguration (H1)
│   ├── 03-configmap-mount/       # P003: Volume mount symlink swap (H1)
│   ├── 04-scheduler-pruning/     # P004: Scheduler decision provenance (H2)
│   ├── 05-ephemeral-exit/        # P005: Ephemeral container evidence loss (H3)
│   └── 06-sampling-bias/         # H5: Observability sampling bias (analysis)
├── docs/
│   ├── architecture.md
│   └── poc-results/
│       ├── 01-oomkill/
│       ├── 02-configmap-env/
│       ├── 03-configmap-mount/
│       ├── 04-scheduler-pruning/  # H2: screenshots + sqlite query output
│       ├── 05-ephemeral-exits/    # H3: screenshots + sqlite query output
│       ├── 06-sampling-bias/      # H5: screenshots
│       ├── aks-final/             # AKS 1.32.10 run
│       ├── latency-stats/         # 30-run statistical latency analysis
│       └── stress-eval/           # 5/10/20 pod concurrent stress evaluation
├── scripts/
│   └── analyze-latency.sh
├── run-latency-stats.sh
├── run-stress-eval.sh
└── save-results.sh
```

---

## Scenarios

### Scenario 01: OOMKill (P001) — H1

Deploys a pod with a 64Mi memory limit configured to allocate 128Mi. Captures the full OOMKill causal chain before the 90-second evidence horizon.

```bash
bash scenarios/01-oomkill/trigger.sh
```

### Scenario 02: ConfigMap Env Var Stale Config (P002) — H1

Deploys 2 pods consuming a ConfigMap as environment variables. Updates the ConfigMap and proves pods continue running with stale values — zero restarts, zero awareness.

```bash
bash scenarios/02-configmap-env/trigger.sh
```

### Scenario 03: ConfigMap Volume Mount Propagation (P003) — H1

Deploys a pod consuming a ConfigMap as a volume mount. Measures kubelet symlink swap propagation latency after a ConfigMap update.

```bash
bash scenarios/03-configmap-mount/trigger.sh
```

### Scenario 04: Scheduler Decision Provenance (P004) — H2

Deploys an unschedulable pod (999Gi request) triggering `FailedScheduling` events, then a schedulable victim that OOMKills. Demonstrates the cross-pattern chain P004→P001 and proves OMA preserves scheduler decisions after the kube-apiserver event TTL expires.

```bash
# Short TTL makes the evidence gap demonstrable in minutes
minikube start --extra-config=apiserver.event-ttl=2m
bash scenarios/04-scheduler-pruning/trigger.sh
```

### Scenario 05: Ephemeral Container Evidence Loss (P005) — H3

Deploys a stable target pod and attaches a `kubectl debug` ephemeral container that runs for 10 seconds and exits with code 42. Demonstrates that `EphemeralContainerStatus` has no `lastState` field — OMA is the only mechanism that preserves exit code, duration, and target container context after the session ends.

```bash
bash scenarios/05-ephemeral-exit/trigger.sh
```

### Scenario 06: Observability Sampling Bias — H5

Deploys a ghost pod designed to OOMKill within 6 seconds — inside one 15-second Prometheus scrape interval. Demonstrates the structural blind spot of poll-based observability. No new OMA pattern is required: existing P001 capture proves the architectural distinction.

```bash
bash scenarios/06-sampling-bias/trigger.sh
```

### H4: Kubelet Restart Gap — Theoretical

H4 is documented as a theoretical evidence horizon in the taxonomy above. Kubelet in-memory state loss during node restart requires a kubelet-level integration outside the current OMA architecture. No scenario is provided for H4. Future work.

---

## Canonical Queries

```bash
# Q1: What caused this OOMKill? (causal chain reconstruction)
python query.py causal-chain --pod <pod-name> --namespace oma-demo

# Q2: Has this pattern occurred before? (recurrence detection)
python query.py pattern-history --pattern P001  # or P002, P003, P004, P005

# Q3: What was the cluster state at time T? (point-in-time, even after deletion)
python query.py state-at --kind Pod --name <pod-name> --namespace oma-demo --at "2026-03-01T17:19:44"

# H2: Scheduler provenance (survives event TTL)
sqlite3 storage/memory.db \
  'SELECT reason, message, pruning_risk, timestamp FROM scheduler_events ORDER BY timestamp;'

# H2: Cross-pattern causal edges
sqlite3 storage/memory.db \
  "SELECT id, pattern_id, confidence, edge_type FROM causal_edges WHERE pattern_id='P004';"

# H3: Ephemeral exit records (no lastState in API spec)
sqlite3 storage/memory.db \
  'SELECT container_name, target_container, exit_code, exit_class, duration_seconds FROM ephemeral_exits;'
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

*Built and validated on Minikube (3-node, arm64) and Azure Kubernetes Service 1.32.10.*
