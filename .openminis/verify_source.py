"""Reject application-source changes in the stock reference build."""
import argparse
import hashlib
import json
from pathlib import Path


def verify(checkout: Path, manifest: Path) -> int:
    report = json.loads(manifest.read_text())
    original = report["applicationFilesSHA256"]
    adapters = report.get("testEntryAdapters", {})
    differences = []
    for name, expected in original.items():
        file = checkout / name
        if not file.is_file() or hashlib.sha256(file.read_bytes()).hexdigest() != adapters.get(name, expected):
            differences.append(name)
    for name, expected in report.get("dependencyAdaptersSHA256", {}).items():
        file = checkout / name
        if not file.is_file() or hashlib.sha256(file.read_bytes()).hexdigest() != expected:
            differences.append(name)
    if differences:
        raise RuntimeError("Reference application/dependency source changed: " + ", ".join(differences))
    return len(original) - len(adapters)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("checkout", type=Path)
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    print(f"Verified {verify(args.checkout, args.manifest)} unchanged original application files; declared Debug entry adapter verified separately")
