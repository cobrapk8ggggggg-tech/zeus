"""Validate host adapters against real, pinned upstream source files."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location("embed_native", HERE / "embed_native.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
UPSTREAM = HERE.parent / "Vendor/OpenMinis"


class NativeEmbeddingTests(unittest.TestCase):
    def test_original_views_and_runtime_survive_host_adapters(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            native, browser = root / "native", root / "browser"
            shutil.copytree(UPSTREAM / "src/ios", native / "src/ios")
            shutil.copytree(HERE / "Host", browser / ".openminis/Host")
            shutil.copyfile(HERE / "source.lock.json", browser / ".openminis/source.lock.json")
            (browser / "ZEUSNext").mkdir()
            shutil.copyfile(HERE.parent / "ZEUSNext/ZEUSNextApp.swift", browser / "ZEUSNext/ZEUSNextApp.swift")
            shutil.copyfile(HERE / "arabic-overrides.json", browser / ".openminis/arabic-overrides.json")
            report = root / "adapters.json"
            revision = json.loads((HERE / "source.lock.json").read_text())["commit"]
            with patch.object(MODULE.subprocess, "check_output", return_value=revision + "\n"):
                MODULE.embed(native, browser, report)
            changed = {item["file"] for item in json.loads(report.read_text())["modifiedNativeFiles"]}
            self.assertGreater(json.loads(report.read_text())["unchangedNativeSwiftFiles"], 340)
            # Every original view remains byte-identical except the declared
            # addition to the existing permission card and app-group constants.
            for file in (UPSTREAM / "src/ios/Views").rglob("*.swift"):
                relative = file.relative_to(UPSTREAM / "src/ios")
                if str(relative) in {"Views/Chat/OffloadPermissionDialog.swift", "Views/Chat/AIChatView.swift", "Views/Chat/ToolLiveSheet.swift", "Views/Settings/OffloadPermissionSettingsView.swift"}:
                    continue
                expected = file.read_text().replace("group.com.openminis.app", "group.tools.zeus.openminis").replace("iCloud.com.openminis.app", "iCloud.tools.zeus.openminis")
                if str(relative) == "Views/ContentView.swift":
                    expected = expected.replace("private struct SettingsSheet: View", "struct SettingsSheet: View")
                    expected = expected.replace("    private static let pendingBackgroundNavigationTTL: TimeInterval = 90\n\n    var body: some View {\n        GeometryReader { geo in", "    private static let pendingBackgroundNavigationTTL: TimeInterval = 90\n\n    private var zeusNativeGeometry: some View {\n        GeometryReader { geo in")
                    expected = expected.replace("        }\n        .onReceive(\n            NotificationCenter.default.publisher(for: .sessionDidCreate),", "        }\n    }\n\n    var body: some View {\n        zeusNativeGeometry\n        .onReceive(\n            NotificationCenter.default.publisher(for: .sessionDidCreate),")
                    expected = expected.replace("    var body: some View {\n        zeusNativeGeometry", "    private var zeusNativeIncoming: some View {\n        zeusNativeGeometry")
                    boundaries = [
                        ("        .fullScreenCover(isPresented: $showTerminal) {", "zeusNativePresentations", "zeusNativeIncoming"),
                        ("        .onReceive(NotificationCenter.default.publisher(for: .cloudSyncDidFetchChanges)) { _ in", "zeusNativeSessionLifecycle", "zeusNativePresentations"),
                        ("        .onChange(of: shareCoordinator.hasPendingShare) { hasPending in", "body", "zeusNativeSessionLifecycle")
                    ]
                    for anchor, name, previous in boundaries:
                        declaration = "    var body: some View {" if name == "body" else "    private var " + name + ": some View {"
                        expected = expected.replace(anchor, "    }\n\n" + declaration + "\n        " + previous + "\n" + anchor)
                if str(relative) == "Views/Chat/AssistantBlockView.swift":
                    expected = expected.replace('case .browserTool:   toolName = "browser_use"', 'case .browserTool:   toolName = block.zeusIsUserBrowser ? "zeus_browser" : "browser_use"')
                expected = expected.replace('"Minis"', '"Zeus"')
                for tool in ("Shell", "Editor", "Browser", "Memory"):
                    expected = expected.replace('return "Minis is using ' + tool + '"', 'return String(localized: "Minis is using ' + tool + '")')
                self.assertEqual((native / "src/ios" / relative).read_text(), expected, str(relative))
            original_store = (UPSTREAM / "src/ios/Agent/Chat/ChatStore.swift").read_text()
            adapted_store = (native / "src/ios/Agent/Chat/ChatStore.swift").read_text()
            # Storage/protocol/sync methods after UI conversion remain untouched.
            marker = "    func toAgentMessage("
            self.assertEqual(adapted_store[adapted_store.index(marker):], original_store[original_store.index(marker):])
            execution = (native / "src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift").read_text()
            self.assertIn('name == "zeus_browser" || zeusBrowserOperation(name) != nil', execution)
            self.assertIn('case "browser_use":', execution)
            self.assertIn("ZEUSNativeAgentBridge.shared.execute", execution)
            self.assertIn("ContentView()", (native / "src/ios/ZEUSNativeIntegration.swift").read_text())
            self.assertIn("return model", (browser / ".openminis/build/BrowserFixtureFactory.swift").read_text())
            localized = json.loads((native / "src/ios/Localizable.xcstrings").read_text())["strings"]
            self.assertFalse(any(entry.get("localizations", {}).get("ar", {}).get("stringUnit", {}).get("value") == "خيار" for entry in localized.values()))
            self.assertIn("ZeusToolPermissions.shared.authorize", execution)
            self.assertNotIn(".offloadPermissionDialog()", (native / "src/ios/Views/Chat/AIChatView.swift").read_text())
            self.assertIn("@MainActor enum BrowserFixtureFactory", (browser / ".openminis/build/BrowserFixtureFactory.swift").read_text())


if __name__ == "__main__":
    unittest.main()
