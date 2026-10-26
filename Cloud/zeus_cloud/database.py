"""One small Atlas pool while active; no monitoring sockets while idle."""
import asyncio
from contextlib import asynccontextmanager
import time
from pymongo import AsyncMongoClient, ReturnDocument


class MongoStore:
    def __init__(self, uri, idle_seconds=30):
        self.uri, self.idle_seconds = uri, idle_seconds
        self.client = None
        self._mutex, self._users, self._idle = asyncio.Lock(), 0, None
        self._event_locks = {}

    @asynccontextmanager
    async def active(self):
        async with self._mutex:
            if self._idle:
                self._idle.cancel(); self._idle = None
            if self.client is None:
                if not self.uri:
                    raise RuntimeError("Atlas credentials are not configured")
                # One API replica, one worker and a few short UI reads. Four
                # application sockets suffice; no prewarmed minimum. Monitoring
                # sockets also disappear when the client is closed below.
                self.client = AsyncMongoClient(self.uri, appname="zeus-cloud",
                    maxPoolSize=4, minPoolSize=0, maxIdleTimeMS=30_000,
                    serverSelectionTimeoutMS=10_000, connectTimeoutMS=10_000,
                    socketTimeoutMS=20_000, retryWrites=True)
            self._users += 1
            database = self.client["zeus_cloud"]
        try:
            yield database
        finally:
            async with self._mutex:
                self._users -= 1
                if self._users == 0:
                    self._idle = asyncio.create_task(self._close_idle())

    async def _close_idle(self):
        try:
            await asyncio.sleep(self.idle_seconds)
            async with self._mutex:
                if self._users == 0 and self.client is not None:
                    await self.client.close(); self.client = None
        except asyncio.CancelledError:
            pass

    async def close(self):
        async with self._mutex:
            if self._idle: self._idle.cancel()
            if self.client: await self.client.close()
            self.client = None

    async def initialize(self):
        async with self.active() as db:
            await db.command("ping")
            await db.records.create_index([("owner", 1), ("kind", 1), ("updated", -1)])
            await db.runs.create_index([("status", 1), ("created", 1)])
            await db.runs.create_index([("owner", 1), ("conversation", 1), ("created", -1)])
            await db.events.create_index([("owner", 1), ("run", 1), ("seq", 1)], unique=True)

    @staticmethod
    def clean(row):
        if row is None: return None
        return {k: v for k, v in row.items() if k != "_id"}

    async def get(self, owner, kind, identifier):
        async with self.active() as db:
            value = await db.records.find_one({"_id": f"{owner}:{kind}:{identifier}", "owner": owner})
        return self.clean(value)

    async def put(self, owner, kind, identifier, value):
        row = {**value, "id": identifier, "owner": owner, "kind": kind, "updated": time.time()}
        async with self.active() as db:
            await db.records.replace_one({"_id": f"{owner}:{kind}:{identifier}", "owner": owner}, row, upsert=True)
        return row

    async def list(self, owner, kind, limit=100):
        async with self.active() as db:
            rows = await db.records.find({"owner": owner, "kind": kind}).sort("updated", -1).limit(min(limit, 100)).to_list()
        return [self.clean(row) for row in rows]

    async def create_run(self, owner, run):
        # Caller-provided UUID doubles as a durable idempotency key. Mongo's
        # atomic _id uniqueness prevents duplicate work across retries/restarts.
        key = owner + ":" + run["id"]
        async with self.active() as db:
            result = await db.runs.find_one_and_update({"_id": key, "owner": owner}, {"$setOnInsert": {**run, "owner": owner, "seq": 0}},
                                                      upsert=True, return_document=ReturnDocument.AFTER)
        return self.clean(result)

    async def run(self, owner, identifier):
        async with self.active() as db:
            row = await db.runs.find_one({"_id": owner + ":" + identifier, "owner": owner})
        return self.clean(row)

    async def update_run(self, owner, identifier, **changes):
        async with self.active() as db:
            result = await db.runs.find_one_and_update({"_id": owner + ":" + identifier, "owner": owner},
                {"$set": {**changes, "updated": time.time()}}, return_document=ReturnDocument.AFTER)
        if result is None: raise KeyError(identifier)
        return self.clean(result)

    async def claim(self):
        async with self.active() as db:
            row = await db.runs.find_one_and_update({"status": "queued"}, {"$set": {"status": "running", "updated": time.time()}},
                sort=[("created", 1)], return_document=ReturnDocument.AFTER)
        return self.clean(row)

    async def recover(self):
        # A new container cannot know whether a prior shell mutation finished.
        async with self.active() as db:
            await db.runs.update_many({"status": {"$in": ["running", "checkpointing"]}},
                {"$set": {"status": "interrupted", "error": "Worker restarted; inspect the checkpoint before resuming.", "updated": time.time()}})

    async def event(self, owner, run, kind, data):
        async with self._event_locks.setdefault((owner, run), asyncio.Lock()):
            async with self.active() as db:
                row = await db.runs.find_one_and_update({"_id": owner + ":" + run, "owner": owner}, {"$inc": {"seq": 1}},
                                                      return_document=ReturnDocument.AFTER)
                if row is None: raise KeyError(run)
                event = {"owner": owner, "run": run, "seq": row["seq"], "kind": kind, "data": data, "created": time.time()}
                await db.events.insert_one(dict(event))
                return event

    async def events(self, owner, run, after=0):
        async with self.active() as db:
            rows = await db.events.find({"owner": owner, "run": run, "seq": {"$gt": max(after, 0)}}).sort("seq", 1).limit(200).to_list()
        return [self.clean(row) for row in rows]

    async def list_runs(self, owner, conversation, before=4102444800):
        async with self.active() as db:
            rows = await db.runs.find({"owner": owner, "conversation": conversation, "created": {"$lt": before}}).sort([("created", -1), ("id", -1)]).limit(25).to_list()
        return [self.clean(row) for row in rows]

    async def prune_events(self, owner, run, through):
        record = await self.run(owner, run)
        if not record or record["status"] not in {"completed", "failed", "cancelled", "interrupted"} or not record.get("event_archives"):
            raise ValueError("Verified archive required before pruning events")
        async with self.active() as db: await db.events.delete_many({"owner": owner, "run": run, "seq": {"$lte": through}})
