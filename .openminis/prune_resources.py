"""Verify and prune a built text-edition app before packaging, including extensions."""
from pathlib import Path
import argparse
import json
import shutil


def prune(app: Path):
    if app.suffix != ".app" or not (app / "Info.plist").is_file():
        raise ValueError("Expected an explicit built .app bundle")
    removed = []
    for path in sorted(app.rglob("*.lproj"), key=lambda p: len(p.parts), reverse=True):
        if path.name == "ar.lproj":
            continue
        removed.append(str(path.relative_to(app)))
        shutil.rmtree(path)
    # These should never be embedded by the target; fail instead of hiding a
    # broken dependency graph by deleting a framework after linking against it.
    forbidden = [p for p in app.rglob("*") if p.name.startswith(("RealTimeCut", "silero", "libavcodec", "libavfilter", "libavformat", "FFmpeg"))]
    if forbidden:
        raise ValueError("Media dependencies still embedded: " + ", ".join(str(p.relative_to(app)) for p in forbidden[:15]))
    return {"removedLocalizations": removed, "edition": "arabic-text"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    print(json.dumps(prune(args.app.resolve()), ensure_ascii=False))
