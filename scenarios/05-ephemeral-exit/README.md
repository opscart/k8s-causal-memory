# Scenario 05: Ephemeral Container Evidence Loss (P005)

**Evidence Horizon H3** — EphemeralContainerStatus has no lastState field

## The Problem

The Kubernetes API spec (v1.32) explicitly excludes ephemeral containers from
the LastTerminationState mechanism. `EphemeralContainerStatus` has no `lastState`
field — unlike `ContainerStatus` which records the prior termination in full.

When a `kubectl debug` session exits:

```
T=0s    kubectl debug attached — ephemeral container running
T=10s   Debug container: exit 42

T=11s   kubectl logs ephemeral-target -c oma-debug-xxx
        → Error from server (NotFound): container not found

T=11s   kubectl describe pod | grep lastState
        → (empty — no lastState field in EphemeralContainerStatus)

T=11s   OMA query → exit_code=42, duration=10s, target=app, node=opscart-m02
```

## What OMA Captures (P005)

| Field | Source |
|---|---|
| `exit_code` | `EphemeralContainerStatus.State.Terminated.ExitCode` |
| `exit_class` | Derived: CLEAN / SIGKILL / SIGTERM / OOM / ERROR |
| `duration_seconds` | `FinishedAt − StartedAt` |
| `target_container` | `EphemeralContainer.TargetContainerName` |
| `node_name` | `Pod.Spec.NodeName` at capture time |
| `log_content` | `NOT_CAPTURABLE_VIA_API` (documented boundary) |

## Running

```bash
# Terminal 1 — collector
./collector/bin/collector --namespace oma-ephemeral --output ./output

# Terminal 2 — scenario
bash scenarios/05-ephemeral-exit/trigger.sh
```

## After the scenario

```bash
cd storage
python ingest.py --events ../output/events.jsonl --snapshots ../output/snapshots.jsonl
sqlite3 memory.db \
  'SELECT container_name, target_container, exit_code, exit_class, duration_seconds FROM ephemeral_exits;'
```
## Limitation
H3 claim: EphemeralContainerStatus has no lastState field by Kubernetes API spec. A regular container's ContainerStatus.lastState records the prior termination and survives across restarts — this is how P001 (OOMKill) captures evidence. Ephemeral containers have no equivalent. Once a second ephemeral session is attached, or the pod is rescheduled, the prior session's exit code, duration, and target context are unrecoverable from the API. OMA captures this at the Terminated transition, before any subsequent modification can overwrite the current state.

## Requirements

- Kubernetes ≥ 1.25 (ephemeral containers GA)
- Minikube default version satisfies this