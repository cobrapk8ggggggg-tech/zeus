"""Validate host adapters against real, pinned upstream source files."""
import hashlib
import importlib.util
import json
import os
import re
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location("embed_native", HERE / "embed_native.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
UPSTREAM = Path(os.environ.get("ZEUS_OPENMINIS_SOURCE", HERE.parent / "Vendor/OpenMinis"))


class NativeEmbeddingTests(unittest.TestCase):
    def test_arabic_overrides_preserve_format_arguments(self):
        overrides = json.loads((HERE / "arabic-overrides.json").read_text())
        token = re.compile(r'%(?:\d+\$)?[-+#0 ]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:ll|l|h|z)?[@diuoxXfFeEgGcs]')
        for source, translated in overrides.items():
            self.assertEqual(sorted(token.findall(source)), sorted(token.findall(translated)), source)
            self.assertFalse(translated.startswith("معلومات:"), source)
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
            shutil.copyfile(HERE / "arabic-base.json", browser / ".openminis/arabic-base.json")
            report = root / "adapters.json"
            revision = json.loads((HERE / "source.lock.json").read_text())["commit"]
            with patch.object(MODULE.subprocess, "check_output", return_value=revision + "\n"):
                MODULE.embed(native, browser, report)
            changed = {item["file"] for item in json.loads(report.read_text())["modifiedNativeFiles"]}
            self.assertGreaterEqual(json.loads(report.read_text())["unchangedNativeSwiftFiles"], 330)
            # Every original view remains byte-identical except the declared
            # addition to the existing permission card and app-group constants.
            for file in (UPSTREAM / "src/ios/Views").rglob("*.swift"):
                relative = file.relative_to(UPSTREAM / "src/ios")
                if str(relative) in {"Views/Chat/OffloadPermissionDialog.swift", "Views/Chat/AIChatView.swift", "Views/Chat/ToolLiveSheet.swift", "Views/Settings/OffloadPermissionSettingsView.swift", "Views/Chat/SelectableMarkdownView.swift", "Views/Settings/StorageManagementView.swift", "Views/Rootfs/FileBrowserView.swift", "Views/Settings/MountedFoldersSettingsView.swift", "Views/Settings/BackupDestinationPicker.swift", "Views/Skills/SkillsManagementView.swift"}:
                    continue
                expected = file.read_text().replace("group.com.openminis.app", "group.tools.zeus.openminis").replace("iCloud.com.openminis.app", "iCloud.tools.zeus.openminis")
                if str(relative) == "Views/ContentView.swift":
                    expected = expected.replace('BrowserSheetView(pool:', 'ZeusAgentBrowserWindow(pool:')
                    expected = expected.replace('                Section("Agent Runtime") {', '''                Section("وكيل ZEUS") {
                    NavigationLink { ZeusAgentRuntimeSettings() } label: { Label("أدوات الوكيل وتنفيذه", systemImage: "terminal") }
                    NavigationLink { ZeusPluginsSettingsView() } label: { Label("الإضافات", systemImage: "puzzlepiece.extension") }
                }
                Section("Agent Runtime") {''')
                    expected = re.sub(r'private let supportedLanguages: \[LanguageOption\] = \[.*?\n\]', 'private let supportedLanguages: [LanguageOption] = [\n    LanguageOption(id: "ar", name: "العربية", flag: "🇸🇦"),\n]', expected, count=1, flags=re.S)
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
                if str(relative) == "Views/Providers/ProviderInstancesView.swift":
                    expected = expected.replace('let shadows = store.shadowVoiceProviders()', 'let shadows: [ProviderConfigStore.ShadowVoiceProvider] = []')
                expected = expected.replace('"Minis"', '"Zeus"')
                if '.fileImporter(' in expected:
                    expected = 'import ZEUSBrowser\n' + expected.replace('.fileImporter(', '.zeusFileImporter(')
                for tool in ("Shell", "Editor", "Browser", "Memory"):
                    expected = expected.replace('return "Minis is using ' + tool + '"', 'return String(localized: "Minis is using ' + tool + '")')
                self.assertEqual((native / "src/ios" / relative).read_text(), expected, str(relative))
            storage = (native / "src/ios/Views/Settings/StorageManagementView.swift").read_text()
            self.assertIn("ZeusStorageCategoryView(category: label)", storage)
            self.assertIn("ZeusStorageDirectoryView(root: minisURL)", storage)
            self.assertTrue((native / "src/ios/ZeusStorageExplorer.swift").exists())
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
            base = json.loads((HERE / "arabic-base.json").read_text())["localizations"]
            self.assertGreater(len(base), 1700)
            self.assertTrue(all("ar" in localized[key].get("localizations", {}) for key in base if key in localized))
            self.assertTrue(all("ar" in entry.get("localizations", {}) for entry in localized.values()))
            self.assertFalse(any(entry.get("localizations", {}).get("ar", {}).get("stringUnit", {}).get("value") == "خيار" for entry in localized.values()))
            for key, entry in localized.items():
                self.assertLessEqual(set(entry.get("localizations", {})), {"ar"})
                arabic = entry.get("localizations", {}).get("ar", {}).get("stringUnit", {}).get("value", "")
                self.assertFalse(arabic.startswith("معلومات:"), key)
            vad = (native / "src/ios/Providers/Voice/VoiceActivityDetector.swift").read_text()
            self.assertNotIn("import RealTimeCutVADLibrary", vad)
            self.assertNotIn("ffmpeg_offload_register();", (native / "src/ios/iSH/ISHKernel.m").read_text())
            self.assertNotIn("micButtonContainer\n", (native / "src/ios/Views/Chat/AIChatView.swift").read_text())
            self.assertIn("ZeusToolPermissions.shared.authorize", execution)
            self.assertNotIn(".offloadPermissionDialog()", (native / "src/ios/Views/Chat/AIChatView.swift").read_text())
            self.assertIn("@MainActor enum BrowserFixtureFactory", (browser / ".openminis/build/BrowserFixtureFactory.swift").read_text())
            chat = (native / "src/ios/Views/Chat/AIChatView.swift").read_text()
            self.assertIn('ZeusAgentBrowserWindow(pool: vm.browserTabPool', chat)
            window = (native / 'src/ios/ZeusAgentBrowserWindow.swift').read_text()
            self.assertIn('.fullScreenCover(isPresented: $expanded, onDismiss:', window)
            self.assertIn('ZeusConversationFiles(sessionID: vm.sessionId)', chat)
            self.assertIn('vm.zeusAddPickedFiles(urls)', chat)
            self.assertIn('FileBrowserView(rootPath: base', chat)
            # All used import routes share the same post-dismiss owner. The old
            # private picker declarations may remain, but have no call sites.
            for relative in ['Views/Settings/MountedFoldersSettingsView.swift', 'Views/Settings/BackupDestinationPicker.swift', 'Views/Rootfs/FileBrowserView.swift', 'Views/Skills/SkillsManagementView.swift']:
                adapted = (native / 'src/ios' / relative).read_text()
                self.assertIn('.zeusFileImporter(', adapted)
                for old in ['FolderPicker {', 'BackupFolderPicker {', 'FileImportPicker {', 'SkillFileDocumentPicker {']:
                    self.assertNotIn(old, adapted)


if __name__ == "__main__":
    unittest.main()
