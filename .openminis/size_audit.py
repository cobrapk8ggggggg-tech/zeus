"""Measure every packaged resource and strip local/debug symbols in Release only.

Uses Apple's strip -S -x, retaining exported symbols needed by dynamic loading.
Does not remove dependencies, fonts, Linux files or app features.
"""
import argparse
import json
from pathlib import Path
import subprocess

MACHO = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}


def audit(app, output, strip=False):
    rows = []
    for file in sorted(app.rglob("*")):
        if not file.is_file() or file.is_symlink():
            continue
        before = file.stat().st_size
        with file.open("rb") as stream:
            macho = stream.read(4) in MACHO
        if strip and macho:
            subprocess.run(["xcrun", "strip", "-S", "-x", str(file)], check=True)
        rows.append({"path": str(file.relative_to(app)), "before": before,
                     "after": file.stat().st_size, "macho": macho})
    result = {"beforeBytes": sum(row["before"] for row in rows),
              "afterBytes": sum(row["after"] for row in rows),
              "files": sorted(rows, key=lambda row: row["after"], reverse=True)}
    output.write_text(json.dumps(result, indent=2) + "\n")
    print(f"App resources: {result['beforeBytes'] / 1e6:.2f} → {result['afterBytes'] / 1e6:.2f} MB")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--strip", action="store_true")
    args = parser.parse_args()
    audit(args.app, args.output, args.strip)
