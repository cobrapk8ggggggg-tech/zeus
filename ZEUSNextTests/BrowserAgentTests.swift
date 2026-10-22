import XCTest
import WebKit
@testable import ZEUSNext

@MainActor final class BrowserAgentTests: XCTestCase {
    private func model() -> (BrowserModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = BrowserModel(profiles: ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("Downloads")), useBackgroundDownloads: false)
        var provider = AIProviderConfiguration(); provider.baseURL = "http://127.0.0.1:8765/v1"; provider.model = "fixture-agent"; provider.name = "Fixture"
        model.data.settings.aiProviders = [provider]
        return (model, root)
    }
    private func waitUntil(_ condition: () -> Bool, seconds: Double = 25) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(80)) }
        XCTAssertTrue(condition())
    }
    func testRealToolRoundWaitsForApprovalNavigatesAndFeedsResultBack() async throws {
        let (model, root) = model(); defer { try? FileManager.default.removeItem(at: root) }
        let agent = BrowserAgent(browser: model); agent.approveContext(); agent.inputText = "Open fixture"; agent.send()
        try await waitUntil { agent.approval != nil }
        XCTAssertEqual(model.tabs.count, 1, "The tool must not navigate before approval")
        XCTAssertEqual(agent.approval?.call.name, "browser_open")
        agent.answerApproval(true, always: true)
        try await waitUntil { !agent.isProcessing }
        XCTAssertEqual(model.tabs.count, 2)
        XCTAssertTrue(model.current?.url.contains("translate-fixture") == true)
        XCTAssertTrue(agent.messages.last?.blocks.contains(where: { $0.toolStatus == .success }) == true)
        XCTAssertTrue(agent.messages.last?.blocks.contains(where: { $0.content.contains("Agent completed") }) == true)
        let restored = BrowserAgent(browser: model)
        XCTAssertTrue(restored.preferences.grants.contains("browser_open:127.0.0.1"))
        XCTAssertEqual(restored.sessions.count, 1)
    }
    func testCancelWhileApprovalPendingDoesNotExecuteTool() async throws {
        let (model, root) = model(); defer { try? FileManager.default.removeItem(at: root) }
        let agent = BrowserAgent(browser: model); agent.approveContext(); agent.inputText = "Open fixture"; agent.send()
        try await waitUntil { agent.approval != nil }
        agent.cancel(); agent.answerApproval(true)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(agent.approval); XCTAssertFalse(agent.isProcessing); XCTAssertEqual(model.tabs.count, 1)
    }
    func testContextAndSessionsAreSeparateBetweenProfilesAndScrollPositionsPersist() async throws {
        let (model, root) = model(); defer { try? FileManager.default.removeItem(at: root) }
        let original = model.profile
        let agent = BrowserAgent(browser: model); agent.newSession(); agent.preferences.memory = "A private note"; agent.save()
        model.data.tabScrollOffsets = ["icab": 1200, "original": 600, "tabs-dualBars": 300]; model.persist()
        let second = model.profiles.add(name: "Second", accent: "cyan", isPrivate: false)
        await model.switchProfile(to: second)
        let other = BrowserAgent(browser: model)
        XCTAssertEqual(other.preferences.memory, ""); XCTAssertTrue(other.sessions.isEmpty); XCTAssertNil(model.data.tabScrollOffsets)
        await model.switchProfile(to: original)
        XCTAssertEqual(model.data.tabScrollOffsets?["icab"], 1200)
        XCTAssertEqual(BrowserAgent(browser: model).preferences.memory, "A private note")
    }
    func testStructuredAccountToolsRejectUnknownActions() throws {
        XCTAssertThrowsError(try BrowserAgentTransport.parseEnvelope(#"{"tool_calls":[{"name":"shell_root","arguments":{}}]}"#))
        let reply = try BrowserAgentTransport.parseEnvelope(#"{"tool_calls":[{"name":"browser_tabs","arguments":{}}]}"#)
        XCTAssertEqual(reply.calls.first?.name, "browser_tabs")
        XCTAssertEqual(try BrowserAgentTransport.parseEnvelope("Example [[ZEUS_OPEN:https://example.com]]").calls.count, 0)
    }
    func testNativeMarkdownIncludesRealCodeTableAndMathNodes() {
        let markdown = MarkdownContent("# Title\n\n```swift\nlet x = 1\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n$$x^2$$")
        XCTAssertTrue(markdown.blocks.contains { if case .codeBlock = $0 { return true }; return false })
        XCTAssertTrue(markdown.blocks.contains { if case .table = $0 { return true }; return false })
        XCTAssertTrue(markdown.blocks.contains { if case .mathBlock = $0 { return true }; return false })
    }
    func testDeletingOneTranslationKeepsOtherSavedTranslations() async throws {
        let (_, root) = model(); defer { try? FileManager.default.removeItem(at: root) }
        let saved = await TranslationMemory.shared.save(["one": "الأولى", "two": "الثانية"], namespace: "test", folder: root)
        XCTAssertTrue(saved)
        let entries = await TranslationMemory.shared.entries(folder: root)
        XCTAssertEqual(entries.count, 2)
        await TranslationMemory.shared.remove(keys: [try XCTUnwrap(entries.first?.id)], folder: root)
        let remaining = await TranslationMemory.shared.entries(folder: root)
        XCTAssertEqual(remaining.count, 1)
    }
    func testPageReadNeverIncludesPasswordValueOrHiddenFields() async throws {
        let (model, root) = model(); defer { try? FileManager.default.removeItem(at: root) }
        let current = try XCTUnwrap(model.current)
        let prepared = await model.prepare(current)
        let view = try XCTUnwrap(prepared)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); let controller = UIViewController(); window.rootViewController = controller; window.frame = scene.screen.bounds; view.frame = window.bounds; controller.view.addSubview(view); window.makeKeyAndVisible()
        defer { window.isHidden = true }
        view.loadHTMLString("<html><body><p>Visible chapter</p><input type='password' value='never-share-this'><input type='hidden' value='hidden-token'><textarea>private draft</textarea></body></html>", baseURL: URL(string: "https://example.test"))
        try await waitUntil { !view.isLoading }
        try await Task.sleep(for: .milliseconds(300))
        let result = try await view.callAsyncJavaScript(BrowserAgent.readScript, arguments: ["full": true], in: nil, contentWorld: .world(name: "ZEUSAgent"))
        let text = String(decoding: try JSONSerialization.data(withJSONObject: result ?? [:]), as: UTF8.self)
        XCTAssertTrue(text.contains("Visible chapter")); XCTAssertFalse(text.contains("never-share-this")); XCTAssertFalse(text.contains("hidden-token")); XCTAssertFalse(text.contains("private draft"))
    }
    func testDeletingOneSitesCookiesKeepsAnotherSitesSession() async throws {
        let (model, root) = model(); defer { try? FileManager.default.removeItem(at: root) }
        let store = model.profiles.websiteDataStore(for: model.profile)
        let one = try XCTUnwrap(HTTPCookie(properties: [.domain: "first.test", .path: "/", .name: "session", .value: "one"]))
        let two = try XCTUnwrap(HTTPCookie(properties: [.domain: "second.test", .path: "/", .name: "session", .value: "two"]))
        await store.httpCookieStore.setCookie(one); await store.httpCookieStore.setCookie(two)
        let context = ProfileSettingsContext(model: model, profile: model.profile)
        let controller = WebsiteStorageController(context: context)
        await controller.refresh()
        let first = try XCTUnwrap(controller.sites.first { $0.id == "first.test" })
        await controller.remove(first, types: [WKWebsiteDataTypeCookies])
        let remaining = await store.httpCookieStore.allCookies()
        XCTAssertFalse(remaining.contains { $0.domain == "first.test" })
        XCTAssertTrue(remaining.contains { $0.domain == "second.test" && $0.value == "two" })
    }
}
