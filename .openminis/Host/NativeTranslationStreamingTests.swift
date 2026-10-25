import XCTest
import WebKit
@testable import ZEUSBrowser

@MainActor final class NativeTranslationStreamingTests: XCTestCase {
    func testWholeDocumentPlanUsesTwoOrThreePartsWithoutLosingUnicode() {
        let originals = (0..<600).map { TranslationSegment(id: "s\($0)", text: "Paragraph \($0): a complete story with العربية 👨‍👩‍👦, accents é and C++.\n") }
        let plan = AITranslationPlan.make(originals)
        XCTAssertEqual(plan.batches.count, 2)
        for original in originals { XCTAssertEqual(plan.pieces.filter { $0.originalID == original.id }.map(\.source).joined(), original.text) }
        let huge = TranslationSegment(id: "one-large-node", text: String(repeating: "A large chapter العربية 👨‍👩‍👦. ", count: 12_000))
        let big = AITranslationPlan.make([huge])
        XCTAssertEqual(big.batches.count, 3)
        XCTAssertEqual(big.pieces.map(\.source).joined(), huge.text)
        XCTAssertEqual(big.pieces.count, 3)
        XCTAssertTrue(AITranslationPlan.make([]).batches.isEmpty)
    }
    func testPartialJSONEscapesUnicodeAndUnknownIDsNeverBecomeMarkup() throws {
        var parser = AITranslationJSONStream(expected: ["t0", "t1"])
        try parser.append("[{\"id\":\"t0\",\"text\":\"مر")
        XCTAssertEqual(parser.updates().first?.text, "مر")
        try parser.append("حبًا \\uD83D")
        XCTAssertEqual(parser.updates().first?.text, "مرحبًا ")
        try parser.append("\\uDE03 \\\"")
        XCTAssertTrue(parser.updates().first?.text.contains("😃 \"") == true)
        try parser.append("quote\\\"\"},{\"text\":\"<script>literal</script>\",\"id\":\"t1\"}]")
        let updates = parser.updates()
        XCTAssertTrue(updates.contains { $0.id == "t0" && $0.finished })
        XCTAssertEqual(updates.first { $0.id == "t1" }?.text, "<script>literal</script>")
        let final = try TextTranslationService.validateAIResponse(parser.response, originals: [TranslationSegment(id: "t0", text: "one"), TranslationSegment(id: "t1", text: "two")])
        XCTAssertEqual(final.count, 2)
        var unknown = AITranslationJSONStream(expected: ["known"])
        try unknown.append("[{\"id\":\"unknown\",\"text\":\"never apply\"}]")
        XCTAssertTrue(unknown.updates().isEmpty)
        var nested = AITranslationJSONStream(expected: ["known"])
        try nested.append("[{\"id\":\"known\",\"metadata\":{\"text\":\"ignore\"},\"text\":\"actual\"}]")
        XCTAssertEqual(nested.updates().first?.text, "actual")
        var duplicate = AITranslationJSONStream(expected: ["known"])
        XCTAssertThrowsError(try duplicate.append("[{\"id\":\"known\",\"text\":\"first\"},{\"id\":\"known\",\"text\":\"second\"}]"))
    }
    func testViscoUsesTheProvidedEndpointAndSchemaWithoutCredentials() throws {
        let text = "C++ & مرحبا بكم كيف حالكم?"
        let request = ViscoTranslationService.request(text: text, target: "ru")
        XCTAssertEqual(request.url?.host, "viscodev.x10.mx")
        XCTAssertEqual(request.url?.path, "/trans/api.php")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "text" }?.value, text)
        XCTAssertEqual(query?.first { $0.name == "to" }?.value, "ru")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(try ViscoTranslationService.parse(["ok": true, "translated": "Добро пожаловать, как дела?"]), "Добро пожаловать, как дела?")
        XCTAssertThrowsError(try ViscoTranslationService.parse(["ok": false, "error": "Unavailable"]))
        XCTAssertThrowsError(try ViscoTranslationService.parse(["ok": true, "translated": ""]))
        let unicode = String(repeating: "العربية 👨‍👩‍👦 C++ & ", count: 300)
        let pieces = try ViscoTranslationService.split(unicode)
        XCTAssertEqual(pieces.joined(), unicode); XCTAssertTrue(pieces.allSatisfy { $0.utf8.count <= 1200 })
        var prefs = TranslationPreferences(); prefs.engine = .ai
        var provider = AIProviderConfiguration(); provider.kind = .geminiAPI
        XCTAssertFalse(prefs.streamsLargeBatches(provider: provider))
        provider.kind = .openAICompatible; XCTAssertTrue(prefs.streamsLargeBatches(provider: provider))
        prefs.engine = .microsoftVisco; XCTAssertFalse(prefs.streamsLargeBatches(provider: provider))
        XCTAssertEqual(try JSONDecoder().decode(TranslationPreferences.self, from: JSONEncoder().encode(prefs)).engine, .microsoftVisco)
    }
    func testActualOpenAIStreamUsesTwoHTTPRequestsForHundredsOfNodes() async throws {
        let provider = provider("fixture-bulk-" + UUID().uuidString)
        var prefs = TranslationPreferences(); prefs.engine = .ai
        let originals = (0..<600).map { TranslationSegment(id: "s\($0)", text: "Paragraph \($0) tells the complete story of a traveler visiting distant mountains.") }
        let sources = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, $0.text) })
        var incremental = false
        let result = try await TextTranslationService.translate(originals, preferences: prefs, provider: provider, secret: "", context: UUID(), onPartial: { values in
            if values.contains(where: { value in value.text.count > 1 && value.text.count < (sources[value.id]?.count ?? 0) }) { incremental = true }
        })
        XCTAssertTrue(incremental, "Partial text must arrive before a complete paragraph/response")
        XCTAssertEqual(result.map(\.id), originals.map(\.id))
        XCTAssertTrue(result.allSatisfy { !$0.text.isEmpty })
        let sent = try await requests(provider.model); XCTAssertEqual(sent.count, 2)
    }
    func testActualLargeNodeUsesAtMostThreeHTTPRequests() async throws {
        let provider = provider("fixture-large-" + UUID().uuidString)
        var prefs = TranslationPreferences(); prefs.engine = .ai
        let original = TranslationSegment(id: "large", text: String(repeating: "A whole chapter with Unicode العربية 👨‍👩‍👦. ", count: 5000))
        let result = try await TextTranslationService.translate([original], preferences: prefs, provider: provider, secret: "", context: UUID())
        let sent = try await requests(provider.model)
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(sent.flatMap { $0 }.joined(), original.text)
        XCTAssertEqual(result.map(\.id), ["large"])
        XCTAssertFalse(result[0].text.isEmpty)
    }
    func testRealWebKitShowsStreamBeforeCompletionRestoresAndReusesCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = BrowserModel(profiles: ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("Downloads")), useBackgroundDownloads: false)
        let provider = provider("fixture-slow-stream-" + UUID().uuidString)
        model.data.settings.shieldsEnabled = false; model.data.settings.aiProviders = [provider]
        var prefs = TranslationPreferences(); prefs.engine = .ai; prefs.providerID = provider.id; model.data.settings.translation = prefs
        let tab = try XCTUnwrap(model.current); tab.url = "http://127.0.0.1:8765/translate-fixture"
        let prepared = await model.prepare(tab), view = try XCTUnwrap(prepared)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene); window.frame = scene.screen.bounds
        let controller = UIViewController(); window.rootViewController = controller; view.frame = window.bounds; controller.view.addSubview(view)
        window.windowLevel = .normal + 1; window.makeKeyAndVisible()
        defer { tab.dispose(); window.isHidden = true; original?.makeKeyAndVisible(); try? FileManager.default.removeItem(at: root) }
        view.load(URLRequest(url: URL(string: tab.url)!)); let page = try XCTUnwrap(tab.translation)
        try await until { page.offered && page.observedFrameCount >= 2 }
        page.translate()
        var live = false
        for _ in 0..<300 {
            let text = try await view.evaluateJavaScript("document.querySelector('#heading')?.textContent ?? ''") as? String ?? ""
            if page.running && text.hasPrefix("ترجمة:") { live = true; break }
            if !page.running && page.error != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(live, page.error ?? "The DOM waited for the complete provider response")
        try await until { !page.running }
        XCTAssertNil(page.error); XCTAssertTrue(page.translated)
        let initial = try await requests(provider.model); XCTAssertEqual(initial.count, 2)
        let isolated = try await view.evaluateJavaScript("typeof window.zeusTranslate") as? String
        let password = try await view.evaluateJavaScript("document.querySelector('#secret').value") as? String
        XCTAssertEqual(isolated, "undefined"); XCTAssertEqual(password, "never-translate")
        await page.restore()
        let restored = try await view.evaluateJavaScript("document.querySelector('#heading').textContent") as? String
        XCTAssertEqual(restored, "A journey beyond the mountains")
        view.reload(); try await until { page.offered && page.observedFrameCount >= 2 }
        page.translate(); try await until { !page.running }
        XCTAssertNil(page.error); XCTAssertGreaterThan(page.reused, 0)
        let reusedRequests = try await requests(provider.model)
        XCTAssertEqual(reusedRequests.count, 2, "A reload must reuse verified translations without new requests")
    }
    func testReaderAlsoUsesTwoStreamingRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = BrowserModel(profiles: ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("Downloads")), useBackgroundDownloads: false)
        let provider = provider("fixture-slow-stream-reader-" + UUID().uuidString)
        model.data.settings.aiProviders = [provider]
        var prefs = TranslationPreferences(); prefs.engine = .ai; prefs.providerID = provider.id; model.data.settings.translation = prefs
        let article = ReaderArticle(title: "A complete story", paragraphs: (0..<8).map { "Chapter \($0) tells a longer story about a traveler who visits the distant mountains." }, sourceURL: "https://example.test/story")
        let reader = ReaderTranslation(); reader.translate(article: article, model: model)
        try await until { reader.running && reader.paragraphs?.contains(where: { $0.hasPrefix("ترجمة:") }) == true }
        try await until { !reader.running }
        XCTAssertNil(reader.error); XCTAssertEqual(reader.paragraphs?.count, article.paragraphs.count)
        let sent = try await requests(provider.model); XCTAssertEqual(sent.count, 2)
        reader.restore(); XCTAssertNil(reader.paragraphs); XCTAssertNil(reader.title)
    }
    private func provider(_ name: String) -> AIProviderConfiguration {
        var provider = AIProviderConfiguration(); provider.kind = .openAICompatible; provider.model = name; provider.baseURL = "http://127.0.0.1:8765/v1"; return provider
    }
    private func requests(_ model: String) async throws -> [[String]] {
        var url = URLComponents(string: "http://127.0.0.1:8765/translation-requests")!; url.queryItems = [URLQueryItem(name: "model", value: model)]
        return try await AIHTTP.object(AIHTTP.request(url.url!)) as? [[String]] ?? []
    }
    private func until(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<400 { if condition() { return }; try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), "Translation condition timed out")
    }
}
