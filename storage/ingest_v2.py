"""
ingest_v2.py  (H2 — P004 scheduler events only)

HOW TO WIRE INTO ingest.py — two additions, nothing else changes:

1. Add import at the top of ingest.py:
       from ingest_v2 import _insert_extended, _build_extended_edges

2. At the END of _insert_event(), add one line:
       _insert_extended(conn, e)

3. At the END of _build_edges(), add one line:
       _build_extended_edges(conn, event)

That's it. All existing P001/P002/P003 logic is untouched.
"""

import json
import sqlite3
import logging

log = logging.getLogger(__name__)


def _insert_extended(conn: sqlite3.Connection, e: dict) -> None:
    """Route to extended table based on event_type. Called from _insert_event()."""
    if e.get("event_type") == "SchedulerEvent":
        _insert_p004(conn, e)


def _insert_p004(conn: sqlite3.Connection, e: dict) -> None:
    """
    Write P004 detail record to scheduler_events.
    The event is already in the main events table (written by _insert_event).
    This table stores the extra fields: pruning_risk, parsed_predicates.
    """
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


def _build_extended_edges(conn: sqlite3.Connection, event: dict) -> None:
    """
    Build P004 causal edges. Called from _build_edges().
    Uses the same causal_edges schema as existing P001 edges:
        (id, cause_event_id, effect_event_id, pattern_id, confidence, edge_type)
    Both cause_event_id and effect_event_id reference events(id) — valid FK
    because _insert_event() writes every event to events first.
    """
    if event.get("event_type") != "SchedulerEvent":
        return

    payload = event.get("payload", {})
    reason  = payload.get("reason", "")
    pod     = event.get("pod_name", "")
    ns      = event.get("namespace", "")
    eid     = event["id"]

    # ── P004→P004: link consecutive scheduler events for the same pod ────
    # Finds the most recent prior SchedulerEvent in the main events table.
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

    # ── P004→P001 cross-pattern: Scheduled → OOMKill ─────────────────────
    # Only attempt on a Scheduled event. Confidence 0.8 (weaker than
    # intra-pattern 1.0) because the OOMKill may arrive later.
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


def _parse_predicates(message: str) -> list:
    """
    Parse structured predicate failures from a FailedScheduling message.

    Input:  "0/1 nodes are available: 1 Insufficient memory. preemption: ..."
    Output: [{"node_count": 1, "reason": "Insufficient memory"}]

    Returns [] on any parse error — the raw message is always stored.
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