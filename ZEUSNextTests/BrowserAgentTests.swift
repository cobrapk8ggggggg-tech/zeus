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
}
