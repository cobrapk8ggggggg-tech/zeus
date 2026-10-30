"""Runs only on the separate Android node. No Docker socket is mounted here."""
import asyncio
import base64
from contextlib import asynccontextmanager
import hashlib
import hmac
import json
import os
from pathlib import Path
import time
import zlib
from uuid import UUID
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse, Response, StreamingResponse
from pydantic import BaseModel, ConfigDict, Field
from .tokens import decode
from .device import Device
from .state import State
from .projects import Projects
from .video import Video
from .lifecycle import Lifecycle
from .ice import servers as ice_servers
from . import audit, reports
from .diagnostics import Diagnostics


class Call(BaseModel):
    model_config = ConfigDict(extra="forbid", hide_input_in_errors=True)
    name: str = Field(pattern="^android_(device|ui|screenshot|network|project)$")
    arguments: dict = Field(default_factory=dict)
    request_id: str = Field(min_length=1, max_length=180, pattern=r"^[a-zA-Z0-9_.:-]+$")


def create_app(root=None, key=None, owner=None, device=None, clock=time.time):
    signing_key = key or os.environ.get("ZEUS_ANDROID_SIGNING_KEY", "")
    allowed_owner = owner or os.environ.get("ZEUS_ANDROID_OWNER_ID", "")
    if len(signing_key) < 32 or not allowed_owner: raise ValueError("Configure an owner and a laboratory signing key")
    state = State(root or os.environ.get("ZEUS_ANDROID_DATA", "/data"), clock)
    projects = Projects(state.root / "projects")
    device = device or Device(os.environ.get("ZEUS_ANDROID_ADB", "android:5555"))
    video = Video(device); gate = asyncio.Lock(); lifecycle = Lifecycle(); observers = set()
    diagnostics=Diagnostics(projects,device,state.record)
    active_agent={}

    def notify():
        for observer in observers: observer.set()

    def summary(event):
        return {k:v for k,v in event.items() if k in {'id', 'flow_id', 'sequence', 'phase', 'started', 'observed', 'method', 'url', 'status', 'direction', 'message_type', 'error','sni','duration_ms','interpretation','observer_dropped_total','observer_delivery_failures_total'}}

    def network(scope, operation, args, role):
        events = state.events(scope, max(0, int(args.get('after', 0))), 1 if operation == 'read' else 5)
        if operation == 'list': events = [summary(event) for event in events]
        else:
            for event in events:
                for field,header in [('request_body','request_headers'),('response_body','response_headers')]:
                    part=event.get(field)
                    if not part or not part.get('base64'):continue
                    try:
                        raw=base64.b64decode(part['base64'],validate=True)
                        encoding=next((v for k,v in event.get(header,{}).items() if k.lower()=='content-encoding'),'')
                        if encoding=='gzip':raw=zlib.decompressobj(16+zlib.MAX_WBITS).decompress(raw,32768)
                        elif encoding=='deflate':raw=zlib.decompressobj().decompress(raw,32768)
                        elif encoding not in ('','identity'):part['preview_unavailable']='Unsupported content encoding';continue
                        part['text_preview']=raw[:(2048 if role=='agent' else 32768)].decode('utf-8',errors='replace')
                        part['preview_limit_bytes']=2048 if role=='agent' else 32768
                    except (ValueError,zlib.error):part['preview_unavailable']='Incomplete or invalid encoded body'
        if operation!='list' and role == 'agent':
            # Keep structured model results below the cloud tool output limit.
            for event in events:
                for field in ('request_body', 'response_body'):
                    if field in event and len(event[field].get('base64', '')) > 4096:
                        event[field] = {**event[field], 'base64':event[field]['base64'][:4096], 'truncated':True}
                for field in ('request_headers', 'response_headers'):
                    if field in event: event[field] = dict(list(event[field].items())[:12])
        return {'events':events}
    initial = state.load()
    if initial and initial["status"] == "running": initial.update(status="interrupted", capture=False); state.save(initial)

    async def stop(value, reason):
        await diagnostics.stop(value['scope'])
        await video.close()
        try:
            await device.command("shell", "settings", "put", "global", "http_proxy", ":0")
            await device.command("shell", "input", "keyevent", "223")
        except (ValueError, OSError, asyncio.TimeoutError): pass
        try: await lifecycle.action("stop")
        except ValueError:
            value.update(status="stop_failed", capture=False, reason="تعذر تأكيد إيقاف Android؛ أعد محاولة الإيقاف."); state.save(value); raise
        value.update(status="stopped", capture=False, reason=reason); state.save(value); notify()

    async def sweep():
        while True:
            await asyncio.sleep(10)
            async with gate:
                value = state.load()
                if value and value["status"] == "running" and (clock() >= value["deadline"] or clock()-value["activity"] >= 300 and not projects.tasks):
                    try: await stop(value, "time_limit" if clock() >= value["deadline"] else "idle")
                    except ValueError: pass
                elif value and value["status"] == "stop_failed":
                    try: await stop(value, "retry_stop")
                    except ValueError: pass

    @asynccontextmanager
    async def lifespan(app):
        interrupted=state.load()
        if interrupted and interrupted["status"]=="interrupted":
            try: await stop(interrupted,"worker_restart")
            except ValueError: pass  # stop_failed is retried by the independent sweep.
        worker = asyncio.create_task(sweep())
        try: yield
        finally:
            worker.cancel(); await asyncio.gather(worker, return_exceptions=True)
            await diagnostics.close();await projects.close(); await video.close(); state.close()

    app = FastAPI(title="ZEUS Android Laboratory", lifespan=lifespan, docs_url=None, redoc_url=None)
    app.state.lab, app.state.device = state, device

    @app.middleware("http")
    async def headers(request, call_next):
        # APK uploads are streamed and bounded in Projects; JSON is much smaller.
        limit = 256*1024**2 if request.url.path == "/v1/upload" else 200000
        try: length = int(request.headers.get("content-length", "0"))
        except ValueError: return JSONResponse({"detail":"Invalid length"}, 400)
        if length > limit: return JSONResponse({"detail":"Request too large"}, 413)
        if request.method == "POST" and request.url.path != "/v1/upload":
            chunks, total = [], 0
            async for chunk in request.stream():
                total += len(chunk)
                if total > limit: return JSONResponse({"detail":"Request too large"}, 413)
                chunks.append(chunk)
            request._body = b"".join(chunks)
        response = await call_next(request)
        cache = response.headers.get('Cache-Control', 'no-store')
        response.headers.update({"Cache-Control":cache, "Referrer-Policy":"no-referrer", "X-Content-Type-Options":"nosniff",
            "Content-Security-Policy":"default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; media-src 'self' blob:; img-src 'self' blob: data:; frame-ancestors 'none'; base-uri 'none'"})
        return response

    async def claims(authorization: str = Header(default="")):
        try: value = decode(signing_key, authorization.removeprefix("Bearer "), clock())
        except ValueError: raise HTTPException(401, "انتهت صلاحية المختبر؛ أغلقه وافتحه مجددًا.") from None
        if value["sub"] != allowed_owner: raise HTTPException(403, "Laboratory belongs to another account")
        return value

    @app.exception_handler(ValueError)
    async def invalid(_, error): return JSONResponse({"detail":str(error)[:1000]}, 400)
    @app.exception_handler(KeyError)
    async def missing(_, error): return JSONResponse({"detail":"العنصر غير موجود في هذه المحادثة."}, 404)
    @app.exception_handler(RequestValidationError)
    async def bad_input(_, error): return JSONResponse({"detail":"قيم الطلب غير صالحة."}, 422)

    @app.get("/health")
    async def health(): return {"service":"zeus-android", "billing_note":"Stopping a session does not stop the host VM"}

    @app.get("/lab/")
    async def page(): return FileResponse(Path(__file__).parent / "web/index.html")
    @app.get("/lab/{name}")
    async def asset(name: str):
        if name not in {"lab.js", "lab.css"}: raise HTTPException(404)
        return FileResponse(Path(__file__).parent / "web" / name)

    @app.get("/v1/session")
    async def session(value=Depends(claims)):
        saved = state.load()
        if not saved or saved["scope"] != state.scope(value): return {"status":"stopped", "controller":"human", "capture":False}
        return {k:v for k,v in saved.items() if k not in {"scope", "owner"}}

    @app.get('/v1/network/feed')
    async def network_feed(request: Request, after: int = 0, value=Depends(claims)):
        if value['role'] != 'viewer': raise HTTPException(403)
        if len(observers) >= 2: raise HTTPException(429, 'Too many network viewers')
        observer = asyncio.Event(); observers.add(observer)
        async def events():
            cursor = max(0, after); scope = state.scope(value)
            try:
                while clock() < value['exp']:
                    observer.clear()
                    batch = state.events(scope, cursor)
                    if batch:
                        for event in batch:
                            cursor = event['id']
                            yield 'id: '+str(cursor)+'\ndata: '+json.dumps(summary(event), ensure_ascii=False)+'\n\n'
                        continue
                    saved = state.load()
                    if not saved or saved['scope'] != scope or saved['status'] != 'running' or not saved['capture']: break
                    try: await asyncio.wait_for(observer.wait(), min(15, max(.01, value['exp']-clock())))
                    except asyncio.TimeoutError: yield ': heartbeat\n\n'
                    if await request.is_disconnected(): break
            finally: observers.discard(observer)
        return StreamingResponse(events(), media_type='text/event-stream', headers={'X-Accel-Buffering':'no', 'Cache-Control':'no-store, no-transform'})

    async def execute_tool(call: Call, value):
        async with gate:
            args = call.arguments; operation = args.get("operation", "status"); scope = state.scope(value)
            if len(json.dumps(args)) > 120000: raise ValueError("Arguments too large")
            read_only = call.name == "android_screenshot" or call.name == "android_device" and operation in {"status","timeline","capabilities","logs","records"} or call.name == "android_ui" and operation == "tree" or call.name == "android_network" and operation in {"list", "read","coverage"} or call.name == "android_project" and operation in {"list", "job", "files", "read","report","search","compare"}
            digest = hashlib.sha256(json.dumps([call.name, args], sort_keys=True).encode()).hexdigest()
            if not read_only:
                prior = state.db.execute("SELECT digest,value FROM operations WHERE scope=? AND id=?", (scope, call.request_id)).fetchone()
                if prior:
                    if prior[0] != digest: raise ValueError("An operation id cannot be reused with different arguments")
                    result = json.loads(prior[1])
                    if result.get("uncertain"): raise ValueError("Previous action was interrupted; inspect the device before retrying with a new id")
                    return result
            saved = state.load()
            if call.name == "android_device" and operation == "status": return await session(value)
            if call.name=='android_project' and operation=='approve_changes':
                if value['role']!='viewer':raise HTTPException(403,'Only the user can approve test APK modifications')
                project=args.get('project','');projects.project(scope,project)
                consent=state.consent(scope,project,'modify',{'operations':['write','build','install_rebuilt']})
                state.record(scope,'modification_approved',{'actor':'viewer','project':project,'expires':consent['expires']})
                result={'approved':True,'expires':consent['expires'],'project':project}
                state.db.execute('INSERT INTO operations VALUES(?,?,?,?)',(scope,call.request_id,digest,json.dumps(result)));state.db.commit()
                return result
            sensitive=call.name=='android_project' and (operation in {'write','build'} or operation=='install' and args.get('variant')=='rebuilt')
            if sensitive and value['role']=='agent' and not state.consent(scope,args.get('project',''),'modify'):
                raise HTTPException(403,'تحتاج نسخة الاختبار موافقة صريحة لهذا المشروع؛ اطلب موافقة المستخدم أولًا.')
            if call.name=='android_device' and operation=='timeline':return {'events':state.history(scope,int(args.get('after',0))),'coverage':state.coverage(scope)}
            if call.name=='android_device' and operation=='capabilities':
                saved=state.load();runtime=await diagnostics.capabilities() if saved and saved['scope']==scope and saved['status']=='running' else {'status':'not_running','requires_device_for_probe':True}
                return {'live_video':'webrtc','runtime':runtime,'audit_formats':['json','html','pdf'],'static_analysis':['jadx','apktool','apksigner'],'host_billing':'Host VM billing does not stop when Android stops.'}
            if call.name=='android_device' and operation=='records':return diagnostics.records(scope,args.get('project',''))
            if call.name=='android_network' and operation=='coverage':return {'counters':state.coverage(scope),'body_limit_bytes':32768,'event_retention_limit':1000,'guarantee':'best_effort','limits':['TLS pinning, non-proxy traffic and dropped events may be missing.','Timing correlation does not prove an action caused a request.']}
            if call.name == "android_project" and operation in {"list", "job", "files", "read"}:
                return await projects.operation(scope, operation, args, device)
            if call.name == 'android_network' and operation in {'list', 'read'}:
                return network(scope, operation, args, value['role'])
            if call.name=='android_project' and operation!='install':
                # Static analysis never boots or requires an Android device.
                if not read_only:
                    state.db.execute('INSERT INTO operations VALUES(?,?,?,?)',(scope,call.request_id,digest,'{"uncertain":true}'));state.db.commit()
                result=await projects.operation(scope,operation,args,device)
                if not read_only:
                    state.db.execute('UPDATE operations SET value=? WHERE scope=? AND id=?',(json.dumps(result),scope,call.request_id));state.db.commit()
                return result
            if call.name == "android_device" and operation == "start":
                if value["role"] != "viewer": raise ValueError("Open the laboratory and start Android explicitly before using agent tools")
                if saved and saved["scope"] != scope and saved["status"] == "running": raise ValueError("Another conversation is using the Android device")
                if saved and saved["scope"] == scope and saved["status"] == "running": return await session(value)
            else:
                saved = state.owned(value,active=not (call.name == "android_device" and operation == "stop"))
                if clock() >= saved["deadline"]: await stop(saved, "time_limit"); raise ValueError("انتهت المدة المحددة للجلسة؛ افتح جلسة جديدة.")
                if not read_only and value["role"] == "agent" and (saved["controller"] != "agent" or clock() > saved["agent_until"]): raise ValueError("المستخدم يتحكم بالجهاز؛ سلّمه للوكيل من واجهة المختبر أولًا.")
                if not read_only and value["role"] == "viewer" and call.name != "android_device" and saved["controller"] != "human": raise ValueError("خذ التحكم من الوكيل أولًا")
            if not read_only:
                state.db.execute("INSERT INTO operations VALUES(?,?,?,?)", (scope, call.request_id, digest, '{"uncertain":true}')); state.db.commit()
            if call.name == "android_device":
                if operation == "start":
                    if saved and saved["scope"] != scope: await lifecycle.action("reset")
                    await lifecycle.action("start")
                    try: await device.connect()
                    except BaseException:
                        await lifecycle.action("stop"); raise
                    saved = {"scope":scope, "owner":value["sub"], "status":"running", "controller":"human", "agent_until":0,
                        "activity":clock(), "started":clock(), "deadline":clock()+1800, "capture":False}
                    # Another conversation cannot inherit an earlier capture.
                    await device.command("shell", "settings", "put", "global", "http_proxy", ":0")
                elif operation == "stop": await stop(saved, "user")
                elif operation=='logs':return await diagnostics.logs(args)
                elif operation=='record_start':
                    result=await diagnostics.start(scope,args)
                    state.db.execute('UPDATE operations SET value=? WHERE scope=? AND id=?',(json.dumps(result),scope,call.request_id));state.db.commit()
                    return result
                elif operation=='record_stop':
                    result=await diagnostics.stop(scope)
                    state.db.execute('UPDATE operations SET value=? WHERE scope=? AND id=?',(json.dumps(result),scope,call.request_id));state.db.commit()
                    return result
                elif operation in {"take", "release"}:
                    if value["role"] != "viewer": raise ValueError("Only the user can transfer device control")
                    saved.update(controller="human" if operation == "take" else "agent", agent_until=clock()+1800)
                else: raise ValueError("Unknown session operation")
                state.save(saved); result = await session(value)
            elif call.name == "android_ui": result = await device.action(operation, args)
            elif call.name == "android_screenshot": result = {"image":{"mime":"image/jpeg", "data":base64.b64encode(await device.screenshot()).decode()}, "output":"Current Android screenshot"}
            elif call.name == "android_project": result = await projects.operation(scope, operation, args, device)
            elif call.name == "android_network":
                if operation in {"start", "stop"}:
                    proxy = os.environ.get("ZEUS_ANDROID_PROXY", "capture:8080") if operation == "start" else ":0"
                    await device.command("shell", "settings", "put", "global", "http_proxy", proxy)
                    saved["capture"] = operation == "start"; state.save(saved); notify()
                    result = {"capturing":saved["capture"], "https":"Requires a trusted certificate; pinned or non-proxy traffic may be unavailable"}
                else: raise ValueError("Unknown capture operation")
            else: raise ValueError("Unknown Android tool")
            current = state.load()
            if current and current["scope"] == scope: current["activity"] = clock(); state.save(current)
            if not read_only:
                state.db.execute("UPDATE operations SET value=? WHERE scope=? AND id=?", (json.dumps(result), scope, call.request_id))
                state.db.execute("DELETE FROM operations WHERE rowid NOT IN (SELECT rowid FROM operations ORDER BY rowid DESC LIMIT 500)"); state.db.commit()
            return result

    @app.post('/v1/tool')
    async def tool(call: Call, value=Depends(claims)):
        scope=state.scope(value);operation=call.arguments.get('operation','status')
        observe=call.name=='android_screenshot' or operation in {'status','timeline','capabilities','tree','list','read','job','files','report','search','compare','coverage','logs','records'}
        details={'request_id':call.request_id,'actor':value['role'],'tool':call.name,'operation':operation}
        if not observe:
            parameters={k:v for k,v in call.arguments.items() if k in {'project','variant','package','x','y','x2','y2','key','path'}}
            if 'text' in call.arguments:parameters['text_characters']=len(str(call.arguments['text']))
            state.record(scope,'action_started',{**details,'parameters':parameters});notify()
        task=asyncio.current_task()
        if value['role']=='agent' and not observe:active_agent[task]=scope
        try:result=await execute_tool(call,value)
        except asyncio.CancelledError:
            if not observe:state.record(scope,'action_interrupted',{**details,'reason':'manual_takeover_or_request_cancellation','uncertain':True});notify()
            return JSONResponse({'detail':'تم إيقاف الإجراء؛ افحص الجهاز قبل تكراره.','uncertain':True},409)
        except BaseException as error:
            if not observe:state.record(scope,'action_failed',{**details,'error':str(error)[:1000]});notify()
            raise
        finally:active_agent.pop(task,None)
        if not observe:state.record(scope,'action_finished',details);notify()
        return result

    @app.post('/v1/control/take')
    async def take_control(value=Depends(claims)):
        if value['role']!='viewer':raise HTTPException(403)
        saved=state.owned(value,active=False);saved.update(controller='human',agent_until=0);state.save(saved)
        state.db.execute('DELETE FROM consents WHERE scope=?',(state.scope(value),));state.db.commit()
        # Do not wait behind a stalled ADB call holding the ordinary tool gate.
        for task,scope in list(active_agent.items()):
            if scope==state.scope(value):task.cancel()
        state.record(state.scope(value),'manual_takeover',{'actor':'viewer'});notify()
        return await session(value)

    @app.get('/v1/timeline')
    async def timeline(after:int=0,value=Depends(claims)):
        return {'events':state.history(state.scope(value),after),'coverage':state.coverage(state.scope(value))}

    @app.get('/v1/projects/{identifier}/export')
    async def report_export(identifier:str,format:str='json',variant:str='original',value=Depends(claims)):
        if value['role']!='viewer':raise HTTPException(403)
        async with gate:
            scope=state.scope(value);root=projects.project(scope,identifier);report=projects.report(root,variant)
            report['runtime_correlations']=audit.correlate(report,state.all_events(scope))
            report['timeline']=state.history(scope,limit=200)
            report['coverage']['runtime_capture']={'retention':state.coverage(scope),'limits':'Bounded, best effort; no packet-level completeness guarantee.'}
        content,mime=await asyncio.to_thread(reports.export,report,format)
        return Response(content,media_type=mime,headers={'Content-Disposition':f'attachment; filename="zeus-report-{identifier}.{format}"'})

    @app.get('/v1/projects/{identifier}/evidence/{recording}')
    async def evidence_download(identifier:str,recording:str,value=Depends(claims)):
        if value['role']!='viewer':raise HTTPException(403)
        path,metadata=diagnostics.artifact(state.scope(value),identifier,recording)
        return FileResponse(path,media_type='application/octet-stream',filename=metadata['file'])

    @app.post("/v1/upload")
    async def upload(request: Request, value=Depends(claims)):
        if value["role"] != "viewer": raise HTTPException(403)
        async with gate:
            return await projects.upload(state.scope(value), request.stream(), request.headers.get("x-filename", "application.apk"))

    @app.delete("/v1/session")
    async def delete_session(value=Depends(claims)):
        async with gate:
            scope=state.scope(value); saved=state.load()
            if saved and saved["scope"]==scope:
                await diagnostics.stop(scope)
                await video.close();await lifecycle.action("reset")
                state.db.execute("DELETE FROM state WHERE id=1")
            await projects.delete(scope)
            state.db.execute("DELETE FROM events WHERE scope=?",(scope,))
            state.db.execute("DELETE FROM operations WHERE scope=?",(scope,));state.db.commit()
            state.db.execute('DELETE FROM timeline WHERE scope=?',(scope,));state.db.execute('DELETE FROM counters WHERE scope=?',(scope,));state.db.commit()
            state.db.execute('DELETE FROM consents WHERE scope=?',(scope,));state.db.commit()
            state.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            notify()
        return {"deleted":True}

    @app.post("/v1/video")
    async def offer(request: Request, value=Depends(claims)):
        state.owned(value)
        body = await request.json()
        return await video.offer(body.get("sdp", ""), body.get("type", ""), state.scope(value))

    @app.get("/v1/ice")
    async def ice(value=Depends(claims)):
        return {"iceServers":ice_servers(state.scope(value))}

    @app.post("/v1/heartbeat")
    async def heartbeat(value=Depends(claims)):
        async with gate:
            saved = state.owned(value)
            # Viewer presence keeps the device awake, but never extends deadline.
            saved["activity"] = clock(); state.save(saved)
        return {"deadline":saved["deadline"]}

    @app.post("/internal/capture")
    async def capture(request: Request, x_capture_token: str = Header(default="")):
        expected = os.environ.get("ZEUS_ANDROID_CAPTURE_TOKEN", "")
        if len(expected) < 32 or not hmac.compare_digest(x_capture_token, expected): raise HTTPException(403)
        async with gate:
            saved = state.load(); event = await request.json()
            if not saved or saved["status"] != "running" or not saved["capture"]: return {"accepted":False}
            # Exclude flows started before this conversation/session.
            if not isinstance(event.get("started"), (int,float)) or event["started"] < saved["started"]: return {"accepted":False}
            identifier = state.capture(saved["scope"], event); notify()
            for key in ('observer_dropped_total','observer_delivery_failures_total'):
                count=event.get(key)
                if isinstance(count,int) and 0<=count<1_000_000_000:
                    state.db.execute('INSERT INTO counters VALUES(?,?,?) ON CONFLICT(scope,name) DO UPDATE SET value=MAX(value,excluded.value)',(saved['scope'],key,count))
            state.db.commit()
        return {"accepted":True, "id":identifier}

    return app
