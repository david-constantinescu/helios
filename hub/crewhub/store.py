"""SQLite storage on the Pi: habitat sensor history, every observation the app uploads, and the latest snapshot per person."""
from __future__ import annotations

import json
import sqlite3
import threading
import time
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

SCHEMA = """
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
CREATE TABLE IF NOT EXISTS env_minute (ts INTEGER NOT NULL, sensor TEXT NOT NULL, mean REAL, min REAL, max REAL, n INTEGER,
                                       PRIMARY KEY (ts, sensor));
CREATE TABLE IF NOT EXISTS persons (key TEXT PRIMARY KEY, device TEXT, person_id TEXT, name TEXT, role TEXT, updated REAL);
CREATE TABLE IF NOT EXISTS observations (uid TEXT PRIMARY KEY, person TEXT NOT NULL, metric TEXT NOT NULL, ts REAL NOT NULL,
                                         value REAL NOT NULL, unit TEXT, device TEXT, kind TEXT, received REAL);
CREATE INDEX IF NOT EXISTS obs_pmt ON observations(person, metric, ts);
CREATE TABLE IF NOT EXISTS snapshots (person TEXT PRIMARY KEY, json TEXT NOT NULL, updated REAL);
CREATE TABLE IF NOT EXISTS events (ts REAL NOT NULL, kind TEXT, text TEXT);
CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT);
"""


class Store:
    def __init__(self, path: str):
        self.path = path
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.lock = threading.Lock()
        with self.lock:
            self.db.executescript(SCHEMA)

    def close(self) -> None:
        with self.lock:
            self.db.close()

    # --- habitat sensors ---------------------------------------------------------------------------------------
    def add_env_minute(self, ts: int, stats: Dict[str, Tuple[float, float, float, int]]) -> None:
        rows = [(ts, k, m, lo, hi, n) for k, (m, lo, hi, n) in stats.items()]
        with self.lock, self.db:
            self.db.executemany("INSERT OR REPLACE INTO env_minute VALUES (?,?,?,?,?,?)", rows)

    def env_history(self, sensor: str, since: float) -> List[Tuple[int, float]]:
        with self.lock:
            return list(self.db.execute("SELECT ts, mean FROM env_minute WHERE sensor=? AND ts>=? ORDER BY ts", (sensor, int(since))))

    def log_event(self, kind: str, text: str, ts: Optional[float] = None) -> None:
        with self.lock, self.db:
            self.db.execute("INSERT INTO events VALUES (?,?,?)", (ts or time.time(), kind, text))

    def recent_events(self, limit: int = 20) -> List[Tuple[float, str, str]]:
        with self.lock:
            return list(self.db.execute("SELECT ts, kind, text FROM events ORDER BY ts DESC LIMIT ?", (limit,)))

    # --- people and their data ---------------------------------------------------------------------------------
    def upsert_person(self, key: str, device: str, person_id: str, name: str, role: str) -> None:
        with self.lock, self.db:
            self.db.execute("INSERT INTO persons VALUES (?,?,?,?,?,?) ON CONFLICT(key) DO UPDATE SET name=excluded.name, "
                            "role=excluded.role, updated=excluded.updated", (key, device, person_id, name, role, time.time()))

    def persons(self) -> List[Dict[str, Any]]:
        with self.lock:
            rows = self.db.execute("SELECT key, device, person_id, name, role, updated FROM persons ORDER BY updated DESC").fetchall()
        return [dict(zip(("key", "device", "person_id", "name", "role", "updated"), r)) for r in rows]

    def insert_observations(self, person: str, rows: Iterable[Sequence[Any]]) -> int:
        """rows: (uid, metric, ts, value, unit, device, kind). Same uid replaces (edits upstream are re-sent)."""
        now = time.time()
        clean = []
        for r in rows:
            if len(r) < 4:
                continue
            uid, metric, ts, value = str(r[0]), str(r[1]), float(r[2]), float(r[3])
            if value != value:
                continue
            unit = str(r[4]) if len(r) > 4 and r[4] is not None else ""
            device = str(r[5]) if len(r) > 5 and r[5] is not None else ""
            kind = str(r[6]) if len(r) > 6 and r[6] is not None else ""
            clean.append((f"{person}|{uid}", person, metric, ts, value, unit, device, kind, now))
        with self.lock, self.db:
            self.db.executemany("INSERT OR REPLACE INTO observations VALUES (?,?,?,?,?,?,?,?,?)", clean)
        return len(clean)

    def delete_observations(self, person: str, uids: Iterable[str]) -> int:
        keys = [(f"{person}|{u}",) for u in uids]
        with self.lock, self.db:
            cur = self.db.executemany("DELETE FROM observations WHERE uid=?", keys)
        return cur.rowcount

    def observation_count(self, person: Optional[str] = None) -> int:
        with self.lock:
            if person:
                return self.db.execute("SELECT COUNT(*) FROM observations WHERE person=?", (person,)).fetchone()[0]
            return self.db.execute("SELECT COUNT(*) FROM observations").fetchone()[0]

    def metric_counts(self, person: str) -> Dict[str, int]:
        with self.lock:
            return dict(self.db.execute("SELECT metric, COUNT(*) FROM observations WHERE person=? GROUP BY metric", (person,)))

    def put_snapshot(self, person: str, snap: Dict[str, Any]) -> None:
        with self.lock, self.db:
            self.db.execute("INSERT OR REPLACE INTO snapshots VALUES (?,?,?)", (person, json.dumps(snap), time.time()))

    def snapshots(self) -> Dict[str, Dict[str, Any]]:
        with self.lock:
            rows = self.db.execute("SELECT person, json FROM snapshots").fetchall()
        out = {}
        for p, j in rows:
            try:
                out[p] = json.loads(j)
            except ValueError:
                pass
        return out

    # --- settings ----------------------------------------------------------------------------------------------
    def get(self, key: str, default: Optional[str] = None) -> Optional[str]:
        with self.lock:
            r = self.db.execute("SELECT value FROM kv WHERE key=?", (key,)).fetchone()
        return r[0] if r else default

    def set(self, key: str, value: str) -> None:
        with self.lock, self.db:
            self.db.execute("INSERT OR REPLACE INTO kv VALUES (?,?)", (key, value))

    def prune(self, env_days: int = 400) -> None:
        with self.lock, self.db:
            self.db.execute("DELETE FROM env_minute WHERE ts < ?", (int(time.time() - env_days * 86400),))
            self.db.execute("DELETE FROM events WHERE ts < ?", (time.time() - env_days * 86400,))
