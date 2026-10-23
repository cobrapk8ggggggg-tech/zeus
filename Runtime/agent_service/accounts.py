"""Use Codex's own public account protocol; never reuse host ChatGPT cookies."""
import asyncio
import os
import httpx
from .codex import CodexRPC


class Accounts:
    def __init__(self, store, connections, binary):
        self.store, self.connections, self.binary = store, connections, binary
        self.login = None
        self.expiry = None
        self.state = {"status": "idle"}

    async def open(self):
        directory = self.store.root / "codex"
        directory.mkdir(exist_ok=True, mode=0o700)
        environment = self.connections.environment()
        environment["CODEX_HOME"] = str(directory)
        async def notification(method, params):
            if method == "account/login/completed":
                self.state = {"status": "completed" if params.get("success") else "failed", "error": params.get("error")}
        async def request(method, params, identifier):
            raise ValueError("Unexpected account request")
        rpc = CodexRPC([self.binary, "app-server"], str(self.store.root), environment, notification, request)
        try:
            await rpc.start()
        except BaseException:
            await rpc.close()
            raise
        return rpc

    async def start(self, kind, key=""):
        await self.close()
        rpc = await self.open()
        try:
            params = {"type": "apiKey", "apiKey": key} if kind == "apiKey" else {"type": "chatgptDeviceCode"}
            response = await rpc.call("account/login/start", params)
            if kind == "apiKey":
                self.state = {"status": "configured", "validation": "Credential saved by Codex; availability is checked by model listing or the first task."}
                await rpc.close()
            else:
                self.login = rpc
                self.state = {"status": "pending", **response}
                self.expiry = asyncio.create_task(self.expire())
            auth = self.store.root / "codex/auth.json"
            if auth.exists():
                auth.chmod(0o600)
            return self.state
        except BaseException:
            await rpc.close()
            raise

    async def expire(self):
        await asyncio.sleep(900)
        if self.login:
            await self.login.close()
            self.login = None
            if self.state.get("status") == "pending":
                self.state = {"status": "expired"}

    async def models(self):
        provider = self.connections.engine_provider()
        if provider.get("mode") == "custom":
            key = self.connections.credentials("codex-custom")["access_token"]
            async with httpx.AsyncClient(timeout=25) as client:
                response = await client.get(provider["base_url"] + "/models", headers={"Authorization": "Bearer " + key})
                response.raise_for_status()
                items = response.json().get("data", [])
            return {"data": [{"id": item["id"], "model": item["id"], "displayName": item["id"]} for item in items if isinstance(item, dict) and isinstance(item.get("id"), str)]}
        rpc = await self.open()
        try:
            result = await rpc.call("model/list", {"limit": 100})
            return result
        finally:
            await rpc.close()

    async def close(self):
        if self.expiry:
            self.expiry.cancel()
            self.expiry = None
        if self.login:
            await self.login.close()
            self.login = None
