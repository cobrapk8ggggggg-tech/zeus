"""HTTP storage adapter with no idle database-monitoring sockets."""
from contextlib import asynccontextmanager
import httpx


class PostgresGatewayStore:
    def __init__(self, url, token, client=None):
        self.url, self.token = url, token
        self.client = client or httpx.AsyncClient(timeout=30, follow_redirects=False)

    @asynccontextmanager
    async def active(self): yield self

    async def call(self, command, **arguments):
        if self.client.is_closed: self.client = httpx.AsyncClient(timeout=30, follow_redirects=False)
        response = await self.client.post(self.url, params={"op": "runtime"}, json={"command": command, "args": arguments},
            headers={"Authorization": "Bearer " + self.token})
        response.raise_for_status(); return response.json()

    async def initialize(self): return await self.call("initialize")
    async def recover(self): return await self.call("recover")
    async def close(self): await self.client.aclose()
    async def get(self, owner, kind, identifier): return await self.call("get", owner=owner, kind=kind, id=identifier)
    async def put(self, owner, kind, identifier, value): return await self.call("put", owner=owner, kind=kind, id=identifier, value=value)
    async def list(self, owner, kind, limit=100): return await self.call("list", owner=owner, kind=kind)
    async def create_run(self, owner, run): return await self.call("create_run", owner=owner, id=run["id"], value=run)
    async def run(self, owner, identifier): return await self.call("run", owner=owner, id=identifier)
    async def update_run(self, owner, identifier, **changes): return await self.call("update_run", owner=owner, id=identifier, value=changes)
    async def claim(self): return await self.call("claim")
    async def event(self, owner, run, kind, data): return await self.call("event", owner=owner, id=run, event_kind=kind, data=data)
    async def events(self, owner, run, after=0): return await self.call("events", owner=owner, id=run, after=after)
    async def list_runs(self, owner, conversation, before=4102444800): return await self.call("list_runs", owner=owner, id=conversation, before=before)
    async def prune_events(self, owner, run, through): return await self.call("prune_events", owner=owner, id=run, through=through)
    async def account_state(self, owner): return await self.call("account_state", owner=owner)
    async def transition(self, owner, identifier, command): return await self.call(command + "_transition", owner=owner, id=identifier)

    async def list_conversations(self, owner, after=""): return await self.call("list_conversations", owner=owner, after=after)

    async def deletions(self, owner): return await self.call("deletions", owner=owner)
    async def delete_conversation(self, owner, conversation): return await self.call("delete_conversation", owner=owner, id=conversation)

    async def gc_snapshot(self, owner): return await self.call("gc_snapshot", owner=owner)
    async def gc_prepare(self, owner, revision, epoch, candidates, prune): return await self.call("gc_prepare", owner=owner, revision=revision, epoch=epoch, candidates=candidates, prune=prune)
    async def gc_delete(self, owner, revision, digest): return await self.call("gc_delete", owner=owner, revision=revision, sha256=digest)

    async def gc_end(self, owner): return await self.call("gc_end", owner=owner)
