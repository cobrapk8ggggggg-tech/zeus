from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import time
import json
from urllib.parse import urlparse, parse_qs
from threading import Lock
import struct
import zlib

TRANSLATION_REQUESTS = {}
TRANSLATION_LOCK = Lock()

PAYLOAD = bytes(range(256)) * 4096

def chunk(kind, value):
    return struct.pack('>I', len(value)) + kind + value + struct.pack('>I', zlib.crc32(kind + value) & 0xffffffff)

rows = b''.join(b'\0' + bytes([255 if (x // 25 + y // 25) % 2 else 0 for x in range(200)]) for y in range(400))
IMAGE = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 200, 400, 8, 0, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
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
        except Exception:
            self.send_response(400); self.end_headers()

    def do_GET(self):
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


ThreadingHTTPServer(('0.0.0.0', 8765), Handler).serve_forever()
