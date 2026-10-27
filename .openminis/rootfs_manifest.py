"""Describe reproducible OS bytes; never install/extract Linux on the device."""
import hashlib
import json
from pathlib import Path
import sys
import zipfile


def manifest(source):
    with zipfile.ZipFile(source) as archive:
        files = {}
        for entry in archive.infolist():
            name = entry.filename.removeprefix("alpine-rootfs/").rstrip("/")
            if not name and entry.is_dir(): continue
            if name.startswith("/") or any(p in {"", ".", ".."} for p in name.split("/")):
                raise ValueError("Unsafe rootfs entry")
            files[name + "/" if entry.is_dir() else name] = "" if entry.is_dir() else hashlib.sha256(archive.read(entry)).hexdigest()
        if "meta.db" not in files or not any(p.startswith("data/") for p in files):
            raise ValueError("Incomplete rootfs bundle")
        return files


if __name__ == "__main__":
    Path(sys.argv[2]).write_text(json.dumps(manifest(sys.argv[1]), sort_keys=True))
