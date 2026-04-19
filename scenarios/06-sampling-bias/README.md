# Scenario 06: Observability Sampling Bias (H5)

**Evidence Horizon H5** — Scrape interval blind spot

## The Problem

Prometheus scrapes metrics on a fixed interval (default: 15s). Any pod whose
entire lifecycle falls within a single scrape gap generates **zero time-series
data**. This is not a configuration issue — it is a structural property of
poll-based observability.

```
Prometheus timeline (15s scrape interval):

  T=0s    ← scrape fires   (ghost-pod not yet created)
  T=7s      ghost-pod starts, allocates 128Mi, OOMKills   ← INVISIBLE
  T=15s   ← scrape fires   (ghost-pod already gone: NotFound)

  PromQL: container_cpu_usage_seconds_total{pod="ghost-pod"} → {} (empty)
  PromQL: kube_pod_container_status_last_terminated_reason{pod="ghost-pod"} → {} (empty)
```

OMA subscribes to the Kubernetes watch API. Every event is delivered at
the moment it occurs — no polling gap exists.

## No New Pattern Required

H5 uses OMA's existing **P001** pattern. The point is not what OMA captures —
that is unchanged from H1 — but *when*. OMA's watch-based architecture has no
sampling blind spot. This scenario is an analysis demonstration, not a new
pattern encoder.

## Architecture Distinction

| | Prometheus | OMA |
|---|---|---|
| Architecture | Poll-based | Event-driven |
| Capture mechanism | Scrape every N seconds | Kubernetes watch API |
| Sub-interval pods | Invisible | Captured at occurrence |
| OOMKill reason | Unknown (0 datapoints) | exit_code=137, preserved |
| Causal chain | Impossible | P001 full chain |

## Running

```bash
# Terminal 1 — collector
./collector/bin/collector --namespace oma-sampling --output ./output

# Terminal 2 — scenario
bash scenarios/06-sampling-bias/trigger.sh
```

## After the scenario

```bash
cd storage
python ingest.py --events ../output/events.jsonl --snapshots ../output/snapshots.jsonl
sqlite3 memory.db \
  "SELECT pod_name, event_type, timestamp FROM events WHERE namespace='oma-sampling';"
```

## Note on Prometheus

This scenario does not require Prometheus to be installed. The architectural
argument is made by comparing the structural properties of poll-based vs
event-driven collection. If Prometheus is available in the `monitoring`
namespace, the PromQL queries in the trigger script will return empirical
empty results confirming the blind spot.