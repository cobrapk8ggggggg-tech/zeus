"""Exercise the actual Playwright MCP and Chromium, with no model or external site."""
import asyncio
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import shutil
import tempfile
import threading


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        page = b'''<!doctype html><html><body><h1>ZEUS browser test</h1>
<label>Name <input id="name"></label><button onclick="document.getElementById('result').textContent=document.getElementById('name').value+' ready'">Verify</button>
<output id="result" aria-live="polite"></output></body></html>'''
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(page)))
        self.end_headers()
        self.wfile.write(page)
    def log_message(self, *_): pass


async def main():
    chromium = shutil.which("chromium")
    executable = shutil.which("playwright-mcp")
    if not chromium or not executable:
        raise RuntimeError("Real Chromium and Playwright MCP are required")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix="zeus-browser-smoke-") as directory:
        process = await asyncio.create_subprocess_exec(executable, "--headless", "--no-sandbox", "--isolated", "--executable-path", chromium, "--output-dir", directory,
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, limit=8_000_000, cwd=directory)
        async def drain():
            while await process.stderr.read(65536): pass
        stderr = asyncio.create_task(drain())
        sequence = 0
        async def send(value):
            process.stdin.write((json.dumps(value) + "\n").encode())
            await process.stdin.drain()
        async def call(method, params):
            nonlocal sequence
            sequence += 1
            await send({"jsonrpc": "2.0", "id": sequence, "method": method, "params": params})
            async with asyncio.timeout(90):
                while line := await process.stdout.readline():
                    value = json.loads(line)
                    if value.get("id") == sequence:
                        if "error" in value: raise RuntimeError(value["error"])
                        result = value["result"]
                        if result.get("isError"): raise RuntimeError(str(result.get("content"))[:2000])
                        return result
                raise RuntimeError("MCP exited before answering")
        async def tool(name, arguments): return await call("tools/call", {"name": name, "arguments": arguments})
        def text(result):
            output = "\n".join(c.get("text", "") for c in result.get("content", []))
            # Current official MCP returns the real accessibility snapshot as
            # a file link. Read that file instead of assuming inline text.
            for reference in re.findall(r'\[Snapshot\]\(([^)]+)\)', output):
                file = (Path(directory) / reference).resolve()
                assert file.is_relative_to(Path(directory).resolve()), reference
                output += "\n" + file.read_text()
            return output
        try:
            await call("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "zeus-worker-smoke", "version": "1"}})
            await send({"jsonrpc": "2.0", "method": "notifications/initialized"})
            tools = {t["name"] for t in (await call("tools/list", {}))["tools"]}
            assert {"browser_navigate", "browser_snapshot", "browser_fill_form", "browser_click", "browser_take_screenshot", "browser_network_requests", "browser_console_messages"}.issubset(tools), tools
            snapshot = text(await tool("browser_navigate", {"url": f"http://127.0.0.1:{server.server_port}/"}))
            assert "ZEUS browser test" in snapshot, snapshot
            field = re.search(r'textbox "Name" \[ref=([^\]]+)\]', snapshot)
            button = re.search(r'button "Verify" \[ref=([^\]]+)\]', snapshot)
            assert field and button, snapshot
            await tool("browser_fill_form", {"fields": [{"name": "Name", "type": "textbox", "ref": field[1], "value": "Zeus"}]})
            result = text(await tool("browser_click", {"ref": button[1], "element": "Verify button"}))
            assert "Zeus ready" in result, result
            await tool("browser_take_screenshot", {"type": "png", "filename": "browser-smoke.png"})
            image = Path(directory) / "browser-smoke.png"
            assert image.read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
            print(json.dumps({"playwright_mcp": True, "real_chromium": True, "navigation": True, "form_fill_and_click": True, "verified_dom_result": True, "actual_png_screenshot": True}))
        finally:
            if process.returncode is None:
                process.terminate()
                try: await asyncio.wait_for(process.wait(), 10)
                except TimeoutError:
                    process.kill()
                    await process.wait()
            stderr.cancel()
            await asyncio.gather(stderr, return_exceptions=True)
            server.shutdown()


if __name__ == "__main__": asyncio.run(main())
