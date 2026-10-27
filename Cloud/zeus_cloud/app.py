"""Authenticated personal runtime. Health reads do not open Atlas connections."""
import asyncio
from contextlib import asynccontextmanager
import hashlib
import json
import os
from pathlib import Path
import time
from urllib.parse import urlsplit
import uuid
import httpx
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, ConfigDict, Field, SecretStr
from .database import MongoStore
from .postgres import PostgresGatewayStore
from .engine import Engine, Vault, TERMINAL
from .files import FilesGateway, Workspaces, WORKSPACE_LIMIT, GLOBAL_WORKSPACE, WorkspaceConflict
from .providers import Models, provider_url, normalize_history
from .terminal import Terminals

PROJECT = "https://pdfzdcwkkgapcwsnezvn.supabase.co"
PUBLISHABLE = "sb_publishable_ByPkZ3pyYzYJBY9QZz6aXg_YYqMe1Lu"


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid", hide_input_in_errors=True)


class ProviderInput(Input):
    kind: str = Field(pattern="^(openai|responses|anthropic)$")
    base_url: str = Field(max_length=2000)
    model: str = Field(min_length=1, max_length=200)
    api_key: SecretStr
    image_input: bool = True
    max_tokens: int = Field(default=4096, ge=256, le=8192)


class RunInput(Input):
    id: uuid.UUID
    conversation: uuid.UUID
    prompt: str = Field(min_length=1, max_length=100_000)
    history: list[dict] = Field(default_factory=list, max_length=200)
    provider_id: str = Field(default="default", max_length=100)
    provider: ProviderInput | None = None
    file_grant: SecretStr
    permission_mode: str = Field(default="consequential", pattern="^(ask_all|consequential|unrestricted)$")
    max_seconds: int = Field(default=7200, ge=30, le=7200)
    native_user_id: uuid.UUID | None = None
    native_assistant_id: uuid.UUID | None = None
    native_session: dict | None = None
    tools: list[dict] | None = Field(default=None, max_length=256)
    instructions: str = Field(default="", max_length=120000)


class ApprovalInput(Input):
    allowed: bool


class ImportInput(Input):
    title: str = Field(default="", max_length=500)
    native_session: dict | None = None
    history: list[dict] = Field(default_factory=list, max_length=1000)
    files: list[dict] = Field(default_factory=list, max_length=4096)
    file_key: SecretStr
    file_grant: SecretStr
    lease_id: uuid.UUID | None = None
    expected_workspace_hash: str | None = Field(default=None, pattern="^[a-f0-9]{64}$")
    replace_existing: bool = False


class TerminalInput(Input):
    conversation: uuid.UUID
    file_grant: SecretStr


class TerminalWrite(Input):
    chars: str = Field(default="", max_length=8192)
    columns: int = Field(default=100, ge=20, le=300)
    rows: int = Field(default=28, ge=10, le=200)


class Authorizer:
    def __init__(self, owner, email=""): self.owner, self.email, self.cache = owner, email.lower(), {}
    async def __call__(self, authorization: str = Header(default="")):
        if not self.owner and not self.email: raise HTTPException(503, "لم يربط مالك الخادم بعد؛ بيانات حسابك ومزامنة المتصفح مستقلة.")
        token = authorization.removeprefix("Bearer ")
        if len(token) < 30 or len(token) > 20_000: raise HTTPException(401, "يلزم تسجيل الدخول.")
        key = hashlib.sha256(token.encode()).hexdigest()
        saved = self.cache.get(key)
        if saved and saved[1] > time.time(): return saved[0]
        async with httpx.AsyncClient(timeout=15, follow_redirects=False) as client:
            response = await client.get(PROJECT + "/auth/v1/user", headers={"apikey": PUBLISHABLE, "Authorization": "Bearer " + token})
        if response.status_code != 200: raise HTTPException(401, "انتهت جلسة الحساب؛ أعد تسجيل الدخول.")
        user = response.json()
        allowed = user.get("id") == self.owner if self.owner else str(user.get("email", "")).lower() == self.email
        if not allowed or not user.get("email_confirmed_at"): raise HTTPException(403, "هذا الحساب لا يملك خدمة التنفيذ.")
        if len(self.cache) >= 64: self.cache.clear()
        self.cache[key] = (user["id"], time.time() + 30)
        return user["id"]


def public_run(run):
    if run is None: raise HTTPException(404, "المهمة غير موجودة.")
    return {key: run[key] for key in ["id", "conversation", "status", "seq", "created", "updated", "checkpoint", "error", "pending_approval", "native_user_id", "native_assistant_id", "pending_device"] if key in run}


class BodyLimit:
    def __init__(self, app): self.app = app
    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope["method"] not in {"POST", "PUT", "PATCH"}:
            return await self.app(scope, receive, send)
        frames, total = [], 0
        while True:
            frame = await receive()
            if frame["type"] == "http.disconnect": return
            total += len(frame.get("body", b""))
            if total > 2 * 1024 * 1024:
                await JSONResponse({"detail": "الطلب أكبر من الحد."}, 413)(scope, receive, send); return
            frames.append(frame)
            if not frame.get("more_body"): break
        async def replay(): return frames.pop(0) if frames else await receive()
        await self.app(scope, replay, send)


def create_app(store=None, owner=None, key=None, auth=None, work_root=None, models=None, gateway=None, child_uid=10001):
    owner = owner or os.environ.get("ZEUS_OWNER_ID", "")
    owner_email = os.environ.get("ZEUS_OWNER_EMAIL", "")
    key = key or os.environ.get("ZEUS_DATA_KEY", "")
    if store is None:
        store = MongoStore(os.environ["MONGODB_URI"]) if os.environ.get("MONGODB_URI") else PostgresGatewayStore(
            PROJECT + "/functions/v1/zeus-files", os.environ.get("ZEUS_STORAGE_TOKEN", ""))
    vault = Vault(key) if key else None
    gateway = gateway or FilesGateway(PROJECT + "/functions/v1/zeus-files")
    spaces = Workspaces(work_root or os.environ.get("ZEUS_WORK_ROOT", "/tmp/zeus-work"), gateway, store, vault)
    models = models or Models()
    auth = auth or Authorizer(owner, owner_email)

    terminal_grants = {}
    async def terminal_event(terminal, kind, value):
        # Terminal replay is bounded in memory. Agent output and command
        # results are committed through run events, not an unbounded PTY log.
        if kind == "exit" and terminal.id in terminal_grants:
            grant = terminal_grants.pop(terminal.id)
            try:
                await spaces.checkpoint(terminal.owner, terminal.conversation, grant)
                if spaces.path(terminal.owner, GLOBAL_WORKSPACE).is_dir(): await spaces.checkpoint(terminal.owner, GLOBAL_WORKSPACE, grant)
            finally: engine.wakeup.set()
    terminals = Terminals(terminal_event)
    engine = Engine(store, spaces, models, terminals, vault, child_uid) if vault else None

    @asynccontextmanager
    async def lifespan(app):
        app.state.ready = False; app.state.problem = None
        worker = None
        if vault and (owner or owner_email):
            try:
                await store.initialize(); await store.recover()
                app.state.ready = True
                worker = asyncio.create_task(engine.loop()); engine.wakeup.set()
            except Exception:
                app.state.problem = "تعذر الاتصال بالتخزين السحابي. لم يبدأ تنفيذ أي مهمة."
                await store.close()
        try: yield
        finally:
            if engine: await engine.shutdown()
            if worker: worker.cancel(); await asyncio.gather(worker, return_exceptions=True)
            await store.close(); await gateway.close(); await models.close()

    app = FastAPI(title="ZEUS Cloud", version="4.0.0", lifespan=lifespan, docs_url=None, redoc_url=None)
    app.add_middleware(BodyLimit)
    app.state.store, app.state.engine = store, engine
    app.state.ready = False; app.state.problem = None

    @app.exception_handler(RequestValidationError)
    async def invalid_request(_, error):
        # Pydantic's input field can contain credentials; never echo it.
        return JSONResponse({"detail": "قيم الطلب غير صالحة."}, 422)
    @app.exception_handler(KeyError)
    async def missing(_, error): return JSONResponse({"detail": "العنصر غير موجود."}, 404)
    @app.exception_handler(ValueError)
    async def invalid(_, error): return JSONResponse({"detail": str(error)[:1000]}, 400)
    @app.exception_handler(WorkspaceConflict)
    async def workspace_conflict(_, error): return JSONResponse({"detail": str(error)}, 409)

    def ready():
        if not app.state.ready or engine is None: raise HTTPException(503, app.state.problem or "إعداد اتصال الخادم غير مكتمل.")

    @app.get("/health")
    async def health(): return {"service": "zeus-cloud", "version": "4.0.0", "ready": app.state.ready, "browser": False}

    @app.get("/v1/capabilities")
    async def capabilities(account=Depends(auth)):
        return {"ready": app.state.ready, "reason": app.state.problem,
            "cloud_agent": True, "terminal": True, "browser": False, "xcode": False,
            "max_parallel_runs": 1, "workspace_bytes": WORKSPACE_LIMIT,
            "provider_protocols": ["openai", "responses", "anthropic"], "canonical_tools": True, "device_tool_bridge": True, "owner_configured": bool(owner or owner_email),
            "browser_notice": "الخادم بلا متصفح. أخبر المستخدم مبكرًا إن احتاجت المهمة تفاعلًا مع صفحة أو جلسة جهازه."}

    @app.get("/v1/account/state")
    async def account_state(account=Depends(auth)):
        ready(); value = await store.account_state(account)
        return {**value, "terminal_active": any(t.owner == account and terminals.active(account, t.id) for t in terminals.sessions.values())}

    @app.post("/v1/transitions/{identifier}/{operation}")
    async def transition(identifier: uuid.UUID, operation: str, account=Depends(auth)):
        ready()
        if operation not in {"begin", "renew", "end"}: raise HTTPException(404, "عملية غير متاحة.")
        if operation == "renew":
            try: return await store.transition(account, str(identifier), operation)
            except httpx.HTTPStatusError as error:
                if error.response.status_code == 409: raise HTTPException(409, "انتهت مهلة نقل الحساب؛ بقيت الأصول محفوظة. أعد المحاولة.") from None
                raise
        async with engine.execution_gate:
            if operation == "begin" and any(t.owner == account and terminals.active(account, t.id) for t in terminals.sessions.values()):
                raise HTTPException(409, "أغلق الطرفية السحابية واحفظ ملفاتها قبل تغيير مكان التنفيذ.")
            try: return await store.transition(account, str(identifier), operation)
            except httpx.HTTPStatusError as error:
                if error.response.status_code == 409: raise HTTPException(409, "أكمل المهام السحابية أو أوقفها قبل تغيير مكان التنفيذ، ثم أعد المحاولة.") from None
                raise

    @app.put("/v1/providers/{identifier}")
    async def configure_provider(identifier: str, value: ProviderInput, account=Depends(auth)):
        ready()
        if not identifier or len(identifier) > 100: raise ValueError("معرف المزود غير صالح.")
        provider_url(value.base_url)
        if not 8 <= len(value.api_key.get_secret_value()) <= 20_000: raise ValueError("مفتاح المزود غير صالح.")
        data = {**value.model_dump(exclude={"api_key"}), "api_key": value.api_key.get_secret_value()}
        await store.put(account, "provider", identifier, {"encrypted": vault.seal(account, data),
                                                        "model": value.model, "protocol": value.kind})
        return {"configured": True, "model": value.model, "protocol": value.kind}

    @app.post("/v1/runs")
    async def submit(value: RunInput, account=Depends(auth)):
        ready()
        conversation, identifier = str(value.conversation), str(value.id)
        if value.native_session and (str(value.native_session.get("id", "")).lower() != conversation or len(json.dumps(value.native_session)) > 16_000):
            raise ValueError("بيانات المحادثة الأصلية غير صالحة.")
        existing = await store.run(account, identifier)
        fingerprint = hashlib.sha256(json.dumps(value.model_dump(mode="json", exclude={"file_grant"}), sort_keys=True).encode()).hexdigest()
        if existing:
            if existing.get("fingerprint") != fingerprint: raise HTTPException(409, "معرف الطلب مستخدم لمهمة أخرى.")
            if existing.get("status") == "queued": engine.wakeup.set()
            return public_run(existing)
        if value.provider:
            provider_url(value.provider.base_url)
            definition = {**value.provider.model_dump(exclude={"api_key"}), "api_key": value.provider.api_key.get_secret_value()}
            if not 8 <= len(definition["api_key"]) <= 20_000: raise ValueError("مفتاح المزود غير صالح.")
            provider = {"encrypted": vault.seal(account, definition)}
        else: provider = await store.get(account, "provider", value.provider_id)
        if provider is None: raise ValueError("اربط مزود النموذج في إعدادات السحابة أولًا.")
        grant = value.file_grant.get_secret_value()
        checked = await gateway.check(grant)
        if checked.get("user_id") != account or checked.get("conversation_id") != conversation: raise HTTPException(403, "تصريح الملفات لا ينتمي لهذه المحادثة والحساب.")
        for message in value.history:
            if message.get("role") not in {"user", "assistant", "tool"}: raise ValueError("سجل محادثة غير صالح.")
        async with engine.execution_gate:
            if (await store.account_state(account)).get("lease"):
                raise HTTPException(409, "نقل الحساب جارٍ. انتظر اكتماله قبل إرسال مهمة سحابية.")
            if value.provider: await store.put(account, "provider", value.provider_id, provider)
            run = await store.create_run(account, {"id": identifier, "conversation": conversation, "prompt": value.prompt,
                "history": normalize_history(value.history), "provider": provider["encrypted"], "grant": vault.seal(account, grant),
                "permission_mode": value.permission_mode, "max_seconds": value.max_seconds,
                "native_user_id": str(value.native_user_id).upper() if value.native_user_id else None,
                "native_assistant_id": str(value.native_assistant_id).upper() if value.native_assistant_id else None,
                "native_session": value.native_session, "tools": value.tools, "instructions": value.instructions,
                "fingerprint": fingerprint, "status": "queued", "created": time.time()})
            if run.get("fingerprint") != fingerprint: raise HTTPException(409, "معرف الطلب مستخدم لمهمة أخرى.")
            record = await store.get(account, "conversation", conversation) or {"messages": normalize_history(value.history), "title": value.prompt[:120]}
            if value.native_session:
                record["native_session"] = value.native_session
            await store.put(account, "conversation", conversation, {**record, "latest_run": identifier, "latest_created": run["created"]})
            engine.wakeup.set()
        return public_run(run)

    @app.get("/v1/runs/{identifier}")
    async def run(identifier: uuid.UUID, account=Depends(auth)):
        ready(); return public_run(await store.run(account, str(identifier)))

    @app.get("/v1/runs/{identifier}/events")
    async def events(identifier: uuid.UUID, after: int = 0, authorization: str = Header(default=""), account=Depends(auth)):
        ready(); current = public_run(await store.run(account, str(identifier)))
        items = await engine.history.events(account, str(identifier), after, authorization.removeprefix("Bearer "))
        return {"run": current, "events": items, "cursor": items[-1]["seq"] if items else after}

    @app.get("/v1/runs/{identifier}/stream")
    async def stream(identifier: uuid.UUID, request: Request, after: int = 0, authorization: str = Header(default=""), account=Depends(auth)):
        ready(); public_run(await store.run(account, str(identifier)))
        async def lines():
            nonlocal after
            while not await request.is_disconnected():
                items = await engine.history.events(account, str(identifier), after, authorization.removeprefix("Bearer "))
                for item in items:
                    after = item["seq"]
                    yield "id: " + str(after) + "\ndata: " + json.dumps(item, ensure_ascii=False) + "\n\n"
                current = await store.run(account, str(identifier))
                if not items and (current or {}).get("status") in TERMINAL: break
                await asyncio.sleep(1)
        return StreamingResponse(lines(), media_type="text/event-stream", headers={"Cache-Control": "private, no-store"})

    @app.post("/v1/runs/{identifier}/cancel")
    async def cancel(identifier: uuid.UUID, account=Depends(auth)):
        ready(); current = await store.run(account, str(identifier)); public_run(current)
        if current["status"] in {"queued", "waiting_user"}: await store.update_run(account, str(identifier), status="cancelled")
        elif current["status"] not in TERMINAL:
            # Single owner and a single worker. Never cancel a different run.
            if engine.running and not engine.running.done() and engine.running.get_name() == str(identifier): engine.running.cancel()
        return public_run(await store.run(account, str(identifier)))

    @app.post("/v1/approvals/{identifier}")
    async def answer(identifier: uuid.UUID, value: ApprovalInput, account=Depends(auth)):
        ready(); key = str(identifier)
        approval = await store.get(account, "approval", key)
        if not approval or approval["status"] != "pending": raise HTTPException(409, "طلب الموافقة لم يعد نشطًا.")
        run = await store.run(account, approval["run"])
        if not run or run["status"] != "waiting_user" or run.get("pending_approval") != key:
            raise HTTPException(409, "طلب الموافقة لا يطابق حالة المهمة.")
        await store.put(account, "approval", key, {**approval, "status": "allowed" if value.allowed else "denied"})
        await store.update_run(account, run["id"], status="queued", resume_approval=key)
        engine.wakeup.set(); return {"accepted": True}

    @app.post("/v1/device-tools/{identifier}/{operation}")
    async def device_tool(identifier: uuid.UUID, operation: str, request: Request, account=Depends(auth)):
        ready(); key = str(identifier); body = await request.json()
        async with engine.execution_gate:
            record = await store.get(account, "approval", key)
            if not record or record.get("type") != "device": raise HTTPException(404, "طلب الأداة غير موجود.")
            run = await store.run(account, record["run"])
            if not run: raise HTTPException(409, "طلب الأداة لم يعد نشطًا.")
            claimant = str(uuid.UUID(body.get("claimant", "")))
            if operation == "result" and record["status"] == "completed" and record.get("claimant") == claimant:
                prior = record.get("result", {})
                if prior.get("output") == str(body.get("output", ""))[:32000] and prior.get("success") == (body.get("success") is True) and prior.get("image") == body.get("image"):
                    return {"accepted": True}
                raise HTTPException(409, "النتيجة محفوظة ولا يمكن استبدالها.")
            if run.get("pending_device") != key: raise HTTPException(409, "طلب الأداة لم يعد نشطًا.")
            if operation == "claim":
                if run["status"] != "waiting_user": raise HTTPException(409, "المهمة لا تنتظر تنفيذ هذه الأداة.")
                if record["status"] not in {"pending", "claimed"} or record.get("claimant", claimant) != claimant:
                    raise HTTPException(409, "الأداة محجوزة لجهاز آخر أو نُفذت بالفعل.")
                await store.put(account, "approval", key, {**record, "status": "claimed", "claimant": claimant})
                return {"call": record["call"]}
            if operation != "result": raise HTTPException(404, "عملية غير متاحة.")
            if record.get("claimant") != claimant: raise HTTPException(409, "الجهاز لا يملك تنفيذ هذا الطلب.")
            result = {"output": str(body.get("output", ""))[:32000], "success": body.get("success") is True}
            image = body.get("image")
            if image:
                import base64
                if not isinstance(image, dict) or image.get("mime") not in {"image/jpeg", "image/png", "image/webp"} or len(base64.b64decode(image.get("data", ""), validate=True))>900000:
                    raise ValueError("Invalid device tool image")
                result["image"] = image
            if record["status"] == "completed":
                if record.get("result") != result: raise HTTPException(409, "النتيجة محفوظة ولا يمكن استبدالها.")
                return {"accepted": True}
            if run["status"] != "waiting_user" or record["status"] != "claimed": raise HTTPException(409, "حالة المهمة تغيرت.")
            await store.put(account, "approval", key, {**record, "status": "completed", "result": result})
            await store.update_run(account, run["id"], status="queued", resume_device=key)
            engine.wakeup.set(); return {"accepted": True}

    @app.get("/v1/conversations")
    async def conversations(after: str = "", account=Depends(auth)):
        ready()
        if after: after = str(uuid.UUID(after))
        records = await store.list_conversations(account, after)
        return {"conversations": [{"id": r["id"], "title": r.get("title", ""), "updated": r["updated"], "native_session": r.get("native_session")} for r in records], "next_cursor": records[-1]["id"] if len(records) == 100 else None}

    @app.get("/v1/conversations/{identifier}/files")
    async def files(identifier: uuid.UUID, account=Depends(auth)):
        ready(); record = await store.get(account, "workspace", str(identifier))
        return {"files": (record or {}).get("files", []), "version": (record or {}).get("version", 0), "workspace_hash": spaces.fingerprint(record)}

    @app.get("/v1/conversations/{identifier}")
    async def conversation(identifier: uuid.UUID, account=Depends(auth)):
        ready(); record = await store.get(account, "conversation", str(identifier))
        if not record: raise HTTPException(404, "المحادثة غير موجودة.")
        return {"id": str(identifier), "messages": record.get("messages", [])[-100:], "latest_run": record.get("latest_run")}

    @app.get("/v1/conversations/{identifier}/runs")
    async def conversation_runs(identifier: uuid.UUID, before: float = 4102444800, account=Depends(auth)):
        ready(); rows = await store.list_runs(account, str(identifier), before)
        return {"runs": [{**public_run(r), "prompt": r["prompt"], "native_user_id": r.get("native_user_id"), "native_assistant_id": r.get("native_assistant_id")} for r in rows],
                "before": min((r["created"] for r in rows), default=None)}

    @app.put("/v1/conversations/{identifier}/import")
    async def import_conversation(identifier: uuid.UUID, value: ImportInput, account=Depends(auth)):
        ready(); key = str(identifier)
        checked = await gateway.check(value.file_grant.get_secret_value())
        if checked.get("user_id") != account or checked.get("conversation_id") != key: raise HTTPException(403, "تصريح الملفات لا يطابق المحادثة.")
        async with engine.execution_gate:
            if engine.running and not engine.running.done() or any(terminals.active(account, t.id) for t in terminals.sessions.values() if t.owner == account):
                raise HTTPException(409, "أوقف المهمة والطرفية قبل نقل ملفات المحادثة.")
            lease = (await store.account_state(account)).get("lease")
            if lease and lease["id"] != str(value.lease_id): raise HTTPException(409, "عملية نقل أخرى قيد التنفيذ.")
            if value.replace_existing and not lease: raise HTTPException(409, "يلزم بدء انتقال موثق قبل استبدال نسخة الملفات.")
            await spaces.import_files(account, key, value.files, value.file_key.get_secret_value(), value.file_grant.get_secret_value(), value.expected_workspace_hash, value.replace_existing)
        existing = await store.get(account, "conversation", key)
        if existing is None:
            for message in value.history:
                if message.get("role") not in {"user", "assistant", "tool"}: raise ValueError("سجل محادثة غير صالح.")
            await store.put(account, "conversation", key, {"title": value.title, "messages": normalize_history(value.history), "native_session": value.native_session})
        elif value.native_session and not existing.get("native_session"):
            await store.put(account, "conversation", key, {**existing, "native_session": value.native_session})
        return {"imported": True, "files": len(value.files)}

    @app.post("/v1/conversations/{identifier}/file")
    async def file_content(identifier: uuid.UUID, request: Request, account=Depends(auth)):
        ready(); args = await request.json()
        grant = str(args.get("file_grant", "")); checked = await gateway.check(grant)
        if checked.get("user_id") != account or checked.get("conversation_id") != str(identifier): raise HTTPException(403, "تصريح الملفات لا يطابق المحادثة.")
        data = await spaces.read_cloud_file(account, str(identifier), str(args.get("path", "")), grant, max(0, int(args.get("offset", 0))))
        from fastapi.responses import Response
        return Response(data, media_type="application/octet-stream")

    @app.post("/v1/terminals")
    async def open_terminal(value: TerminalInput, account=Depends(auth)):
        ready()
        conversation = str(value.conversation); grant = value.file_grant.get_secret_value()
        checked = await gateway.check(grant)
        if checked.get("user_id") != account or checked.get("conversation_id") != conversation: raise HTTPException(403, "تصريح الملفات لا يطابق المحادثة.")
        async with engine.execution_gate:
            if (await store.account_state(account)).get("lease"): raise HTTPException(409, "نقل الحساب جارٍ. انتظر اكتماله قبل فتح الطرفية.")
            if engine.running and not engine.running.done(): raise HTTPException(409, "الوكيل يستخدم خانة التنفيذ. انتظر انتهاء مهمته أو أوقفها.")
            root = await spaces.restore(account, conversation, grant); engine.own(root)
            global_root = await spaces.restore(account, GLOBAL_WORKSPACE, grant)
            for folder in ["shared", "skills", "memory"]: (global_root / folder).mkdir(exist_ok=True)
            engine.own(global_root)
            engine.aliases(account, root)
            terminal = await terminals.start(account, conversation, root, uid=child_uid, seconds=900, global_root=global_root)
            terminal_grants[terminal.id] = grant
        return terminals.read(account, terminal.id)

    @app.get("/v1/terminals/{identifier}")
    async def read_terminal(identifier: uuid.UUID, offset: int = 0, account=Depends(auth)):
        ready(); return terminals.read(account, str(identifier), max(0, offset))

    @app.post("/v1/terminals/{identifier}/input")
    async def write_terminal(identifier: uuid.UUID, value: TerminalWrite, account=Depends(auth)):
        ready(); key = str(identifier)
        terminals.resize(account, key, value.columns, value.rows)
        if value.chars: terminals.input(account, key, value.chars)
        return {"accepted": True}

    @app.post("/v1/terminals/{identifier}/close")
    async def close_terminal(identifier: uuid.UUID, account=Depends(auth)):
        ready(); await terminals.stop(account, str(identifier)); return {"closed": True}

    return app
