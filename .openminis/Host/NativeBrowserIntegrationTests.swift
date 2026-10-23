import XCTest
import WebKit
@testable import ZEUSBrowser
@testable import Minis

@MainActor
final class NativeBrowserIntegrationTests: XCTestCase {
    func testProfileSwitchCancelsInlineBrowserApproval() async throws {
        let (browser, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = NativeBrowserSession(browser: browser)
        browser.agent = bridge; ZEUSNativeAgentBridge.shared.bind(bridge)
        let permissions = ZeusToolPermissions.shared, previous = permissions.mode
        permissions.mode = .askAll; defer { permissions.mode = previous }
        let id = UUID()
        let call = Task { try await permissions.authorize(tool: "zeus_browser", args: ["operation": "browser_tabs"], sessionID: "test", blockID: id) }
        while permissions.requests[id] == nil { try await Task.sleep(for: .milliseconds(10)) }
        let second = browser.profiles.add(name: "Second", accent: "white", isPrivate: false)
        await browser.switchProfile(to: second)
        XCTAssertNil(permissions.requests[id])
        do { try await call.value; XCTFail("Old approval must be cancelled immediately") } catch {}
    }
    func testPermissionModesAndConcurrentRequestsStayIndependent() async throws {
        let permissions = ZeusToolPermissions.shared, previous = permissions.mode
        defer { permissions.mode = previous }
        permissions.mode = .consequential
        try await permissions.authorize(tool: "zeus_browser", args: ["operation": "browser_read"], sessionID: "test", blockID: UUID())
        XCTAssertFalse(ZeusToolPermissions.isConsequential(tool: "zeus_browser", args: ["operation": "browser_settings", "action": "read"]))
        XCTAssertTrue(ZeusToolPermissions.isConsequential(tool: "zeus_browser", args: ["operation": "browser_settings", "action": "set"]))
        XCTAssertTrue(ZeusToolPermissions.isConsequential(tool: "shell_execute", args: ["command": "rm file"]))
        permissions.mode = .askAll
        let first = UUID(), second = UUID()
        let a = Task { try await permissions.authorize(tool: "file_read", args: [:], sessionID: "test", blockID: first) }
        let b = Task { try await permissions.authorize(tool: "file_read", args: [:], sessionID: "test", blockID: second) }
        while permissions.requests.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        permissions.respond(first, allowed: false)
        XCTAssertNotNil(permissions.requests[second])
        permissions.respond(second, allowed: true)
        do { try await a.value; XCTFail("Denied call must not execute") } catch {}
        try await b.value
        permissions.mode = .unrestricted
        try await permissions.authorize(tool: "shell_execute", args: ["command": "true"], sessionID: "test", blockID: UUID())
        XCTAssertTrue(permissions.requests.isEmpty)
    }
    func testBrowserToolAcceptsFlatAndLegacyObjectsAndRejectsInvalidFields() throws {
        let open = try XCTUnwrap(ZEUSNativeAgentBridge.definitions.first { $0.name == "zeus_browser_open" })
        XCTAssertTrue(open.required.contains("url"))
        XCTAssertNil(open.parameters["operation"])
        XCTAssertNil(open.parameters["arguments"])
        XCTAssertNil(AIChatViewModel.preflightValidateToolCall(name: "zeus_browser_type", args: ["tab_id": UUID().uuidString, "element_id": "e1", "text": ""], tools: ZEUSNativeAgentBridge.definitions))
        let storage = try XCTUnwrap(ZEUSNativeAgentBridge.definitions.first { $0.name == "zeus_browser_storage" })
        XCTAssertEqual(storage.parameters["action"]?.enumValues, ["read", "set", "remove", "clear"])
        XCTAssertEqual(try ZEUSNativeAgentBridge.normalizedInput(["url": "https://example.com"], toolName: "zeus_browser_open").0, "browser_open")
        let flat = try ZEUSNativeAgentBridge.normalizedInput(["operation": "browser_open", "url": "https://example.com", "new_tab": "false"])
        XCTAssertEqual(flat.0, "browser_open")
        XCTAssertTrue(flat.1.contains("false"))
        let legacy = try ZEUSNativeAgentBridge.normalizedInput(["operation": "browser_open", "arguments": ["url": "https://example.com", "new_tab": false]])
        XCTAssertEqual(flat.1, legacy.1)
        XCTAssertThrowsError(try ZEUSNativeAgentBridge.normalizedInput(["operation": "browser_open"]))
        XCTAssertThrowsError(try ZEUSNativeAgentBridge.normalizedInput(["operation": "browser_read", "selector_typo": "a"]))
        XCTAssertThrowsError(try ZEUSNativeAgentBridge.normalizedInput(["operation": "browser_cookies", "action": "removeAll"]))
        XCTAssertThrowsError(try ZEUSNativeAgentBridge.normalizedInput(["operation": "browser_open", "url": "https://a.test", "arguments": ["url": "https://b.test"]]))
    }
    func testParallelBrowserCallsAreSerializedRatherThanRandomlyRejected() async throws {
        let (browser, root) = model(); defer { try? FileManager.default.removeItem(at: root) }
        let bridge = NativeBrowserSession(browser: browser)
        bridge.authorization = { _ in try? await Task.sleep(for: .milliseconds(50)); return true }
        async let first = bridge.execute(operation: "browser_tabs", arguments: "{}", sessionID: nil)
        async let second = bridge.execute(operation: "browser_tabs", arguments: "{}", sessionID: nil)
        let results = try await [first, second]
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.text.contains("tab_id=") })
    }
    func testSettingsToolsPersistRealSettingsAndValidateBeforeWriting() async throws {
        let (browser, root) = model(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await NativeBrowserControl.execute("browser_settings", args: ["action": "set", "key": "shieldsEnabled", "value": "false"], browser: browser)
        XCTAssertFalse(browser.data.settings.shieldsEnabled)
        XCTAssertFalse(browser.profiles.load(browser.profile).settings.shieldsEnabled)
        do { _ = try await NativeBrowserControl.execute("browser_settings", args: ["action": "set", "key": "textScale", "value": "99"], browser: browser); XCTFail("Invalid value accepted") } catch {}
        XCTAssertEqual(browser.data.settings.textScale, 1)
        let read = try await NativeBrowserControl.execute("browser_settings", args: ["action": "read"], browser: browser)
        XCTAssertTrue(read.contains("advanced.forceDarkWebPages"))
        _ = try await NativeBrowserControl.execute("browser_settings", args: ["action": "set", "key": "reading.backgroundHex", "value": "\"141414\""], browser: browser)
        XCTAssertEqual(browser.data.settings.reading?.backgroundHex, "141414")
        _ = try await NativeBrowserControl.execute("browser_settings", args: ["action": "set", "key": "reading.backgroundHex", "value": "null"], browser: browser)
        XCTAssertNil(browser.data.settings.reading?.backgroundHex)
        let help = try await NativeBrowserControl.execute("browser_help", args: [:], browser: browser)
        XCTAssertTrue(help.contains("assistantButton")); XCTAssertTrue(help.contains("twinHorizontal"))
        _ = try await NativeBrowserControl.execute("browser_profiles", args: ["action": "create", "name": "Agent created"], browser: browser)
        let target = try XCTUnwrap(browser.profiles.profiles.first { $0.name == "Agent created" })
        _ = try await NativeBrowserControl.execute("browser_profiles", args: ["action": "update", "profile_id": target.id.uuidString, "key": "name", "value": "\"Updated profile\""], browser: browser)
        XCTAssertEqual(browser.profiles.profile(target.id)?.name, "Updated profile")
    }
    func testOriginalAgentTransportStreamsLongUnicodeAnswerWithoutDroppingTheTail() async throws {
        let model = LLMModel(id: "fixture-native-stream", displayName: "Native stream fixture", provider: "openai")
        let transport = OpenAIProvider(apiKey: "local-fixture-only", model: model, customBaseURL: "http://127.0.0.1:8765/v1", appendV1Suffix: false)
        let provider = OpenAIAgentProvider(provider: transport)
        let stream = try await provider.streamAgentMessage(messages: [AgentMessage(role: .user, parts: [.text("Stream fixture")])], systemPrompt: nil, tools: [], maxTokens: 16000, thinkingLevel: .off)
        var text = "", deltas = 0
        for try await event in stream { if case .textDelta(let delta) = event { deltas += 1; text += delta } }
        XCTAssertGreaterThan(deltas, 6)
        XCTAssertGreaterThan(text.count, 20_000)
        XCTAssertTrue(text.contains("العربية"))
        XCTAssertTrue(text.hasSuffix("نهاية الرسالة NATIVE_STREAM_END"))
        XCTAssertTrue(text.contains("```swift"))
    }
    func testOriginalAgentTransportAccumulatesPartialBrowserToolArguments() async throws {
        let model = LLMModel(id: "fixture-native-tool", displayName: "Native tool fixture", provider: "openai")
        let provider = OpenAIAgentProvider(provider: OpenAIProvider(apiKey: "local-fixture-only", model: model, customBaseURL: "http://127.0.0.1:8765/v1", appendV1Suffix: false))
        let stream = try await provider.streamAgentMessage(messages: [AgentMessage(role: .user, parts: [.text("Inspect tabs")])], systemPrompt: nil, tools: [ZEUSNativeAgentBridge.definition], maxTokens: 1000, thinkingLevel: .off)
        var partials = 0, complete = false
        for try await event in stream {
            switch event {
            case .toolInputDelta(let name, _): XCTAssertEqual(name, "zeus_browser"); partials += 1
            case .toolCallComplete(let id, let name, let args, _):
                XCTAssertEqual(id, "native-tool-fixture"); XCTAssertEqual(name, "zeus_browser")
                XCTAssertEqual(args["operation"] as? String, "browser_tabs")
                XCTAssertEqual(args["arguments"] as? String, "{}")
                XCTAssertEqual(args["tool_title"] as? String, "قراءة التبويبات الفعلية")
                complete = true
            default: break
            }
        }
        XCTAssertGreaterThan(partials, 1)
        XCTAssertTrue(complete)
    }
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
        let node = try await NativeBrowserInspector.execute("browser_evaluate", args: ["code": "return document.querySelector('#chapter')"], view: view)
        XCTAssertTrue(node.contains("MAIN"))
        let circular = try await NativeBrowserInspector.execute("browser_evaluate", args: ["code": "const a={n:123n};a.self=a;return a;"], view: view)
        XCTAssertTrue(circular.contains("Circular")); XCTAssertTrue(circular.contains("123"))
        do { _ = try await NativeBrowserInspector.execute("browser_evaluate", args: ["code": "throw Error('Fixture real failure')"], view: view); XCTFail("JS error must surface") } catch {}

        _ = try await NativeBrowserInspector.execute("browser_storage", args: ["area": "local", "action": "set", "key": "chapter", "value": "42"], view: view)
        let stored = try await NativeBrowserInspector.execute("browser_storage", args: ["area": "local", "action": "read", "key": "chapter"], view: view)
        XCTAssertTrue(stored.contains("42"))
        _ = try await NativeBrowserInspector.execute("browser_storage", args: ["area": "local", "action": "remove", "key": "chapter"], view: view)
        let empty = try await NativeBrowserInspector.execute("browser_storage", args: ["area": "local", "action": "read", "key": "chapter"], view: view)
        XCTAssertFalse(empty.contains("42"))
    }
    func testPageReadSuppliesTabIDAndOldElementIDsSurviveAnotherRead() async throws {
        let (browser, root) = model(); defer { try? FileManager.default.removeItem(at: root) }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let loader = NativeInspectorFixture()
        try await loader.load("<input id='name' aria-label='Name'><div contenteditable='true' aria-label='Message' style='width:200px;height:80px'></div><p>Real interaction fixture.</p>", view: view)
        let tab = try XCTUnwrap(browser.current); tab.url = "https://example.com"; tab.webView = view
        let session = NativeBrowserSession(browser: browser); session.authorization = { _ in true }
        let first = try await session.execute(operation: "browser_read", arguments: "{}", sessionID: nil)
        let data = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(first.text.utf8)) as? [String: Any])
        XCTAssertEqual(data["tab_id"] as? String, tab.id.uuidString)
        let elements = try XCTUnwrap(data["elements"] as? [[String: Any]])
        let input = try XCTUnwrap(elements.first { $0["label"] as? String == "Name" }?["element_id"] as? String)
        let editor = try XCTUnwrap(elements.first { $0["label"] as? String == "Message" }?["element_id"] as? String)
        _ = try await session.execute(operation: "browser_read", arguments: "{}", sessionID: nil)
        func args(_ id: String, _ text: String) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["tab_id": tab.id.uuidString, "element_id": id, "text": text]), as: UTF8.self)
        }
        _ = try await session.execute(operation: "browser_type", arguments: args(input, "Alice"), sessionID: nil)
        _ = try await session.execute(operation: "browser_type", arguments: args(editor, "A real editable message"), sessionID: nil)
        let actual = try await view.callAsyncJavaScript("return {name:document.querySelector('#name').value,message:document.querySelector('[contenteditable]').textContent}", arguments: [:], in: nil, contentWorld: .page) as? [String: String]
        XCTAssertEqual(actual?["name"], "Alice")
        XCTAssertEqual(actual?["message"], "A real editable message")
        try await loader.load("<input id='replacement' value='unchanged'>", view: view)
        do { _ = try await session.execute(operation: "browser_type", arguments: args(input, "must not type"), sessionID: nil); XCTFail("Previous-document IDs must be rejected") } catch {}
        let unchanged = try await view.callAsyncJavaScript("return document.querySelector('#replacement').value", arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(unchanged, "unchanged")
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
        let blockedDataFile = folder.appendingPathComponent("browser.json")
        if FileManager.default.fileExists(atPath: blockedDataFile.path) {
            try FileManager.default.removeItem(at: blockedDataFile)
        }
        try FileManager.default.createDirectory(at: blockedDataFile, withIntermediateDirectories: true)
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
