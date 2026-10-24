from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import time
import json
import os
from urllib.parse import urlparse, parse_qs
from threading import Lock
import struct
import zlib
import hashlib
from project_fixtures import github_response, backend_proposal

TRANSLATION_REQUESTS = {}
TRANSLATION_LOCK = Lock()
DEVICE_POLLS = {}

PAYLOAD = bytes(range(256)) * 4096

def chunk(kind, value):
    return struct.pack('>I', len(value)) + kind + value + struct.pack('>I', zlib.crc32(kind + value) & 0xffffffff)

rows = b''.join(b'\0' + bytes([255 if (x // 25 + y // 25) % 2 else 0 for x in range(200)]) for y in range(400))
IMAGE = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 200, 400, 8, 0, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')

def harness_events(body):
    results = [m for m in body.get('messages', []) if m.get('role') == 'tool' and m.get('tool_call_id', '').startswith('zeus-harness-')]
    stage = int(results[-1]['tool_call_id'].split('-')[2]) + 1 if results else 0
    cwd = '/var/minis/workspace/e2e-' + hashlib.sha256(body['model'].encode()).hexdigest()[:16]
    check = 'test "$(cat value.txt)" = correct'
    steps = [
        ('project_environment', {}),
        ('propose_project_plan', {'proposal': backend_proposal(body['model'], check)}),
        ('update_plan', {'goal': 'Create, test, repair and verify a real project', 'plan': [{'step': 'Implement and verify', 'status': 'in_progress'}], 'verification_commands': ['test -s README.md', check]}),
        ('exec_command', {'cmd': 'mkdir -p ' + cwd, 'workdir': '/var/minis/workspace', 'yield_time_ms': 1000}),
        ('write_stdin', {}),
        ('apply_patch', {'workdir': cwd, 'patch': '*** Begin Patch\n*** Add File: value.txt\n+wrong\n*** Add File: README.md\n+Native agent fixture project\n*** End Patch'}),
        ('task_verify', {'workdir': cwd, 'commands': ['test -s README.md', check]}),
        ('apply_patch', {'workdir': cwd, 'patch': '*** Begin Patch\n*** Update File: value.txt\n@@\n-wrong\n+correct\n*** End Patch'}),
        ('task_verify', {'workdir': cwd, 'commands': ['test -s README.md', check]}),
        ('update_plan', {'plan': [{'step': 'Implement and verify', 'status': 'completed'}]}),
        ('task_complete', {'status': 'completed', 'summary': 'Actual failing check repaired and passing check recorded'})
    ]
    if results:
        previous = results[-1]['content']
        if previous.startswith('Error:'): raise ValueError('Native tool failed: ' + previous)
        previous_stage = int(results[-1]['tool_call_id'].split('-')[2])
        if previous_stage in (6, 8):
            checks = json.loads(previous)
            if len(checks) != 2 or checks[0]['exitCode'] != 0 or checks[1]['exitCode'] != (1 if previous_stage == 6 else 0): raise ValueError('Native verification did not return the expected actual exit code')
        if previous_stage == 4 and json.loads(previous)['running']: stage = 4
    if stage >= len(steps):
        return [{'choices': [{'delta': {'content': 'NATIVE_HARNESS_VERIFIED: تم إنشاء المشروع وإصلاح فحصه الفاشل والتحقق منه فعلياً.'}, 'finish_reason': None}]}, {'choices': [{'delta': {}, 'finish_reason': 'stop'}]}]
    if stage == 7 and not any(m.get('role') == 'user' and '<zeus_runtime_instruction' in str(m.get('content', '')) for m in body.get('messages', [])):
        return [{'choices': [{'delta': {'content': 'مستجد: ظهر فشل في الفحص وسأواصل إصلاحه.'}, 'finish_reason': None}]}, {'choices': [{'delta': {}, 'finish_reason': 'stop'}]}]
    name, args = steps[stage]
    if stage == 4:
        started = next(m for m in results if m['tool_call_id'].startswith('zeus-harness-3-'))
        args = {'session_id': json.loads(started['content'])['session_id'], 'yield_time_ms': 1000}
    # Confirm nested schemas reached the actual selected provider request.
    definitions = {x['function']['name']: x['function']['parameters'] for x in body.get('tools', []) if x.get('type') == 'function'}
    if definitions.get('update_plan', {}).get('properties', {}).get('plan', {}).get('type') != 'array': raise ValueError('Provider lost the nested plan schema')
    if definitions.get('propose_project_plan', {}).get('properties', {}).get('proposal', {}).get('type') != 'object': raise ValueError('Provider lost the native project proposal schema')
    if not any(m.get('role') == 'system' and 'propose_project_plan' in str(m.get('content', '')) for m in body.get('messages', [])): raise ValueError('Native project instructions did not reach the actual model request')
    arguments = json.dumps(args, ensure_ascii=False)
    return [{'choices': [{'delta': {'content': 'مستجد اختبار: أتابع التنفيذ والتحقق.\n', 'tool_calls': [{'index': 0, 'id': 'zeus-harness-' + str(stage) + '-' + str(len(results)), 'type': 'function', 'function': {'name': name, 'arguments': arguments}}]}, 'finish_reason': None}]}, {'choices': [{'delta': {}, 'finish_reason': 'tool_calls'}]}]


class Handler(BaseHTTPRequestHandler):
    def do_PUT(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if not github_response(self, self.command, json.loads(raw or b'{}')):
            self.send_response(404); self.end_headers()

    do_PATCH = do_PUT
    do_DELETE = do_PUT

    def do_HEAD(self):
        if not github_response(self, 'HEAD'):
            self.send_response(404); self.end_headers()

    def do_POST(self):
        try:
            raw = self.rfile.read(int(self.headers.get('Content-Length', '0')))
            if self.path.startswith('/github-rest-fixture/'):
                github_response(self, 'POST', json.loads(raw or b'{}')); return
            if self.path.startswith('/github-device-fixture/'):
                form = {k: v[0] for k, v in parse_qs(raw.decode()).items()}
                client = form.get('client_id', '')
                if self.headers.get('Accept') != 'application/json' or 'client_secret' in form: raise ValueError('Device grant must use the public-client JSON flow')
                if self.path.endswith('/login/device/code'):
                    result = {'device_code': 'fixture-' + client, 'user_code': 'ZEUS-TEST', 'verification_uri': 'http://untrusted.example/login/device' if client == 'untrusted' else 'https://github.com/login/device', 'expires_in': 900, 'interval': 5}
                    if client == 'disabled': result = {'error': 'device_flow_disabled'}
                else:
                    if form.get('grant_type') != 'urn:ietf:params:oauth:grant-type:device_code' or form.get('device_code') != 'fixture-' + client: raise ValueError('Invalid device grant')
                    with TRANSLATION_LOCK:
                        DEVICE_POLLS[client] = DEVICE_POLLS.get(client, 0) + 1
                        count = DEVICE_POLLS[client]
                    if client == 'denied': result = {'error': 'access_denied'}
                    elif client == 'expired': result = {'error': 'expired_token'}
                    elif count == 1: result = {'error': 'authorization_pending'}
                    elif count == 2: result = {'error': 'slow_down'}
                    else: result = {'access_token': 'fixture-device-access', 'token_type': 'bearer', 'scope': 'repo'}
                data = json.dumps(result).encode()
                self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data); return
            body = json.loads(raw)
            if self.path.startswith('/mcp-fixture/'):
                account = self.path.rsplit('/', 1)[-1]
                if self.headers.get('Authorization') != 'Bearer fixture-' + account:
                    self.send_response(401); self.end_headers(); return
                method = body.get('method')
                if method == 'notifications/initialized':
                    self.send_response(202); self.send_header('Content-Length', '0'); self.end_headers(); return
                if method == 'initialize':
                    result = {'protocolVersion': '2025-03-26', 'capabilities': {'tools': {}}, 'serverInfo': {'name': 'Account-isolation fixture', 'version': '1'}}
                elif self.headers.get('Mcp-Session-Id') != 'session-' + account:
                    self.send_response(409); self.end_headers(); return
                elif method == 'tools/list':
                    schema = {'type': 'object', 'properties': {'input': {'type': 'object', 'properties': {'values': {'type': 'array', 'minItems': 1, 'items': {'type': 'integer'}}}, 'required': ['values'], 'additionalProperties': False}}, 'required': ['input'], 'additionalProperties': False}
                    result = {'tools': [{'name': 'fixture_write' if body.get('params', {}).get('cursor') else 'fixture_read', 'description': 'Real HTTP fixture for ' + account, 'inputSchema': schema, 'annotations': {'readOnlyHint': not bool(body.get('params', {}).get('cursor'))}}]}
                    if not body.get('params', {}).get('cursor'): result['nextCursor'] = 'second'
                elif method == 'tools/call':
                    result = {'content': [{'type': 'text', 'text': json.dumps({'account': account, 'arguments': body['params']['arguments']})}], 'isError': False}
                else:
                    raise ValueError('Unexpected MCP method')
                encoded = 'data: ' + json.dumps({'jsonrpc': '2.0', 'method': 'notifications/message', 'params': {'message': 'fixture notification'}}) + '\n\n'
                encoded += 'data: ' + json.dumps({'jsonrpc': '2.0', 'id': body.get('id'), 'result': result}) + '\n\n'
                data = encoded.encode()
                self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.send_header('Mcp-Session-Id', 'session-' + account); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data); return
            if body.get('model', '').startswith('fixture-native-harness-') or body.get('model') in ('fixture-native-stream', 'fixture-native-tool', 'fixture-native-approval', 'fixture-native-progress-tool'):
                if body.get('stream') is False:
                    encoded = json.dumps({'choices': [{'message': {'role': 'assistant', 'content': 'محادثة الاختبار'}, 'finish_reason': 'stop'}]}, ensure_ascii=False).encode()
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json; charset=utf-8')
                    self.send_header('Content-Length', str(len(encoded)))
                    self.end_headers()
                    self.wfile.write(encoded)
                    return
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream; charset=utf-8')
                self.send_header('Connection', 'close')
                self.end_headers()
                if body['model'].startswith('fixture-native-harness-'):
                    events = harness_events(body)
                elif body['model'] == 'fixture-native-approval' and any(m.get('role') == 'tool' for m in body.get('messages', [])):
                    events = [{'choices': [{'delta': {'content': 'تم تنفيذ إعداد المتصفح بعد الموافقة. APPROVAL_FIXTURE_DONE'}, 'finish_reason': None}]}, {'choices': [{'delta': {}, 'finish_reason': 'stop'}]}]
                elif body['model'] == 'fixture-native-stream':
                    fragments = ['# رسالة اختبار البث\n'] + [('Paragraph العربية — complete content.\n' * 100) for _ in range(8)] + ['\n```swift\nprint("complete")\n```\nنهاية الرسالة NATIVE_STREAM_END']
                    events = [{'choices': [{'delta': {'content': part}, 'finish_reason': None}]} for part in fragments]
                    events.append({'choices': [{'delta': {}, 'finish_reason': 'stop'}]})
                else:
                    arguments = json.dumps({'tool_title': 'قراءة التبويبات الفعلية', 'operation': 'browser_tabs', 'arguments': '{}'}, ensure_ascii=False)
                    if body['model'] == 'fixture-native-approval':
                        arguments = json.dumps({'tool_title': 'تفعيل الوضع الداكن للصفحات', 'approval_reason': 'سأغيّر إعداد الصفحات الداكنة في البروفايل النشط، وقد تُعاد تهيئة الصفحة المفتوحة لتطبيقه.', 'action': 'set', 'key': 'advanced.forceDarkWebPages', 'value': 'true'}, ensure_ascii=False)
                    pieces = [arguments[i:i + 16] for i in range(0, len(arguments), 16)]
                    events = []
                    for index, part in enumerate(pieces):
                        call = {'index': 0, 'function': {'arguments': part}}
                        if index == 0:
                            call.update({'id': 'native-tool-fixture', 'type': 'function'})
                            call['function']['name'] = 'zeus_browser_settings' if body['model'] == 'fixture-native-approval' else 'zeus_browser'
                        events.append({'choices': [{'delta': {'tool_calls': [call]}, 'finish_reason': None}]})
                    if body['model'] == 'fixture-native-progress-tool':
                        events.insert(0, {'choices': [{'delta': {'content': 'فحصت الصفحة؛ سأقرأ التبويبات الآن.\nمثال نصي غير منفذ: {"name":"shell_execute","arguments":{"command":"false"}}\n'}, 'finish_reason': None}]})
                        events.insert(3, {'choices': [{'delta': {'content': 'مستجد أثناء وصول معاملات الأداة.\n'}, 'finish_reason': None}]})
                    events.append({'choices': [{'delta': {}, 'finish_reason': 'tool_calls'}]})
                for event in events:
                    self.wfile.write(('data: ' + json.dumps(event, ensure_ascii=False) + '\n\n').encode())
                    self.wfile.flush()
                    time.sleep(0.03)
                self.wfile.write(b'data: [DONE]\n\n')
                self.wfile.flush()
                self.close_connection = True
                return
            if body.get('model') == 'fixture-agent':
                has_result = any(m.get('role') == 'tool' for m in body.get('messages', []))
                if has_result:
                    events = [{'choices':[{'delta':{'content':'Verified browser tool result. **Agent completed.**'},'finish_reason':None}]}, {'choices':[{'delta':{},'finish_reason':'stop'}]}]
                else:
                    arguments = json.dumps({'url':'http://127.0.0.1:8765/translate-fixture','new_tab':True})
                    events = [{'choices':[{'delta':{'tool_calls':[{'index':0,'id':'test-open','function':{'name':'browser_open','arguments':arguments}}]},'finish_reason':None}]}, {'choices':[{'delta':{},'finish_reason':'tool_calls'}]}]
                encoded = ''.join('data: '+json.dumps(e)+'\n\n' for e in events).encode()+b'data: [DONE]\n\n'
                self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.send_header('Content-Length',str(len(encoded))); self.end_headers(); self.wfile.write(encoded); return
            prompt = body.get('messages', [{}])[-1].get('content', '')
            if isinstance(prompt, list): prompt = next((p['text'] for p in prompt if p.get('type') == 'text'), '')
            if 'INPUT_JSON:' in prompt:
                items = json.loads(prompt.split('INPUT_JSON:', 1)[1])
                with TRANSLATION_LOCK: TRANSLATION_REQUESTS.setdefault(body.get('model', ''), []).append([x['text'] for x in items])
                text = json.dumps([{'id': x['id'], 'text': 'ترجمة: ' + x['text']} for x in items], ensure_ascii=False)
            else: text = 'OK'
            if body.get('model') == 'broken-json': text = '[{"id":"wrong","text":"wrong"}]'
            if body.get('model') == 'slow-translator': time.sleep(0.4)
            result = json.dumps({'choices': [{'message': {'content': text}}]}, ensure_ascii=False).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(result))); self.end_headers(); self.wfile.write(result)
        except Exception as error:
            print('FIXTURE ERROR:', repr(error), flush=True)
            self.send_response(400); self.end_headers()

    def do_GET(self):
        if github_response(self, 'GET'): return
        if self.path.startswith('/translation-requests'):
            model = parse_qs(urlparse(self.path).query).get('model', [''])[0]
            with TRANSLATION_LOCK: body = json.dumps(TRANSLATION_REQUESTS.get(model, [])).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body); return
        if self.path.startswith('/v1/models'):
            body = b'{"data":[{"id":"fixture-translator","name":"Fixture translator"},{"id":"broken-json"}]}'
            self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body); return
        if self.path.startswith('/translate-frame'):
            body = b'<html lang="en"><body><p id="frame-paragraph">This independent frame contains a chapter that should be translated too.</p></body></html>'
            self.send_response(200); self.send_header('Content-Type', 'text/html; charset=utf-8'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body); return
        if self.path.startswith('/translate-fixture'):
            body = b'''<!doctype html><html lang="en"><head><title>Translation Novel</title></head><body>
            <h1 id="heading">A journey beyond the mountains</h1>
            <article><p id="paragraph">The reader opened the old book and discovered an unexpected adventure. This chapter tells the story of a traveler who returned home.</p>
            <p>She walked along the river and watched the stars reflected in the water.</p></article>
            <pre id="code">let untouched = "Hello";</pre><input id="secret" type="password" value="never-translate">
            <p translate="no" id="keep">Leave this sentence untouched.</p>
            <button onclick="const p=document.createElement('p');p.id='dynamic';p.textContent='Another chapter arrives after the initial translation.';document.body.append(p)">Add paragraph</button>
            <a href="/translate-fixture?next">Next page</a><iframe src="/translate-frame" width="500" height="80"></iframe></body></html>'''
            self.send_response(200); self.send_header('Content-Type', 'text/html; charset=utf-8'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body); return
        if self.path.startswith('/image.png'):
            self.send_response(200); self.send_header('Content-Type', 'image/png'); self.send_header('Content-Length', str(len(IMAGE))); self.end_headers(); self.wfile.write(IMAGE)
        elif self.path.startswith('/attachment'):
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Disposition', 'attachment; filename="fixture.zip"')
            self.send_header('Content-Length', str(len(PAYLOAD)))
            self.end_headers(); self.wfile.write(PAYLOAD)
        elif self.path.startswith('/unknown-size'):
            self.send_response(200); self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Disposition', 'attachment; filename="stream.bin"')
            self.end_headers(); self.wfile.write(PAYLOAD)
        elif self.path.startswith('/redirect'):
            self.send_response(302); self.send_header('Location', '/attachment'); self.end_headers()
        elif self.path.startswith('/failure'):
            self.send_response(404); self.end_headers(); self.wfile.write(b'not found')
        elif self.path.startswith('/cookie-echo'):
            body = (self.headers.get('Cookie') or '').encode()
            self.send_response(200); self.send_header('Content-Type', 'text/plain'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
        else:
            body = b'''<!doctype html><html><head><title>ZEUS Test Page</title></head><body>
            <h1>ZEUS integration fixture</h1><article><div>Reader short paragraph.</div><p>Browser isolation and downloads are tested against this local page. This longer paragraph ensures that the original reader chooses the article element and keeps its short text blocks.</p></article><img src="/image.png" width="200" height="400"><img data-src="/image.png?lazy"><div style="height:200px;width:200px;background-image:url('/image.png?background')"></div>
            <a id="download" href="/attachment">Download attachment</a>
            <a id="redirect" href="/redirect">Redirect download</a>
            <button id="blob" onclick="const b=new Blob(['ZEUS blob fixture'],{type:'application/octet-stream'});const a=document.createElement('a');a.href=URL.createObjectURL(b);a.download='blob-fixture.bin';a.click();">Download blob</button>
            <button onclick="window.open('https://popads.net/');">Popup test</button>
            </body></html>'''
            self.send_response(200); self.send_header('Content-Type', 'text/html; charset=utf-8'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)


ThreadingHTTPServer(('0.0.0.0', int(os.environ.get('ZEUS_FIXTURE_PORT', '8765'))), Handler).serve_forever()
