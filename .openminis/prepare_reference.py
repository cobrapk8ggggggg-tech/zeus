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


def prepare(root: Path, sdk: str) -> dict:
    expected = json.loads((Path(__file__).parent / "source.lock.json").read_text())
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    if actual != expected["commit"]:
        raise RuntimeError(f"Source revision mismatch: {actual}")
    manifest = {}
    for base in ("src/ios/Views", "src/ios/Agent", "src/ios/Providers", "src/ios/Shared"):
        for file in sorted((root / base).rglob("*")):
            if file.is_file():
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
            code = code.replace("'-miphoneos-version-min=$IOS_DEPLOYMENT_TARGET'", "'-target', 'arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator'")
            code = code.replace("' -target", "'-target")
            # Shell double quotes expand this target before writing the cross file.
            code = code.replace("'-target arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator'", "'-target', 'arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator'")
            code = code.replace("<string>iPhoneOS</string>", "<string>iPhoneSimulator</string>")
            file.write_text(code)
    template = root / "src/ios/Configs/ProviderCustomization.xcconfig.example"
    template.with_suffix("").write_text(template.read_text())
    return {"repository": expected["repository"], "commit": actual, "sdk": sdk,
            "applicationFilesSHA256": manifest}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("checkout", type=Path)
    parser.add_argument("--sdk", choices=("iphoneos", "iphonesimulator"), required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()
    report = prepare(args.checkout.resolve(), args.sdk)
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(json.dumps(report, ensure_ascii=False, indent=2))
