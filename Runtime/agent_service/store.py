import json
import sqlite3
import time
from pathlib import Path


class Store:
    """Persist state before publishing events; disconnected clients own no jobs."""
    def __init__(self, root: Path):
        self.root = root.resolve()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = self.root / "zeus.sqlite3"
        with self.connect() as db:
            db.executescript('''
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS records(kind TEXT,id TEXT,body TEXT NOT NULL,PRIMARY KEY(kind,id));
                CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY AUTOINCREMENT,task TEXT NOT NULL,kind TEXT NOT NULL,body TEXT NOT NULL,created REAL NOT NULL);
                CREATE INDEX IF NOT EXISTS task_events ON events(task,seq);
            ''')

    def connect(self):
        db = sqlite3.connect(self.path, timeout=15)
        db.row_factory = sqlite3.Row
        return db

    def get(self, kind, identifier):
        with self.connect() as db:
            row = db.execute("SELECT body FROM records WHERE kind=? AND id=?", (kind, identifier)).fetchone()
        if row is None:
            raise KeyError(identifier)
        return json.loads(row[0])

    def put(self, kind, value):
        with self.connect() as db:
            db.execute("INSERT INTO records(kind,id,body) VALUES(?,?,?) ON CONFLICT(kind,id) DO UPDATE SET body=excluded.body", (kind, value["id"], json.dumps(value, ensure_ascii=False)))
        return value

    def all(self, kind):
        with self.connect() as db:
            rows = db.execute("SELECT body FROM records WHERE kind=? ORDER BY rowid DESC", (kind,)).fetchall()
        return [json.loads(r[0]) for r in rows]

    def event(self, task, kind, value):
        created = time.time()
        with self.connect() as db:
            cursor = db.execute("INSERT INTO events(task,kind,body,created) VALUES(?,?,?,?)", (task, kind, json.dumps(value, ensure_ascii=False), created))
            seq = cursor.lastrowid
        return {"seq": seq, "task": task, "kind": kind, "data": value, "created": created}

    def events(self, task, after=0, limit=200):
        with self.connect() as db:
            rows = db.execute("SELECT * FROM events WHERE task=? AND seq>? ORDER BY seq LIMIT ?", (task, after, min(limit, 500))).fetchall()
        return [{"seq": r["seq"], "task": task, "kind": r["kind"], "data": json.loads(r["body"]), "created": r["created"]} for r in rows]

    def update(self, kind, identifier, **changes):
        value = self.get(kind, identifier)
        value.update(changes, updated=time.time())
        return self.put(kind, value)
