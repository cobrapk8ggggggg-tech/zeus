"""Verify reference preparation against the pinned, real upstream build files."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

HERE = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location("prepare_reference", HERE / "prepare_reference.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
UPSTREAM = HERE.parent / "Vendor/OpenMinis"


class OriginalReferenceTests(unittest.TestCase):
    def checkout(self, root):
        names = [f"deps/{name}" for name in ("build_lame.sh", "build_ffmpeg.sh", "build_ish.sh")]
        names += ["src/ios/Configs/ProviderCustomization.xcconfig.example",
                  "src/ios/Minis.xcodeproj/xcshareddata/xcschemes/Minis.xcscheme",
                  "src/ios/Views/Chat/AIChatView.swift",
                  "src/ios/Agent/MessageList/CollectionViewMessageListV3.swift",
                  "src/ios/MinisApp.swift", "src/ios/Debug/DebugJSONRPC.swift", "src/ios/Providers/ProviderConfigStore.swift"]
        for name in names:
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(UPSTREAM / name, target)

    def prepare(self, root, sdk):
        with patch.object(MODULE.subprocess, "check_output", return_value="6339bfcb25190ebf80fd03086c4ead81cf9428ba\n"):
            return MODULE.prepare(root, sdk)

    def test_simulator_has_real_simulator_targets_and_unchanged_ui(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.checkout(root)
            report = self.prepare(root, "iphonesimulator")
            for name in ("build_lame.sh", "build_ffmpeg.sh", "build_ish.sh"):
                file = root / "deps" / name
                subprocess.run(["bash", "-n", str(file)], check=True)
                self.assertNotIn("--sdk iphoneos", file.read_text())
                self.assertNotIn("-miphoneos-version-min", file.read_text())
            cross = (root / "deps/build_ish.sh").read_text()
            self.assertIn("'-target', 'arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator'", cross)
            self.assertIn("make clean\nmake -j", (root / "deps/build_lame.sh").read_text())
            for name in report["applicationFilesSHA256"]:
                if not name.endswith(".xcconfig") and name not in report["testEntryAdapters"]:
                    self.assertEqual((root / name).read_bytes(), (UPSTREAM / name).read_bytes())
            tests = ET.parse(root / "src/ios/Minis.xcodeproj/xcshareddata/xcschemes/Minis.xcscheme").getroot().find("TestAction/Testables")
            self.assertEqual([t.find("BuildableReference").get("BlueprintName") for t in tests], ["MinisUITests"])
            app = (root / "src/ios/MinisApp.swift").read_text()
            self.assertIn("MessageListTestView()", app)
            self.assertIn("else { ContentView() }", app)
            self.assertEqual(report["testEntryAdapters"]["src/ios/MinisApp.swift"], hashlib.sha256((root / "src/ios/MinisApp.swift").read_bytes()).hexdigest())

    def test_device_dependencies_are_not_modified(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.checkout(root)
            self.prepare(root, "iphoneos")
            for name in ("build_lame.sh", "build_ffmpeg.sh", "build_ish.sh"):
                self.assertEqual((root / "deps" / name).read_bytes(), (UPSTREAM / "deps" / name).read_bytes())

    def test_mismatched_source_commit_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(MODULE.subprocess, "check_output", return_value="another-revision\n"):
                with self.assertRaisesRegex(RuntimeError, "revision mismatch"):
                    MODULE.prepare(Path(directory), "iphonesimulator")


if __name__ == "__main__":
    unittest.main()
