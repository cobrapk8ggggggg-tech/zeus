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
            report = root / "adapters.json"
            revision = json.loads((HERE / "source.lock.json").read_text())["commit"]
            with patch.object(MODULE.subprocess, "check_output", return_value=revision + "\n"):
                MODULE.embed(native, browser, report)
            changed = {item["file"] for item in json.loads(report.read_text())["modifiedNativeFiles"]}
            self.assertGreater(json.loads(report.read_text())["unchangedNativeSwiftFiles"], 350)
            # Every original view remains byte-identical except the declared
            # addition to the existing permission card and app-group constants.
            for file in (UPSTREAM / "src/ios/Views").rglob("*.swift"):
                relative = file.relative_to(UPSTREAM / "src/ios")
                if str(relative) == "Views/Chat/OffloadPermissionDialog.swift":
                    continue
                expected = file.read_text().replace("group.com.openminis.app", "group.tools.zeus.openminis").replace("iCloud.com.openminis.app", "iCloud.tools.zeus.openminis")
                if str(relative) == "Views/ContentView.swift":
                    expected = expected.replace("private struct SettingsSheet: View", "struct SettingsSheet: View")
                    expected = expected.replace("    private static let pendingBackgroundNavigationTTL: TimeInterval = 90\n\n    var body: some View {\n        GeometryReader { geo in", "    private static let pendingBackgroundNavigationTTL: TimeInterval = 90\n\n    private var zeusNativeGeometry: some View {\n        GeometryReader { geo in")
                    expected = expected.replace("        }\n        .onReceive(\n            NotificationCenter.default.publisher(for: .sessionDidCreate),", "        }\n    }\n\n    var body: some View {\n        zeusNativeGeometry\n        .onReceive(\n            NotificationCenter.default.publisher(for: .sessionDidCreate),")
                self.assertEqual((native / "src/ios" / relative).read_text(), expected, str(relative))
            for name in ("Agent/MessageList/CollectionViewMessageListV3.swift", "Agent/Chat/ChatStore.swift"):
                self.assertNotIn(name, changed)
            execution = (native / "src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift").read_text()
            self.assertIn('case "zeus_browser":', execution)
            self.assertIn('case "browser_use":', execution)
            self.assertIn("ZEUSNativeAgentBridge.shared.execute", execution)
            self.assertIn("ContentView()", (native / "src/ios/ZEUSNativeIntegration.swift").read_text())
            self.assertIn("return model", (browser / ".openminis/build/BrowserFixtureFactory.swift").read_text())
            self.assertIn("@MainActor enum BrowserFixtureFactory", (browser / ".openminis/build/BrowserFixtureFactory.swift").read_text())


if __name__ == "__main__":
    unittest.main()
