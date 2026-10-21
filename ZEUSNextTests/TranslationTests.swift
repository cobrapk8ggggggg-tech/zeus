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
    func testGoogleBatchPreservesPlusSignsOrderingAndRejectsPartialResults() throws {
        let texts = ["C++ & العربية + accents é", "A chapter."]
        let request = TextTranslationService.googleBatchRequest(texts, target: "ar")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("C%2B%2B"))
        let decoded = URLComponents(string: "https://example.com/?" + body)?.queryItems?.map(\.value)
        XCTAssertEqual(decoded?.compactMap { $0 }, texts)
        let items = texts.enumerated().map { TranslationSegment(id: String($0.offset), text: $0.element) }
        let result = try TextTranslationService.parseGoogleBatch([["الأول", "en"], ["الثاني", "en"]], originals: items)
        XCTAssertEqual(result.map(\.id), ["0", "1"]); XCTAssertEqual(result.map(\.text), ["الأول", "الثاني"])
        XCTAssertThrowsError(try TextTranslationService.parseGoogleBatch(["ناقص"], originals: items))
    }
    func testHundredParagraphsUseTwoGoogleHTTPBatchesAndPreserveOriginalOrder() async throws {
        GoogleBatchProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [GoogleBatchProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let originals = (0..<100).map { TranslationSegment(id: String($0), text: "  Paragraph \($0) tells the story of a traveler.  ") }
        let result = try await TextTranslationService.translate(originals, preferences: TranslationPreferences(), provider: nil, secret: "", context: UUID(), session: session)
        XCTAssertEqual(GoogleBatchProtocol.count, 2, "Google must receive arrays, never a request for every paragraph")
        XCTAssertEqual(result.map(\.id), originals.map(\.id))
        for (index, value) in result.enumerated() { XCTAssertTrue(value.text.contains("Paragraph \(index) ")); XCTAssertTrue(value.text.hasPrefix("  ترجمة:")); XCTAssertTrue(value.text.hasSuffix("  ")) }
    }
    func testPersistentMemorySurvivesNewStoreAndSeparatesPageProviderLanguageAndChangedText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), other = root.appendingPathComponent("other")
        defer { try? FileManager.default.removeItem(at: root) }
        var prefs = TranslationPreferences(); prefs.engine = .ai
        var provider = AIProviderConfiguration(); provider.model = "one"
        let namespace = TranslationMemory.namespace(page: "https://example.com/chapter?part=1#old", preferences: prefs, provider: provider)
        XCTAssertEqual(namespace, TranslationMemory.namespace(page: "https://example.com/chapter?part=1#new", preferences: prefs, provider: provider))
        let first = TranslationMemory()
        let saved = await first.save(["A story": "قصة", "An unchanged paragraph": "فقرة ثابتة"], namespace: namespace, folder: root)
        XCTAssertTrue(saved)
        let reopened = TranslationMemory()
        let items = [TranslationSegment(id: "new-dom-id", text: "A story"), TranslationSegment(id: "changed", text: "An updated story")]
        let hits = await reopened.lookup(items, namespace: namespace, folder: root)
        XCTAssertEqual(hits["A story"], "قصة"); XCTAssertNil(hits["An updated story"])
        let otherProfile = await reopened.lookup(items, namespace: namespace, folder: other); XCTAssertTrue(otherProfile.isEmpty)
        provider.model = "two"
        let changedModel = TranslationMemory.namespace(page: "https://example.com/chapter?part=1", preferences: prefs, provider: provider)
        XCTAssertNotEqual(namespace, changedModel)
        let otherModel = await reopened.lookup(items, namespace: changedModel, folder: root); XCTAssertTrue(otherModel.isEmpty)
        prefs.target = "fr"
        XCTAssertNotEqual(namespace, TranslationMemory.namespace(page: "https://example.com/chapter?part=1", preferences: prefs, provider: provider))
        XCTAssertNotEqual(namespace, TranslationMemory.namespace(page: "https://example.com/other", preferences: prefs, provider: provider))
        let stats = await reopened.stats(folder: root); XCTAssertEqual(stats.entries, 2); XCTAssertLessThan(stats.bytes, TranslationMemory.maximumBytes)
        try await reopened.clear(folder: root)
        let cleared = await reopened.lookup(items, namespace: namespace, folder: root); XCTAssertTrue(cleared.isEmpty)
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
        model.data.settings.aiProviders?[0].model = "broken-json"
        page.translate(); try await until { page.error != nil && !page.running }
        XCTAssertFalse(page.translated)
        let failedLanguage = try await view.evaluateJavaScript("document.documentElement.lang") as? String
        XCTAssertEqual(failedLanguage, "en", "A rejected response must leave language and text unchanged")
        let failedText = try await view.evaluateJavaScript("document.querySelector('#heading').textContent") as? String
        XCTAssertEqual(failedText, "A journey beyond the mountains")
        model.data.settings.aiProviders?[0].model = "fixture-translator"
        page.translate(); try await until { page.translated && !page.running && page.completed >= 6 }
        XCTAssertNil(page.error)
        let frameText = try await view.evaluateJavaScript("document.querySelector('iframe').contentDocument.querySelector('p').textContent") as? String
        XCTAssertTrue(frameText?.hasPrefix("ترجمة:") == true)
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
    func testRemovedAdFramesBeforeStartAndDuringApplyNeverAbortArticleTranslation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = BrowserModel(profiles: ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("Downloads")), useBackgroundDownloads: false)
        model.data.settings.shieldsEnabled = false
        var provider = AIProviderConfiguration(); provider.baseURL = "http://127.0.0.1:8765/v1"; provider.model = "fixture-translator"; model.data.settings.aiProviders = [provider]
        var prefs = TranslationPreferences(); prefs.engine = .ai; prefs.providerID = provider.id; model.data.settings.translation = prefs
        let tab = try XCTUnwrap(model.current); tab.url = "http://127.0.0.1:8765/translate-fixture"
        let prepared = await model.prepare(tab), view = try XCTUnwrap(prepared); let window = try window(view)
        defer { tab.dispose(); window.isHidden = true; try? FileManager.default.removeItem(at: root) }
        view.load(URLRequest(url: URL(string: tab.url)!)); let page = try XCTUnwrap(tab.translation)
        try await until { page.offered && page.observedFrameCount >= 2 }
        _ = try await view.evaluateJavaScript("const ad=document.createElement('iframe');ad.id='temporary-ad';ad.src='/translate-frame?ad';document.body.append(ad)")
        try await until { page.observedFrameCount >= 3 }
        _ = try await view.evaluateJavaScript("document.querySelector('#temporary-ad').remove()")
        page.translate(); try await until { page.translated && !page.running }
        XCTAssertNil(page.error, "A removed frame at start must not abort the article")
        let text = try await view.evaluateJavaScript("document.querySelector('#heading').textContent") as? String
        XCTAssertTrue(text?.hasPrefix("ترجمة:") == true)
        XCTAssertEqual(page.observedFrameCount, 2, "Dead frame metadata must be discarded")
        await page.restore()
        model.data.settings.aiProviders?[0].model = "slow-translator"
        page.translate()
        try await until { page.completed >= 5 && page.running }
        _ = try await view.evaluateJavaScript("document.querySelectorAll('iframe').forEach(frame=>frame.remove())")
        try await until { !page.running }
        XCTAssertNil(page.error, "A frame removed while awaiting its provider response must not abort main content")
        let direction = try await view.evaluateJavaScript("getComputedStyle(document.querySelector('#paragraph')).direction") as? String
        XCTAssertEqual(direction, "rtl")
        await page.restore()
        let original = try await view.evaluateJavaScript("document.querySelector('#heading').textContent") as? String
        XCTAssertEqual(original, "A journey beyond the mountains")
    }
    func testViewportPriorityAndReloadReuseSavedTranslationWithoutProviderRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = BrowserModel(profiles: ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("Downloads")), useBackgroundDownloads: false)
        model.data.settings.shieldsEnabled = false
        var provider = AIProviderConfiguration(); provider.baseURL = "http://127.0.0.1:8765/v1"; provider.model = "memory-" + UUID().uuidString; model.data.settings.aiProviders = [provider]
        var prefs = TranslationPreferences(); prefs.engine = .ai; prefs.providerID = provider.id; model.data.settings.translation = prefs
        let tab = try XCTUnwrap(model.current); tab.url = "http://127.0.0.1:8765/translate-fixture"
        let prepared = await model.prepare(tab), view = try XCTUnwrap(prepared), window = try window(view)
        defer { tab.dispose(); window.isHidden = true; try? FileManager.default.removeItem(at: root) }
        view.load(URLRequest(url: URL(string: tab.url)!)); let page = try XCTUnwrap(tab.translation)
        try await until { page.offered }
        // The visible section is deliberately AFTER a long region in DOM order.
        _ = try await view.evaluateJavaScript("document.body.innerHTML='<p id=before>Earlier offscreen chapter text should wait for the visible text to finish translating.</p><div style=height:3000px></div><p id=visible>Visible chapter first paragraph with enough words to detect English correctly.</p><p id=visible2>Visible chapter second paragraph belongs to the same request.</p><div style=height:3000px></div><p id=after>Later offscreen chapter text should be prefetched after the visible paragraphs.</p>';document.querySelector('#visible').scrollIntoView()")
        let collection = try await view.callAsyncJavaScript("return zeusTranslate.collect(10000,64,true)", arguments: [:], in: nil, contentWorld: PageTranslation.world) as? [String: Any]
        let visible = collection?["segments"] as? [[String: String]]
        XCTAssertTrue(visible?.contains { $0["text"]?.hasPrefix("Visible chapter first") == true } == true)
        XCTAssertTrue(visible?.contains { $0["text"]?.hasPrefix("Visible chapter second") == true } == true)
        XCTAssertFalse(visible?.contains { $0["text"]?.hasPrefix("Earlier offscreen") == true } == true)
        page.translate(); try await until { page.translated && !page.running }; XCTAssertNil(page.error)
        let endpoint = URL(string: "http://127.0.0.1:8765/translation-requests?model=" + provider.model)!
        let (beforeData, _) = try await URLSession.shared.data(from: endpoint)
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: beforeData) as? [[String]])
        XCTAssertTrue(before.first?.contains { $0.hasPrefix("Visible chapter first") } == true)
        XCTAssertTrue(before.first?.contains { $0.hasPrefix("Visible chapter second") } == true)
        // Reload the same content under a fresh document ID, with one new paragraph.
        view.reload(); try await until { page.offered && !page.running && !page.translated && !view.isLoading }
        _ = try await view.evaluateJavaScript("document.body.innerHTML='<p>Earlier offscreen chapter text should wait for the visible text to finish translating.</p><p>Visible chapter first paragraph with enough words to detect English correctly.</p><p>Visible chapter second paragraph belongs to the same request.</p><p>Later offscreen chapter text should be prefetched after the visible paragraphs.</p>'")
        page.translate(); try await until { page.translated && !page.running }; XCTAssertNil(page.error); XCTAssertEqual(page.reused, 4)
        let (afterData, _) = try await URLSession.shared.data(from: endpoint)
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: afterData) as? [[String]])
        XCTAssertEqual(after.count, before.count, "Reloaded text must not spend another provider request")
        _ = try await view.evaluateJavaScript("const p=document.createElement('p');p.id='new-content';p.textContent='Only this changed paragraph may spend another request.';document.body.append(p)")
        try await until { page.completed == 5 && !page.running }
        let (changedData, _) = try await URLSession.shared.data(from: endpoint)
        let changed = try XCTUnwrap(JSONSerialization.jsonObject(with: changedData) as? [[String]])
        XCTAssertEqual(changed.count, before.count + 1); XCTAssertEqual(changed.last?.count, 1)
        let source = try await view.evaluateJavaScript("document.querySelector('#new-content').textContent") as? String
        XCTAssertTrue(source?.hasPrefix("ترجمة:") == true)
    }
    func testReaderUsesVisibleBatchAndANewReaderReusesPaidTranslationsFromDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = BrowserModel(profiles: ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("Downloads")), useBackgroundDownloads: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var provider = AIProviderConfiguration(); provider.baseURL = "http://127.0.0.1:8765/v1"; provider.model = "reader-memory-" + UUID().uuidString; model.data.settings.aiProviders = [provider]
        var prefs = TranslationPreferences(); prefs.engine = .ai; prefs.providerID = provider.id; model.data.settings.translation = prefs
        var paragraphs = (0..<40).map { "Paragraph \($0) tells the story of a traveler returning to the ancient city with a new book." }
        paragraphs[16] = "Visible first: " + String(repeating: "A traveler reads a long chapter. ", count: 180)
        paragraphs[17] = "Visible second: " + String(repeating: "The ancient city wakes up again. ", count: 180)
        let article = ReaderArticle(title: "A new story", paragraphs: paragraphs, sourceURL: "https://example.com/reader-chapter")
        let reader = ReaderTranslation(); reader.prepare(article: article, model: model); reader.viewport(height: 1300)
        for index in 0...paragraphs.count { reader.observe(index: index, rect: CGRect(x: 0, y: CGFloat(4000 + index * 1000), width: 700, height: 300)) }
        reader.observe(index: 17, rect: CGRect(x: 0, y: 100, width: 700, height: 300)); reader.observe(index: 18, rect: CGRect(x: 0, y: 500, width: 700, height: 300))
        reader.translate(article: article, model: model); try await until { reader.completed == 41 && !reader.running }; XCTAssertNil(reader.error)
        let endpoint = URL(string: "http://127.0.0.1:8765/translation-requests?model=" + provider.model)!
        let (data, _) = try await URLSession.shared.data(from: endpoint), before = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String]])
        XCTAssertEqual(before.first?.count, 2, "All visible text, including more than 5000 characters, must share one AI request")
        XCTAssertTrue(before.first?.first?.hasPrefix("Visible first:") == true); XCTAssertTrue(before.first?.last?.hasPrefix("Visible second:") == true)
        let reopened = ReaderTranslation(); reopened.prepare(article: article, model: model); reopened.translate(article: article, model: model)
        try await until { reopened.completed == 41 && !reopened.running }; XCTAssertNil(reopened.error); XCTAssertEqual(reopened.reused, 41)
        let (afterData, _) = try await URLSession.shared.data(from: endpoint), after = try XCTUnwrap(JSONSerialization.jsonObject(with: afterData) as? [[String]])
        XCTAssertEqual(after.count, before.count, "A new reader instance must restore disk results without spending provider quota")
    }
    func testDetectionAutomaticTranslationReaderAndNavigationReset() async throws {
        XCTAssertEqual(PageTranslation.detect(sample: "هذه فقرة عربية طويلة بما يكفي لاكتشاف اللغة بصورة صحيحة ودقيقة دون إرسالها إلى أي خادم.", hint: "en"), "ar")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = BrowserModel(profiles: ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("Downloads")), useBackgroundDownloads: false)
        model.data.settings.shieldsEnabled = false
        var provider = AIProviderConfiguration(); provider.baseURL = "http://127.0.0.1:8765/v1"; provider.model = "fixture-translator"; model.data.settings.aiProviders = [provider]
        var prefs = TranslationPreferences(); prefs.engine = .ai; prefs.providerID = provider.id; prefs.automatic = true; model.data.settings.translation = prefs
        let tab = try XCTUnwrap(model.current); tab.url = "http://127.0.0.1:8765/translate-fixture"
        let prepared = await model.prepare(tab); let view = try XCTUnwrap(prepared); let window = try window(view)
        defer { tab.dispose(); window.isHidden = true; try? FileManager.default.removeItem(at: root) }
        view.load(URLRequest(url: URL(string: tab.url)!))
        let page = try XCTUnwrap(tab.translation)
        try await until { page.translated && !page.running }; XCTAssertNil(page.error)
        // Switching off automatic translation must ask on the following document.
        prefs.automatic = false; model.data.settings.translation = prefs
        view.load(URLRequest(url: URL(string: tab.url + "?next")!))
        try await until { view.url?.query == "next" && page.offered && !page.running && !page.translated }
        XCTAssertEqual(page.completed, 0)
        XCTAssertTrue(view.canGoBack); view.goBack()
        try await until { view.url?.query == nil && !view.isLoading && page.offered && !page.running && !page.translated }
        let restoredLanguage = try await view.evaluateJavaScript("document.documentElement.lang") as? String
        XCTAssertEqual(restoredLanguage, "en", "Back/forward restoration must not leave an untracked translated DOM")
        let reader = ReaderTranslation(), article = ReaderArticle(title: "A new story", paragraphs: ["A traveler opened the ancient book and started reading another fascinating chapter.", "The stars shone brightly above the quiet village."])
        reader.prepare(article: article, model: model); XCTAssertTrue(reader.suggested)
        reader.translate(article: article, model: model)
        try await until { reader.paragraphs?.count == 2 && !reader.running }; XCTAssertNil(reader.error)
        XCTAssertTrue(reader.title?.hasPrefix("ترجمة:") == true); XCTAssertTrue(reader.paragraphs?.allSatisfy { $0.hasPrefix("ترجمة:") } == true)
        reader.restore(); XCTAssertNil(reader.paragraphs); XCTAssertNil(reader.title)
        page.navigationStarted(); XCTAssertFalse(page.offered); XCTAssertFalse(page.running); XCTAssertFalse(page.translated)
    }
}

private final class GoogleBatchProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests = 0
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    static func reset() { lock.lock(); requests = 0; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "translate.googleapis.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests += 1; Self.lock.unlock()
        do {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count)) }
            }
            let query = String(decoding: body, as: UTF8.self)
            let texts = URLComponents(string: "https://example.com/?" + query)?.queryItems?.filter { $0.name == "q" }.compactMap(\.value) ?? []
            guard request.httpMethod == "POST", request.url?.path == "/translate_a/t", !texts.isEmpty else { throw TranslationFailure.message("Invalid Google batch request") }
            let data = try JSONSerialization.data(withJSONObject: texts.map { ["ترجمة: " + $0, "en"] })
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
