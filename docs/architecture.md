# OMA Architecture Specification

## Overview

Operational Memory Architecture (OMA) defines five layers. This repository
implements Layers 1 and 3. Layers 2, 4, and 5 are specified here for
future implementation.

## Layer 1: Decision Capture (Collector)
**Status:** Implemented — see `collector/`

Captures Kubernetes decisions at the moment they occur:
- Pod lifecycle events with full context
- OOMKill with node memory state at kill time
- Scheduler placement decisions
- ConfigMap version in effect at pod start

## Layer 2: Causal Correlator
**Status:** Spec only

Builds causal DAG from captured events using:
- Temporal proximity (configurable window)
- Object identity (shared pod/node/configmap)
- Encoded causal patterns (from `collector/patterns/`)

## Layer 3: Operational Memory Store
**Status:** Implemented — see `storage/`

SQLite-backed store answering three canonical queries:
1. "What happened before this pod restarted?"
2. "Has this causal pattern occurred before?"
3. "What was the cluster state at time T?"

## Layer 4: Bounded Autonomy Policy Engine
**Status:** Spec only

YAML-defined policies evaluated against memory query results.
Controls what automated systems can act on without human approval.

## Layer 5: AI Query Layer
**Status:** Spec only

Structures causal memory as LLM-ready context for AI-assisted operations.

---

## Causal Patterns Encoded

| Pattern ID | Name | Trigger | Causal Chain |
|---|---|---|---|
| P001 | OOMKill | Memory limit breach | MemPressure → OOMKill → Restart → EvidenceLoss |
| P002 | ConfigMap env freeze | ConfigMap update, env var consumer | CMUpdate → NoRestart → StaleConfig |
| P003 | ConfigMap mount sync | ConfigMap update, volume mount consumer | CMUpdate → SymlinkSwap → inotify → Reload |
