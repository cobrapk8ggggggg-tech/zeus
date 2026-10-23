"""Capture the actual stock app through its existing settings deep links."""
import argparse
import json
from pathlib import Path
import subprocess
import time
import urllib.request


def run(*arguments):
    return subprocess.run(arguments, text=True, check=True, capture_output=True, timeout=60).stdout


def rpc(method, params=None):
    request = urllib.request.Request("http://127.0.0.1:8321/rpc", data=json.dumps({"jsonrpc": "2.0", "id": method, "method": method, "params": params or {}}).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=5) as response:
        value = json.load(response)
    if "error" in value: raise RuntimeError(str(value["error"]))
    return value["result"]


def capture(device, app, output, bundle="com.openminis.app"):
    output.mkdir(parents=True, exist_ok=True)
    run("xcrun", "simctl", "install", device, str(app))
    run("xcrun", "simctl", "status_bar", device, "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100")
    arguments = ["xcrun", "simctl", "launch", "--terminate-running-process", device,
                 bundle, "-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA",
                 "-appearanceMode", "2", "-appLanguage", "ar", "--zeus-native-fixture"]
    if bundle != "com.openminis.app":
        arguments += ["--open-native-agent", "--layout=icab", "--uitesting"]
    launch = run(*arguments)
    (output / "launch.txt").write_text(launch)
    deadline = time.monotonic() + 45
    while True:
        try:
            if rpc("debug.fixture.providerReady").get("ready"): break
        except Exception: pass
        if time.monotonic() > deadline: raise RuntimeError("Simulator app/debug/provider bootstrap did not become ready")
        time.sleep(0.3)
    pages = ["home", "settings", "settings/providers", "settings/model-groups",
             "settings/usage", "settings/appearance", "settings/skills", "settings/memory",
             "settings/permissions", "settings/storage", "settings/shared-folders",
             "settings/mount-external", "settings/environments"]
    captured = []
    for page in pages:
        print("Capture", page, flush=True)
        if page != "home":
            rpc("debug.fixture.route", {"url": "minis://" + page})
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
