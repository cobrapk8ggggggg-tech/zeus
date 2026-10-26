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
        file = {"path": ".env", "bytes": len(data), "sha256": digest, "parts": [ref]}
        body = {"files": [file], "file_key": base64.b64encode(key).decode(), "file_grant": "grant", "history": [], "title": "Existing project"}
        path = f"/v1/conversations/{self.conversation}/import"
        response = await self.client.put(path, json=body); self.assertEqual(response.status_code, 200, response.text)
        record = await self.store.get(self.owner, "workspace", self.conversation)
        self.assertNotIn(base64.b64encode(key).decode(), json.dumps(record))
        root = await self.app.state.engine.spaces.restore(self.owner, self.conversation, "grant")
        self.assertEqual((root / ".env").read_bytes(), data)
        # Same archive is safe to import again; a different owner-bound key is not.
        self.assertEqual((await self.client.put(path, json=body)).status_code, 200)
        body["file_key"] = base64.b64encode(os.urandom(32)).decode()
        with self.assertRaises(Exception): await self.client.put(path, json=body)
        self.assertEqual((await self.store.get(self.owner, "workspace", self.conversation))["files"], record["files"])

    async def test_inline_provider_snapshot_does_not_require_a_separate_configuration_write(self):
        body = {"id": str(uuid.uuid4()), "conversation": self.conversation, "prompt": "create a file", "provider": self.provider,
                "file_grant": "grant", "permission_mode": "unrestricted", "max_seconds": 30}
        response = await self.client.post("/v1/runs", json=body); self.assertEqual(response.status_code, 200, response.text)
        identifier = response.json()["id"]
        self.assertEqual((await self.wait_state(identifier, {"completed", "failed"}))["status"], "completed")
        snapshot = self.app.state.engine.vault.open(self.owner, (await self.store.run(self.owner, identifier))["provider"])
        self.assertEqual(snapshot["model"], self.provider["model"])
        self.assertIsNone(await self.store.get(self.owner, "provider", "default"))

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


if __name__ == "__main__": unittest.main()
