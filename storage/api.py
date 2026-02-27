#!/usr/bin/env python3
"""
api.py — REST wrapper for the operational memory query interface.
Exposes Q1/Q2/Q3 as HTTP endpoints for AI system integration (OMA Layer 4).

Usage:
    python api.py --db memory.db --port 8080

Endpoints:
    GET /causal-chain?pod=<name>&namespace=<ns>
    GET /pattern-history?pattern=P001&days=30
    GET /state-at?object=Pod&name=<name>&namespace=<ns>&time=<iso>
    GET /summary
    GET /health
"""
import json
import sqlite3
import argparse
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from pathlib import Path
import sys

# Reuse query logic
sys.path.insert(0, str(Path(__file__).parent))
import query as q

DB_PATH = "memory.db"
_db_path = DB_PATH


def get_conn():
    conn = sqlite3.connect(_db_path)
    conn.row_factory = sqlite3.Row
    return conn


class OMAHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        params = {k: v[0] for k, v in parse_qs(parsed.query).items()}
        path = parsed.path

        try:
            if path == "/health":
                self._json({"status": "ok", "db": _db_path})

            elif path == "/summary":
                conn = get_conn()
                data = {
                    "events": conn.execute("SELECT COUNT(*) FROM events").fetchone()[0],
                    "causal_edges": conn.execute("SELECT COUNT(*) FROM causal_edges").fetchone()[0],
                    "snapshots": conn.execute("SELECT COUNT(*) FROM snapshots").fetchone()[0],
                }
                conn.close()
                self._json(data)

            elif path == "/causal-chain":
                pod = params.get("pod", "")
                ns = params.get("namespace", "default")
                if not pod:
                    self._error(400, "pod parameter required")
                    return
                conn = get_conn()
                anchor = conn.execute("""
                    SELECT * FROM events
                    WHERE pod_name=? AND namespace=?
                      AND event_type IN ('OOMKill','CrashLoopBackOff','ContainerTerminated')
                    ORDER BY timestamp DESC LIMIT 1
                """, (pod, ns)).fetchone()
                if not anchor:
                    self._json({"pod": pod, "namespace": ns, "chain": [], "message": "no events found"})
                    conn.close()
                    return
                chain = q._walk_chain(conn, dict(anchor), 0, 5)
                anchor_dict = dict(anchor)
                anchor_dict["payload"] = json.loads(anchor_dict.get("payload", "{}"))
                self._json({"anchor": anchor_dict, "causal_chain": chain})
                conn.close()

            elif path == "/pattern-history":
                pattern = params.get("pattern", "")
                if not pattern:
                    self._error(400, "pattern parameter required")
                    return
                days = int(params.get("days", 30))
                conn = get_conn()
                rows = conn.execute("""
                    SELECT id, timestamp, event_type, pod_name, namespace, node_name
                    FROM events
                    WHERE pattern_id=?
                      AND timestamp >= datetime('now', ? || ' days')
                    ORDER BY timestamp DESC
                """, (pattern, f"-{days}")).fetchall()
                conn.close()
                self._json({"pattern": pattern, "days": days, "count": len(rows),
                            "events": [dict(r) for r in rows]})

            elif path == "/state-at":
                obj_kind = params.get("object", "Pod")
                obj_name = params.get("name", "")
                ns = params.get("namespace", "default")
                ts = params.get("time", "")
                if not obj_name or not ts:
                    self._error(400, "name and time parameters required")
                    return
                conn = get_conn()
                snap = conn.execute("""
                    SELECT * FROM snapshots
                    WHERE object_kind=? AND object_name=?
                      AND (namespace=? OR namespace='')
                      AND timestamp <= ?
                    ORDER BY timestamp DESC LIMIT 1
                """, (obj_kind, obj_name, ns, ts)).fetchone()
                conn.close()
                if not snap:
                    self._json({"found": False, "object": f"{obj_kind}/{obj_name}", "query_time": ts})
                    return
                d = dict(snap)
                d["state"] = json.loads(d["state"])
                self._json({"found": True, "snapshot": d})

            else:
                self._error(404, f"Unknown endpoint: {path}")

        except Exception as e:
            self._error(500, str(e))

    def _json(self, data):
        body = json.dumps(data, indent=2, default=str).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def _error(self, code, msg):
        body = json.dumps({"error": msg}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print(f"[api] {self.address_string()} {fmt % args}")


def main():
    global _db_path
    p = argparse.ArgumentParser(description="k8s-causal-memory REST API")
    p.add_argument("--db", default=DB_PATH)
    p.add_argument("--port", type=int, default=8080)
    p.add_argument("--host", default="127.0.0.1")
    args = p.parse_args()
    _db_path = args.db

    if not Path(args.db).exists():
        print(f"ERROR: DB not found: {args.db} — run ingest.py first")
        sys.exit(1)

    print(f"[api] Operational Memory API")
    print(f"[api] DB:   {args.db}")
    print(f"[api] Listening on http://{args.host}:{args.port}")
    print(f"[api] Endpoints: /health /summary /causal-chain /pattern-history /state-at")

    HTTPServer((args.host, args.port), OMAHandler).serve_forever()


if __name__ == "__main__":
    main()
