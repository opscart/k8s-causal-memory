#!/usr/bin/env python3
"""
ingest.py — Ingest collector JSONL events into the operational memory store.

Usage:
    python ingest.py --events ../output/events.jsonl --snapshots ../output/snapshots.jsonl
    python ingest.py --watch ../output/   # streaming mode
"""
import json
import sqlite3
import argparse
import sys
import time
from pathlib import Path

DB_PATH = "memory.db"


def get_db(db_path=DB_PATH):
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    schema = (Path(__file__).parent / "schema.sql").read_text()
    conn.executescript(schema)
    conn.commit()
    return conn


def ingest_events(conn, path):
    p = Path(path)
    if not p.exists():
        print(f"[ingest] Not found: {path}")
        return 0
    n = 0
    with open(p) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
                _insert_event(conn, event)
                _build_edges(conn, event)
                n += 1
            except (json.JSONDecodeError, sqlite3.IntegrityError):
                pass
    conn.commit()
    print(f"[ingest] {n} events ingested from {path}")
    return n


def ingest_snapshots(conn, path):
    p = Path(path)
    if not p.exists():
        print(f"[ingest] Not found: {path}")
        return 0
    n = 0
    with open(p) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                snap = json.loads(line)
                _insert_snapshot(conn, snap)
                n += 1
            except (json.JSONDecodeError, sqlite3.IntegrityError):
                pass
    conn.commit()
    print(f"[ingest] {n} snapshots ingested from {path}")
    return n


def _insert_event(conn, e):
    conn.execute("""
        INSERT OR IGNORE INTO events
            (id, timestamp, event_type, pattern_id, pod_name, namespace, node_name, pod_uid, payload)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (e["id"], e["timestamp"], e["event_type"], e.get("pattern_id", ""),
          e.get("pod_name", ""), e.get("namespace", ""), e.get("node_name", ""),
          e.get("pod_uid", ""), json.dumps(e.get("payload", {}))))


def _insert_snapshot(conn, s):
    conn.execute("""
        INSERT OR IGNORE INTO snapshots
            (id, timestamp, object_kind, object_name, namespace, trigger_event, state)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    """, (s["id"], s["timestamp"], s["object_kind"], s["object_name"],
          s.get("namespace", ""), s.get("trigger_event", ""), json.dumps(s.get("state", {}))))


def _build_edges(conn, event):
    t = event.get("event_type", "")
    if t == "OOMKill":
        rows = conn.execute("""
            SELECT id FROM events
            WHERE event_type = 'NodeMemoryPressure'
              AND node_name = ?
              AND timestamp <= ?
              AND timestamp >= datetime(?, '-300 seconds')
            ORDER BY timestamp DESC LIMIT 3
        """, (event.get("node_name", ""), event["timestamp"], event["timestamp"])).fetchall()
        for r in rows:
            eid = f"{r['id']}->{event['id']}"
            try:
                conn.execute("INSERT INTO causal_edges (id,cause_event_id,effect_event_id,pattern_id,confidence,edge_type) VALUES (?,?,?,'P001',0.9,'direct')",
                             (eid, r["id"], event["id"]))
            except sqlite3.IntegrityError:
                pass

    if t == "OOMKillEvidence":
        r = conn.execute("""
            SELECT id FROM events
            WHERE event_type='OOMKill' AND pod_name=? AND namespace=?
              AND timestamp <= ? AND timestamp >= datetime(?,'-90 seconds')
            ORDER BY timestamp DESC LIMIT 1
        """, (event.get("pod_name",""), event.get("namespace",""), event["timestamp"], event["timestamp"])).fetchone()
        if r:
            eid = f"{r['id']}->{event['id']}"
            try:
                conn.execute("INSERT INTO causal_edges (id,cause_event_id,effect_event_id,pattern_id,confidence,edge_type) VALUES (?,?,?,'P001',1.0,'direct')",
                             (eid, r["id"], event["id"]))
            except sqlite3.IntegrityError:
                pass


def watch_and_ingest(conn, output_dir):
    ep = Path(output_dir) / "events.jsonl"
    sp = Path(output_dir) / "snapshots.jsonl"
    epos = spos = 0
    print(f"[ingest] Watching {output_dir} ...")
    while True:
        if ep.exists():
            with open(ep) as f:
                f.seek(epos)
                lines = f.readlines()
                epos = f.tell()
            for line in lines:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                    _insert_event(conn, ev)
                    _build_edges(conn, ev)
                except (json.JSONDecodeError, sqlite3.IntegrityError):
                    pass
            if lines:
                conn.commit()
        if sp.exists():
            with open(sp) as f:
                f.seek(spos)
                lines = f.readlines()
                spos = f.tell()
            for line in lines:
                line = line.strip()
                if not line:
                    continue
                try:
                    _insert_snapshot(conn, json.loads(line))
                except (json.JSONDecodeError, sqlite3.IntegrityError):
                    pass
            if lines:
                conn.commit()
        time.sleep(1)


def main():
    p = argparse.ArgumentParser(description="k8s-causal-memory ingestion")
    p.add_argument("--events")
    p.add_argument("--snapshots")
    p.add_argument("--watch", help="Watch directory (streaming)")
    p.add_argument("--db", default=DB_PATH)
    args = p.parse_args()
    conn = get_db(args.db)
    print(f"[ingest] DB: {args.db}")
    if args.watch:
        watch_and_ingest(conn, args.watch)
    else:
        if args.events:
            ingest_events(conn, args.events)
        if args.snapshots:
            ingest_snapshots(conn, args.snapshots)
        if not args.events and not args.snapshots:
            p.print_help()
            sys.exit(1)
    conn.close()


if __name__ == "__main__":
    main()
