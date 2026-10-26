"""Keep complete Xcode output in the artifact, concise diagnostics in Actions.

Large upstream header-warning dumps exceed the connected log reader's limit;
filtering console output must never change Xcode's exit status or stored log.
"""
from pathlib import Path
import os
import re
import signal
import subprocess
import sys
import time


def run(log: Path, command: list[str]) -> int:
    log.parent.mkdir(parents=True, exist_ok=True)
    pattern = re.compile(r"error:|\*\* (?:BUILD|TEST)|Test (?:Case|Suite)|Executed \d+|XCTAssert|Testing (?:started|failed)|^SwiftCompile|^\s*t =")
    last_update = time.monotonic()
    with log.open("w") as output:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace", start_new_session=True)
        def stop(signum, _frame):
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            raise SystemExit(128 + signum)
        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        for line in process.stdout:
            output.write(line)
            output.flush()
            if pattern.search(line):
                print(line, end="", flush=True)
                last_update = time.monotonic()
            elif time.monotonic() - last_update >= 30:
                print("Xcode is running; full output: " + str(log), flush=True)
                last_update = time.monotonic()
        status = process.wait()
    print(f"Xcode exited with {status}; complete log: {log}", flush=True)
    return status


if __name__ == "__main__":
    command = sys.argv[2:]
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        raise SystemExit("Usage: run_xcode.py LOG -- xcodebuild ...")
    raise SystemExit(run(Path(sys.argv[1]), command))
