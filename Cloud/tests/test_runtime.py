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
    def __init__(self): self.rows = {}; self.runs = {}; self.timeline = []; self.leases = {}; self.deleted = set()
    @asynccontextmanager
    async def active(self): yield self
    async def deletions(self, owner): return [c for o,c in self.deleted if o==owner]
    async def delete_conversation(self, owner, conversation):
        self.deleted.add((owner, conversation))
        ids = {r["id"] for (o,_),r in self.runs.items() if o==owner and r["conversation"]==conversation}
        self.runs = {k:v for k,v in self.runs.items() if not (k[0]==owner and k[1] in ids)}
        self.timeline[:] = [e for e in self.timeline if not(e["owner"]==owner and e["run"] in ids)]
        self.rows = {k:v for k,v in self.rows.items() if not(k[0]==owner and (k[1] in {"workspace","conversation"} and k[2]==conversation or k[1]=="approval" and v.get("run") in ids))}
        return {"deleted":True,"runs":len(ids)}
    async def initialize(self): pass
    async def recover(self): pass
    async def close(self): pass
    async def get(self, owner, kind, identifier): return self.rows.get((owner, kind, identifier))
    async def put(self, owner, kind, identifier, value):
        if kind in {"conversation","workspace"} and (owner,identifier) in self.deleted: raise ValueError("conversation_deleted")
        row = {**value, "id": identifier, "owner": owner, "updated": 0}
        self.rows[owner, kind, identifier] = row; return row
    async def list_conversations(self, owner, after=""):
        return sorted((v for (o,k,i),v in self.rows.items() if o==owner and k=="conversation" and i>after), key=lambda row: row["id"])[:100]
    async def list(self, owner, kind): return [v for (o, k, _), v in self.rows.items() if o == owner and k == kind]
    async def run(self, owner, identifier): return self.runs.get((owner, identifier))
    async def create_run(self, owner, value):
        if (owner,value["conversation"]) in self.deleted: raise ValueError("conversation_deleted")
        if owner in self.leases: raise ValueError("Account transition is in progress")
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
    async def account_state(self, owner): return {"lease": self.leases.get(owner), "active_runs": sum(o == owner and r["status"] in {"queued", "running", "waiting_user"} for (o,_),r in self.runs.items())}
    async def transition(self, owner, identifier, command):
        if command == "end": self.leases.pop(owner, None); return True
        if command == "begin" and (await self.account_state(owner))["active_runs"]: raise ValueError("Finish cloud tasks first")
        self.leases[owner] = {"id": identifier, "expires": 4102444800}; return self.leases[owner]


class RuntimeTests(unittest.IsolatedAsyncioTestCase):
    def test_legacy_history_has_contiguous_tool_pairs_and_never_replays_incomplete_calls(self):
        from zeus_cloud.providers import normalize_history
        call = {"id": "done", "type": "function", "function": {"name": "file_write", "arguments": "{}"}}
        history = [{"role": "tool", "tool_call_id": "orphan", "content": "orphan"},
                   {"role": "assistant", "content": "", "tool_calls": [call, {**call, "id": "incomplete"}]},
                   {"role": "user", "content": "next message"}, {"role": "tool", "tool_call_id": "done", "content": "success"}]
        result = normalize_history(history)
        self.assertEqual([r["role"] for r in result], ["assistant", "tool", "user"])
        self.assertEqual(result[0]["tool_calls"], [call]); self.assertEqual(result[1]["tool_call_id"], "done")

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

    async def test_repair_forces_only_registered_structured_tools_in_each_provider_protocol(self):
        from zeus_cloud.tool_protocol import candidate, repair
        tool = {"name":"file_read", "description":"Read", "parameters":{"type":"object", "properties":{"path":{"type":"string"}}}}
        for text in ['normal prose {"tool_calls":[{"name":"file_read"}]}', '```json\n{"tool_calls":[{"name":"file_read"}]}\n```', '{"tool_calls":[{"name":"unknown"}]}']:
            self.assertIsNone(candidate(text, [tool]))
        self.assertEqual(candidate('{"tool_calls":[{"name":"file_read"}]}', [tool]), "file_read")
        for kind, expected, final in [
            ("openai", {"type":"function","function":{"name":"file_read"}}, '[DONE]'),
            ("responses", {"type":"function","name":"file_read"}, '{"type":"response.completed"}'),
            ("anthropic", {"type":"tool","name":"file_read"}, '{"type":"message_stop"}'),
        ]:
            bodies=[]
            def serve(request):
                bodies.append(json.loads(request.content)); return httpx.Response(200, content="data: "+final+"\n\n")
            models=Models(httpx.AsyncClient(transport=httpx.MockTransport(serve)))
            try:
                provider={"kind":kind,"base_url":"https://model.test/v1","model":"test","api_key":"fixture"}
                _=[e async for e in models.stream(provider,[{"role":"user","content":repair("file_read")}],[tool],"system")]
                self.assertEqual(bodies[-1]["tool_choice"], expected)
                _=[e async for e in models.stream(provider,[{"role":"user","content":repair("unknown")}],[tool],"system")]
                self.assertNotIn("tool_choice", bodies[-1])
            finally: await models.close()

    def test_terminal_result_remains_valid_json_when_output_is_truncated(self):
        from zeus_cloud.terminal import protocol_result
        value = {"id":"pty", "output": "\n\x1b مرحبا "*10000, "next_offset":90000, "exit_code":7, "truncated":False}
        result = protocol_result(value)
        self.assertLessEqual(len(result), 32000)
        decoded = json.loads(result)
        self.assertEqual(decoded["id"], "pty"); self.assertEqual(decoded["exit_code"], 7)
        self.assertTrue(decoded["truncated"])

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
