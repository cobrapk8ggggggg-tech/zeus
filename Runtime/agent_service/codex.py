"""Versioned JSON-RPC adapter for the actual Codex app-server, never a mock LLM."""
import asyncio
import json
import os
import signal
from pathlib import Path


class CodexRPC:
    def __init__(self, command, cwd, environment, notification, request):
        self.command, self.cwd, self.environment = command, cwd, environment
        self.notification, self.request = notification, request
        self.pending, self.counter, self.handlers = {}, 0, set()
        self.process = None

    async def start(self):
        if self.environment.get("CODEX_HOME"):
            Path(self.environment["CODEX_HOME"]).mkdir(parents=True, exist_ok=True, mode=0o700)
        self.process = await asyncio.create_subprocess_exec(*self.command, cwd=self.cwd, env=self.environment,
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            start_new_session=True, limit=4 * 1024 * 1024)
        self.reader = asyncio.create_task(self.read())
        self.stderr = asyncio.create_task(self.drain_stderr())
        await self.call("initialize", {"clientInfo": {"name": "zeus-browser", "version": "2.8.0"}, "capabilities": {"experimentalApi": True}})
        await self.send({"method": "initialized"})

    async def send(self, message):
        self.process.stdin.write((json.dumps(message, ensure_ascii=False) + "\n").encode())
        await self.process.stdin.drain()

    async def call(self, method, params, timeout=60):
        self.counter += 1
        identifier = self.counter
        future = asyncio.get_running_loop().create_future()
        self.pending[identifier] = future
        try:
            await self.send({"id": identifier, "method": method, "params": params})
            return await asyncio.wait_for(future, timeout)
        finally:
            self.pending.pop(identifier, None)

    async def answer(self, message):
        try:
            result = await self.request(message["method"], message.get("params", {}), message["id"])
            await self.send({"id": message["id"], "result": result})
        except asyncio.CancelledError:
            raise
        except Exception as error:
            await self.send({"id": message["id"], "error": {"code": -32000, "message": str(error)[:1000]}})

    async def read(self):
        try:
            while line := await self.process.stdout.readline():
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if "method" in message and "id" in message:
                    handler = asyncio.create_task(self.answer(message))
                    self.handlers.add(handler)
                    handler.add_done_callback(self.handlers.discard)
                elif "method" in message:
                    await self.notification(message["method"], message.get("params", {}))
                elif message.get("id") in self.pending:
                    future = self.pending[message["id"]]
                    if not future.done():
                        if "error" in message:
                            future.set_exception(RuntimeError(str(message["error"])))
                        else:
                            future.set_result(message.get("result", {}))
        finally:
            for future in list(self.pending.values()):
                if not future.done():
                    future.set_exception(RuntimeError("Codex app-server disconnected"))
            await self.notification("zeus/processExited", {})

    async def drain_stderr(self):
        # Consume diagnostics without leaking authentication headers into events.
        while await self.process.stderr.readline():
            pass

    async def close(self):
        for handler in list(self.handlers):
            handler.cancel()
        if self.process and self.process.returncode is None:
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
                await asyncio.wait_for(self.process.wait(), 5)
            except (ProcessLookupError, asyncio.TimeoutError):
                try:
                    os.killpg(self.process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                await self.process.wait()
        for reader in (getattr(self, "reader", None), getattr(self, "stderr", None)):
            if reader:
                reader.cancel()
        await asyncio.gather(*self.handlers, return_exceptions=True)
