#!/usr/bin/env python3
"""
query.py — Operational Memory Query Interface

Three canonical OMA queries:
  Q1: causal-chain   — What happened before this pod restarted?
  Q2: pattern-history — Has this causal pattern occurred before?
  Q3: state-at        — What was the cluster state at time T?

Usage:
    python query.py causal-chain --pod <name> --namespace default
    python query.py pattern-history --pattern P001
    python query.py state-at --object Pod --name <name> --time "2026-01-10T23:19:42Z"
    python query.py summary
"""
import json
import sqlite3
import argparse
import sys
from pathlib import Path

try:
    from rich.console import Console
    from rich.table import Table
    from rich.tree import Tree
    from rich.panel import Panel
    RICH = True
except ImportError:
    RICH = False

DB_PATH = "memory.db"


def get_db(db_path=DB_PATH):
    if not Path(db_path).exists():
        print(f"ERROR: Memory store not found: {db_path}")
        print("Run: python ingest.py --events ../output/events.jsonl --snapshots ../output/snapshots.jsonl")
        sys.exit(1)
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    return conn


# ── Q1: Causal Chain ──────────────────────────────────────────────────────────

def query_causal_chain(conn, pod_name, namespace, event_id=None):
    """Q1: What happened before this pod restarted?"""
    if event_id:
        anchor = conn.execute("SELECT * FROM events WHERE id=?", (event_id,)).fetchone()
    else:
        anchor = conn.execute("""
            SELECT * FROM events
            WHERE pod_name=? AND namespace=?
              AND event_type IN ('OOMKill','CrashLoopBackOff','ContainerTerminated')
            ORDER BY timestamp DESC LIMIT 1
        """, (pod_name, namespace)).fetchone()

    if not anchor:
        print(f"No significant events found for pod={pod_name} ns={namespace}")
        return

    chain = _walk_chain(conn, dict(anchor), 0, 5)

    if RICH:
        _render_rich(conn, dict(anchor), chain)
    else:
        _render_plain(dict(anchor), chain)


def _walk_chain(conn, event, depth, max_depth):
    if depth >= max_depth:
        return []
    causes = conn.execute("""
        SELECT e.*, ce.confidence, ce.edge_type
        FROM events e JOIN causal_edges ce ON e.id=ce.cause_event_id
        WHERE ce.effect_event_id=?
        ORDER BY e.timestamp ASC
    """, (event["id"],)).fetchall()
    result = []
    for c in causes:
        d = dict(c)
        d["payload"] = json.loads(d.get("payload", "{}"))
        d["children"] = _walk_chain(conn, d, depth+1, max_depth)
        result.append(d)
    return result


def _render_rich(conn, anchor, chain):
    console = Console()
    payload = json.loads(anchor["payload"]) if isinstance(anchor["payload"], str) else anchor["payload"]
    console.print(Panel(
        f"[bold red]Causal Chain Analysis[/bold red]\n"
        f"Pod: [cyan]{anchor['pod_name']}[/cyan]  "
        f"Namespace: [cyan]{anchor['namespace']}[/cyan]  "
        f"Event: [yellow]{anchor['event_type']}[/yellow]\n"
        f"Time: {anchor['timestamp']}",
        title="k8s-causal-memory — Q1: What caused this?"
    ))
    tree = Tree(f"[yellow]{anchor['event_type']}[/yellow]  [dim]{anchor['timestamp']}[/dim]")
    if payload.get("is_oomkill"):
        tree.add(f"[red]OOMKilled[/red]  exit_code={payload.get('exit_code')}  restart_count={payload.get('restart_count')}")
    if payload.get("resource_limits"):
        lim = payload["resource_limits"]
        tree.add(f"Limits: cpu={lim.get('cpu','none')}  memory={lim.get('memory','none')}")
    refs = payload.get("config_references", {})
    if refs.get("configmaps"):
        tree.add(f"ConfigMaps in effect: {', '.join(refs['configmaps'])}")

    def add_causes(node, causes):
        for c in causes:
            b = node.add(f"[blue]←causes—[/blue] {c['event_type']}  [dim]{c['timestamp']}[/dim]  [green](confidence: {c.get('confidence',1.0):.1f})[/green]")
            if c.get("node_name"):
                b.add(f"Node: {c['node_name']}")
            if c.get("children"):
                add_causes(b, c["children"])

    add_causes(tree, chain)
    console.print(tree)
    if not chain:
        console.print("[dim]No causal predecessors found. Is the collector running?[/dim]")


def _render_plain(anchor, chain):
    print(f"\n=== Causal Chain: {anchor['pod_name']} / {anchor['event_type']} ===")
    print(f"Time: {anchor['timestamp']}")
    def print_causes(causes, indent=0):
        for c in causes:
            print("  "*indent + f"←causes— {c['event_type']} at {c['timestamp']} (conf: {c.get('confidence',1.0):.1f})")
            if c.get("children"):
                print_causes(c["children"], indent+1)
    print_causes(chain)


# ── Q2: Pattern History ───────────────────────────────────────────────────────

def query_pattern_history(conn, pattern_id, pod_name=None, namespace=None, days=30):
    """Q2: Has this causal pattern occurred before?"""
    params = [pattern_id]
    where = ["pattern_id=?"]
    if pod_name:
        where.append("pod_name=?")
        params.append(pod_name)
    if namespace:
        where.append("namespace=?")
        params.append(namespace)
    where.append(f"timestamp >= datetime('now','-{days} days')")

    rows = conn.execute(
        f"SELECT id,timestamp,event_type,pod_name,namespace,node_name FROM events WHERE {' AND '.join(where)} ORDER BY timestamp DESC",
        params
    ).fetchall()

    pinfo = conn.execute("SELECT * FROM patterns WHERE id=?", (pattern_id,)).fetchone()
    name = pinfo["name"] if pinfo else pattern_id

    if RICH:
        console = Console()
        t = Table(title=f"Q2: Pattern History — {name}  (last {days}d)")
        t.add_column("Time", style="dim")
        t.add_column("Pod", style="cyan")
        t.add_column("Namespace")
        t.add_column("Node", style="dim")
        t.add_column("Event", style="yellow")
        for r in rows:
            t.add_row(r["timestamp"], r["pod_name"] or "—", r["namespace"] or "—",
                      r["node_name"] or "—", r["event_type"])
        console.print(t)
        console.print(f"\n[bold]Total occurrences:[/bold] {len(rows)} in last {days} days")
        if len(rows) >= 3:
            console.print(f"\n[bold red]⚠ Pattern {pattern_id} has fired {len(rows)} times — escalate to human review.[/bold red]")
    else:
        print(f"\n=== Pattern {pattern_id}: {name} (last {days}d) ===")
        for r in rows:
            print(f"  {r['timestamp']}  {r['pod_name']}  {r['event_type']}")
        print(f"\nTotal: {len(rows)}")


# ── Q3: State at Time ─────────────────────────────────────────────────────────

def query_state_at(conn, object_kind, object_name, namespace, query_time):
    """Q3: What was the cluster state at time T?"""
    snap = conn.execute("""
        SELECT * FROM snapshots
        WHERE object_kind=? AND object_name=?
          AND (namespace=? OR namespace='' OR namespace IS NULL)
          AND timestamp <= ?
        ORDER BY timestamp DESC LIMIT 1
    """, (object_kind, object_name, namespace or "", query_time)).fetchone()

    if not snap:
        print(f"No snapshot found for {object_kind}/{object_name} at or before {query_time}")
        return

    state = json.loads(snap["state"])
    if RICH:
        console = Console()
        console.print(Panel(
            f"[bold]Q3: Point-in-Time State[/bold]\n"
            f"Object: [cyan]{object_kind}/{object_name}[/cyan]\n"
            f"Query time:     [yellow]{query_time}[/yellow]\n"
            f"Snapshot taken: [green]{snap['timestamp']}[/green]\n"
            f"Trigger: {snap['trigger_event']}",
            title="k8s-causal-memory — Historical State"
        ))
        console.print_json(json.dumps(state, indent=2, default=str))
    else:
        print(f"\n=== {object_kind}/{object_name} at {query_time} ===")
        print(f"Snapshot: {snap['timestamp']}")
        print(json.dumps(state, indent=2, default=str))


# ── Summary ───────────────────────────────────────────────────────────────────

def query_summary(conn):
    ec = conn.execute("SELECT COUNT(*) FROM events").fetchone()[0]
    cc = conn.execute("SELECT COUNT(*) FROM causal_edges").fetchone()[0]
    sc = conn.execute("SELECT COUNT(*) FROM snapshots").fetchone()[0]

    patterns = conn.execute("""
        SELECT pattern_id, COUNT(*) cnt FROM events
        WHERE pattern_id != '' GROUP BY pattern_id ORDER BY cnt DESC
    """).fetchall()

    pods = conn.execute("""
        SELECT pod_name, namespace, COUNT(*) events, MAX(timestamp) last_seen
        FROM events WHERE pod_name != ''
        GROUP BY pod_name, namespace ORDER BY events DESC LIMIT 10
    """).fetchall()

    if RICH:
        console = Console()
        console.print(Panel(
            f"Events: [cyan]{ec}[/cyan]   Causal edges: [cyan]{cc}[/cyan]   Snapshots: [cyan]{sc}[/cyan]",
            title="k8s-causal-memory — Memory Store Summary"
        ))
        if patterns:
            pt = Table(title="Pattern Distribution")
            pt.add_column("ID"); pt.add_column("Name"); pt.add_column("Count", justify="right")
            for p in patterns:
                pi = conn.execute("SELECT name FROM patterns WHERE id=?", (p["pattern_id"],)).fetchone()
                pt.add_row(p["pattern_id"], pi["name"] if pi else "—", str(p["cnt"]))
            console.print(pt)
        if pods:
            pod_t = Table(title="Top Pods by Event Count")
            pod_t.add_column("Pod"); pod_t.add_column("Namespace")
            pod_t.add_column("Events", justify="right"); pod_t.add_column("Last Seen")
            for r in pods:
                pod_t.add_row(r["pod_name"], r["namespace"], str(r["events"]), r["last_seen"])
            console.print(pod_t)
    else:
        print(f"\nMemory Store: {ec} events | {cc} edges | {sc} snapshots")
        for p in patterns:
            print(f"  Pattern {p['pattern_id']}: {p['cnt']} events")


# ── CLI ───────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="k8s-causal-memory query interface")
    parser.add_argument("--db", default=DB_PATH)
    sub = parser.add_subparsers(dest="cmd")

    cc = sub.add_parser("causal-chain")
    cc.add_argument("--pod", required=True)
    cc.add_argument("--namespace", default="default")
    cc.add_argument("--event-id")

    ph = sub.add_parser("pattern-history")
    ph.add_argument("--pattern", required=True)
    ph.add_argument("--pod")
    ph.add_argument("--namespace")
    ph.add_argument("--days", type=int, default=30)

    sa = sub.add_parser("state-at")
    sa.add_argument("--object", required=True)
    sa.add_argument("--name", required=True)
    sa.add_argument("--namespace", default="default")
    sa.add_argument("--time", required=True)

    sub.add_parser("summary")

    args = parser.parse_args()
    if not args.cmd:
        parser.print_help()
        sys.exit(1)

    conn = get_db(args.db)

    if args.cmd == "causal-chain":
        query_causal_chain(conn, args.pod, args.namespace, getattr(args, "event_id", None))
    elif args.cmd == "pattern-history":
        query_pattern_history(conn, args.pattern, getattr(args, "pod", None),
                              getattr(args, "namespace", None), getattr(args, "days", 30))
    elif args.cmd == "state-at":
        query_state_at(conn, args.object, args.name, args.namespace, args.time)
    elif args.cmd == "summary":
        query_summary(conn)

    conn.close()


if __name__ == "__main__":
    main()
