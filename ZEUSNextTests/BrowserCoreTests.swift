import XCTest
import Combine
import WebKit
@testable import ZEUSNext

final class BrowserCoreTests: XCTestCase {
    func testSearchPreservesAmpersandAsQueryValue() throws {
        let url = try XCTUnwrap(BrowserURL.resolve("swift & glass + privacy", provider: .google))
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "swift & glass + privacy")
    }
    func testDomainBoundariesDoNotTrustSubstring() {
        XCTAssertTrue(BrowserURL.hostMatches("accounts.google.com", domain: "google.com"))
        XCTAssertFalse(BrowserURL.hostMatches("notgoogle.com", domain: "google.com"))
        XCTAssertFalse(BrowserURL.hostMatches("google.com.attacker.invalid", domain: "google.com"))
    }
    func testFilenameCannotEscapeDestination() {
        for input in ["../../outside.zip", "..\\outside.zip", "/root/file.pdf", ".", "\n\r"] {
            let name = DownloadFiles.safeName(input)
            XCTAssertFalse(name.contains("/")); XCTAssertFalse(name.contains("\\")); XCTAssertNotEqual(name, "."); XCTAssertFalse(name.isEmpty)
        }
    }
    func testRuleRegexDoesNotTreatDotAsWildcard() throws {
        let regex = try NSRegularExpression(pattern: FilterRules.regex(for: "doubleclick.net"))
        func matches(_ s: String) -> Bool { regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        XCTAssertTrue(matches("https://ads.doubleclick.net/x"))
        XCTAssertFalse(matches("https://doubleclickXnet.invalid/x"))
        XCTAssertFalse(matches("https://example.org/?q=doubleclick.net"))
    }
    func testUnsupportedFilterOptionsAreNotSilentlyBroadened() {
        let parsed = FilterRules.parse("||ads.example.com^\n||scoped.example.com^$domain=foo.com\n@@||safe.example.com^\n")
        XCTAssertEqual(parsed.domains, ["ads.example.com"]); XCTAssertTrue(parsed.allowed.contains("safe.example.com")); XCTAssertEqual(parsed.unsupported, 1)
    }
    func testSecureCookiesNeverGoToHTTPOrUnrelatedHost() throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: ".example.com", .path: "/private", .name: "session", .value: "secret", .secure: "TRUE"]))
        XCTAssertNil(DownloadFiles.cookieHeaders([cookie], for: URL(string: "https://notexample.com/private")!)["Cookie"])
        XCTAssertNil(DownloadFiles.cookieHeaders([cookie], for: URL(string: "http://example.com/private")!)["Cookie"])
        XCTAssertNil(DownloadFiles.cookieHeaders([cookie], for: URL(string: "https://example.com/private-extra")!)["Cookie"])
        XCTAssertNotNil(DownloadFiles.cookieHeaders([cookie], for: URL(string: "https://example.com/private/file")!)["Cookie"])
    }
    @MainActor func testProfileFilesAndWebKitStoresAreIndependent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("Downloads"))
        let a = store.active, b = store.add(name: "Work", accent: "violet", isPrivate: false)
        var data = ProfileData(); data.bookmarks = [Bookmark(title: "Only A", url: "https://example.com")]; store.save(data, for: a)
        XCTAssertTrue(store.load(b).bookmarks.isEmpty)
        XCTAssertNotEqual(store.websiteDataStore(for: a).identifier, store.websiteDataStore(for: b).identifier)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "example.com", .path: "/", .name: "profileA", .value: "1"]))
        await withCheckedContinuation { c in store.websiteDataStore(for: a).httpCookieStore.setCookie(cookie) { c.resume() } }
        let cookies: [HTTPCookie] = await withCheckedContinuation { c in store.websiteDataStore(for: b).httpCookieStore.getAllCookies { c.resume(returning: $0) } }
        XCTAssertFalse(cookies.contains { $0.name == "profileA" })
        try await store.delete(b)
        await store.websiteDataStore(for: a).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        try? FileManager.default.removeItem(at: root)
    }
    @MainActor func testPrivateProfileDoesNotPersistHistory() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("Downloads"))
        let profile = store.add(name: "Private", accent: "violet", isPrivate: true)
        var data = ProfileData(); data.history = [Visit(title: "private", url: "https://example.com")]; store.save(data, for: profile)
        XCTAssertTrue(store.load(profile).history.isEmpty)
        XCTAssertFalse(store.websiteDataStore(for: profile).isPersistent)
        try? FileManager.default.removeItem(at: root)
    }
    @MainActor func testPublicDownloadRedirectPersistsCompleteFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("Downloads"))
        let service = DownloadService(store: store, useBackground: false)
        let done = expectation(description: "redirected download saved")
        var subscription: AnyCancellable?
        subscription = service.$records.sink { if $0.contains(where: { $0.state == .completed }) { done.fulfill() } }
        await service.start(url: URL(string: "http://127.0.0.1:8765/redirect")!, profile: store.active)
        await fulfillment(of: [done], timeout: 35); subscription?.cancel()
        let item = try XCTUnwrap(service.records.first); let file = try XCTUnwrap(service.fileURL(item))
        XCTAssertEqual(try Data(contentsOf: file).count, 1_048_576); XCTAssertEqual(item.filename, "fixture.zip")
        service.removeAll(profileID: store.activeID); try? FileManager.default.removeItem(at: root)
    }
    @MainActor func testUnknownLengthDownloadAndHTTPFailureAreHandled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("Downloads"))
        let service = DownloadService(store: store, useBackground: false)
        let done = expectation(description: "unknown length file and 404 handled")
        var fired = false
        let sub = service.$records.sink { rows in if !fired && rows.contains(where: { $0.state == .completed }) && rows.contains(where: { $0.state == .failed }) { fired = true; done.fulfill() } }
        await service.start(url: URL(string: "http://127.0.0.1:8765/unknown-size")!, profile: store.active)
        await service.start(url: URL(string: "http://127.0.0.1:8765/failure")!, profile: store.active)
        await fulfillment(of: [done], timeout: 35); sub.cancel()
        XCTAssertEqual(service.records.filter { $0.state == .completed }.count, 1)
        XCTAssertNotNil(service.records.first { $0.state == .failed }?.error)
        service.removeAll(profileID: store.activeID); try? FileManager.default.removeItem(at: root)
    }
}

@MainActor final class WebKitBehaviorTests: XCTestCase {
    func testGalleryRestoresCSSBackgroundsAndLazySourcesAndReaderKeepsShortDivText() async throws {
        let loader = WebKitFixtureLoader()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 800))
        await loader.load("""
        <html><body><article><h1>Fixture</h1><div>ظلام...</div><p>This is a real paragraph used for testing the original extraction behavior. It contains enough content to select this article as the reading root.</p></article>
        <div style="width:200px;height:200px;background-image:url('https://example.com/background.jpg')"></div>
        <img data-src="https://example.com/lazy.jpg">
        </body></html>
        """, view: view)
        let images = try await view.evaluateJavaScript(BrowserTools.gallery) as? [String]
        XCTAssertTrue(images?.contains("https://example.com/background.jpg") == true)
        XCTAssertTrue(images?.contains("https://example.com/lazy.jpg") == true)
        let article = try await view.evaluateJavaScript(BrowserTools.reader) as? [String: Any]
        XCTAssertTrue((article?["paragraphs"] as? [String])?.contains("ظلام...") == true)
    }
    func testLocalStorageIsSeparatedByPersistentProfileAndGuestIsEphemeral() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("Downloads"))
        let a = store.active, b = store.add(name: "B", accent: "white", isPrivate: false)
        let loaderA = WebKitFixtureLoader(), loaderB = WebKitFixtureLoader()
        let configA = WKWebViewConfiguration(); configA.websiteDataStore = store.websiteDataStore(for: a)
        let configB = WKWebViewConfiguration(); configB.websiteDataStore = store.websiteDataStore(for: b)
        let viewA = WKWebView(frame: .zero, configuration: configA), viewB = WKWebView(frame: .zero, configuration: configB)
        await loaderA.loadURL(URL(string: "http://127.0.0.1:8765/")!, view: viewA)
        await loaderB.loadURL(URL(string: "http://127.0.0.1:8765/")!, view: viewB)
        _ = try await viewA.evaluateJavaScript("localStorage.setItem('zeus-profile-test','A')")
        let stored = try await viewA.evaluateJavaScript("localStorage.getItem('zeus-profile-test')") as? String; XCTAssertEqual(stored, "A")
        let other = try await viewB.evaluateJavaScript("localStorage.getItem('zeus-profile-test')")
        XCTAssertTrue(other is NSNull)
        viewA.navigationDelegate = nil; viewB.navigationDelegate = nil
        try await store.delete(b)
        await store.websiteDataStore(for: a).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        try? FileManager.default.removeItem(at: root)
    }
    func testPasswordsAndAccountAdministrationCannotCrossAccounts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("Downloads"))
        let admin = store.active, user = store.add(name: "Protected", accent: "white", isPrivate: false)
        XCTAssertTrue(admin.isAdmin)
        try await AccountVault.set("fixture correct password", id: user.id)
        let valid = await AccountVault.verify("fixture correct password", id: user.id); XCTAssertTrue(valid)
        let invalid = await AccountVault.verify("incorrect", id: user.id); XCTAssertFalse(invalid)
        let model = BrowserModel(profiles: store, useBackgroundDownloads: false)
        await model.switchProfile(to: user, password: "incorrect"); XCTAssertEqual(model.profile.id, admin.id)
        await model.switchProfile(to: user, password: "fixture correct password"); XCTAssertEqual(model.profile.id, user.id)
        let count = store.profiles.count
        _ = store.add(name: "Forbidden", accent: "white", isPrivate: false); XCTAssertEqual(store.profiles.count, count)
        await model.switchProfile(to: admin)
        try await store.delete(user); XCTAssertFalse(AccountVault.exists(user.id))
        try? FileManager.default.removeItem(at: root)
    }
    func testWebKitBlobDownloadIsSavedThroughNativeDelegate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("Downloads"))
        let model = BrowserModel(profiles: store, useBackgroundDownloads: false)
        let tab = try XCTUnwrap(model.current); tab.url = "http://127.0.0.1:8765/"
        let prepared = await model.prepare(tab); let view = try XCTUnwrap(prepared)
        let loaded = expectation(description: "page loaded")
        var loadedOnce = false
        let watch = view.observe(\.isLoading, options: [.new]) { web, _ in if !web.isLoading && !loadedOnce { loadedOnce = true; loaded.fulfill() } }
        view.load(URLRequest(url: URL(string: tab.url)!))
        await fulfillment(of: [loaded], timeout: 25); watch.invalidate()
        let finished = expectation(description: "blob saved")
        var fired = false
        let sub = model.downloads.$records.sink { records in if !fired && records.contains(where: { $0.state == .completed }) { fired = true; finished.fulfill() } }
        _ = try await view.evaluateJavaScript("(()=>{const a=document.createElement('a');a.href=URL.createObjectURL(new Blob(['ZEUS blob fixture'],{type:'text/plain'}));a.download='fixture-blob.txt';document.body.appendChild(a);a.click()})()")
        await fulfillment(of: [finished], timeout: 30); sub.cancel()
        let item = try XCTUnwrap(model.downloads.records.first { $0.state == .completed })
        let path = try XCTUnwrap(model.downloads.fileURL(item))
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "ZEUS blob fixture")
        model.downloads.removeAll(profileID: store.activeID); tab.dispose(); try? FileManager.default.removeItem(at: root)
    }
}

@MainActor private final class WebKitFixtureLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    func load(_ html: String, view: WKWebView) async { await withCheckedContinuation { c in continuation = c; view.navigationDelegate = self; view.loadHTMLString(html, baseURL: URL(string: "https://example.com")) } }
    func loadURL(_ url: URL, view: WKWebView) async { await withCheckedContinuation { c in continuation = c; view.navigationDelegate = self; view.load(URLRequest(url: url)) } }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { continuation?.resume(); continuation = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { continuation?.resume(); continuation = nil }
}

final class TransferAndPreferenceTests: XCTestCase {
    func testLocalTransferParserRejectsAmbiguousLengthsAndChunkedUploads() throws {
        XCTAssertNil(try LocalHTTPRequest.parse(Data("GET /token/ HTTP/1.1\r\nHost: phone".utf8)))
        let valid = try XCTUnwrap(LocalHTTPRequest.parse(Data("POST /token/import HTTP/1.1\r\nHost: phone\r\nContent-Length: 2\r\n\r\n{}".utf8)))
        XCTAssertEqual(valid.contentLength, 2); XCTAssertEqual(valid.path, "/token/import")
        for headers in ["Content-Length: 2\r\nContent-Length: 4", "Transfer-Encoding: chunked", "Content-Length: 6000001", "Content-Length: -1"] {
            XCTAssertThrowsError(try LocalHTTPRequest.parse(Data(("POST /token/import HTTP/1.1\r\n" + headers + "\r\n\r\n").utf8)))
        }
    }
    func testImportRejectsSettingsThatWouldCrashCollectionLimits() {
        var data = ProfileData(); var options = AdvancedSettings(); options.historyLimit = -1; data.settings.advanced = options
        XCTAssertThrowsError(try ProfileBackup(name: "untrusted", data: data).validated())
        data.settings.advanced = AdvancedSettings(); data.bookmarks = [Bookmark(title: "bad", url: "javascript:alert(1)")]
        XCTAssertThrowsError(try ProfileBackup(name: "untrusted", data: data).validated())
    }
    func testCustomSearchEncodesQueryAsOneValue() throws {
        var settings = BrowserSettings(); var options = AdvancedSettings()
        let engine = CustomSearchEngine(name: "Fixture", template: "https://example.com/search?q={query}")
        options.customSearchEngines = [engine]; options.selectedSearchEngineID = engine.id; settings.advanced = options
        let url = try XCTUnwrap(BrowserURL.resolve("one & admin=true", settings: settings))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.count, 1); XCTAssertEqual(items?.first?.value, "one & admin=true")
    }
    @MainActor func testAdminEditingAnotherAccountsSettingsDoesNotModifyOwnSettings() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("Downloads"))
        let target = store.add(name: "Other", accent: "white", isPrivate: false)
        let model = BrowserModel(profiles: store, useBackgroundDownloads: false)
        let context = ProfileSettingsContext(model: model, profile: target)
        context.setting(\.desktopMode).wrappedValue = true
        XCTAssertTrue(store.load(target).settings.desktopMode); XCTAssertFalse(model.data.settings.desktopMode)
        context.option(\.downloadsWiFiOnly).wrappedValue = true
        XCTAssertTrue(store.load(target).settings.advanced?.downloadsWiFiOnly == true)
    }
    @MainActor func testTwinBrowserKeepsDifferentWebViewsInSameProfileStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("Downloads"))
        let model = BrowserModel(profiles: store, useBackgroundDownloads: false)
        model.data.settings.shieldsEnabled = false
        let primary = try XCTUnwrap(model.primary); primary.url = "https://example.com/first"
        model.toggleTwin(vertical: false)
        let secondary = try XCTUnwrap(model.secondary)
        let left = await model.prepare(primary), right = await model.prepare(secondary)
        XCTAssertFalse(left === right); XCTAssertTrue(left?.configuration.websiteDataStore === right?.configuration.websiteDataStore)
        model.focusPane(secondary); model.home()
        XCTAssertTrue(secondary.isHome); XCTAssertEqual(primary.url, "https://example.com/first")
        model.closeTab(secondary); XCTAssertNil(model.secondary)
        primary.dispose()
    }
    func testSavedFormValuesAreScopedToProfileInKeychain() throws {
        let a = UUID(), b = UUID(), id = UUID()
        let fields = [SavedFormField(selector: "#email", type: "email", value: "fixture@example.com", checked: false)]
        try FormVault.save(fields, profileID: a, id: id)
        XCTAssertEqual(FormVault.load(profileID: a, id: id)?.first?.value, "fixture@example.com")
        XCTAssertNil(FormVault.load(profileID: b, id: id))
        FormVault.remove(profileID: a); XCTAssertNil(FormVault.load(profileID: a, id: id))
    }
    @MainActor func testFullBundledFilterListCompilesInWebKit() async throws {
        let resource = try XCTUnwrap(Bundle.main.url(forResource: "safari-rules", withExtension: "json"))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: resource)) as? [[String: Any]])
        XCTAssertGreaterThan(rows.count, 1000)
        let profile = BrowserProfile(name: "Filter fixture")
        let shield = ShieldEngine(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let compiled = try await shield.list(profile: profile, settings: BrowserSettings())
        XCTAssertNotNil(compiled); shield.erase(profile.id)
    }
}
