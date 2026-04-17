"""
ingest_v2.py  (H2 + H3 — P004 and P005)

HOW TO WIRE INTO ingest.py (already done for H2, no new changes needed):
    from ingest_v2 import _insert_extended, _build_extended_edges
    # end of _insert_event():  _insert_extended(conn, e)
    # end of _build_edges():   _build_extended_edges(conn, event)

This file is the complete replacement for the H2-only version.
P004 logic is unchanged. P005 is added.
"""

import json
import sqlite3
import logging

log = logging.getLogger(__name__)


def _insert_extended(conn: sqlite3.Connection, e: dict) -> None:
    """Route to extended table based on event_type. Called from _insert_event()."""
    event_type = e.get("event_type")
    if event_type == "SchedulerEvent":
        _insert_p004(conn, e)
    elif event_type == "EphemeralContainerTerminated":
        _insert_p005(conn, e)


# ── P004: Scheduler Event ─────────────────────────────────────────────────

def _insert_p004(conn: sqlite3.Connection, e: dict) -> None:
    payload = e.get("payload", {})
    predicates = _parse_predicates(payload.get("message", ""))
    try:
        conn.execute("""
            INSERT OR IGNORE INTO scheduler_events (
                id, timestamp, namespace, pod_name,
                reason, message,
                first_timestamp, last_timestamp, count,
                age_seconds, pruning_risk, source_host,
                resource_version, event_uid, parsed_predicates
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, (
            e["id"],
            e["timestamp"],
            e.get("namespace", ""),
            e.get("pod_name", ""),
            payload.get("reason", ""),
            payload.get("message", ""),
            payload.get("first_timestamp"),
            payload.get("last_timestamp"),
            payload.get("count", 1),
            payload.get("age_seconds", 0.0),
            payload.get("pruning_risk", "LOW"),
            payload.get("source_host"),
            payload.get("resource_version"),
            payload.get("event_uid"),
            json.dumps(predicates) if predicates else None,
        ))
    except sqlite3.Error as exc:
        log.warning("[P004] insert failed: %s", exc)


# ── P005: Ephemeral Container Exit ────────────────────────────────────────

def _insert_p005(conn: sqlite3.Connection, e: dict) -> None:
    """
    Write P005 detail record to ephemeral_exits.
    The event is already in the main events table (written by _insert_event).
    This table stores the extra fields not in the generic events schema.
    """
    payload = e.get("payload", {})
    try:
        conn.execute("""
            INSERT OR IGNORE INTO ephemeral_exits (
                id, timestamp, namespace, pod_name, node_name,
                container_name, image, image_id, container_id,
                target_container, exit_code, reason, exit_class,
                started_at, finished_at, duration_seconds,
                pod_phase, pod_restart_count, log_api_boundary
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, (
            e["id"],
            e["timestamp"],
            e.get("namespace", ""),
            e.get("pod_name", ""),
            e.get("node_name"),
            payload.get("container_name", ""),
            payload.get("image"),
            payload.get("image_id"),
            payload.get("container_id"),
            payload.get("target_container"),
            payload.get("exit_code"),
            payload.get("reason"),
            payload.get("exit_class"),
            payload.get("started_at"),
            payload.get("finished_at"),
            payload.get("duration_seconds"),
            payload.get("pod_phase"),
            payload.get("pod_restart_count"),
            payload.get("log_content", "NOT_CAPTURABLE_VIA_API"),
        ))
    except sqlite3.Error as exc:
        log.warning("[P005] insert failed: %s", exc)


# ── Edge building ─────────────────────────────────────────────────────────

def _build_extended_edges(conn: sqlite3.Connection, event: dict) -> None:
    """Build P004 causal edges. P005 has no edges (single-step pattern)."""
    if event.get("event_type") != "SchedulerEvent":
        return

    payload = event.get("payload", {})
    reason  = payload.get("reason", "")
    pod     = event.get("pod_name", "")
    ns      = event.get("namespace", "")
    eid     = event["id"]

    # ── P004→P004: consecutive scheduler events for same pod ─────────────
    prior = conn.execute("""
        SELECT id FROM events
        WHERE event_type = 'SchedulerEvent'
          AND pod_name   = ?
          AND namespace  = ?
          AND id        != ?
        ORDER BY timestamp DESC
        LIMIT 1
    """, (pod, ns, eid)).fetchone()

    if prior:
        edge_id = f"{prior['id']}->{eid}"
        try:
            conn.execute("""
                INSERT INTO causal_edges
                    (id, cause_event_id, effect_event_id, pattern_id, confidence, edge_type)
                VALUES (?, ?, ?, 'P004', 1.0, 'scheduler_sequence')
            """, (edge_id, prior["id"], eid))
        except sqlite3.Error:
            pass

    # ── P004→P001: Scheduled → OOMKill cross-pattern ─────────────────────
    if reason == "Scheduled":
        oom = conn.execute("""
            SELECT id FROM events
            WHERE event_type = 'OOMKill'
              AND pod_name   = ?
              AND namespace  = ?
            ORDER BY timestamp DESC
            LIMIT 1
        """, (pod, ns)).fetchone()

        if oom:
            edge_id = f"{eid}->{oom['id']}"
            try:
                conn.execute("""
                    INSERT INTO causal_edges
                        (id, cause_event_id, effect_event_id, pattern_id, confidence, edge_type)
                    VALUES (?, ?, ?, 'P004', 0.8, 'cross_pattern_P004_P001')
                """, (edge_id, eid, oom["id"]))
            except sqlite3.Error:
                pass


# ── Helpers ───────────────────────────────────────────────────────────────

def _parse_predicates(message: str) -> list:
    """
    Parse predicate failures from a FailedScheduling message.
    Input:  "0/3 nodes are available: 3 Insufficient memory. preemption: ..."
    Output: [{"node_count": 3, "reason": "Insufficient memory"}]
    """
    predicates = []
    try:
        idx = message.find(": ")
        if idx == -1:
            return predicates
        body = message[idx + 2:]
        for segment in body.split(", "):
            segment = segment.rstrip(". ")
            if segment.lower().startswith("preemption:"):
                continue
            parts = segment.split(" ", 1)
            if len(parts) < 2:
                continue
            try:
                count  = int(parts[0])
                reason = parts[1].strip().split(". ")[0].strip()
                if reason:
                    predicates.append({"node_count": count, "reason": reason})
            except ValueError:
                continue
    except Exception as exc:
        log.debug("predicate parse failed: %s", exc)
    return predicates