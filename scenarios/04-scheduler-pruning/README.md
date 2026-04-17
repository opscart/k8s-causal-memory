# Scenario 04: Scheduler Decision Provenance (P004)

**Evidence Horizon H2** — Scheduler event pruning

## The Problem

The Kubernetes scheduler records placement decisions as `Event` objects. These events — including which nodes were rejected and why — are retained by kube-apiserver for a maximum of **1 hour** (`--event-ttl` default) **or until 1,000 events cluster-wide**, whichever comes first.

Once pruned, it is impossible to answer:
- Why was this pod placed on node X and not node Y?
- Which nodes were rejected and for what reason?
- Did the pod land on the only node with marginal memory headroom?

```
T=0m    FailedScheduling — 0/1 nodes available: 1 Insufficient memory
T=2m    FailedScheduling — 0/1 nodes available: 1 Insufficient memory
T=5m    Scheduled → minikube
T=5m30s OOMKill — exit_code=137, memory=64Mi

T+1hr   kubectl get events -n oma-scheduler → "No resources found"
        OMA scheduler_events table → full chain preserved
```

## Cross-Pattern Chain (P004 → P001)

This scenario demonstrates OMA's first cross-horizon causal chain:

```
[H2] FailedScheduling (0/1: Insufficient memory) — P004
[H2] Scheduled → minikube                        — P004
[H1] OOMKill on minikube (exit_code=137)          — P001
     ↑
     Pod was placed on the only viable node,
     which had marginal memory headroom.
     This causal link is invisible after event pruning.
```

## Running

```bash
# Terminal 1 — start collector
./collector/bin/collector --namespace oma-scheduler --output ./output

# Terminal 2 — run scenario
bash scenarios/04-scheduler-pruning/trigger.sh
```

## Minikube: Make TTL Demonstrable

The default 1hr TTL is too long to demonstrate live. Use 2 minutes:

```bash
minikube start --extra-config=apiserver.event-ttl=2m
```

After 2 minutes, verify the evidence gap:

```bash
# kubectl returns empty
kubectl get events -n oma-scheduler

# OMA still has the full chain
sqlite3 storage/memory.db \
  'SELECT reason, message, pruning_risk FROM scheduler_events ORDER BY timestamp;'
```

## Expected Output

```
SchedulerEvents captured: 3+
  FailedScheduling × 2  (predicate: Insufficient memory)
  Scheduled × 1         (→ minikube)

OOMKill (P001) × 1      (exit_code=137, cross-pattern P004→P001)

After TTL:
  kubectl get events → No resources found
  OMA query         → Full chain preserved
```