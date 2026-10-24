"""Drive the original DEBUG RPC to capture a real conversation end to end.

Only isolated simulator data is used. The provider is the local fixture server;
no real account, external provider or manually constructed chat UI is involved.
"""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import time
import urllib.request
import uuid
from native_screenshot import capture as screenshot


def run(*arguments, check=True):
    return subprocess.run(arguments, check=check, text=True, capture_output=True, timeout=60).stdout.strip()


def rpc(method, params=None, timeout=30):
    print("RPC", method, flush=True)
    request = urllib.request.Request("http://127.0.0.1:8321/rpc", data=json.dumps({"jsonrpc": "2.0", "id": method, "method": method, "params": params or {}}).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        payload = json.load(response)
    if "error" in payload:
        raise RuntimeError(f"{method}: {payload['error']}")
    return payload["result"]


def capture(device, bundle, output):
    output.mkdir(parents=True, exist_ok=True)
    run("xcrun", "simctl", "terminate", device, bundle, check=False)
    container = Path(run("xcrun", "simctl", "get_app_container", device, bundle, "data"))
    preferences = container / "Library/Preferences" / (bundle + ".plist")
    settings = plistlib.loads(preferences.read_bytes()) if preferences.exists() else {}
    prior = settings.get("debug.auth.required")
    # Permit the existing app-owned debug API only in this ephemeral simulator.
    # Restore its original authentication setting before handing back to tests.
    settings["debug.auth.required"] = False
    settings["appearanceMode"] = 2
    settings["appLanguage"] = "ar"
    settings["loggingEnabled"] = True
    settings["zeus.agent.permissionMode"] = "consequential"
    preferences.parent.mkdir(parents=True, exist_ok=True)
    preferences.write_bytes(plistlib.dumps(settings, fmt=plistlib.FMT_BINARY))
    arguments = ["xcrun", "simctl", "launch", "--console", "--terminate-running-process", device, bundle,
                 "-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA", "-appearanceMode", "2", "-appLanguage", "ar", "-loggingEnabled", "YES", "--zeus-native-fixture"]
    if bundle != "com.openminis.app":
        arguments += ["--open-native-agent", "--layout=icab", "--uitesting"]
    console = (output / "simulator-console.log").open("w")
    launch = subprocess.Popen(arguments, stdout=console, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 40
        while True:
            try:
                if rpc("debug.fixture.providerReady", timeout=2).get("ready"):
                    break
            except Exception:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.5)
        instance = rpc("provider.instances.create", {"providerType": "openAI", "label": "Native fixture", "apiKey": "local-fixture-only", "customBaseURL": "http://127.0.0.1:8765/v1", "appendV1Suffix": False, "seedBuiltInModels": False})["instance"]
        entry = rpc("provider.models.add", {"instanceId": instance["id"], "modelId": "fixture-native-stream", "displayName": "Native fixture model", "contextWindow": 128000, "maxOutputTokens": 16000})
        rpc("provider.groups.create", {"name": "Native fixture group", "memberEntryIds": [entry["id"]]})
        answer = rpc("chat.prompt", {"prompt": "اعرض النص كاملًا كما يرسله مزود الاختبار.", "modelEntryId": entry["id"], "thinkingLevel": "off", "wait": True, "waitTimeout": 90}, timeout=100)
        text = answer.get("responseText", "")
        if not text.endswith("نهاية الرسالة NATIVE_STREAM_END") or len(text) < 20000:
            raise RuntimeError("The original agent did not retain the complete fixture response")
        session = answer["sessionId"]
        (output / "conversation-result.json").write_text(json.dumps(answer, ensure_ascii=False, indent=2))
        rpc("debug.fixture.route", {"url": "minis://sessions/" + session})
        time.sleep(2)
        screenshot(rpc, output / "chat.png")
        (output / "blocks-diff.json").write_text(json.dumps(rpc("chat.session.blocksDiff", {"sessionId": session}), ensure_ascii=False, indent=2))
        (output / "view-tree.json").write_text(json.dumps(rpc("debug.viewTree", {"maxDepth": 20}), ensure_ascii=False, indent=2))
        if bundle != "com.openminis.app":
            harness = rpc("provider.models.add", {"instanceId": instance["id"], "modelId": "fixture-native-harness-" + uuid.uuid4().hex, "displayName": "Project execution fixture", "contextWindow": 128000, "maxOutputTokens": 4000})
            rpc("zeus.fixture.permission", {"mode": "unrestricted"})
            try:
                project = rpc("chat.prompt", {"prompt": "أنشئ مشروع اختبار فعلياً، اعرض الخطة للموافقة ثم شغّل الفحص وأصلح الخطأ وتحقق منه قبل الإكمال.", "modelEntryId": harness["id"], "thinkingLevel": "off", "wait": False})
                rpc("debug.fixture.route", {"url": "minis://sessions/" + project["sessionId"]})
                deadline = time.monotonic() + 180
                approved_plan = False
                while True:
                    requests = rpc("zeus.fixture.approvals")["requests"]
                    for request in requests:
                        if request["tool"] == "propose_project_plan" and request["sessionId"] == project["sessionId"]:
                            if approved_plan: raise RuntimeError("The same approved project unexpectedly requested a second plan")
                            time.sleep(1)
                            screenshot(rpc, output / "project-plan-approval.png")
                            (output / "project-plan-tree.json").write_text(json.dumps(rpc("debug.viewTree", {"maxDepth": 25}), ensure_ascii=False, indent=2))
                            rpc("zeus.fixture.approval.respond", {"id": request["id"], "allowed": True})
                            approved_plan = True
                    if not rpc("chat.session.status", {"sessionId": project["sessionId"]}).get("isRunning", False): break
                    if time.monotonic() > deadline: raise RuntimeError("Approved native project did not complete within its test deadline")
                    time.sleep(0.25)
                if not approved_plan: raise RuntimeError("Project bypassed explicit user plan approval in unrestricted tool mode")
                messages = rpc("chat.messages.list", {"sessionId": project["sessionId"], "roles": ["assistant"], "includeTools": False})["messages"]
                project["responseText"] = "\n".join(m.get("content", "") for m in messages)
                if "NATIVE_HARNESS_VERIFIED" not in project.get("responseText", ""):
                    raise RuntimeError("The original model/tool loop did not finish the real project fixture")
                state = rpc("zeus.fixture.task", {"sessionId": project["sessionId"]})
                if '"status":"completed"' not in state or '"exit_code":0' not in state:
                    raise RuntimeError("Native project completion has no passing verification evidence")
                (output / "native-project-result.json").write_text(json.dumps({"conversation": project, "state": state}, ensure_ascii=False, indent=2))
            finally:
                rpc("zeus.fixture.permission", {"mode": "consequential"})
            critical = rpc("provider.models.add", {"instanceId": instance["id"], "modelId": "fixture-native-approval", "displayName": "Approval fixture", "contextWindow": 128000, "maxOutputTokens": 2000})
            pending = rpc("chat.prompt", {"prompt": "فعّل الصفحات الداكنة بعد عرض الموافقة داخل المحادثة.", "modelEntryId": critical["id"], "thinkingLevel": "off", "wait": False})
            session = pending["sessionId"]
            rpc("debug.fixture.route", {"url": "minis://sessions/" + session})
            deadline = time.monotonic() + 40
            while True:
                requests = rpc("zeus.fixture.approvals")["requests"]
                if requests:
                    break
                if time.monotonic() > deadline:
                    raise RuntimeError("The real agent did not publish its inline approval")
                time.sleep(0.2)
            request = requests[0]
            if request["tool"] != "zeus_browser_settings" or "سأغيّر" not in request["explanation"]:
                raise RuntimeError("The original agent lost the tool schema/approval explanation")
            time.sleep(1)
            screenshot(rpc, output / "inline-approval.png")
            (output / "inline-approval-tree.json").write_text(json.dumps(rpc("debug.viewTree", {"maxDepth": 25}), ensure_ascii=False, indent=2))
            rpc("zeus.fixture.approval.respond", {"id": request["id"], "allowed": True})
            deadline = time.monotonic() + 30
            while rpc("chat.session.status", {"sessionId": session}).get("isRunning", False):
                if time.monotonic() > deadline:
                    raise RuntimeError("Agent did not resume after inline approval")
                time.sleep(0.2)
            actual = json.loads(rpc("zeus.fixture.settings"))
            if actual["settings"]["advanced"]["forceDarkWebPages"] is not True:
                raise RuntimeError("The approved agent tool did not change the real browser setting")
            (output / "approved-browser-state.json").write_text(json.dumps(actual, ensure_ascii=False, indent=2))
            screenshot(rpc, output / "inline-approved-result.png")
        for route in ["settings", "settings/providers", "settings/model-groups"]:
            rpc("debug.fixture.route", {"url": "minis://" + route})
            time.sleep(1.5)
            screenshot(rpc, output / (route.replace("/", "-") + ".png"))
    finally:
        console.flush()
        logs = container / "Library/Logs"
        if logs.exists():
            shutil.copytree(logs, output / "application-logs", dirs_exist_ok=True)
        diagnostics = Path.home() / "Library/Logs/DiagnosticReports"
        for crash in diagnostics.glob("*.ips"):
            if crash.name.startswith(("ZEUS", "Minis")):
                shutil.copy2(crash, output / crash.name)
        run("xcrun", "simctl", "terminate", device, bundle, check=False)
        try:
            launch.wait(timeout=10)
        except subprocess.TimeoutExpired:
            launch.terminate()
        console.close()
        current = plistlib.loads(preferences.read_bytes()) if preferences.exists() else settings
        if prior is None:
            current.pop("debug.auth.required", None)
        else:
            current["debug.auth.required"] = prior
        preferences.write_bytes(plistlib.dumps(current, fmt=plistlib.FMT_BINARY))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("device")
    parser.add_argument("bundle")
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    capture(args.device, args.bundle, args.output)
