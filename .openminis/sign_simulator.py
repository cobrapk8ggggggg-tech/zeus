"""Ad-hoc sign the simulator host so its real Security/Keychain APIs work.

Device IPAs remain unsigned for the user's signing workflow. This grants no
production identity; it only gives the isolated simulator a stable access group.
"""
import argparse
import pathlib
import plistlib
import subprocess
import tempfile


def sign(app):
    # Sign nested code first; each extension gets its own application ID.
    nested = list(app.rglob("*.framework")) + list(app.rglob("*.dylib"))
    for path in sorted(nested, key=lambda p: len(p.parts), reverse=True):
        subprocess.run(["codesign", "--force", "--sign", "-", str(path)], check=True)
    bundles = sorted(app.rglob("*.appex"), key=lambda p: len(p.parts), reverse=True) + [app]
    with tempfile.TemporaryDirectory() as directory:
        path = pathlib.Path(directory) / "simulator.entitlements"
        for bundle in bundles:
            identifier = plistlib.loads((bundle / "Info.plist").read_bytes())["CFBundleIdentifier"]
            identity = "ZEUSCITEST." + identifier
            path.write_bytes(plistlib.dumps({
                "application-identifier": identity,
                "com.apple.developer.team-identifier": "ZEUSCITEST",
                "keychain-access-groups": [identity],
                "get-task-allow": True,
            }))
            subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements", str(path), str(bundle)], check=True)
            print("Signed simulator bundle for real Keychain access:", identifier)
    subprocess.run(["codesign", "--verify", "--deep", str(app)], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=pathlib.Path)
    sign(parser.parse_args().app)
