"""Describe reproducible OS bytes; never install/extract Linux on the device."""
import hashlib
import json
from pathlib import Path
import sys
import re
from urllib.parse import urlsplit
import zipfile


def manifest(source, overlay=None):
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
        def generated(name, data):
            digest = hashlib.sha256(data).hexdigest()
            files["@generated:" + name + ":" + digest] = digest
            for parent in Path(name).parents:
                if str(parent) != ".": files[parent.as_posix() + "/"] = ""
        if overlay:
            overlay = Path(overlay)
            for item in overlay.rglob("*"):
                if item.is_symlink(): raise ValueError("Unexpected overlay symlink")
                name = "data/" + item.relative_to(overlay).as_posix()
                if item.is_dir(): files[name + "/"] = ""
                elif item.is_file(): generated(name, item.read_bytes())
            # Kernel-created device placeholders contain no payload; guest
            # mode/device numbers live in meta.db. Never accept nonempty bytes.
            for device in ["tty", "console", "ptmx", "null", "zero", "full", "random", "urandom"] + ["tty" + str(n) for n in range(1, 8)]:
                generated("data/dev/" + device, b"")
            files["data/dev/pts/"] = ""
            mirrors = overlay.parent / "Views/Rootfs/MirrorSpeedTestView.swift"
            if mirrors.exists():
                text = mirrors.read_text()
                for category, config in [("alpine", "etc/apk/repositories"), ("pip", "etc/pip/pip.conf"), ("npm", "root/.npmrc")]:
                    start = text.index("private static let " + category + "Mirrors:")
                    section = text[start:text.index("}()", start)]
                    for url in re.findall(r'm\("[^"]+", "[^"]+", "(https://[^"]+)"', section):
                        if category == "alpine": values = [url + "v3.21/main\n" + url + "v3.21/community\n"]
                        elif category == "pip": values = ["[global]\nbreak-system-packages = true\nindex-url = " + url + "\ntrusted-host = " + urlsplit(url).hostname + "\n"]
                        else: values = ["registry=" + url + "\n"]
                        for value in values:
                            generated("data/" + config, value.encode())
                            if category == "pip": generated("data/" + config, (value + "\n").encode())
                for config in ["etc/apk/repositories", "etc/pip/pip.conf", "root/.npmrc"]:
                    name = "data/" + config
                    if name in files: generated(name + ".bak", archive.read("alpine-rootfs/" + name))
                    original = overlay / config
                    if original.is_file(): generated(name + ".bak", original.read_bytes())
        return files


if __name__ == "__main__":
    Path(sys.argv[2]).write_text(json.dumps(manifest(sys.argv[1], sys.argv[3] if len(sys.argv) > 3 else None), sort_keys=True))
