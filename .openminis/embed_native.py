"""Apply the declared host adapters to a separate pinned native checkout.

Apply only after the stock reference has been captured and verified, or in a
separate checkout. No chat/message/provider view is replaced, and no renderer,
transport or agent loop is reconstructed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def replace(file, before, after, count=1):
    text = file.read_text()
    if text.count(before) != count:
        raise RuntimeError(f"Upstream adapter anchor changed: {file}: {before[:80]}")
    file.write_text(text.replace(before, after))


def embed(native, browser, report):
    lock = json.loads((browser / ".openminis/source.lock.json").read_text())
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=native, text=True).strip()
    if revision != lock["commit"]:
        raise RuntimeError("Wrong native source revision")
    source = native / "src/ios"
    app = source / "MinisApp.swift"
    if "private struct OpenMinisReferenceRoot: View" in app.read_text():
        app.write_bytes(subprocess.check_output(["git", "show", revision + ":src/ios/MinisApp.swift"], cwd=native))
    before = {str(f.relative_to(source)): hashlib.sha256(f.read_bytes()).hexdigest()
              for f in source.rglob("*.swift")}
    generated = browser / ".openminis/build"
    generated.mkdir(parents=True, exist_ok=True)

    # The application remains OpenMinis' original @main/AppDelegate/root setup;
    # its root content now embeds the browser with the original AI UI alongside.
    replace(source / "MinisApp.swift", "                ContentView()", "                ZEUSBrowserRootEntry()")
    shutil.copyfile(browser / ".openminis/Host/ZEUSNativeIntegration.swift", source / "ZEUSNativeIntegration.swift")
    # Reuse the exact native settings sheet from the browser's AI settings row.
    # Only its file-private visibility changes; its body is untouched.
    replace(source / "Views/ContentView.swift", "private struct SettingsSheet: View", "struct SettingsSheet: View")
    # A compiler boundary around the unchanged native geometry expression.
    # The original giant modifier chain hit the type-checker limit in the
    # embedded target. No view, modifier or state is replaced or reordered.
    replace(source / "Views/ContentView.swift",
            "    private static let pendingBackgroundNavigationTTL: TimeInterval = 90\n\n    var body: some View {\n        GeometryReader { geo in",
            "    private static let pendingBackgroundNavigationTTL: TimeInterval = 90\n\n    private var zeusNativeGeometry: some View {\n        GeometryReader { geo in")
    replace(source / "Views/ContentView.swift",
            "        }\n        .onReceive(\n            NotificationCenter.default.publisher(for: .sessionDidCreate),",
            "        }\n    }\n\n    var body: some View {\n        zeusNativeGeometry\n        .onReceive(\n            NotificationCenter.default.publisher(for: .sessionDidCreate),")
    replace(source / "Views/ContentView.swift", "    var body: some View {\n        zeusNativeGeometry",
            "    private var zeusNativeIncoming: some View {\n        zeusNativeGeometry")
    for anchor, name, previous in [
        ("        .fullScreenCover(isPresented: $showTerminal) {", "zeusNativePresentations", "zeusNativeIncoming"),
        ("        .onReceive(NotificationCenter.default.publisher(for: .cloudSyncDidFetchChanges)) { _ in", "zeusNativeSessionLifecycle", "zeusNativePresentations"),
        ("        .onChange(of: shareCoordinator.hasPendingShare) { hasPending in", "body", "zeusNativeSessionLifecycle")
    ]:
        declaration = "    var body: some View {" if name == "body" else "    private var " + name + ": some View {"
        replace(source / "Views/ContentView.swift", anchor, "    }\n\n" + declaration + "\n        " + previous + "\n" + anchor)

    definitions = source / "Agent/Chat/AIChatViewModel+ToolDefinitions.swift"
    replace(definitions, "        return tools", "        tools.append(ZEUSNativeAgentBridge.definition)\n        return tools")
    replace(definitions, 'description: "Control a web browser with up to 3 tabs.',
            'description: "This is the standalone OpenMinis automation browser, separate from the user\'s ZEUS tabs and browser profile. For the user\'s current page, existing tabs, cookies, storage or navigation use zeus_browser instead. Control a web browser with up to 3 tabs.')
    execution = source / "Agent/Chat/AIChatViewModel+ConcurrentTools.swift"
    text = execution.read_text()
    anchor = '        case "browser_use":'
    parts = text.split(anchor)
    if len(parts) < 2:
        raise RuntimeError("Original browser tool dispatch was not found")
    adapter = '''        case "zeus_browser":
            let result = try await ZEUSNativeAgentBridge.shared.execute(argsJson, sessionID: sessionId)
            toolOutput = result.text
            toolSuccess = true
            if let path = result.imagePath {
                toolImageData = try await Task.detached(priority: .utility) { try Data(contentsOf: URL(fileURLWithPath: path)) }.value
                toolImageMimeType = "image/jpeg"
                if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                    messages[msgIdx].blocks[blockIdx].imageFilePath = path
                }
            }

'''
    execution.write_text(parts[0] + adapter + anchor + parts[1] + ''.join('        case "browser_use", "zeus_browser":' + p for p in parts[2:]))
    stream = source / "Agent/Chat/AIChatViewModel+SSEStream.swift"
    text = stream.read_text()
    if 'case "browser_use":' not in text:
        raise RuntimeError("Original browser card mapping was not found")
    text = text.replace('case "browser_use":', 'case "browser_use", "zeus_browser":')
    # Preserve the original card/preview renderer, supplying its native action
    # field from the added browser tool's operation field.
    text = text.replace('extractPartialStringValue("action", from: accumulated)',
                        'extractPartialStringValue(name == "zeus_browser" ? "operation" : "action", from: accumulated)')
    text = text.replace('extractPartialStringValue("action", from: json)',
                        'extractPartialStringValue(name == "zeus_browser" ? "operation" : "action", from: json)')
    text = text.replace('args["action"] as? String', '(args["action"] as? String ?? args["operation"] as? String)')
    stream.write_text(text)

    # Original permission UI, with host-specific labels and an additional Always
    # action only for the new browser operations. All original tool dialogs keep
    # their original controls and semantics.
    permissions = source / "Agent/Offload/OffloadPermissionManager.swift"
    replace(permissions, "    let continuation: CheckedContinuation<Bool, Never>",
            "    let continuation: CheckedContinuation<Bool, Never>\n    var permitsPersistentGrant = false")
    replace(permissions, 'fullCommand: String = "") async -> PermissionResult',
            'fullCommand: String = "", requestLabel: String? = nil, requestDescription: String? = nil, permitsPersistentGrant: Bool = false) async -> PermissionResult')
    replace(permissions, 'let displayLabel = cmdInfo?.displayLabel ?? command', 'let displayLabel = requestLabel ?? cmdInfo?.displayLabel ?? command')
    replace(permissions, 'let description = cmdInfo?.description ?? ""', 'let description = requestDescription ?? cmdInfo?.description ?? ""')
    replace(permissions, 'continuation: continuation\n', 'continuation: continuation,\n                    permitsPersistentGrant: permitsPersistentGrant\n')
    dialog = source / "Views/Chat/OffloadPermissionDialog.swift"
    replace(dialog, 'Text("The agent wants to use **\\(request.commandName)**")',
            'Text("The agent wants to use **\\(request.commandName.hasPrefix("zeus-browser/") ? request.displayLabel : request.commandName)**")')
    replace(dialog, 'Text("Allow in Session")', 'Text(request.commandName.hasPrefix("zeus-browser/") ? "السماح هذه المرة" : String(localized: "Allow in Session"))')
    marker = '''                Button {
                    OffloadPermissionManager.shared.respond(to: request.id, allowed: false)'''
    addition = '''                if request.commandName.hasPrefix("zeus-browser/"), request.permitsPersistentGrant {
                    Button {
                        OffloadPermissionManager.shared.setPermissionLevel(.bypass, for: request.commandName)
                        OffloadPermissionManager.shared.respond(to: request.id, allowed: true)
                    } label: {
                        Text("السماح دائمًا لهذا الإجراء على هذا الموقع")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }.buttonStyle(.borderedProminent).tint(.blue)
                }

'''
    replace(dialog, marker, addition + marker)

    # Separate identity from a separately installed OpenMinis. Conversations,
    # providers, skills and memory intentionally remain GLOBAL inside ZEUS.
    for file in source.rglob("*"):
        if file.suffix in (".swift", ".m", ".mm", ".h", ".entitlements"):
            text = file.read_text()
            changed = text.replace("group.com.openminis.app", "group.tools.zeus.openminis").replace("iCloud.com.openminis.app", "iCloud.tools.zeus.openminis")
            if text != changed:
                file.write_text(changed)

    original_app = (browser / "ZEUSNext/ZEUSNextApp.swift").read_text()
    (generated / "BrowserAppDelegate.swift").write_text(original_app[:original_app.index("@main struct")])
    start = original_app.index("    init() {", original_app.index("@main struct"))
    end = original_app.index("    var body: some Scene", start)
    factory = original_app[start:end].replace("    init() {", "    static func make() -> BrowserModel {")
    factory = factory.replace("_browser = StateObject(wrappedValue: model)", "return model").replace("_browser = StateObject(wrappedValue: BrowserModel())", "return BrowserModel()")
    (generated / "BrowserFixtureFactory.swift").write_text("import SwiftUI\n@MainActor enum BrowserFixtureFactory {\n" + factory + "}\n")

    changed = []
    for name, digest in before.items():
        file = source / name
        after = hashlib.sha256(file.read_bytes()).hexdigest()
        if digest != after:
            changed.append({"file": name, "before": digest, "after": after})
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps({"sourceCommit": revision, "source": lock["repository"],
        "sharedAcrossProfiles": ["conversations", "providers", "models", "memory", "skills", "agentSettings"],
        "browserIsolation": "Website data stores remain per profile. Old tool contexts are invalidated on switch.",
        "modifiedNativeFiles": changed, "nativeSwiftFiles": len(before),
        "unchangedNativeSwiftFiles": len(before) - len(changed)}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("native", type=Path)
    parser.add_argument("browser", type=Path)
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    embed(args.native.resolve(), args.browser.resolve(), args.report.resolve())
