-- schema_v3.sql  (H3 only — run after schema_v2.sql)
-- sqlite3 memory.db < storage/schema_v3.sql
-- Idempotent — safe to re-run.

PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

-- ── P005: Ephemeral Container Exit Record (H3) ───────────────────────────
-- Captures EphemeralContainerStatus at Terminated transition.
-- The Kubernetes API spec excludes lastState from EphemeralContainerStatus,
-- making OMA the only mechanism that preserves exit_code, duration, and
-- target container context after the debug session exits.
--
-- API boundary: log_content is always 'NOT_CAPTURABLE_VIA_API'.
-- stdout/stderr is accessible only via kubectl logs while container runs.
CREATE TABLE IF NOT EXISTS ephemeral_exits (
    id               TEXT PRIMARY KEY,   -- same id as events.id
    timestamp        DATETIME NOT NULL,
    namespace        TEXT NOT NULL,
    pod_name         TEXT NOT NULL,
    node_name        TEXT,
    container_name   TEXT NOT NULL,      -- ephemeral container name
    image            TEXT,
    image_id         TEXT,
    container_id     TEXT,
    target_container TEXT,               -- --target flag from kubectl debug
    exit_code        INTEGER,
    reason           TEXT,
    exit_class       TEXT,               -- CLEAN|SIGKILL|SIGTERM|OOM|ERROR|UNKNOWN
    started_at       TEXT,
    finished_at      TEXT,
    duration_seconds REAL,
    pod_phase        TEXT,
    pod_restart_count INTEGER,
    log_api_boundary TEXT DEFAULT 'NOT_CAPTURABLE_VIA_API'
);

CREATE INDEX IF NOT EXISTS idx_ephemeral_pod
    ON ephemeral_exits(namespace, pod_name);
CREATE INDEX IF NOT EXISTS idx_ephemeral_timestamp
    ON ephemeral_exits(timestamp);
CREATE INDEX IF NOT EXISTS idx_ephemeral_exit_class
    ON ephemeral_exits(exit_class);

-- Register P005 pattern
INSERT OR IGNORE INTO patterns (id, name, description) VALUES
    ('P005', 'Ephemeral Container Evidence Loss',
     'Debug session state discarded on exit — lastState excluded by API spec');