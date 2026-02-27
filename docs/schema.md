# Operational Memory Store — Schema

## Tables

### events
Captures raw Kubernetes decisions with full context.

| Column | Type | Description |
|---|---|---|
| id | TEXT PRIMARY KEY | UUID |
| timestamp | DATETIME | Event time (nanosecond precision) |
| event_type | TEXT | OOMKill / ConfigMapChange / PodRestart / NodePressure |
| pod_name | TEXT | Anonymizable |
| namespace | TEXT | Anonymizable |
| node_name | TEXT | Anonymizable |
| payload | JSON | Full event context |
| pattern_id | TEXT | FK → patterns (P001/P002/P003) |

### causal_edges
Links events by causal relationship (not just temporal proximity).

| Column | Type | Description |
|---|---|---|
| id | TEXT PRIMARY KEY | UUID |
| cause_event_id | TEXT | FK → events.id |
| effect_event_id | TEXT | FK → events.id |
| confidence | REAL | 0.0–1.0 |
| pattern_id | TEXT | Which pattern encoded this edge |

### snapshots
Point-in-time Kubernetes object state.

| Column | Type | Description |
|---|---|---|
| id | TEXT PRIMARY KEY | UUID |
| timestamp | DATETIME | Snapshot time |
| object_kind | TEXT | Pod / ConfigMap / Node |
| object_name | TEXT | Anonymizable |
| namespace | TEXT | Anonymizable |
| state | JSON | Full object spec at this moment |

## Canonical Queries

```sql
-- Q1: What happened before this pod restarted?
SELECT e.*, ce.confidence
FROM events e
JOIN causal_edges ce ON e.id = ce.cause_event_id
WHERE ce.effect_event_id = :restart_event_id
ORDER BY e.timestamp ASC;

-- Q2: Has this causal pattern occurred before?
SELECT COUNT(*), MIN(timestamp), MAX(timestamp)
FROM events
WHERE pattern_id = :pattern_id
AND pod_name = :pod_name;

-- Q3: What was the cluster state at time T?
SELECT * FROM snapshots
WHERE object_name = :object_name
AND timestamp <= :query_time
ORDER BY timestamp DESC
LIMIT 1;
```
