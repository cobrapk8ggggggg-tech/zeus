#!/usr/bin/env python3
"""Host-only control of one fixed container. Bind only to the private lab bridge.
Stopping the Android container releases its CPU/RAM, not the host VM's bill.
"""
import hmac
import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        key=os.environ.get("ZEUS_ANDROID_NODE_TOKEN", "")
        if len(key)<32 or not hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer "+key): self.send_error(403);return
        commands={"/start":[["docker","start","zeus-lab-android"]],"/stop":[["docker","stop","--time","5","zeus-lab-android"]],
                  "/reset":[["docker","rm","-f","zeus-lab-android"],["docker","volume","rm","zeus-lab-android-data"],
                    ["docker","compose","-f","/opt/zeus/AndroidLab/compose.yaml","--profile","device","create","android"]]}
        if self.path not in commands: self.send_error(404);return
        try: ok=all(subprocess.run(command,capture_output=True,timeout=30,check=False).returncode==0 for command in commands[self.path])
        except (OSError,subprocess.TimeoutExpired): ok=False
        self.send_response(200 if ok else 503);self.send_header("Content-Type","application/json");self.end_headers()
        self.wfile.write(json.dumps({"ok":ok}).encode())


if __name__=="__main__":
    ThreadingHTTPServer((os.environ.get("ZEUS_ANDROID_NODE_BIND","172.31.80.1"),9090),Handler).serve_forever()
