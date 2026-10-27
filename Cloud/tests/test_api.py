import asyncio
from contextlib import asynccontextmanager
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import uuid
import base64
import os
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.fernet import Fernet
from fastapi import Header, HTTPException
import httpx
from zeus_cloud.app import create_app
from test_runtime import MemoryStore


class GatewayFixture:
    def __init__(self, owner, conversation): self.owner, self.conversation, self.objects = owner, conversation, {}
    async def check(self, token): return {"user_id": self.owner, "conversation_id": self.conversation}
    async def put(self, token, data):
        digest = hashlib.sha256(data).hexdigest(); self.objects[digest] = data
        return {"sha256": digest, "bytes": len(data)}
    async def get(self, token, ref): return self.objects[ref["sha256"]]
    async def close(self): pass


class ModelFixture:
    async def stream(self, provider, messages, tools, instructions):
        if not any(m.get("tool_calls") for m in messages):
            yield {"kind": "tool", "id": "write", "name": "file_write", "arguments": {"path": "answer.txt", "content": "actual generated file"}}
        else: yield {"kind": "text", "text": "Created answer.txt"}
    async def close(self): pass


class APITests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.owner, self.other, self.conversation = str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4())
        self.store = MemoryStore(); self.gateway = GatewayFixture(self.owner, self.conversation)
        async def authorized(authorization: str = Header(default="")):
            if authorization == "Bearer fixture-owner": return self.owner
            if authorization == "Bearer fixture-other": return self.other
            raise HTTPException(401, "unauthorized")
        self.app = create_app(store=self.store, owner=self.owner, key=Fernet.generate_key(), auth=authorized,
            work_root=Path(self.temp.name) / "work", models=ModelFixture(), gateway=self.gateway, child_uid=None)
        self.lifecycle = self.app.router.lifespan_context(self.app); await self.lifecycle.__aenter__()
        self.addAsyncCleanup(self.lifecycle.__aexit__, None, None, None)
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app), base_url="http://runtime.test",
                                        headers={"Authorization": "Bearer fixture-owner"})
        self.addAsyncCleanup(self.client.aclose)
        self.provider = {"kind": "openai", "base_url": "https://model.test/v1", "model": "fixture", "api_key": "fixture-secret-not-public"}

    async def submit(self, permission="unrestricted"):
        response = await self.client.put("/v1/providers/default", json=self.provider); self.assertEqual(response.status_code, 200, response.text)
        identifier = str(uuid.uuid4())
        body = {"id": identifier, "conversation": self.conversation, "prompt": "create a file", "file_grant": "fixture-grant",
                "permission_mode": permission, "max_seconds": 30}
        response = await self.client.post("/v1/runs", json=body); self.assertEqual(response.status_code, 200, response.text)
        return identifier, body

    async def wait_state(self, identifier, states):
        for _ in range(100):
            result = await self.client.get("/v1/runs/" + identifier)
            if result.json()["status"] in states: return result.json()
            await asyncio.sleep(0.01)
        self.fail("Run did not reach expected state")

    async def test_disconnected_client_does_not_cancel_server_loop_and_files_are_external(self):
        identifier, body = await self.submit()
        # There is no stream/polling request keeping this run alive.
        await asyncio.sleep(0.05)
        result = await self.wait_state(identifier, {"completed", "failed"})
        self.assertEqual(result["status"], "completed", result)
        self.assertNotIn(b"actual generated file", self.gateway.objects.values())
        grant = "fixture-grant"
        self.assertEqual(await self.app.state.engine.spaces.read_cloud_file(self.owner, self.conversation, "answer.txt", grant), b"actual generated file")
        self.assertFalse(self.app.state.engine.spaces.path(self.owner, self.conversation).exists())
        response = await self.client.get(f"/v1/runs/{identifier}/events")
        events = response.json()["events"]
        self.assertEqual([e["seq"] for e in events], sorted(e["seq"] for e in events))
        self.assertTrue(any(e["kind"] == "tool_result" for e in events))
        replay = await self.client.get(f"/v1/runs/{identifier}/events?after={events[-1]['seq']}")
        self.assertEqual(replay.json()["events"], [])
        again = await self.client.post("/v1/runs", json=body)
        self.assertEqual(again.status_code, 200); self.assertEqual(len(self.store.runs), 1)
        body["prompt"] = "different operation"
        self.assertEqual((await self.client.post("/v1/runs", json=body)).status_code, 409)

    async def test_approval_is_persisted_and_required_before_file_mutation(self):
        identifier, _ = await self.submit("consequential")
        await self.wait_state(identifier, {"waiting_user"})
        self.assertEqual(self.gateway.objects, {})
        requests = [e for e in self.store.timeline if e["kind"] == "approval"]
        self.assertEqual(len(requests), 1)
        response = await self.client.post("/v1/approvals/" + requests[0]["data"]["id"], json={"allowed": True})
        self.assertEqual(response.status_code, 200)
        self.assertEqual((await self.wait_state(identifier, {"completed", "failed"}))["status"], "completed")
        duplicate = await self.client.post("/v1/approvals/" + requests[0]["data"]["id"], json={"allowed": True})
        self.assertEqual(duplicate.status_code, 409)

    async def test_owner_isolation_and_secret_redaction_apply_to_public_routes(self):
        identifier, _ = await self.submit()
        await self.wait_state(identifier, {"completed", "failed"})
        response = await self.client.get("/v1/runs/" + identifier)
        self.assertNotIn("provider", response.json()); self.assertNotIn("grant", response.json())
        encrypted = await self.store.get(self.owner, "provider", "default")
        self.assertNotIn(self.provider["api_key"], json.dumps(encrypted))
        for suffix in ["", "/events", "/stream"]:
            response = await self.client.get("/v1/runs/" + identifier + suffix, headers={"Authorization": "Bearer fixture-other"})
            self.assertEqual(response.status_code, 404)
        response = await self.client.get("/v1/conversations", headers={"Authorization": "Bearer fixture-other"})
        self.assertEqual(response.json()["conversations"], [])

    async def test_validation_does_not_echo_credentials_and_oversize_payload_is_rejected(self):
        response = await self.client.put("/v1/providers/default", json={**self.provider, "kind": "invalid"})
        self.assertEqual(response.status_code, 422); self.assertNotIn("fixture-secret", response.text)
        response = await self.client.post("/v1/runs", content=b"x" * (2 * 1024 * 1024 + 1))
        self.assertEqual(response.status_code, 413)

    async def test_native_aes_archive_import_is_verified_and_can_restore_dotfiles(self):
        key = os.urandom(32); data = b"private value\n"; digest = hashlib.sha256(data).hexdigest(); nonce = os.urandom(12)
        sealed = nonce + AESGCM(key).encrypt(nonce, data, f"{self.owner}|{digest}|0".encode())
        ref = await self.gateway.put("grant", sealed)
        file = {"path": ".env", "bytes": len(data), "sha256": digest, "parts": [ref], "mode": 0o700}
        native = {"id": self.conversation.upper(), "title": "Hidden child", "parentSessionId": str(uuid.uuid4()).upper()}
        body = {"files": [file], "file_key": base64.b64encode(key).decode(), "file_grant": "grant", "history": [], "title": "Existing project", "native_session": native}
        path = f"/v1/conversations/{self.conversation}/import"
        response = await self.client.put(path, json=body); self.assertEqual(response.status_code, 200, response.text)
        record = await self.store.get(self.owner, "workspace", self.conversation)
        self.assertNotIn(base64.b64encode(key).decode(), json.dumps(record))
        root = await self.app.state.engine.spaces.restore(self.owner, self.conversation, "grant")
        self.assertEqual((root / ".env").read_bytes(), data)
        self.assertEqual((root / ".env").stat().st_mode & 0o777, 0o700)
        index = (await self.client.get("/v1/conversations")).json()["conversations"]
        self.assertEqual(index[0]["native_session"], native)
        # Same archive is safe to import again; a different owner-bound key is not.
        self.assertEqual((await self.client.put(path, json=body)).status_code, 200)
        body["file_key"] = base64.b64encode(os.urandom(32)).decode()
        self.assertEqual((await self.client.put(path, json=body)).status_code, 400)
        self.assertEqual((await self.store.get(self.owner, "workspace", self.conversation))["files"], record["files"])

    async def test_inline_provider_snapshot_does_not_require_a_separate_configuration_write(self):
        body = {"id": str(uuid.uuid4()), "conversation": self.conversation, "prompt": "create a file", "provider": self.provider,
                "file_grant": "grant", "permission_mode": "unrestricted", "max_seconds": 30}
        response = await self.client.post("/v1/runs", json=body); self.assertEqual(response.status_code, 200, response.text)
        identifier = response.json()["id"]
        self.assertEqual((await self.wait_state(identifier, {"completed", "failed"}))["status"], "completed")
        for _ in range(100):
            if self.app.state.engine.running is None: break
            await asyncio.sleep(0.01)
        record = await self.store.run(self.owner, identifier)
        self.assertIsNone(record["provider"])
        archived = await self.app.state.engine.history.get(self.owner, "grant", record["payload_archive"])
        snapshot = self.app.state.engine.vault.open(self.owner, archived["provider"])
        self.assertEqual(snapshot["model"], self.provider["model"])
        self.assertEqual(snapshot["api_key"], self.provider["api_key"])
        self.assertEqual(record["history"], []); self.assertEqual(record["tools"], [])
        saved = await self.store.get(self.owner, "provider", "default")
        self.assertNotIn(self.provider["api_key"], json.dumps(saved))
        self.assertEqual(self.app.state.engine.vault.open(self.owner, saved["encrypted"])["model"], self.provider["model"])

    async def test_remote_terminal_is_real_owner_scoped_and_checkpoints_when_closed(self):
        response = await self.client.post("/v1/terminals", json={"conversation": self.conversation, "file_grant": "grant"})
        self.assertEqual(response.status_code, 200, response.text); identifier = response.json()["id"]
        response = await self.client.post(f"/v1/terminals/{identifier}/input", json={"chars": "printf 'terminal file' > terminal.txt\n"})
        self.assertEqual(response.status_code, 200)
        for _ in range(100):
            if (self.app.state.engine.spaces.path(self.owner, self.conversation) / "terminal.txt").exists(): break
            await asyncio.sleep(0.01)
        foreign = await self.client.get(f"/v1/terminals/{identifier}", headers={"Authorization": "Bearer fixture-other"})
        self.assertEqual(foreign.status_code, 404)
        response = await self.client.post(f"/v1/terminals/{identifier}/close")
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(await self.app.state.engine.spaces.read_cloud_file(self.owner, self.conversation, "terminal.txt", "grant"), b"terminal file")

    async def test_completed_events_restore_from_verified_cold_archive_with_fresh_identity(self):
        identifier, _ = await self.submit()
        await self.wait_state(identifier, {"completed"})
        for _ in range(100):
            if not await self.store.events(self.owner, identifier): break
            await asyncio.sleep(0.01)
        record = await self.store.run(self.owner, identifier)
        self.assertTrue(record["event_archives"])
        self.assertEqual(await self.store.events(self.owner, identifier), [])
        original_get = self.gateway.get
        async def current_identity_only(token, ref):
            if token != "fixture-owner": raise ValueError("Previous task capability expired")
            return await original_get(token, ref)
        self.gateway.get = current_identity_only
        response = await self.client.get(f"/v1/runs/{identifier}/events")
        self.assertEqual(response.status_code, 200)
        events = response.json()["events"]
        self.assertEqual(events[-1]["seq"], record["seq"])
        self.assertIn("tool_result", [e["kind"] for e in events])
        with self.assertRaises(ValueError): await self.app.state.engine.history.events(self.owner, identifier)

    async def test_native_identity_is_preserved_and_run_index_never_returns_provider_secrets(self):
        user, assistant = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
        body = {"id": str(uuid.uuid4()), "conversation": self.conversation, "prompt": "create", "provider": self.provider,
                "native_user_id": user, "native_assistant_id": assistant, "native_session": {"id": self.conversation.upper(), "title": "Restorable"},
                "file_grant": "grant", "permission_mode": "unrestricted", "max_seconds": 30}
        response = await self.client.post("/v1/runs", json=body); self.assertEqual(response.status_code, 200, response.text)
        await self.wait_state(body["id"], {"completed"})
        response = await self.client.get(f"/v1/conversations/{self.conversation}/runs")
        self.assertEqual(response.json()["runs"][0]["native_user_id"], user)
        self.assertEqual(response.json()["runs"][0]["native_assistant_id"], assistant)
        self.assertNotIn("provider", response.json()["runs"][0]); self.assertNotIn("grant", response.json()["runs"][0])
        index = (await self.client.get("/v1/conversations")).json()["conversations"]
        self.assertEqual(index[0]["native_session"]["id"], self.conversation.upper())

    async def test_account_memory_is_cloud_persistent_and_separate_from_conversation_files(self):
        class MemoryWriter:
            async def stream(self, provider, messages, tools, instructions):
                if not any(m.get("tool_calls") for m in messages):
                    yield {"kind": "tool", "id": "remember", "name": "file_write", "arguments": {"path": "@memory/preference.md", "content": "persistent account memory"}}
                else: yield {"kind": "text", "text": "Saved memory"}
        self.app.state.engine.models = MemoryWriter()
        identifier, _ = await self.submit()
        self.assertEqual((await self.wait_state(identifier, {"completed", "failed"}))["status"], "completed")
        for _ in range(100):
            if self.app.state.engine.running is None: break
            await asyncio.sleep(0.01)
        from zeus_cloud.files import GLOBAL_WORKSPACE
        record = await self.store.get(self.owner, "workspace", GLOBAL_WORKSPACE)
        self.assertEqual(record["files"][0]["path"], "memory/preference.md")
        self.assertEqual((await self.store.get(self.owner, "workspace", self.conversation))["files"], [])
        self.assertFalse(self.app.state.engine.spaces.path(self.owner, GLOBAL_WORKSPACE).exists())
        root = await self.app.state.engine.spaces.restore(self.owner, GLOBAL_WORKSPACE, "grant")
        self.assertEqual((root / "memory/preference.md").read_text(), "persistent account memory")

    async def test_new_queued_submission_remains_latest_while_an_older_run_saves_progress(self):
        release = asyncio.Event()
        class SlowModel(ModelFixture):
            async def stream(self, *args):
                await release.wait()
                async for item in super().stream(*args): yield item
        self.app.state.engine.models = SlowModel()
        first, _ = await self.submit()
        await self.wait_state(first, {"running"})
        second = str(uuid.uuid4())
        body = {"id": second, "conversation": self.conversation, "prompt": "second queued instruction", "file_grant": "grant", "permission_mode": "unrestricted"}
        self.assertEqual((await self.client.post("/v1/runs", json=body)).status_code, 200)
        release.set()
        await self.wait_state(first, {"completed"})
        record = (await self.client.get(f"/v1/conversations/{self.conversation}")).json()
        self.assertEqual(record["latest_run"], second)
        self.assertEqual((await self.wait_state(second, {"completed", "failed"}))["status"], "completed")

    async def test_local_edit_can_replace_its_verified_base_without_clobbering_an_unseen_cloud_edit(self):
        key = os.urandom(32)
        async def file(content):
            digest = hashlib.sha256(content).hexdigest(); nonce = os.urandom(12)
            ciphertext = nonce + AESGCM(key).encrypt(nonce, content, f"{self.owner}|{digest}|0".encode())
            return {"path": "attachments/project.txt", "bytes": len(content), "sha256": digest, "parts": [await self.gateway.put("grant", ciphertext)]}
        original, changed = await file(b"original project file"), await file(b"edited locally")
        path = f"/v1/conversations/{self.conversation}/import"
        body = {"files": [original], "file_key": base64.b64encode(key).decode(), "file_grant": "grant"}
        self.assertEqual((await self.client.put(path, json=body)).status_code, 200)
        base = (await self.client.get(f"/v1/conversations/{self.conversation}/files")).json()
        self.assertEqual(base["files"][0]["origin"], "workspace")
        lease = str(uuid.uuid4())
        self.assertEqual((await self.client.post(f"/v1/transitions/{lease}/begin")).status_code, 200)
        body.update(files=[changed], lease_id=lease, replace_existing=True, expected_workspace_hash=base["workspace_hash"])
        self.assertEqual((await self.client.put(path, json=body)).status_code, 200)
        # The same verified transition may be retried after an ambiguous reply.
        self.assertEqual((await self.client.put(path, json=body)).status_code, 200)
        current = await self.store.get(self.owner, "workspace", self.conversation)
        self.assertEqual(current["previous"]["files"][0]["sha256"], original["sha256"])
        # Simulate an unseen concurrent revision; the old base must stop it.
        import copy
        newer = copy.deepcopy(current); newer["files"].append({"path": "new-cloud-file", "bytes": 0, "sha256": hashlib.sha256(b"").hexdigest(), "parts": []})
        await self.store.put(self.owner, "workspace", self.conversation, newer)
        self.assertEqual((await self.client.put(path, json=body)).status_code, 409)
        self.assertEqual(len((await self.store.get(self.owner, "workspace", self.conversation))["files"]), 2)
        self.assertEqual((await self.client.post(f"/v1/transitions/{lease}/end")).status_code, 200)

    async def test_canonical_browser_tool_waits_without_worker_and_resumes_once(self):
        class DeviceModel:
            async def stream(self, provider, messages, tools, instructions):
                names = {t["name"] for t in tools}
                assert "browser_use" in names and "shell_execute" in names
                if not any(m.get("role") == "tool" for m in messages):
                    yield {"kind": "tool", "id": "browser-call", "name": "browser_use", "arguments": {"action": "get_text"}}
                else: yield {"kind": "text", "text": "Browser returned original page"}
        self.app.state.engine.models = DeviceModel()
        body = {"id": str(uuid.uuid4()), "conversation": self.conversation, "prompt": "read current browser page", "provider": self.provider,
                "tools": [{"name": n, "description": n, "parameters": {"type": "object", "properties": {}}} for n in ["browser_use", "shell_execute"]],
                "file_grant": "grant", "permission_mode": "unrestricted"}
        response = await self.client.post("/v1/runs", json=body); self.assertEqual(response.status_code, 200, response.text)
        run = await self.wait_state(body["id"], {"waiting_user", "failed"})
        self.assertEqual(run["status"], "waiting_user", run)
        request = run["pending_device"]; claimant = str(uuid.uuid4())
        for _ in range(100):
            if self.app.state.engine.running is None: break
            await asyncio.sleep(0.01)
        self.assertIsNone(self.app.state.engine.running)
        self.assertEqual((await self.client.post(f"/v1/device-tools/{request}/claim", json={"claimant": claimant}, headers={"Authorization": "Bearer fixture-other"})).status_code, 404)
        self.assertEqual((await self.client.post(f"/v1/device-tools/{request}/claim", json={"claimant": claimant})).status_code, 200)
        self.assertEqual((await self.client.post(f"/v1/device-tools/{request}/claim", json={"claimant": str(uuid.uuid4())})).status_code, 409)
        result = {"claimant": claimant, "output": "Actual native browser page", "success": True}
        self.assertEqual((await self.client.post(f"/v1/device-tools/{request}/result", json=result)).status_code, 200)
        done = await self.wait_state(body["id"], {"completed", "failed"})
        self.assertEqual(done["status"], "completed", done)
        messages = (await self.store.get(self.owner, "conversation", self.conversation))["messages"]
        self.assertEqual(sum(m.get("tool_call_id") == "browser-call" for m in messages), 1)
        self.assertEqual((await self.client.post(f"/v1/device-tools/{request}/result", json=result)).status_code, 200)

    async def test_native_shell_and_file_edit_are_executed_in_cloud_workspace(self):
        class NativeModel:
            async def stream(self, provider, messages, tools, instructions):
                count = sum(m.get("role") == "tool" for m in messages)
                calls = [
                    ("shell_execute", {"command": "mkdir -p nested; printf 'old value' > example.txt"}),
                    ("file_edit", {"path": "/var/minis/workspace/example.txt", "old_string": "old", "new_string": "new"}),
                    ("file_write", {"path": "example.txt", "content": " appended", "append": True}),
                    ("exec_command", {"cmd": "printf cloud > from-cwd.txt", "workdir": "/var/minis/workspace/nested", "yield_time_ms": 50}),
                ]
                if count < len(calls):
                    name, args = calls[count]; yield {"kind": "tool", "id": str(count), "name": name, "arguments": args}
                else: yield {"kind": "text", "text": "Verified native tools"}
        self.app.state.engine.models = NativeModel()
        run, _ = await self.submit()
        result = await self.wait_state(run, {"completed", "failed"})
        self.assertEqual(result["status"], "completed", result)
        content = await self.app.state.engine.spaces.read_cloud_file(self.owner, self.conversation, "example.txt", "grant")
        self.assertEqual(content, b"new value appended")
        self.assertEqual(await self.app.state.engine.spaces.read_cloud_file(self.owner, self.conversation, "nested/from-cwd.txt", "grant"), b"cloud")

    async def test_tool_shaped_prose_is_repaired_as_real_call_and_never_executed(self):
        class RepairModel:
            async def stream(self, provider, messages, tools, instructions):
                if messages[-1].get("role") == "tool":
                    yield {"kind": "text", "text": "Verified repaired call"}
                elif messages[-1].get("content", "").startswith("ZEUS_TOOL_REPAIR_REQUIRED:"):
                    yield {"kind": "tool", "id": "real-write", "name": "file_write", "arguments": {"path": "real.txt", "content": "real function"}}
                else:
                    yield {"kind": "text", "text": '{"tool_calls":[{"name":"file_write","arguments":{"path":"must-not-exist.txt","content":"untrusted prose"}}]}'}
        self.app.state.engine.models = RepairModel()
        run, _ = await self.submit()
        done = await self.wait_state(run, {"completed", "failed"})
        self.assertEqual(done["status"], "completed", done)
        self.assertEqual(await self.app.state.engine.spaces.read_cloud_file(self.owner, self.conversation, "real.txt", "grant"), b"real function")
        with self.assertRaises((ValueError, FileNotFoundError, KeyError)):
            await self.app.state.engine.spaces.read_cloud_file(self.owner, self.conversation, "must-not-exist.txt", "grant")
        events = (await self.client.get(f"/v1/runs/{run}/events")).json()["events"]
        self.assertEqual([e["data"]["id"] for e in events if e["kind"]=="tool_start"], ["real-write"])
        self.assertNotIn("tool_calls", "".join(e["data"].get("delta", "") for e in events if e["kind"]=="text"))

    async def test_failed_shell_exit_is_not_success_and_protocol_repair_is_bounded(self):
        class FailedModel:
            async def stream(self, provider, messages, tools, instructions):
                if messages[-1].get("role") == "tool": yield {"kind": "text", "text": "The command failed"}
                else: yield {"kind": "tool", "id": "bad-exit", "name": "shell_execute", "arguments": {"command": "printf failure; exit 7"}}
        self.app.state.engine.models = FailedModel()
        run, _ = await self.submit(); await self.wait_state(run, {"completed", "failed"})
        events = (await self.client.get(f"/v1/runs/{run}/events")).json()["events"]
        result = next(e["data"] for e in events if e["kind"] == "tool_result")
        self.assertFalse(result["success"]); self.assertEqual(json.loads(result["output"])["exit_code"], 7)
        class BrokenModel:
            count = 0
            async def stream(self, provider, messages, tools, instructions):
                self.count += 1
                yield {"kind": "text", "text": '{"tool_calls":[{"name":"file_write","arguments":{"path":"bad.txt","content":"bad"}}]}'}
        broken = BrokenModel(); self.app.state.engine.models = broken
        run, _ = await self.submit(); done = await self.wait_state(run, {"completed", "failed"})
        self.assertEqual(done["status"], "failed", done); self.assertEqual(broken.count, 3)
        events = (await self.client.get(f"/v1/runs/{run}/events")).json()["events"]
        self.assertFalse(any(e["kind"] == "tool_start" for e in events))

    async def test_disabling_all_native_tools_does_not_restore_a_cloud_fallback_catalog(self):
        class NoTools:
            async def stream(self, provider, messages, tools, instructions):
                assert tools == [], "Disabled native tools must stay disabled"
                yield {"kind": "text", "text": "Ordinary conversation without tools"}
        self.app.state.engine.models = NoTools()
        body = {"id": str(uuid.uuid4()), "conversation": self.conversation, "prompt": "just chat", "provider": self.provider,
                "tools": [], "file_grant": "grant", "permission_mode": "unrestricted"}
        self.assertEqual((await self.client.post("/v1/runs", json=body)).status_code, 200)
        self.assertEqual((await self.wait_state(body["id"], {"completed", "failed"}))["status"], "completed")


if __name__ == "__main__": unittest.main()
