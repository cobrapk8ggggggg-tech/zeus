from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import time
import struct
import zlib

PAYLOAD = bytes(range(256)) * 4096

def chunk(kind, value):
    return struct.pack('>I', len(value)) + kind + value + struct.pack('>I', zlib.crc32(kind + value) & 0xffffffff)

rows = b''.join(b'\0' + bytes([255 if (x // 25 + y // 25) % 2 else 0 for x in range(200)]) for y in range(400))
IMAGE = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 200, 400, 8, 0, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
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
