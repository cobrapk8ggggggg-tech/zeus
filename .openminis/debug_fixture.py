"""Non-visual DEBUG hooks for deterministic isolated simulator captures.

Route through the actual in-app deep-link router (simctl openurl can display an
iOS 'Open in app?' alert). Wait for the real provider DB adoption before fixtures
create providers. No Release RPC or replacement view is introduced.
"""
from pathlib import Path


def prepare_fixture(root: Path):
    source = root / "src/ios"
    provider = source / "Providers/ProviderConfigStore.swift"
    code = provider.read_text()
    if "zeusFixtureLoadFinished" not in code:
        code = code.replace("    init() {", "    private(set) var zeusFixtureLoadFinished = false\n\n    init() {", 1)
        code = code.replace("    private func adoptDB(_ db: ProviderConfigDB?) async {", "    private func adoptDB(_ db: ProviderConfigDB?) async {\n        defer { zeusFixtureLoadFinished = true }", 1)
        provider.write_text(code)
    rpc = source / "Debug/DebugJSONRPC.swift"
    code = rpc.read_text()
    if 'case "debug.fixture.route":' not in code:
        code = code.replace('        case "rpc.discover":', '''        case "debug.fixture.providerReady":
            guard CommandLine.arguments.contains("--zeus-native-fixture") else { throw RPCError(code: -32601, message: "Fixture launch required") }
            return await MainActor.run { ["ready": ProviderConfigStore.shared.zeusFixtureLoadFinished] }
        case "debug.fixture.route":
            guard CommandLine.arguments.contains("--zeus-native-fixture"),
                  let raw = params["url"] as? String, let url = URL(string: raw), url.scheme == "minis" else { throw RPCError(code: -32602, message: "Fixture launch and internal route required") }
            await MainActor.run { DeepLinkRouter.handle(url: url, shareCoordinator: ShareCoordinator.shared) }
            return ["routed": true]
        case "rpc.discover":''', 1)
        rpc.write_text(code)
    return [provider, rpc]
