import asyncio
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch
from fastapi.testclient import TestClient
from agent_service.app import create_app
from agent_service.codex import CodexRPC
from agent_service.plugins import Connections
from agent_service.store import Store
from agent_service.worker import Worker, command

TOKEN = "zeus-test-independent-owner-12345678"


class APITests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.app = create_app(self.directory.name, TOKEN)
        self.client = TestClient(self.app, headers={"Authorization": "Bearer " + TOKEN})

    def tearDown(self):
        self.client.close()
        self.directory.cleanup()

    def project(self):
        response = self.client.post("/v1/projects", json={"name": "Actual Git tree", "verify_commands": ["git status --porcelain"]})
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def test_auth_and_private_file_boundaries(self):
        self.assertEqual(self.client.get("/v1/projects", headers={"Authorization": "Bearer wrong"}).status_code, 401)
        project = self.project()
        root = Path(project["workspace"])
        (root / "hello.txt").write_text("مرحبا")
        self.assertEqual(self.client.get(f"/v1/projects/{project['id']}/files", params={"path": "hello.txt"}).json()["text"], "مرحبا")
        for path in ["../zeus.sqlite3", ".git/config"]:
            self.assertEqual(self.client.get(f"/v1/projects/{project['id']}/files", params={"path": path}).status_code, 400)

    def test_retry_is_idempotent_but_different_payload_is_rejected(self):
        project = self.project()
        path = f"/v1/projects/{project['id']}/tasks"
        body = {"prompt": "Implement", "idempotency_key": "same-request"}
        first = self.client.post(path, json=body).json()
        self.assertEqual(first["id"], self.client.post(path, json=body).json()["id"])
        self.assertEqual(self.client.post(path, json={**body, "prompt": "different"}).status_code, 409)
        self.assertEqual(len(self.client.get("/v1/tasks").json()["tasks"]), 1)

    def test_diff_keeps_changes_after_the_agent_commits_them(self):
        import subprocess
        project = self.project()
        root = Path(project["workspace"])
        (root / "feature.txt").write_text("actual change")
        for args in [["git", "add", "feature.txt"], ["git", "commit", "-m", "Implement feature"]]:
            subprocess.run(args, cwd=root, capture_output=True, check=True)
        value = self.client.get(f"/v1/projects/{project['id']}/diff").json()
        self.assertIn("actual change", value["diff"])
        self.assertEqual(value["status"], "")

    def test_restart_keeps_thread_and_events_without_replaying_writes(self):
        project = self.project()
        task = self.client.post(f"/v1/projects/{project['id']}/tasks", json={"prompt": "work"}).json()
        store = self.app.state.store
        store.update("task", task["id"], status="running", thread_id="saved-codex-thread")
        store.event(task["id"], "item/agentMessage/delta", {"delta": "persistent"})
        second = create_app(self.directory.name, TOKEN)
        second.state.worker.recover()
        current = second.state.store.get("task", task["id"])
        self.assertEqual(current["status"], "interrupted")
        self.assertEqual(current["thread_id"], "saved-codex-thread")
        self.assertEqual(second.state.store.events(task["id"])[-1]["data"]["delta"], "persistent")

    def test_worker_continues_after_client_closes_its_connection(self):
        class Engine:
            def __init__(self, command, cwd, environment, notification, request): self.notification = notification
            async def start(self): pass
            async def close(self): pass
            async def call(self, method, params):
                if method.startswith("thread/"): return {"thread": {"id": "saved-thread"}}
                await asyncio.sleep(.5)
                await self.notification("item/agentMessage/delta", {"delta": "finished without client"})
                await self.notification("turn/completed", {"turn": {"status": "completed"}})
                return {}
        with patch("agent_service.worker.CodexRPC", Engine), TestClient(self.app, headers={"Authorization": "Bearer " + TOKEN}) as server:
            project = server.post("/v1/projects", json={"name": "Disconnect test", "verify_commands": ["exit 0"]}).json()
            other = TestClient(self.app, headers={"Authorization": "Bearer " + TOKEN})
            task = other.post(f"/v1/projects/{project['id']}/tasks", json={"prompt": "work"}).json()
            other.close()
            # The short-lived HTTP client is now gone; the server's worker is
            # still owned by the outer application lifespan.
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                current = server.get(f"/v1/tasks/{task['id']}").json()
                if current["status"] == "completed": break
                time.sleep(.05)
            self.assertEqual(current["status"], "completed")
            events = server.get(f"/v1/tasks/{task['id']}/events").json()["events"]
            self.assertTrue(any(e["data"].get("delta") == "finished without client" for e in events))


class WorkerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.directory.name))
        self.connections = Connections(self.store, "https://example.org", TOKEN, 8080)
        self.worker = Worker(self.store, self.connections)

    async def asyncTearDown(self):
        self.directory.cleanup()

    async def test_output_limit_and_timeout_kill_real_process(self):
        code, output = await command(["python3", "-c", "print('x'*1000000)"], self.store.root)
        self.assertEqual(code, 0)
        self.assertEqual(len(output), 200000)
        with self.assertRaises(TimeoutError):
            await command(["python3", "-c", "import time; time.sleep(30)"], self.store.root, timeout=.05)

    async def test_unconnected_plugins_do_not_break_codex_mcp_startup(self):
        self.store.put("plugin", {"id": "github", "revision": "test", "skills": []})
        self.connections.write_codex_config()
        config = self.store.root / "codex/config.toml"
        self.assertNotIn("[mcp_servers.github]", config.read_text())
        self.connections.save_token("github", {"access_token": "independent-test-token"})
        self.connections.write_codex_config()
        self.assertIn("[mcp_servers.github]", config.read_text())
        self.assertNotIn("independent-test-token", config.read_text())
        self.assertNotIn("independent-test-token", self.store.get("connection", "github")["encrypted"])

    async def test_approval_survives_requester_and_grants_only_requested_permissions(self):
        task = self.store.put("task", {"id": "task", "status": "running", "permission_mode": "consequential"})
        permissions = {"network": {"enabled": True}}
        pending = asyncio.create_task(self.worker.approve(task, "item/permissions/requestApproval", {"permissions": permissions}, 1))
        await asyncio.sleep(.03)
        approval = self.store.all("approval")[0]
        self.assertEqual(self.store.get("task", "task")["status"], "waiting_user")
        self.store.update("approval", approval["id"], status="allowed")
        self.worker.approvals[approval["id"]].set_result({"allowed": True})
        self.assertEqual((await pending)["permissions"], permissions)
        self.assertFalse(Worker.decision("item/permissions/requestApproval", False, {"permissions": permissions})["permissions"])

    async def test_verification_failure_is_never_completed(self):
        root = self.store.root / "workspace"
        root.mkdir()
        await command(["git", "init", str(root)], self.store.root)
        self.store.put("project", {"id": "p", "workspace": str(root), "name": "tests", "verify_commands": ["exit 7"]})
        self.store.put("task", {"id": "t", "project_id": "p", "prompt": "task", "acceptance": "must pass", "status": "queued", "permission_mode": "unrestricted", "max_seconds": 60, "max_attempts": 2})
        # The engine fixture ends its turn successfully; independent real shell
        # checks still fail, so the service must request repair and report failure.
        class Engine:
            turns = 0
            def __init__(self, command, cwd, environment, notification, request): self.notification = notification
            async def start(self): pass
            async def close(self): pass
            async def call(self, method, params):
                if method.startswith("thread/"): return {"thread": {"id": "real-thread-shape"}}
                Engine.turns += 1
                await self.notification("turn/completed", {"turn": {"status": "completed"}})
                return {}
        with patch("agent_service.worker.CodexRPC", Engine):
            await self.worker.run("t")
        self.assertEqual(Engine.turns, 2)
        self.assertEqual(self.store.get("task", "t")["status"], "failed")
        checks = [e for e in self.store.events("t") if e["kind"] == "verification"]
        self.assertEqual([e["data"]["exit_code"] for e in checks], [7, 7])

    async def test_real_codex_protocol_handshake_without_model_request(self):
        import shutil
        binary = shutil.which("codex")
        if not binary: self.skipTest("Codex not installed")
        async def notification(method, params): pass
        async def request(method, params, identifier): raise AssertionError(method)
        environment = self.connections.environment()
        environment["CODEX_HOME"] = str(self.store.root / "codex")
        rpc = CodexRPC([binary, "app-server"], str(self.store.root), environment, notification, request)
        try:
            await rpc.start()
            account = await rpc.call("account/read", {"refreshToken": False})
            self.assertIn("requiresOpenaiAuth", account)
        finally:
            await rpc.close()


if __name__ == "__main__": unittest.main()
