from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import time

PAYLOAD = bytes(range(256)) * 4096


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/attachment'):
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
            <h1>ZEUS integration fixture</h1><article><p>Browser isolation and downloads are tested against this local page.</p></article>
            <a id="download" href="/attachment">Download attachment</a>
            <a id="redirect" href="/redirect">Redirect download</a>
            <button id="blob" onclick="const b=new Blob(['ZEUS blob fixture'],{type:'application/octet-stream'});const a=document.createElement('a');a.href=URL.createObjectURL(b);a.download='blob-fixture.bin';a.click();">Download blob</button>
            <button onclick="window.open('https://popads.net/');">Popup test</button>
            </body></html>'''
            self.send_response(200); self.send_header('Content-Type', 'text/html; charset=utf-8'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)


ThreadingHTTPServer(('0.0.0.0', 8765), Handler).serve_forever()
