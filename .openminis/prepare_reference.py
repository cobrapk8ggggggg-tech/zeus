"""Prepare SDK-correct upstream dependencies without changing application/UI code.

Upstream's dependency scripts only target iphoneos. Simulator builds need their
own Mach-O platform, not just the same arm64 instruction set. Run in a separate
checkout/cache for each SDK; never relabel a device binary as a simulator binary.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET


def prepare(root: Path, sdk: str) -> dict:
    expected = json.loads((Path(__file__).parent / "source.lock.json").read_text())
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    if actual != expected["commit"]:
        raise RuntimeError(f"Source revision mismatch: {actual}")
    manifest = {}
    for file in sorted((root / "src/ios").rglob("*")):
        if file.is_file() and ".xcodeproj" not in str(file.relative_to(root)):
            manifest[str(file.relative_to(root))] = hashlib.sha256(file.read_bytes()).hexdigest()
    if sdk == "iphonesimulator":
        # iSH's host C runtime and FFmpeg must be compiled for the simulator SDK.
        # Guest architecture stays aarch64; it is unrelated to the SDK platform.
        for name in ("build_lame.sh", "build_ffmpeg.sh", "build_ish.sh"):
            file = root / "deps" / name
            code = file.read_text()
            code = code.replace("--sdk iphoneos", "--sdk iphonesimulator")
            code = code.replace("-miphoneos-version-min=$IOS_DEPLOYMENT_TARGET", "-target arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator")
            code = code.replace("-fembed-bitcode", "")
            if name == "build_lame.sh":
                # Upstream includes timestamped object files; force recompilation
                # so make cannot reuse device objects in the simulator archive.
                code = code.replace("make -j$(sysctl -n hw.ncpu)", "make clean\nmake -j$(sysctl -n hw.ncpu)")
            # Meson's generated compiler argument is single-quoted.
            # Shell double quotes expand this target before writing the cross file.
            code = code.replace("'-target arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator'", "'-target', 'arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator'")
            code = code.replace("<string>iPhoneOS</string>", "<string>iPhoneSimulator</string>")
            file.write_text(code)
    template = root / "src/ios/Configs/ProviderCustomization.xcconfig.example"
    template.with_suffix("").write_text(template.read_text())
    # The upstream scheme also builds standalone command-line Swift scripts as
    # part of MinisTests. Reference rendering uses its unchanged MinisUITests;
    # select that target in the CI scheme rather than editing any test source.
    scheme = root / "src/ios/Minis.xcodeproj/xcshareddata/xcschemes/Minis.xcscheme"
    document = ET.parse(scheme)
    testables = document.getroot().find("TestAction/Testables")
    if testables is None:
        raise RuntimeError("The original test scheme has no test targets")
    for test in list(testables):
        reference = test.find("BuildableReference")
        if reference is None or reference.get("BlueprintName") != "MinisUITests":
            testables.remove(test)
    scheme.write_text(ET.tostring(document.getroot(), encoding="unicode"))
    # Upstream ships the original renderer harness and its UI tests, but its
    # App entry does not route the tests' launch flag to that harness. Wire only
    # that Debug entry point; normal launches still show the stock ContentView.
    app = root / "src/ios/MinisApp.swift"
    code = app.read_text()
    anchor = "                ContentView()"
    if code.count(anchor) != 1:
        raise RuntimeError("Original app entry anchor changed")
    code = code.replace(anchor, "                OpenMinisReferenceRoot()")
    code += '''
// Reference-test entry only; both branches use untouched upstream views.
private struct OpenMinisReferenceRoot: View {
    @ViewBuilder var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitest-message-list") {
            MessageListTestView()
        } else { ContentView() }
        #else
        ContentView()
        #endif
    }
}
'''
    app.write_text(code)
    return {"repository": expected["repository"], "commit": actual, "sdk": sdk,
            "applicationFilesSHA256": manifest,
            "testEntryAdapters": {"src/ios/MinisApp.swift": hashlib.sha256(app.read_bytes()).hexdigest()}}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("checkout", type=Path)
    parser.add_argument("--sdk", choices=("iphoneos", "iphonesimulator"), required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()
    report = prepare(args.checkout.resolve(), args.sdk)
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(json.dumps(report, ensure_ascii=False, indent=2))
