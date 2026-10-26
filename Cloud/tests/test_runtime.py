import asyncio
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
import uuid
from contextlib import asynccontextmanager
import httpx
from zeus_cloud.files import FilesGateway, Workspaces, open_regular, inventory, relative_path
from zeus_cloud.providers import Models, provider_url
from zeus_cloud.terminal import Terminals


class MemoryStore:
    def __init__(self): self.rows = {}; self.runs = {}; self.timeline = []
    @asynccontextmanager
    async def active(self): yield self
    async def initialize(self): pass
    async def recover(self): pass
    async def close(self): pass
    async def get(self, owner, kind, identifier): return self.rows.get((owner, kind, identifier))
    async def put(self, owner, kind, identifier, value):
        row = {**value, "id": identifier, "owner": owner, "updated": 0}
        self.rows[owner, kind, identifier] = row; return row
    async def list(self, owner, kind): return [v for (o, k, _), v in self.rows.items() if o == owner and k == kind]
    async def run(self, owner, identifier): return self.runs.get((owner, identifier))
    async def create_run(self, owner, value):
        return self.runs.setdefault((owner, value["id"]), {**value, "owner": owner, "seq": 0})
    async def update_run(self, owner, identifier, **changes):
        self.runs[owner, identifier].update(changes); return self.runs[owner, identifier]
    async def claim(self):
        for value in self.runs.values():
            if value["status"] == "queued": value["status"] = "running"; return value
    async def event(self, owner, identifier, kind, data):
        run = self.runs[owner, identifier]; run["seq"] += 1
        self.timeline.append({"owner": owner, "run": identifier, "seq": run["seq"], "kind": kind, "data": data})
    async def events(self, owner, identifier, after=0): return [v for v in self.timeline if v["owner"] == owner and v["run"] == identifier and v["seq"] > after]
    async def list_runs(self, owner, conversation, before=4102444800): return sorted([r for (o,_),r in self.runs.items() if o == owner and r["conversation"] == conversation and r["created"] < before], key=lambda r:r["created"], reverse=True)[:25]
    async def prune_events(self, owner, run, through): self.timeline[:] = [e for e in self.timeline if not (e["owner"] == owner and e["run"] == run and e["seq"] <= through)]


class RuntimeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.root = Path(self.temp.name)
        self.owner, self.conversation = str(uuid.uuid4()), str(uuid.uuid4())
    async def asyncTearDown(self): self.temp.cleanup()

    async def test_checkpoint_restores_actual_binary_and_utf8_files_without_reupload(self):
        blobs, uploads = {}, []
        def service(request):
            query = request.url.params
            if query["op"] == "put":
                data = request.content; digest = hashlib.sha256(data).hexdigest(); blobs[digest] = data; uploads.append(digest)
                return httpx.Response(200, json={"sha256": digest, "bytes": len(data), "verified": True})
            return httpx.Response(200, content=blobs[query["sha"]])
        gateway = FilesGateway("https://files.test", httpx.AsyncClient(transport=httpx.MockTransport(service)))
        self.addAsyncCleanup(gateway.close)
        store = MemoryStore(); spaces = Workspaces(self.root / "a", gateway, store)
        root = await spaces.restore(self.owner, self.conversation, "grant")
        (root / "hello.txt").write_text("مرحبا ZEUS"); (root / "image.bin").write_bytes(bytes(range(256)))
        original = await spaces.checkpoint(self.owner, self.conversation, "grant")
        await spaces.checkpoint(self.owner, self.conversation, "grant")
        self.assertEqual(len(uploads), 2)
        recreated = Workspaces(self.root / "b", gateway, store)
        restored = await recreated.restore(self.owner, self.conversation, "grant")
        self.assertEqual((restored / "hello.txt").read_text(), "مرحبا ZEUS")
        self.assertEqual((restored / "image.bin").read_bytes(), bytes(range(256)))
        self.assertEqual(original, await store.get(self.owner, "workspace", self.conversation))

    async def test_corrupt_remote_object_is_never_accepted(self):
        gateway = FilesGateway("https://files.test", httpx.AsyncClient(transport=httpx.MockTransport(lambda _: httpx.Response(200, content=b"wrong"))))
        self.addAsyncCleanup(gateway.close)
        with self.assertRaises(ValueError): await gateway.get("grant", {"sha256": hashlib.sha256(b"right").hexdigest(), "bytes": 5})

    async def test_snapshot_does_not_follow_links_to_a_secret_or_publish_incomplete_manifest(self):
        store = MemoryStore(); spaces = Workspaces(self.root / "work", None, store)
        root = await spaces.restore(self.owner, self.conversation, "grant")
        secret = self.root / "private"; secret.write_text("secret")
        (root / "link").symlink_to(secret)
        with self.assertRaises(ValueError): await spaces.checkpoint(self.owner, self.conversation, "grant")
        self.assertIsNone(await store.get(self.owner, "workspace", self.conversation))
        with self.assertRaises(OSError):
            with open_regular(root, "link") as file: file.read()
        (root / "directory").symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(OSError):
            with open_regular(root, "directory/private") as file: file.read()

    async def test_paths_reject_escape_and_absolute_names(self):
        for path in ["../secret", "/etc/passwd", "folder/../../secret", "a//b", "a\\b", "a/./b"]:
            with self.assertRaises(ValueError): relative_path(path)

    async def test_provider_stream_assembles_real_function_arguments_and_rejects_truncation(self):
        events = [
            {"choices": [{"delta": {"content": "hello "}}]},
            {"choices": [{"delta": {"content": "world", "tool_calls": [{"index": 0, "id": "call_1", "function": {"name": "file_read", "arguments": '{"path":'}}]}}]},
            {"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {"arguments": '"hello.txt"}'}}]}, "finish_reason": "tool_calls"}]},
        ]
        content = "".join("data: " + json.dumps(event) + "\n\n" for event in events)
        models = Models(httpx.AsyncClient(transport=httpx.MockTransport(lambda _: httpx.Response(200, content=content))))
        self.addAsyncCleanup(models.close)
        provider = {"kind": "openai", "base_url": "https://model.test/v1", "model": "test", "api_key": "fixture"}
        result = [event async for event in models.stream(provider, [{"role": "user", "content": "inspect"}], [], "system")]
        self.assertEqual("".join(e.get("text", "") for e in result), "hello world")
        self.assertEqual(result[-1]["arguments"], {"path": "hello.txt"})
        truncated = Models(httpx.AsyncClient(transport=httpx.MockTransport(lambda _: httpx.Response(200, content='data: {"choices":[{"delta":{"content":"partial"}}]}\n\n'))))
        self.addAsyncCleanup(truncated.close)
        with self.assertRaises(ValueError): _ = [event async for event in truncated.stream(provider, [], [], "system")]

    async def test_terminal_is_a_real_pty_and_does_not_inherit_backend_secrets(self):
        events = []
        async def event(terminal, kind, value): events.append((kind, value))
        manager = Terminals(event); self.addAsyncCleanup(manager.close)
        os.environ["ZEUS_TEST_BACKEND_SECRET"] = "must-not-inherit"
        self.addCleanup(os.environ.pop, "ZEUS_TEST_BACKEND_SECRET", None)
        terminal = await manager.start(self.owner, self.conversation, self.root,
            command="test -t 0 && printf 'pty:%s' \"${ZEUS_TEST_BACKEND_SECRET:-absent}\"", seconds=10)
        await asyncio.wait_for(terminal.reader, 5)
        output = manager.read(self.owner, terminal.id)
        self.assertIn("pty:absent", output["output"]); self.assertEqual(output["exit_code"], 0)
        with self.assertRaises(KeyError): manager.read(str(uuid.uuid4()), terminal.id)


if __name__ == "__main__": unittest.main()
