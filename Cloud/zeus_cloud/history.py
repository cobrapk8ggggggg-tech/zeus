"""Encrypted cold history outside the hot task database; verified before pruning."""
import base64
import gzip
import json


class History:
    def __init__(self, store, gateway, vault): self.store, self.gateway, self.vault = store, gateway, vault

    async def put(self, owner, grant, value):
        raw = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()
        if len(raw) > 8 * 1024 * 1024: raise ValueError("History page exceeds archival limit")
        sealed = self.vault.seal(owner, {"gzip": base64.b64encode(gzip.compress(raw, mtime=0)).decode()}).encode()
        ref = await self.gateway.put(grant, sealed)
        # The gateway verifies stored ciphertext; also verify its decoded value.
        if await self.get(owner, grant, ref) != value: raise ValueError("History archive verification failed")
        return ref

    async def get(self, owner, grant, ref):
        encrypted = await self.gateway.get(grant, ref)
        value = self.vault.open(owner, encrypted.decode())
        from io import BytesIO
        with gzip.GzipFile(fileobj=BytesIO(base64.b64decode(value["gzip"], validate=True))) as file:
            raw = file.read(8 * 1024 * 1024 + 1)
        if len(raw) > 8 * 1024 * 1024: raise ValueError("History archive exceeds decoded limit")
        return json.loads(raw)

    async def events(self, owner, run, after=0, grant=None):
        record = await self.store.run(owner, run)
        if not record: raise KeyError(run)
        for page in record.get("event_archives", []):
            if page["last"] > after:
                token = grant or self.vault.open(owner, record["grant"])
                events = await self.get(owner, token, page["ref"])
                return [e for e in events if e["seq"] > after][:200]
        return (await self.store.events(owner, run, after))[:200]

    async def archive_events(self, owner, run):
        record = await self.store.run(owner, run)
        if not record or record["status"] not in {"completed", "cancelled", "failed", "interrupted"}: return
        pages = record.get("event_archives", [])[:]
        after = pages[-1]["last"] if pages else 0
        token = self.vault.open(owner, record["grant"])
        while True:
            events = (await self.store.events(owner, run, after))[:50]
            if not events: break
            ref = await self.put(owner, token, events)
            pages.append({"first": events[0]["seq"], "last": events[-1]["seq"], "ref": ref})
            after = events[-1]["seq"]
            # Publish verified references before pruning any hot rows.
            await self.store.update_run(owner, run, event_archives=pages)
            await self.store.prune_events(owner, run, after)

    async def archive_run_payload(self, owner, identifier):
        record = await self.store.run(owner, identifier)
        if not record or record["status"] not in {"completed", "cancelled", "failed", "interrupted"} or record.get("payload_archive"): return
        fields = {k: record[k] for k in ["history", "provider", "instructions", "tools", "pending_calls"] if record.get(k)}
        if not fields: return
        token = self.vault.open(owner, record["grant"])
        ref = await self.put(owner, token, fields)
        # Publish only a verified encrypted archive before clearing duplicated
        # private input/context. Prompts and native identities remain searchable.
        await self.store.update_run(owner, identifier, payload_archive=ref, history=[], provider=None, instructions="", tools=[], pending_calls=[])
