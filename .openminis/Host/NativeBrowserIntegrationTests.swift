import XCTest
@testable import ZEUSBrowser
@testable import Minis

@MainActor
final class NativeBrowserIntegrationTests: XCTestCase {
    private func model() -> (BrowserModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (BrowserModel(profiles: ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("Downloads")), useBackgroundDownloads: false), root)
    }
    func testOriginalChatDatabaseAndProvidersRemainSharedAfterProfileSwitch() async throws {
        let (browser, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = await ChatStore.shared.createSession(modelId: "integration-reference", title: "Shared across browser profiles")
        let providers = ProviderConfigStore.shared
        let firstStore = browser.profiles.websiteDataStore(for: browser.profile)
        let second = browser.profiles.add(name: "Second", accent: "white", isPrivate: false)
        await browser.switchProfile(to: second)
        let sessions = await ChatStore.shared.listSessions()
        XCTAssertTrue(sessions.contains { $0.id == chat.id })
        XCTAssertTrue(providers === ProviderConfigStore.shared)
        XCTAssertFalse(firstStore === browser.profiles.websiteDataStore(for: browser.profile))
        await ChatStore.shared.deleteSession(chat.id)
    }
    func testRealTabToolUsesCurrentBrowserAndDoesNotCreateChatArchive() async throws {
        let (browser, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        browser.current?.title = "A real browser tab"
        let bridge = NativeBrowserSession(browser: browser)
        var requests = 0
        bridge.authorization = { _ in requests += 1; return true }
        let result = try await bridge.execute(operation: "browser_tabs", arguments: "{}", sessionID: nil)
        XCTAssertTrue(result.text.contains("A real browser tab"))
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: browser.profiles.folder(for: browser.profile).appendingPathComponent("OpenMinis/agent.json").path))
    }
    func testDenialPreventsNavigation() async throws {
        let (browser, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = NativeBrowserSession(browser: browser)
        bridge.authorization = { _ in false }
        do {
            _ = try await bridge.execute(operation: "browser_open", arguments: #"{"url":"https://example.com"}"#, sessionID: nil)
            XCTFail("Denied navigation must throw")
        } catch {}
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertTrue(browser.current?.isHome == true)
    }
    func testSwitchInvalidatesAnApprovalThatWasAlreadyPending() async throws {
        let (browser, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = NativeBrowserSession(browser: browser)
        browser.agent = bridge
        var answer: CheckedContinuation<Bool, Never>?
        let waiting = expectation(description: "Real tool awaiting authorization")
        bridge.authorization = { _ in
            await withCheckedContinuation { continuation in answer = continuation; waiting.fulfill() }
        }
        let call = Task {
            try await bridge.execute(operation: "browser_open", arguments: #"{"url":"https://example.com"}"#, sessionID: nil)
        }
        await fulfillment(of: [waiting], timeout: 5)
        let second = browser.profiles.add(name: "Second", accent: "white", isPrivate: false)
        await browser.switchProfile(to: second)
        answer?.resume(returning: true)
        do { _ = try await call.value; XCTFail("The old profile must not navigate after a switch") } catch {}
        XCTAssertEqual(browser.profile.id, second.id)
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertTrue(browser.current?.isHome == true)
    }
}
