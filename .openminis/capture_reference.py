"""Capture the actual stock app through its existing settings deep links."""
import argparse
import json
from pathlib import Path
import subprocess
import time


def run(*arguments):
    return subprocess.run(arguments, text=True, check=True, capture_output=True, timeout=60).stdout


def capture(device, app, output, bundle="com.openminis.app"):
    output.mkdir(parents=True, exist_ok=True)
    run("xcrun", "simctl", "install", device, str(app))
    run("xcrun", "simctl", "status_bar", device, "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100")
    arguments = ["xcrun", "simctl", "launch", "--terminate-running-process", device,
                 bundle, "-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA",
                 "-appearanceMode", "2", "-appLanguage", "ar"]
    if bundle != "com.openminis.app":
        arguments += ["--open-native-agent", "--layout=icab", "--uitesting"]
    launch = run(*arguments)
    (output / "launch.txt").write_text(launch)
    time.sleep(3)
    pages = ["home", "settings", "settings/providers", "settings/model-groups",
             "settings/usage", "settings/appearance", "settings/skills", "settings/memory",
             "settings/permissions", "settings/storage", "settings/shared-folders",
             "settings/mount-external", "settings/environments"]
    captured = []
    for page in pages:
        if page != "home":
            run("xcrun", "simctl", "openurl", device, "minis://" + page)
            # Allow the original navigation animation and its SQLite reads.
            time.sleep(1.5)
        filename = page.replace("/", "-") + ".png"
        run("xcrun", "simctl", "io", device, "screenshot", str(output / filename))
        captured.append({"route": page, "file": filename})
    (output / "screens.json").write_text(json.dumps(captured, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("device")
    parser.add_argument("app", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--bundle", default="com.openminis.app")
    args = parser.parse_args()
    capture(args.device, args.app, args.output, args.bundle)
