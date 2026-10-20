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
