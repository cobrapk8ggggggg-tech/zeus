"""mitmproxy addon. Raw captures are bounded and sent only to the local worker."""
import asyncio
import base64
import os
import time
import json
import urllib.request


class Capture:
    def __init__(self): self.pending = set()

    def response(self, flow):
        if len(self.pending) >= 16: return
        def headers(value):
            return {k:("[redacted]" if k.lower() in {"authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key"} else v[:2000]) for k,v in value.items()}
        def body(value):
            raw = value.raw_content or b""
            return {"base64":base64.b64encode(raw[:32768]).decode(), "bytes":len(raw), "truncated":len(raw)>32768}
        event = {"started":flow.request.timestamp_start, "finished":time.time(), "method":flow.request.method,
            "url":flow.request.pretty_url[:4000], "status":flow.response.status_code,
            "request_headers":headers(flow.request.headers), "response_headers":headers(flow.response.headers),
            "request_body":body(flow.request), "response_body":body(flow.response)}
        task = asyncio.create_task(self.send(event)); self.pending.add(task); task.add_done_callback(self.pending.discard)

    async def send(self, event):
        def deliver():
            request=urllib.request.Request(os.environ.get("ZEUS_ANDROID_CAPTURE_ENDPOINT", "http://worker:8080/internal/capture"),
                data=json.dumps(event).encode(),headers={"Content-Type":"application/json","X-Capture-Token":os.environ["ZEUS_ANDROID_CAPTURE_TOKEN"]})
            # This is the explicit private worker connection, not Internet egress.
            with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request,timeout=3) as response: response.read(1000)
        try:
            await asyncio.to_thread(deliver)
        except (OSError, KeyError): pass

addons = [Capture()]
