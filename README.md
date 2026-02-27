# k8s-causal-memory

> **Operational Memory Architecture (OMA) — Reference Implementation**  
> A research proof-of-concept demonstrating causal memory capture for Kubernetes clusters.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Language: Go](https://img.shields.io/badge/Collector-Go-00ADD8.svg)](collector/)
[![Language: Python](https://img.shields.io/badge/Storage-Python-3776AB.svg)](storage/)

---

## The Problem

Cloud-native systems optimize for convergence but discard the causal history behind
failures. Kubernetes self-heals in seconds — faster than humans can observe. By the
time an engineer investigates, the evidence has rotated.

This repository implements the core layers of **Operational Memory Architecture (OMA)**:
a structured memory layer that preserves events, decisions, intent, and causal
relationships — enabling safer, more intelligent infrastructure operations.

> Related research: ["When Kubernetes Forgets: The 90-Second Evidence Gap"](https://opscart.com/when-kubernetes-forgets-the-90-second-evidence-gap/)  
> Companion article: ["When Kubernetes Restarts Your Pod"](https://opscart.com/when-kubernetes-restarts-your-pod/)

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                    │
│  Pod Events │ OOMKill │ ConfigMap Changes │ Node State  │
└──────────────────────────┬──────────────────────────────┘
                           │
                ┌──────────▼──────────┐
                │   collector/ (Go)   │
                │  Watches K8s API    │
                │  Captures decisions │
                │  Encodes patterns   │
                └──────────┬──────────┘
                           │ structured JSON events
                ┌──────────▼──────────┐
                │  storage/ (Python)  │
                │  SQLite memory store│
                │  Causal edge index  │
                │  Point-in-time snap │
                └──────────┬──────────┘
                           │
                ┌──────────▼──────────┐
                │   Query Interface   │
                │  "What caused this?"│
                │  "Has this happened │
                │   before?"          │
                │  "State at time T?" │
                └─────────────────────┘
```

---

## Layers Implemented

| Layer | Status | Language | Description |
|---|---|---|---|
| Collector | ✅ Working | Go | K8s watcher + decision capture |
| Storage | ✅ Working | Python | SQLite-backed causal memory store |
| Correlator | 📋 Spec | — | Causal graph builder |
| Policy | 📋 Spec | — | Bounded autonomy engine |
| AI Query | 📋 Spec | — | LLM context injection layer |

---

## Quick Start

```bash
# Prerequisites: kubectl configured, minikube running
make setup
make build
make scenario-01   # OOMKill POC
```

---

## POC Scenarios

| Scenario | Description | Causal Pattern |
|---|---|---|
| [01-oomkill](scenarios/01-oomkill/) | Pod OOMKill + evidence rotation | Memory pressure → OOMKill → Evidence loss |
| [02-configmap-env](scenarios/02-configmap-env/) | Silent env var misconfiguration | ConfigMap update → No restart → Stale config |
| [03-configmap-mount](scenarios/03-configmap-mount/) | Volume mount symlink swap | ConfigMap update → Symlink swap → inotify |

---

## Research Context

This repository supports two companion publications:

- **InfoQ Article:** *Infrastructure Without Memory: The Missing Primitive in Cloud-Native Architecture*
- **arXiv Paper:** *Operational Memory Architecture: A Structured Causal Memory Layer for Autonomous Kubernetes Operations*

### Citation

```bibtex
@misc{khan2026k8scausalmemory,
  author       = {Khan, Shamsher},
  title        = {k8s-causal-memory: Operational Memory Architecture Reference Implementation},
  year         = {2026},
  publisher    = {GitHub},
  url          = {https://github.com/opscart/k8s-causal-memory}
}
```

---

## Author

**Shamsher Khan** — Senior DevOps Engineer, GlobalLogic (Hitachi Group)  
IEEE Senior Member | DZone Core Member  
[opscart.com](https://opscart.com) · [LinkedIn](https://linkedin.com/in/shamsher-khan)

---

## License

MIT — see [LICENSE](LICENSE)
