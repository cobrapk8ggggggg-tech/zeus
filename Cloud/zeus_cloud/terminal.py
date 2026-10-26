"""Real PTYs, bounded output, explicit lifetime, no inherited cloud secrets."""
import asyncio
import codecs
from dataclasses import dataclass
import fcntl
import os
from pathlib import Path
import pty
import resource
import signal
import struct
import termios
import time
import uuid
from .files import contained


def environment(home, global_root=None):
    # Never copy os.environ: it contains Atlas credentials and the seal key.
    value = {"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": str(home), "TMPDIR": str(home / ".tmp"),
            "TERM": "xterm-256color", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
            "GIT_TERMINAL_PROMPT": "0", "PYTHONDONTWRITEBYTECODE": "1"}
    if global_root:
        for name in ["shared", "skills", "memory"]: value["ZEUS_" + name.upper() + "_DIR"] = str(Path(global_root) / name)
    return value


def child_limits(uid):
    def setup():
        os.setsid()
        if os.isatty(0): fcntl.ioctl(0, termios.TIOCSCTTY, 0)
        if uid is not None:
            os.setgroups([]); os.setgid(uid); os.setuid(uid)
        resource.setrlimit(resource.RLIMIT_NOFILE, (128, 128))
        resource.setrlimit(resource.RLIMIT_NPROC, (48, 48))
        resource.setrlimit(resource.RLIMIT_FSIZE, (128 * 1024 * 1024,) * 2)
        resource.setrlimit(resource.RLIMIT_AS, (256 * 1024 * 1024,) * 2)
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    return setup


@dataclass
class Terminal:
    id: str
    owner: str
    conversation: str
    process: asyncio.subprocess.Process
    descriptor: int
    output: bytearray
    offset: int = 0
    closed: bool = False
    reader: object = None
    expiry: object = None


class Terminals:
    def __init__(self, event, limit=1):
        self.sessions, self.event, self.limit = {}, event, limit

    async def start(self, owner, conversation, workspace, command="/bin/bash --noprofile --norc", uid=None, seconds=7200, global_root=None):
        if sum(t.process.returncode is None or t.reader and not t.reader.done() for t in self.sessions.values()) >= self.limit:
            raise ValueError("A terminal is already active; close it before starting another")
        closed = [key for key, value in self.sessions.items() if value.closed]
        for key in closed[:-16]: self.sessions.pop(key, None)
        root = Path(workspace)
        temporary = root / ".tmp"; temporary.mkdir(exist_ok=True, mode=0o700)
        if uid is not None: os.chown(temporary, uid, uid)
        master, slave = pty.openpty()
        try:
            process = await asyncio.create_subprocess_exec("/bin/bash", "--noprofile", "--norc", "-c", command,
                stdin=slave, stdout=slave, stderr=slave, cwd=root, env=environment(root, global_root), preexec_fn=child_limits(uid))
        except BaseException:
            os.close(master); raise
        finally: os.close(slave)
        os.set_blocking(master, False)
        terminal = Terminal(str(uuid.uuid4()), owner, conversation, process, master, bytearray())
        self.sessions[terminal.id] = terminal
        terminal.reader = asyncio.create_task(self._read(terminal))
        terminal.expiry = asyncio.create_task(self._expire(terminal, seconds))
        self.resize(owner, terminal.id, 100, 28)
        return terminal

    async def _expire(self, terminal, seconds):
        try:
            await asyncio.sleep(seconds)
            await self.stop(terminal.owner, terminal.id)
        except asyncio.CancelledError: pass

    async def _read(self, terminal):
        loop = asyncio.get_running_loop()
        waiting = asyncio.Event()
        decoder = codecs.getincrementaldecoder("utf-8")("replace")
        loop.add_reader(terminal.descriptor, waiting.set)
        try:
            while True:
                await waiting.wait(); waiting.clear()
                try: data = os.read(terminal.descriptor, 16384)
                except BlockingIOError: continue
                except OSError: break
                if not data: break
                text = decoder.decode(data)
                terminal.output.extend(text.encode())
                if len(terminal.output) > 64 * 1024:
                    removed = len(terminal.output) - 64 * 1024
                    while removed < len(terminal.output) and terminal.output[removed] & 0xc0 == 0x80: removed += 1
                    del terminal.output[:removed]; terminal.offset += removed
                if text: await self.event(terminal, "output", text)
        finally:
            loop.remove_reader(terminal.descriptor)
            os.close(terminal.descriptor); terminal.closed = True
            await terminal.process.wait()
            terminal.expiry.cancel()
            await self.event(terminal, "exit", terminal.process.returncode)

    def get(self, owner, identifier):
        terminal = self.sessions.get(identifier)
        if terminal is None or terminal.owner != owner: raise KeyError(identifier)
        return terminal

    def read(self, owner, identifier, offset=0):
        t = self.get(owner, identifier)
        start = max(offset, t.offset) - t.offset
        return {"id": t.id, "output": bytes(t.output[start:]).decode(errors="replace"),
                "next_offset": t.offset + len(t.output), "truncated": offset < t.offset,
                "exit_code": None if self.active(owner, identifier) else t.process.returncode}

    def active(self, owner, identifier):
        value = self.get(owner, identifier)
        return value.process.returncode is None or value.reader is not None and not value.reader.done()

    def input(self, owner, identifier, data):
        t = self.get(owner, identifier)
        if t.closed or len(data.encode()) > 8192: raise ValueError("Terminal input unavailable or too large")
        os.write(t.descriptor, data.encode())

    def resize(self, owner, identifier, columns, rows):
        t = self.get(owner, identifier)
        if t.closed: return
        fcntl.ioctl(t.descriptor, termios.TIOCSWINSZ, struct.pack("HHHH", max(10, min(rows, 200)), max(20, min(columns, 300)), 0, 0))

    async def stop(self, owner, identifier):
        t = self.get(owner, identifier)
        try: os.killpg(t.process.pid, signal.SIGTERM)
        except ProcessLookupError: pass
        if t.process.returncode is None:
            try: await asyncio.wait_for(t.process.wait(), 2)
            except asyncio.TimeoutError:
                try: os.killpg(t.process.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                await t.process.wait()
        if t.reader is not asyncio.current_task():
            try: await asyncio.wait_for(asyncio.shield(t.reader), 2)
            except asyncio.TimeoutError:
                try: os.killpg(t.process.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                await asyncio.gather(t.reader, return_exceptions=True)

    async def close(self):
        await asyncio.gather(*(self.stop(t.owner, t.id) for t in list(self.sessions.values())), return_exceptions=True)
