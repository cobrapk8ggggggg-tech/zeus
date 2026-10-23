"""Authenticated single-owner API. Worker lifetime never follows an HTTP request."""
import asyncio
from contextlib import asynccontextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import time
import uuid
from urllib.parse import urlparse
import httpx
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse
from pydantic import BaseModel, Field
from .store import Store
from .worker import Worker, TERMINAL, command
from .plugins import Connections
from .accounts import Accounts


class ProjectInput(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    repo_url: str = ""
    base_ref: str = ""
    kind: str = "generic"
    model: str = ""
    verify_commands: list[str] = Field(default_factory=list, max_length=20)


class TaskInput(BaseModel):
    prompt: str = Field(min_length=1, max_length=100_000)
    acceptance: str = Field(default="", max_length=20_000)
    permission_mode: str = "consequential"
    max_seconds: int = Field(default=7200, ge=60, le=86_400)
    max_attempts: int = Field(default=3, ge=1, le=10)
    idempotency_key: str = Field(default="", max_length=100)


def create_app(data_dir=None, api_token=None, codex_binary=None, public_url=None, port=None):
    root = Path(data_dir or os.environ.get("ZEUS_DATA_DIR", "./zeus-data"))
    token = api_token or os.environ.get("ZEUS_API_TOKEN", "")
    if len(token) < 24:
        raise RuntimeError("Set ZEUS_API_TOKEN to an independent random token of at least 24 characters")
    store = Store(root)
    connections = Connections(store, public_url or os.environ.get("ZEUS_PUBLIC_URL", ""), token, port or int(os.environ.get("PORT", "8080")))
    worker = Worker(store, connections, codex_binary or os.environ.get("ZEUS_CODEX_BINARY", "codex"))
    accounts = Accounts(store, connections, worker.codex_binary)

    async def authenticated(authorization: str = Header(default="")):
        supplied = authorization.removeprefix("Bearer ")
        if not secrets.compare_digest(supplied, token):
            raise HTTPException(401, "يلزم رمز ربط Zeus الصحيح.")

    @asynccontextmanager
    async def lifespan(app):
        worker.recover()
        loop = asyncio.create_task(worker.loop())
        try:
            yield
        finally:
            loop.cancel()
            await worker.shutdown()
            await accounts.close()
            await asyncio.gather(loop, return_exceptions=True)

    app = FastAPI(title="ZEUS Project Agent", version="1.0.0", lifespan=lifespan)
    app.state.store, app.state.worker, app.state.connections = store, worker, connections
    authorized = [Depends(authenticated)]

    @app.exception_handler(KeyError)
    async def missing(_, error):
        return JSONResponse({"detail": "العنصر المطلوب غير موجود."}, status_code=404)

    @app.exception_handler(ValueError)
    async def invalid(_, error):
        return JSONResponse({"detail": str(error)[:2000]}, status_code=400)

    @app.get("/health")
    async def health():
        return {"service": "zeus-project-agent", "version": "1.0.0"}

    @app.get("/v1/capabilities", dependencies=authorized)
    async def capabilities():
        binary = shutil.which(worker.codex_binary)
        version = ""
        if binary:
            _, version = await command([binary, "--version"], store.root, timeout=10)
        return {"codex_installed": bool(binary), "codex_version": version.strip(),
            "auth_configured": bool(os.environ.get("CODEX_API_KEY") or (store.root / "codex/auth.json").exists()),
            "durable_jobs": True, "platform": os.uname().sysname,
            "xcode_available": bool(shutil.which("xcodebuild")),
            "permission_note": "Codex approvals cover the engine's command/file/permission requests. Internal read operations are not individually exposed as approval requests.",
            "single_owner": True}

    @app.get("/v1/projects", dependencies=authorized)
    async def projects():
        return {"projects": store.all("project")}

    @app.post("/v1/account/login", dependencies=authorized)
    async def account_login(values: dict):
        kind = values.get("type", "")
        if kind not in {"apiKey", "chatgptDeviceCode"}:
            raise ValueError("اختر مفتاح API أو تسجيل دخول Codex برمز الجهاز.")
        key = values.get("apiKey", "")
        if kind == "apiKey" and (not isinstance(key, str) or not 8 <= len(key) <= 20000):
            raise ValueError("مفتاح API غير صالح.")
        return await accounts.start(kind, key)

    @app.get("/v1/account/login", dependencies=authorized)
    async def account_status():
        return accounts.state

    @app.get("/v1/models", dependencies=authorized)
    async def models():
        return await accounts.models()

    @app.post("/v1/projects", dependencies=authorized)
    async def create_project(value: ProjectInput):
        if value.kind not in {"generic", "web", "ios", "android"}:
            raise ValueError("نوع المشروع غير صالح.")
        if value.base_ref and not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._/\-]{0,150}", value.base_ref):
            raise ValueError("مرجع Git غير صالح.")
        if any(len(check) > 5000 for check in value.verify_commands):
            raise ValueError("أمر تحقق أكبر من الحد.")
        identifier = str(uuid.uuid4())
        workspace = store.root / "workspaces" / identifier
        workspace.parent.mkdir(exist_ok=True)
        environment = connections.environment()
        if value.repo_url:
            parsed = urlparse(value.repo_url)
            if parsed.scheme != "https" or parsed.hostname not in {"github.com", "gitlab.com", "bitbucket.org"} or parsed.username or parsed.password:
                raise ValueError("استخدم رابط HTTPS لمستودع GitHub أو GitLab أو Bitbucket دون بيانات دخول في الرابط.")
            arguments = ["git", "-c", "credential.helper=!gh auth git-credential", "clone", "--no-recurse-submodules"]
            if value.base_ref:
                arguments += ["--branch", value.base_ref]
            arguments += ["--", value.repo_url, str(workspace)]
            code, output = await command(arguments, store.root, environment, timeout=180)
            if code:
                raise ValueError("تعذر استنساخ المستودع. تحقق من الربط والصلاحيات: " + output[-2000:])
        else:
            workspace.mkdir()
            code, output = await command(["git", "init"], workspace, environment)
            if code:
                raise ValueError(output)
        branch = "zeus/" + identifier[:8]
        code, output = await command(["git", "checkout", "-b", branch], workspace, environment)
        if code:
            raise ValueError(output)
        for key, value_text in [("user.name", "Zeus"), ("user.email", "zeus@localhost"), ("credential.helper", "!gh auth git-credential")]:
            await command(["git", "config", key, value_text], workspace, environment)
        project = {**value.model_dump(), "id": identifier, "workspace": str(workspace), "branch": branch, "created": time.time()}
        return store.put("project", project)

    @app.patch("/v1/projects/{identifier}", dependencies=authorized)
    async def update_project(identifier: str, values: dict):
        allowed = {"name", "model", "verify_commands"}
        if set(values) - allowed:
            raise ValueError("حقول المشروع غير قابلة للتعديل.")
        current = store.get("project", identifier)
        checked = ProjectInput.model_validate({**current, **values})
        return store.update("project", identifier, **{key: getattr(checked, key) for key in values})

    @app.get("/v1/projects/{identifier}/files", dependencies=authorized)
    async def project_files(identifier: str, path: str = ""):
        project = store.get("project", identifier)
        root = Path(project["workspace"]).resolve()
        selected = (root / path).resolve()
        if not selected.is_relative_to(root) or ".git" in Path(path).parts:
            raise ValueError("مسار الملف خارج مساحة المشروع.")
        if selected.is_dir():
            return {"path": path, "files": [{"name": p.name, "directory": p.is_dir()} for p in sorted(selected.iterdir()) if p.name != ".git"][:1000]}
        if selected.stat().st_size > 2_000_000:
            raise ValueError("الملف أكبر من حد المعاينة؛ استخدم أدوات المشروع لقراءة أجزاء منه.")
        return {"path": path, "text": selected.read_text(errors="replace")}

    @app.get("/v1/projects/{identifier}/diff", dependencies=authorized)
    async def project_diff(identifier: str):
        project = store.get("project", identifier)
        _, status = await command(["git", "status", "--short"], project["workspace"])
        code, diff = await command(["git", "diff", "HEAD", "--"], project["workspace"])
        return {"status": status, "diff": diff, "has_head": code == 0, "branch": project["branch"]}

    @app.get("/v1/tasks", dependencies=authorized)
    async def tasks(project_id: str = ""):
        return {"tasks": [t for t in store.all("task") if not project_id or t["project_id"] == project_id]}

    @app.post("/v1/projects/{identifier}/tasks", dependencies=authorized)
    async def create_task(identifier: str, value: TaskInput):
        store.get("project", identifier)
        if value.permission_mode not in {"askAll", "consequential", "unrestricted"}:
            raise ValueError("وضع الموافقة غير صالح.")
        fingerprint = hashlib.sha256(json.dumps(value.model_dump(exclude={"idempotency_key"}), sort_keys=True).encode()).hexdigest()
        if value.idempotency_key:
            for existing in store.all("task"):
                if existing["project_id"] == identifier and existing.get("idempotency_key") == value.idempotency_key:
                    if existing["fingerprint"] != fingerprint:
                        raise HTTPException(409, "مفتاح إعادة المحاولة مرتبط بطلب مختلف.")
                    return existing
        task = {**value.model_dump(), "id": str(uuid.uuid4()), "project_id": identifier, "fingerprint": fingerprint,
            "status": "queued", "thread_id": None, "created": time.time()}
        store.put("task", task)
        store.event(task["id"], "state", {"status": "queued"})
        return task

    @app.get("/v1/tasks/{identifier}", dependencies=authorized)
    async def task(identifier: str):
        return store.get("task", identifier)

    @app.get("/v1/tasks/{identifier}/events", dependencies=authorized)
    async def events(identifier: str, after: int = 0):
        current = store.get("task", identifier)
        items = store.events(identifier, after)
        return {"task": current, "events": items, "cursor": items[-1]["seq"] if items else after}

    @app.get("/v1/tasks/{identifier}/stream", dependencies=authorized)
    async def stream(identifier: str, request: Request, after: int = 0):
        store.get("task", identifier)
        async def lines():
            nonlocal after
            while not await request.is_disconnected():
                items = store.events(identifier, after)
                for item in items:
                    yield "id: " + str(item["seq"]) + "\ndata: " + json.dumps(item, ensure_ascii=False) + "\n\n"
                    after = item["seq"]
                if not items and store.get("task", identifier)["status"] in TERMINAL:
                    return
                if not items:
                    yield ": heartbeat\n\n"
                await asyncio.sleep(0.5)
        return StreamingResponse(lines(), media_type="text/event-stream", headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})

    @app.post("/v1/tasks/{identifier}/cancel", dependencies=authorized)
    async def cancel(identifier: str):
        current = store.get("task", identifier)
        if current["status"] not in TERMINAL:
            store.update("task", identifier, status="cancelling")
            if identifier in worker.running:
                worker.running[identifier].cancel()
            else:
                store.update("task", identifier, status="cancelled")
                store.event(identifier, "state", {"status": "cancelled"})
        return store.get("task", identifier)

    @app.post("/v1/tasks/{identifier}/resume", dependencies=authorized)
    async def resume(identifier: str):
        current = store.get("task", identifier)
        if current["status"] not in TERMINAL or identifier in worker.running:
            raise HTTPException(409, "المهمة قيد التنفيذ بالفعل.")
        store.update("task", identifier, status="queued", error=None)
        store.event(identifier, "state", {"status": "queued", "resuming": True})
        return store.get("task", identifier)

    @app.get("/v1/approvals", dependencies=authorized)
    async def approvals():
        return {"approvals": [a for a in store.all("approval") if a["status"] == "pending"]}

    @app.post("/v1/approvals/{identifier}", dependencies=authorized)
    async def answer(identifier: str, values: dict):
        current = store.get("approval", identifier)
        if current["status"] != "pending" or identifier not in worker.approvals:
            raise HTTPException(409, "انتهت صلاحية الطلب؛ حدّث حالة المهمة.")
        if not isinstance(values.get("allowed"), bool):
            raise ValueError("اختر السماح أو الرفض.")
        future = worker.approvals[identifier]
        store.update("approval", identifier, status="allowed" if values["allowed"] else "denied")
        if not future.done():
            future.set_result(values)
        return {"answered": True}

    @app.get("/v1/plugins", dependencies=authorized)
    async def plugins():
        return {"plugins": connections.catalog()}

    @app.post("/v1/plugins/{identifier}/install", dependencies=authorized)
    async def install(identifier: str):
        return await connections.install(identifier)

    @app.post("/v1/connections/{identifier}/token", dependencies=authorized)
    async def connect_token(identifier: str, values: dict):
        provider = connections.definition(identifier)
        access = values.get("token", "")
        if not isinstance(access, str) or len(access) < 8 or len(access) > 20_000:
            raise ValueError("توكن الوصول غير صالح.")
        async with httpx.AsyncClient(timeout=30) as client:
            probe = await client.post(provider["mcp_url"], headers={"Authorization": "Bearer " + access,
                "Accept": "application/json, text/event-stream"}, json={"jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "ZEUS", "version": "1.0"}}})
        if probe.status_code not in {200, 202}:
            raise ValueError(f"رفض المزود التوكن (HTTP {probe.status_code}). استخدم تسجيل OAuth إذا كان مطلوبًا.")
        connections.save_token(identifier, {"access_token": access})
        connections.write_codex_config()
        return {"connected": True}

    @app.post("/v1/connections/{identifier}/oauth", dependencies=authorized)
    async def oauth(identifier: str):
        return await connections.start_oauth(identifier)

    @app.get("/oauth/callback")
    async def oauth_callback(state: str, code: str):
        await connections.finish_oauth(state, code)
        connections.write_codex_config()
        return HTMLResponse('<html dir="rtl" lang="ar"><meta charset="utf-8"><h2>تم ربط الحساب بـ Zeus</h2><p>يمكنك العودة إلى التطبيق وتحديث الإضافات.</p></html>')

    @app.api_route("/mcp/{identifier}", methods=["GET", "POST", "DELETE"])
    async def mcp(identifier: str, request: Request):
        bearer = request.headers.get("authorization", "").removeprefix("Bearer ")
        if not (secrets.compare_digest(bearer, token) or secrets.compare_digest(bearer, connections.proxy_token(identifier))):
            raise HTTPException(401, "MCP authorization required")
        provider = connections.definition(identifier)
        upstream = await connections.token(identifier)
        headers = {key: value for key, value in request.headers.items() if key.lower() in {"accept", "content-type", "mcp-session-id", "mcp-protocol-version", "last-event-id"}}
        headers["Authorization"] = "Bearer " + upstream
        if identifier == "github":
            headers["X-MCP-Toolsets"] = "repos,issues,pull_requests,actions"
        client = httpx.AsyncClient(timeout=httpx.Timeout(120, read=3600))
        try:
            outgoing = client.build_request(request.method, provider["mcp_url"], headers=headers, content=await request.body())
            response = await client.send(outgoing, stream=True)
        except BaseException:
            await client.aclose()
            raise
        async def body():
            try:
                async for chunk in response.aiter_bytes():
                    yield chunk
            finally:
                await response.aclose()
                await client.aclose()
        forwarded = {key: value for key, value in response.headers.items() if key.lower() in {"content-type", "mcp-session-id", "mcp-protocol-version"}}
        return StreamingResponse(body(), status_code=response.status_code, headers=forwarded)

    return app
