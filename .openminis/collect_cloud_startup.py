"""Copy startup diagnostics early; no account secrets or database contents."""
from pathlib import Path
import json
import shutil
import subprocess
import sys
import stat

device, bundle, destination = sys.argv[1:]
output = Path(destination); output.mkdir(parents=True, exist_ok=True)
lookup = subprocess.run(["xcrun", "simctl", "get_app_container", device, bundle, "data"], capture_output=True, text=True)
if lookup.returncode == 0:
    container = Path(lookup.stdout.strip())
    logs = container / "Library/Logs"
    if logs.exists(): shutil.copytree(logs, output / "application-logs", dirs_exist_ok=True)
    measurement_errors = []
    def size(root):
        total = 0
        if not root.exists(): return total
        try:
            for path in root.rglob("*"):
                try:
                    info = path.lstat()
                    if stat.S_ISREG(info.st_mode): total += info.st_size
                except FileNotFoundError: pass  # Atomically replaced cache/temp file.
                except OSError as error: measurement_errors.append(type(error).__name__)
        except OSError as error: measurement_errors.append(type(error).__name__)
        return total
    roots = {name: container / name for name in ["Documents", "Library"]}
    linux = container / "Documents/alpine-rootfs"
    values = {"local_linux_exists": linux.exists(), "local_linux_bytes": size(linux), "roots": {n: size(p) for n,p in roots.items()}}
    values["measurement_errors"] = measurement_errors
    (output / "actual-storage.json").write_text(json.dumps(values, indent=2))
diagnostics = Path.home() / "Library/Logs/DiagnosticReports"
for crash in diagnostics.glob("*.ips"):
    if crash.name.startswith(("Minis", "ZEUS")): shutil.copy2(crash, output / crash.name)
