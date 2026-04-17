-- schema_v2.sql  (H2 only)
-- Run once after schema.sql:  sqlite3 memory.db < storage/schema_v2.sql
-- Idempotent — safe to re-run.

PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

-- ── P004: Scheduler Decision Provenance ──────────────────────────────────
-- Extended detail table for SchedulerEvent records.
-- The event is also written to the main `events` table by ingest.py
-- (_insert_event runs for all events). This table stores the extra fields
-- that don't fit the generic events schema: pruning_risk, parsed_predicates.
--
-- causal_edges still references events(id) — same id used in both tables.
CREATE TABLE IF NOT EXISTS scheduler_events (
    id               TEXT PRIMARY KEY,   -- same id as events.id
    timestamp        DATETIME NOT NULL,
    namespace        TEXT NOT NULL,
    pod_name         TEXT NOT NULL,
    reason           TEXT NOT NULL,      -- FailedScheduling | Scheduled | Preempting
    message          TEXT NOT NULL,
    first_timestamp  TEXT,
    last_timestamp   TEXT,
    count            INTEGER DEFAULT 1,
    age_seconds      REAL    DEFAULT 0,
    pruning_risk     TEXT    DEFAULT 'LOW',  -- LOW | MEDIUM | HIGH | CRITICAL
    source_host      TEXT,
    resource_version TEXT,
    event_uid        TEXT,
    -- JSON array: [{"node_count": 1, "reason": "Insufficient memory"}]
    parsed_predicates TEXT
);

CREATE INDEX IF NOT EXISTS idx_scheduler_pod
    ON scheduler_events(namespace, pod_name);
CREATE INDEX IF NOT EXISTS idx_scheduler_reason
    ON scheduler_events(reason);
CREATE INDEX IF NOT EXISTS idx_scheduler_ts
    ON scheduler_events(timestamp);

-- Register P004 pattern
INSERT OR IGNORE INTO patterns (id, name, description) VALUES
    ('P004', 'Scheduler Decision Provenance',
     'Scheduler placement decisions pruned before downstream failure RCA');