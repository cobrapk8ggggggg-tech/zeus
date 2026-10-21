import XCTest
import WebKit
import UIKit
@testable import ZEUSNext

final class TranslationDataTests: XCTestCase {
    func testOldProfilesDecodeWithoutNewSettingsAndSecretsStayOutOfExports() throws {
        var settings = BrowserSettings(); settings.translation = TranslationPreferences()
        var p = AIProviderConfiguration(); p.name = "Example"; p.model = "fixture"; settings.aiProviders = [p]
        let encoded = try JSONEncoder().encode(settings)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("accessToken")); XCTAssertFalse(text.contains("Cookie")); XCTAssertFalse(text.contains("apiKey"))
        let decoded = try JSONDecoder().decode(BrowserSettings.self, from: encoded)
        XCTAssertEqual(decoded.translation?.target, "ar"); XCTAssertEqual(decoded.aiProviders?.first?.id, p.id)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any]); raw.removeValue(forKey: "translation"); raw.removeValue(forKey: "aiProviders")
        let legacy = try JSONDecoder().decode(BrowserSettings.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertNil(legacy.translation); XCTAssertNil(legacy.aiProviders)
    }
    func testResponseIDsMustMatchExactlyAndTranslatedMarkupStaysText() throws {
        let items = [TranslationSegment(id: "a", text: "One"), TranslationSegment(id: "b", text: "Two")]
        XCTAssertThrowsError(try TextTranslationService.validateAIResponse("[{\"id\":\"a\",\"text\":\"واحد\"}]", originals: items))
        XCTAssertThrowsError(try TextTranslationService.validateAIResponse("[{\"id\":\"a\",\"text\":\"واحد\"},{\"id\":\"a\",\"text\":\"اثنان\"}]", originals: items))
        let values = try TextTranslationService.validateAIResponse("```json\n[{\"id\":\"b\",\"text\":\"اثنان\"},{\"id\":\"a\",\"text\":\"<script>text</script>\"}]\n```", originals: items)
        XCTAssertEqual(values.map(\.id), ["a", "b"]); XCTAssertEqual(values[0].text, "<script>text</script>")
    }
    func testUnicodeChunkingPreservesEveryCharacterAndRTL() {
        let text = String(repeating: "Hello 👨‍👩‍👦 مرحبًا. \n", count: 600)
        let chunks = TextTranslationService.split(text, limit: 1400)
        XCTAssertEqual(chunks.joined(), text); XCTAssertTrue(chunks.allSatisfy { $0.count <= 1400 })
        XCTAssertTrue(TranslationPreferences.rtl("ar")); XCTAssertTrue(TranslationPreferences.rtl("fa-IR")); XCTAssertFalse(TranslationPreferences.rtl("en"))
    }
    func testProviderEndpointValidationAndFormEscaping() throws {
        for invalid in ["http://example.com", "https://user:password@example.com", "https://example.com/v1?key=private", "file:///tmp/provider"] { XCTAssertThrowsError(try AIHTTP.endpoint(invalid)) }
        XCTAssertEqual(try AIHTTP.endpoint("http://127.0.0.1:8765/v1/", path: "models").path, "/v1/models")
        let body = String(decoding: AIHTTP.form(["at": "a+b&c=d"]), as: UTF8.self)
        XCTAssertTrue(body.contains("%2B")); XCTAssertTrue(body.contains("%26")); XCTAssertTrue(body.contains("%3D"))
    }
    func testDiscoveryAndTranslationUseRealOpenAICompatibleHTTPAndRejectMalformedOutput() async throws {
        var provider = AIProviderConfiguration(); provider.baseURL = "http://127.0.0.1:8765/v1"
        provider = try await AIProviderService.shared.discover(provider, secret: "")
        XCTAssertTrue(provider.models.contains { $0.id == "fixture-translator" })
        provider.model = "fixture-translator"
        var prefs = TranslationPreferences(); prefs.engine = .ai
        let original = [TranslationSegment(id: "p1", text: "The reader opened a book."), TranslationSegment(id: "p2", text: "Another chapter.")]
        let output = try await TextTranslationService.translate(original, preferences: prefs, provider: provider, secret: "", context: UUID())
        XCTAssertEqual(output.map(\.id), original.map(\.id)); XCTAssertTrue(output.allSatisfy { $0.text.hasPrefix("ترجمة:") })
        provider.model = "broken-json"
        do { _ = try await TextTranslationService.translate(original, preferences: prefs, provider: provider, secret: "", context: UUID()); XCTFail("Malformed IDs must never be applied") } catch { XCTAssertTrue(error.localizedDescription.contains("مكتملة")) }
    }
    func testKeychainCredentialsAreScopedToProfileAndProvider() throws {
        let a = UUID(), b = UUID(), provider = UUID().uuidString
        defer { AISecretVault.removeAll(profile: a); AISecretVault.removeAll(profile: b) }
        try AISecretVault.save("private-fixture", profile: a, provider: provider)
        XCTAssertEqual(AISecretVault.read(profile: a, provider: provider), "private-fixture")
        XCTAssertEqual(AISecretVault.read(profile: b, provider: provider), "")
        AISecretVault.removeAll(profile: a); XCTAssertEqual(AISecretVault.read(profile: a, provider: provider), "")
    }
}

@MainActor final class PageTranslationTests: XCTestCase {
    private func window(_ view: WKWebView) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = scene.screen.bounds
        let root = UIViewController(); window.rootViewController = root; view.frame = window.bounds; root.view.addSubview(view); window.windowLevel = .normal + 1; window.makeKeyAndVisible(); return window
    }
    private func until(_ condition: @escaping @MainActor () -> Bool, seconds: Double = 20) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(condition(), "Translation condition timed out")
    }
    func testActualWebKitTranslationDynamicTextRTLRestoreAndIsolatedWorld() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = BrowserModel(profiles: ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("Downloads")), useBackgroundDownloads: false)
        model.data.settings.shieldsEnabled = false
        var provider = AIProviderConfiguration(); provider.baseURL = "http://127.0.0.1:8765/v1"; provider.model = "fixture-translator"
        model.data.settings.aiProviders = [provider]
        var prefs = TranslationPreferences(); prefs.engine = .ai; prefs.providerID = provider.id; model.data.settings.translation = prefs
        let tab = try XCTUnwrap(model.current); tab.url = "http://127.0.0.1:8765/translate-fixture"
        let prepared = await model.prepare(tab); let view = try XCTUnwrap(prepared); let window = try window(view)
        defer { tab.dispose(); window.isHidden = true; try? FileManager.default.removeItem(at: root) }
        view.load(URLRequest(url: URL(string: tab.url)!))
        let page = try XCTUnwrap(tab.translation)
        try await until { page.offered }
        XCTAssertEqual(page.sourceLanguage, "en"); XCTAssertFalse(page.running)
        let isolated = try await view.evaluateJavaScript("typeof window.zeusTranslate") as? String
        XCTAssertEqual(isolated, "undefined")
        page.translate(); try await until { page.translated && !page.running }
        XCTAssertNil(page.error); XCTAssertGreaterThan(page.completed, 3)
        let heading = try await view.evaluateJavaScript("document.querySelector('#heading').textContent") as? String
        XCTAssertTrue(heading?.hasPrefix("ترجمة:") == true)
        let direction = try await view.evaluateJavaScript("getComputedStyle(document.querySelector('#paragraph')).direction") as? String
        XCTAssertEqual(direction, "rtl")
        let code = try await view.evaluateJavaScript("document.querySelector('#code').textContent") as? String
        XCTAssertEqual(code, "let untouched = \"Hello\";")
        let password = try await view.evaluateJavaScript("document.querySelector('#secret').value") as? String
        XCTAssertEqual(password, "never-translate")
        let keep = try await view.evaluateJavaScript("document.querySelector('#keep').textContent") as? String
        XCTAssertEqual(keep, "Leave this sentence untouched.")
        let before = page.completed
        _ = try await view.evaluateJavaScript("const p=document.createElement('p');p.id='dynamic';p.textContent='Another chapter arrives after the initial translation.';document.body.append(p)")
        try await until { page.completed > before && !page.running }
        let dynamic = try await view.evaluateJavaScript("document.querySelector('#dynamic').textContent") as? String
        XCTAssertTrue(dynamic?.hasPrefix("ترجمة:") == true)
        await page.restore()
        let original = try await view.evaluateJavaScript("document.querySelector('#heading').textContent") as? String
        XCTAssertEqual(original, "A journey beyond the mountains")
        let originalDirection = try await view.evaluateJavaScript("getComputedStyle(document.querySelector('#paragraph')).direction") as? String
        XCTAssertEqual(originalDirection, "ltr")
        let language = try await view.evaluateJavaScript("document.documentElement.lang") as? String
        XCTAssertEqual(language, "en")
    }
    func testDetectionAutomaticTranslationAndNavigationCancel() async throws {
        XCTAssertEqual(PageTranslation.detect(sample: "هذه فقرة عربية طويلة بما يكفي لاكتشاف اللغة بصورة صحيحة ودقيقة دون إرسالها إلى أي خادم.", hint: "en"), "ar")
        let reader = ReaderTranslation(); reader.cancel(); XCTAssertFalse(reader.running)
        let model = BrowserModel(useBackgroundDownloads: false)
        let tab = try XCTUnwrap(model.current), page = PageTranslation(model: model, tab: try XCTUnwrap(model.current))
        page.navigationStarted(); XCTAssertFalse(page.offered); XCTAssertFalse(page.running); XCTAssertFalse(page.translated)
        tab.dispose()
    }
}
