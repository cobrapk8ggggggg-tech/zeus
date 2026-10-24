"""Bound the host hostname copied into Linux's fixed-size utsname field.

Applied to the separate pinned dependency checkout before compiling either SDK.
Never disable fortified libc checks: a macOS/iOS hostname can exceed Linux's
64-byte field (and the simulator otherwise traps in __strcpy_chk/sys_uname).
"""
from pathlib import Path
import subprocess

ISH_COMMIT = "19c690c3b979c3addef38318231b93a2dcdbe990"


def patch(root: Path):
    ish = root / "deps/ish"
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ish, text=True).strip()
    if revision != ISH_COMMIT:
        raise RuntimeError("iSH dependency revision changed; review hostname fix")
    file = ish / "kernel/uname.c"
    code = file.read_text()
    changes = [("    struct utsname real_uname;", "    struct utsname real_uname = {0};"),
               ("    strcpy(uts->hostname, hostname);", '    snprintf(uts->hostname, sizeof(uts->hostname), "%s", hostname);')]
    for before, after in changes:
        if after in code:
            continue
        if code.count(before) != 1:
            raise RuntimeError("iSH uname source anchor changed")
        code = code.replace(before, after)
    file.write_text(code)
