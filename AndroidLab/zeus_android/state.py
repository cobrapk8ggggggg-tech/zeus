"""Small on-worker state and bounded capture. Android payloads never enter iOS."""
import hashlib
import json
from pathlib import Path
import sqlite3
import time


class State:
    def __init__(self, root, clock=time.time):
        self.root, self.clock = Path(root), clock
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.db = sqlite3.connect(self.root / "state.sqlite3")
        self.db.row_factory = sqlite3.Row
        self.db.executescript("""
        PRAGMA journal_mode=WAL; PRAGMA journal_size_limit=0;
        CREATE TABLE IF NOT EXISTS state(id INTEGER PRIMARY KEY CHECK(id=1), value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY AUTOINCREMENT, scope TEXT NOT NULL, bytes INTEGER NOT NULL, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS operations(scope TEXT NOT NULL, id TEXT NOT NULL, digest TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY(scope,id));
        """)
        self.db.commit()

    @staticmethod
    def scope(claims): return hashlib.sha256((claims["sub"] + ":" + claims["conversation"]).encode()).hexdigest()

    def load(self):
        row = self.db.execute("SELECT value FROM state WHERE id=1").fetchone()
        return json.loads(row[0]) if row else None

    def save(self, value):
        self.db.execute("INSERT OR REPLACE INTO state VALUES(1,?)", (json.dumps(value),)); self.db.commit()

    def owned(self, claims, active=True):
        value = self.load()
        if not value or value["scope"] != self.scope(claims): raise KeyError("No laboratory session for this conversation")
        if active and value["status"] != "running": raise ValueError("Start the Android laboratory first")
        return value

    def capture(self, scope, event):
        raw = json.dumps(event, ensure_ascii=False)
        size = len(raw.encode())
        if size > 140000: raise ValueError("Network event too large")
        self.db.execute("INSERT INTO events(scope,bytes,value) VALUES(?,?,?)", (scope, size, raw))
        # Limits apply globally too; switching conversations cannot evade them.
        self.db.execute("DELETE FROM events WHERE id NOT IN (SELECT id FROM events ORDER BY id DESC LIMIT 1000)")
        while self.db.execute("SELECT COALESCE(SUM(bytes),0) FROM events").fetchone()[0] > 8*1024*1024:
            self.db.execute("DELETE FROM events WHERE id=(SELECT MIN(id) FROM events)")
        self.db.commit()

    def events(self, scope, after=0):
        rows = self.db.execute("SELECT id,value FROM events WHERE scope=? AND id>? ORDER BY id LIMIT 50", (scope, after)).fetchall()
        return [{"id": r[0], **json.loads(r[1])} for r in rows]

    def close(self): self.db.execute("PRAGMA wal_checkpoint(TRUNCATE)"); self.db.close()
