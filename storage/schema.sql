PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS events (
    id              TEXT PRIMARY KEY,
    timestamp       DATETIME NOT NULL,
    event_type      TEXT NOT NULL,
    pattern_id      TEXT,
    pod_name        TEXT,
    namespace       TEXT,
    node_name       TEXT,
    pod_uid         TEXT,
    payload         TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestamp);
CREATE INDEX IF NOT EXISTS idx_events_type      ON events(event_type);
CREATE INDEX IF NOT EXISTS idx_events_pod       ON events(pod_name, namespace);
CREATE INDEX IF NOT EXISTS idx_events_pattern   ON events(pattern_id);
CREATE INDEX IF NOT EXISTS idx_events_node      ON events(node_name);

-- Causal edges: what no existing observability tool stores
CREATE TABLE IF NOT EXISTS causal_edges (
    id              TEXT PRIMARY KEY,
    cause_event_id  TEXT NOT NULL REFERENCES events(id),
    effect_event_id TEXT NOT NULL REFERENCES events(id),
    pattern_id      TEXT NOT NULL,
    confidence      REAL DEFAULT 1.0,
    edge_type       TEXT DEFAULT 'direct',
    created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_edges_cause   ON causal_edges(cause_event_id);
CREATE INDEX IF NOT EXISTS idx_edges_effect  ON causal_edges(effect_event_id);
CREATE INDEX IF NOT EXISTS idx_edges_pattern ON causal_edges(pattern_id);

-- Point-in-time object state snapshots
CREATE TABLE IF NOT EXISTS snapshots (
    id            TEXT PRIMARY KEY,
    timestamp     DATETIME NOT NULL,
    object_kind   TEXT NOT NULL,
    object_name   TEXT NOT NULL,
    namespace     TEXT,
    trigger_event TEXT,
    state         TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_snapshots_object    ON snapshots(object_kind, object_name);
CREATE INDEX IF NOT EXISTS idx_snapshots_timestamp ON snapshots(timestamp);

CREATE TABLE IF NOT EXISTS patterns (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    description TEXT,
    created_at  DATETIME DEFAULT CURRENT_TIMESTAMP
);

INSERT OR IGNORE INTO patterns (id, name, description) VALUES
    ('P001', 'OOMKill Causal Chain',                   'Memory pressure → OOMKill → evidence rotation'),
    ('P002', 'ConfigMap Env Var Silent Misconfiguration', 'ConfigMap update not propagated to env var consumers'),
    ('P003', 'ConfigMap Volume Mount Symlink Swap',     'ConfigMap update via kubelet atomic symlink swap');
