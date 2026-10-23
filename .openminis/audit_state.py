"""Inventory integration boundaries in the pinned native source.

This reports locations for review, not a claim that each match is unsafe or that
profile isolation has already been implemented. Never prints user credentials.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


PATTERNS = {
    "shared_instances": re.compile(r"static\s+(?:let|var)\s+shared\b"),
    "storage_paths": re.compile(r"\.(?:documentDirectory|libraryDirectory|applicationSupportDirectory)|containerURL\(forSecurityApplicationGroupIdentifier"),
    "credential_boundaries": re.compile(r"kSecAttrService|kSecAttrAccount|kSecAttrAccessGroup"),
    "defaults_namespaces": re.compile(r"UserDefaults\.(?:standard|shared)|UserDefaults\(suiteName|@AppStorage\("),
    "detached_tasks": re.compile(r"Task\.detached"),
    "webview_creation": re.compile(r"WKWebView\(frame:"),
}


def inventory(root):
    lock = json.loads((Path(__file__).parent / "source.lock.json").read_text())
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    if revision != lock["commit"]:
        raise RuntimeError("Only the pinned original source can be audited")
    matches = {name: [] for name in PATTERNS}
    files = {}
    for file in sorted((root / "src/ios").rglob("*")):
        if file.suffix not in (".swift", ".m", ".mm", ".h", ".c"):
            continue
        relative = str(file.relative_to(root))
        if any(part in ("MinisTests", "MinisUITests", "Vendor") for part in file.relative_to(root).parts):
            continue
        content = file.read_bytes()
        files[relative] = hashlib.sha256(content).hexdigest()
        for number, line in enumerate(content.decode("utf-8", errors="replace").splitlines(), 1):
            if line.lstrip().startswith(("//", "*")):
                continue
            for name, pattern in PATTERNS.items():
                if pattern.search(line):
                    matches[name].append({"file": relative, "line": number, "source": line.strip()})
    return {"commit": revision, "counts": {name: len(items) for name, items in matches.items()},
            "note": "Inventory only. Matches require review; this does not establish isolation.",
            "matches": matches, "sourceFilesSHA256": files}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("checkout", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    report = inventory(args.checkout.resolve())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(json.dumps({"commit": report["commit"], "sourceFiles": len(report["sourceFilesSHA256"]), "counts": report["counts"]}))
