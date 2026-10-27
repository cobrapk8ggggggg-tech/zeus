"""Reference-checked collection; a storage object is not a conversation row."""
import json
import asyncio
import re


def references(value):
    result = set()
    def visit(node):
        if isinstance(node, list):
            for child in node: visit(child)
        elif isinstance(node, dict):
            digest = node.get("sha256")
            # A file's plaintext digest isn't its encrypted storage object.
            if "parts" not in node and isinstance(digest, str) and re.fullmatch("[a-f0-9]{64}", digest) and isinstance(node.get("bytes"), int): result.add(digest)
            for child in node.values(): visit(child)
    visit(value)
    return result


class Collection:
    def __init__(self, store, gateway): self.store, self.gateway = store, gateway

    async def collect(self, owner, token):
        try: return await self._collect(owner, token)
        finally:
            if hasattr(self.store, "gc_end"): await asyncio.shield(self.store.gc_end(owner))

    async def _collect(self, owner, token):
        snapshot = await self.store.gc_snapshot(owner)
        if snapshot.get("active"): return {"deleted_objects": 0, "deferred": True}
        native = {}
        for ref in snapshot.get("native_refs", []):
            value = json.loads(await self.gateway.get(token, ref))
            if value.get("version") != 1 or not isinstance(value.get("files"), list): raise ValueError("Invalid archive; storage collection stopped")
            native[ref["sha256"]] = value
        current = snapshot.get("native")
        epoch = snapshot.get("deletion_epoch", 0)
        clean = current and current["sha256"] in native and epoch > snapshot.get("purged_epoch", 0) and native[current["sha256"]].get("deletionEpoch") == epoch
        old = set()
        if clean:
            for digest, archive in native.items():
                if digest != current["sha256"]:
                    # Ordinary file chunks receive the upload grace period.
                    # Fresh random backup ciphertext cannot be a staged upload.
                    private = {"secrets": archive.get("secrets"), "files": [f for f in archive["files"] if f.get("scope") in {"native_database", "agent_task_notes"}]}
                    old |= references(private) | {digest}
        # Prepare checks the head revision and deletion generation atomically.
        # It retains old recovery checkpoints unless a clean replacement exists.
        prepared = asyncio.create_task(self.store.gc_prepare(owner, snapshot["revision"], epoch, sorted(old), bool(clean)))
        try: snapshot = await asyncio.shield(prepared)
        except asyncio.CancelledError:
            await prepared  # Resolve the lease transaction before releasing it.
            raise
        if snapshot.get("active"): return {"deleted_objects": 0, "deferred": True}
        protected = references(snapshot.get("roots", []))
        for ref in snapshot.get("native_refs", []):
            archive = native.get(ref["sha256"])
            if archive is None: raise ValueError("Account changed during collection; no objects were removed")
            protected |= references(archive) | {ref["sha256"]}
        return await self._remove(owner, snapshot, protected)

    async def _remove(self, owner, snapshot, protected):
        deleted = 0
        for candidate in snapshot.get("candidates", [])[:25]:
            digest = candidate["sha256"]
            if digest in protected: continue
            # The gateway rechecks current metadata and the exact head revision
            # before using Storage's physical-delete API, then releases bytes.
            result = await self.store.gc_delete(owner, snapshot["revision"], digest)
            if result.get("deleted"): deleted += 1
        return {"deleted_objects": deleted, "deferred": False}
