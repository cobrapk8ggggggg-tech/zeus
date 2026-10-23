import XCTest
import WebKit
@testable import ZEUSBrowser
@testable import Minis

@MainActor
final class NativeBrowserIntegrationTests: XCTestCase {
    func testInspectorRunsAgainstRealDOMAndOriginStorage() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        let loader = NativeInspectorFixture()
        try await loader.load("<main id='chapter' style='color:rgb(0,0,0)'>Real chapter text</main>", view: view)
        let dom = try await NativeBrowserInspector.execute("browser_dom", args: ["selector": "#chapter"], view: view)
        XCTAssertTrue(dom.contains("Real chapter text"))
        let evaluated = try await NativeBrowserInspector.execute("browser_evaluate", args: ["code": "document.querySelector('#chapter').textContent='Changed by real JavaScript'; return document.querySelector('#chapter').textContent"], view: view)
        XCTAssertTrue(evaluated.contains("Changed by real JavaScript"))
        _ = try await NativeBrowserInspector.execute("browser_storage", args: ["area": "local", "action": "set", "key": "chapter", "value": "42"], view: view)
        let stored = try await NativeBrowserInspector.execute("browser_storage", args: ["area": "local", "action": "read", "key": "chapter"], view: view)
        XCTAssertTrue(stored.contains("42"))
        _ = try await NativeBrowserInspector.execute("browser_storage", args: ["area": "local", "action": "remove", "key": "chapter"], view: view)
        let empty = try await NativeBrowserInspector.execute("browser_storage", args: ["area": "local", "action": "read", "key": "chapter"], view: view)
        XCTAssertFalse(empty.contains("42"))
    }
    func testInspectorCookiesIncludeHttpOnlyButStayWithinTheSelectedSite() async throws {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        let loader = NativeInspectorFixture()
        try await loader.load("<main>Cookie fixture</main>", view: view)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "example.com", .path: "/", .name: "fixture-session", .value: "fixture-only", HTTPCookiePropertyKey("HttpOnly"): "TRUE"]))
        let other = try XCTUnwrap(HTTPCookie(properties: [.domain: "unrelated.invalid", .path: "/", .name: "unrelated-session", .value: "must-not-leak"]))
        for item in [cookie, other] { await withCheckedContinuation { c in config.websiteDataStore.httpCookieStore.setCookie(item) { c.resume() } } }
        let result = try await NativeBrowserInspector.execute("browser_cookies", args: ["action": "list"], view: view)
        XCTAssertTrue(result.contains("fixture-only"))
        XCTAssertTrue(result.contains("\"httpOnly\":true"))
        XCTAssertFalse(result.contains("must-not-leak"))
        _ = try await NativeBrowserInspector.execute("browser_cookies", args: ["action": "delete", "name": "fixture-session"], view: view)
        let after = try await NativeBrowserInspector.execute("browser_cookies", args: ["action": "list"], view: view)
        XCTAssertFalse(after.contains("fixture-only"))
    }
    func testBackupReaderAcceptsValidBackupWithoutJSONExtensionAndRejectsInvalidFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("My browser.backup")
        var data = ProfileData()
        data.tabs = [SavedTab(title: "Restored chapter", url: "https://example.com/chapter")]
        try JSONEncoder().encode(ProfileBackup(name: "Source", data: data)).write(to: file)
        let backup = try await BackupFileReader.load(file)
        XCTAssertEqual(backup.data.tabs.first?.title, "Restored chapter")
        try Data("not a browser backup".utf8).write(to: file)
        do { _ = try await BackupFileReader.load(file); XCTFail("Invalid input must not be accepted") } catch {}
        try Data(repeating: 32, count: BackupFileReader.maximumBytes + 1).write(to: file)
        do { _ = try await BackupFileReader.load(file); XCTFail("Oversized input must not be loaded") } catch {
            XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum)
        }
    }
    func testBackupRestoresLiveTabOrderGroupsSelectionAndScrollAfterRelaunch() throws {
        let (browser, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        var source = ProfileData()
        let group = TabGroup(name: "Research", color: "FFD700", collapsed: true)
        source.tabs = [SavedTab(title: "One", url: "https://example.com/one", groupID: group.id),
                       SavedTab(title: "Two", url: "https://example.com/two")]
        source.selectedTabID = source.tabs[1].id
        source.tabGroups = [group]
        source.tabScrollOffsets = ["icab-strip": 420]
        source.history = [Visit(title: "Chapter", url: "https://example.com/chapter")]
        source.scripts = [BrowserScript(name: "Imported script", domain: "example.com", code: "void 0", isActive: true)]
        let merged = try ProfileBackup(name: "Source", data: source).merged(into: browser.data, importSettings: true, restoreTabs: true)
        try browser.importProfileData(merged, restoreOpenTabs: true)
        XCTAssertEqual(browser.tabs.map(\.id), source.tabs.map(\.id))
        XCTAssertEqual(browser.current?.id, source.selectedTabID)
        XCTAssertEqual(browser.data.tabGroups, source.tabGroups)
        XCTAssertEqual(browser.data.tabScrollOffsets, source.tabScrollOffsets)
        XCTAssertFalse(try XCTUnwrap(browser.data.scripts.first).isActive)
        let reloaded = BrowserModel(profiles: browser.profiles, useBackgroundDownloads: false)
        XCTAssertEqual(reloaded.tabs.map(\.id), source.tabs.map(\.id))
        XCTAssertEqual(reloaded.current?.id, source.selectedTabID)
        XCTAssertEqual(reloaded.data.history.first?.url, source.history.first?.url)
    }
    func testFailedBackupWritePreservesLiveBrowserSession() throws {
        let (browser, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalIDs = browser.tabs.map(\.id)
        let folder = browser.profiles.folder(for: browser.profile)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A directory in place of the data file reliably fails atomic writes.
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("browser.json"), withIntermediateDirectories: true)
        var imported = ProfileData()
        imported.tabs = [SavedTab(title: "Must not replace live tab", url: "https://example.com")]
        XCTAssertThrowsError(try browser.importProfileData(imported, restoreOpenTabs: true))
        XCTAssertEqual(browser.tabs.map(\.id), originalIDs)
    }
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

@MainActor private final class NativeInspectorFixture: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var watchdog: Task<Void, Never>?
    func load(_ html: String, view: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            view.navigationDelegate = self
            watchdog = Task { @MainActor [weak self, weak view] in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                view?.stopLoading(); self?.finish(URLError(.timedOut))
            }
            view.loadHTMLString(html, baseURL: URL(string: "https://example.com"))
        }
    }
    private func finish(_ error: Error? = nil) {
        watchdog?.cancel(); watchdog = nil
        let answer = continuation; continuation = nil
        if let error { answer?.resume(throwing: error) } else { answer?.resume() }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
}
