"""Run inside the production image as root; tool commands MUST run as UID 10001.

The extra threads reproduce NPROC's per-real-UID accounting. Host tests with
child_uid=None/root miss this failure. No network, API keys or model are used.
"""
import asyncio
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import threading
import time
from zeus_cloud.terminal import Terminals


def occupy_uid():
    os.setsid(); os.setgroups([]); os.setgid(10001); os.setuid(10001)
    for _ in range(60): threading.Thread(target=time.sleep, args=(45,), daemon=True).start()
    print("ready", flush=True)
    time.sleep(45)


async def main():
    assert os.geteuid() == 0, "Run this boundary test inside Docker"
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder); os.chown(root, 10001, 10001)
        helper = subprocess.Popen(["python", __file__, "occupy"], stdout=subprocess.PIPE, text=True)
        terminals = Terminals(lambda *args: asyncio.sleep(0))
        try:
            assert await asyncio.to_thread(helper.stdout.readline) == "ready\n"
            # Real child processes + pipeline + Python subprocess. An NPROC=48
            # implementation fails here even though this container has room.
            command = "set -eu; test \"$UID\" = 10001; /bin/true; printf 'zeus-linux-ok\\n' | /bin/cat; python -c 'import subprocess; assert subprocess.check_output([\"/bin/echo\",\"child-ok\"]).strip()==b\"child-ok\"'; printf file-ok > check.txt; /bin/cat check.txt; /bin/rm check.txt"
            terminal = await terminals.start("owner", "conversation", root, command, uid=10001, seconds=20)
            async with asyncio.timeout(25):
                while terminals.active("owner", terminal.id): await asyncio.sleep(.05)
            result = terminals.read("owner", terminal.id)
            assert result["exit_code"] == 0, result
            assert "zeus-linux-ok" in result["output"] and "file-ok" in result["output"], result
            assert not (root / "check.txt").exists()
            print("PASS: real UID 10001 forks and runs pipelines/file operations with 60 other UID threads")
        finally:
            await terminals.close()
            os.killpg(helper.pid, signal.SIGTERM); helper.wait(timeout=5)


if __name__ == "__main__":
    import sys
    if sys.argv[1:] == ["occupy"]: occupy_uid()
    else: asyncio.run(main())
