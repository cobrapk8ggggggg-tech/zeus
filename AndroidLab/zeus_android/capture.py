"""Bounded, passive request/stream/WebSocket observations sent to the worker."""
import asyncio
import base64
import json
import os
import time
import urllib.request

LIMIT = 32768


def headers(value):
    # Both count and values are bounded; unusual headers cannot evade the event cap.
    return {k[:80]: ('[redacted]' if k.lower() in {'authorization', 'proxy-authorization', 'cookie', 'set-cookie', 'x-api-key'} else v[:140]) for k, v in list(value.items())[:16]}


def body(raw, total=None, available=True):
    raw = raw or b''
    count = len(raw) if total is None else total
    return {'base64': base64.b64encode(raw[:LIMIT]).decode(), 'bytes': count if available else None,
            'truncated': not available or count > LIMIT, 'available': available}


class Capture:
    def __init__(self): self.pending = set()

    def event(self, flow, phase, **extra):
        sequence = flow.metadata.get('zeus_sequence', 0) + 1
        flow.metadata['zeus_sequence'] = sequence
        event = {'flow_id': flow.id, 'sequence': sequence, 'phase': phase,
                 'started': flow.request.timestamp_start, 'observed': time.time(),
                 'method': flow.request.method, 'url': flow.request.pretty_url[:4000],
                 'status': flow.response.status_code if flow.response else None,
                 'request_headers': headers(flow.request.headers),
                 'request_body': body(flow.request.raw_content, available=flow.request.raw_content is not None), **extra}
        self.emit(event)

    def emit(self, event):
        if len(self.pending) >= 16: return
        task = asyncio.create_task(self.send(event))
        self.pending.add(task); task.add_done_callback(self.pending.discard)

    def request(self, flow):
        self.event(flow, 'request', request_headers=headers(flow.request.headers),
                   request_body=body(flow.request.raw_content, available=flow.request.raw_content is not None))

    def responseheaders(self, flow):
        self.event(flow, 'headers', response_headers=headers(flow.response.headers))
        # Stream these protocols unchanged; never wait for their connection to close.
        content_type = flow.response.headers.get('content-type', '').lower()
        live = any(t in content_type for t in ('text/event-stream', 'ndjson', 'application/grpc'))
        preview = bytearray(); total = 0; previous = 0; emitted = 0
        def stream(chunk):
            nonlocal total, previous, emitted
            total += len(chunk)
            room = LIMIT - len(preview)
            if room: preview.extend(chunk[:room])
            now = time.monotonic()
            if not chunk or live and emitted < 64 and (not emitted or room and now - previous >= .5):
                self.event(flow, 'stream' if chunk else 'complete', response_body=body(bytes(preview), total),
                           response_headers=headers(flow.response.headers))
                previous = now; emitted += 1
            return chunk  # No alteration or replay of the application traffic.
        flow.metadata['zeus_stream'] = True
        flow.response.stream = stream

    def response(self, flow):
        if flow.metadata.get('zeus_stream'): return
        self.event(flow, 'complete', request_headers=headers(flow.request.headers),
                   response_headers=headers(flow.response.headers),
                   request_body=body(flow.request.raw_content, available=flow.request.raw_content is not None),
                   response_body=body(flow.response.raw_content, available=flow.response.raw_content is not None))

    def error(self, flow):
        self.event(flow, 'error', error=str(flow.error)[:500])

    def websocket_message(self, flow):
        message = flow.websocket.messages[-1]
        self.event(flow, 'websocket', direction='outgoing' if message.from_client else 'incoming',
                   message_type='text' if message.is_text else 'binary', response_body=body(message.content))
        # mitmproxy otherwise retains the entire long-lived WebSocket history.
        del flow.websocket.messages[:-1]

    async def send(self, event):
        def deliver():
            request = urllib.request.Request(os.environ.get('ZEUS_ANDROID_CAPTURE_ENDPOINT', 'http://worker:8080/internal/capture'),
                data=json.dumps(event, ensure_ascii=False).encode(), headers={'Content-Type':'application/json', 'X-Capture-Token':os.environ['ZEUS_ANDROID_CAPTURE_TOKEN']})
            with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=3) as response: response.read(1000)
        try: await asyncio.to_thread(deliver)
        except (OSError, KeyError): pass

addons = [Capture()]
