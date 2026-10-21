import XCTest
@testable import ZEUSNext

final class CloudflareTranslationTests: XCTestCase {
    private let token = String(repeating: "A", count: 43)
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CloudflareProtocol.self]
        return URLSession(configuration: config, delegate: AIRedirectPolicy(), delegateQueue: nil)
    }
    func testVisibleParagraphBatchUsesOneHTTPRequestAndChecksEveryID() async throws {
        CloudflareProtocol.reset(); let session = session(); defer { session.invalidateAndCancel() }
        var prefs = TranslationPreferences(); prefs.engine = .cloudflare; prefs.cloudflare = CloudflareTranslationConfiguration()
        let originals = (0..<100).map { TranslationSegment(id: "p\($0)", text: "  Chapter paragraph \($0).  ") }
        let result = try await TextTranslationService.translate(originals, preferences: prefs, provider: nil, secret: token, context: UUID(), session: session)
        XCTAssertEqual(CloudflareProtocol.requests.count, 1, "The visible batch must not become one HTTP request per paragraph")
        XCTAssertEqual(result.map(\.id), originals.map(\.id)); XCTAssertTrue(result.allSatisfy { $0.text.hasPrefix("  ترجمة:") && $0.text.hasSuffix("  ") })
        let captured = try XCTUnwrap(CloudflareProtocol.requests.first)
        XCTAssertEqual(captured.url?.host, "zeus-translation.cookies-studio-36c499.workers.dev"); XCTAssertEqual(captured.url?.path, "/v1/translate")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
        let body = try XCTUnwrap(CloudflareProtocol.bodies.first)
        XCTAssertEqual(Set(body.keys), ["model", "target", "instruction", "segments"])
        XCTAssertFalse(String(describing: body).contains(token)); XCTAssertNil(body["url"]); XCTAssertNil(body["cookie"])
    }
    func testQuotaFailureAndIncompleteResultsStopWithoutAutomaticRetry() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        var prefs = TranslationPreferences(); prefs.engine = .cloudflare
        for mode in ["quota", "partial", "wrong-model", "oversized"] {
            CloudflareProtocol.reset(mode: mode)
            do {
                _ = try await TextTranslationService.translate([TranslationSegment(id: "a", text: "One"), TranslationSegment(id: "b", text: "Two")], preferences: prefs, provider: nil, secret: token, context: UUID(), session: session)
                XCTFail("Incomplete/quota responses must not be applied")
            } catch {
                XCTAssertEqual(CloudflareProtocol.requests.count, 1)
                if mode == "quota" { XCTAssertTrue(error.localizedDescription.contains("اليومية")) }
            }
        }
    }
    func testServerModelDiscoveryDoesNotClaimInferenceHasBeenVerified() async throws {
        CloudflareProtocol.reset(); let session = session(); defer { session.invalidateAndCancel() }
        let result = try await CloudflareTranslationService.discover(CloudflareTranslationConfiguration(), secret: token, session: session)
        XCTAssertEqual(result.models.count, 2); XCTAssertNil(result.lastChecked); XCTAssertEqual(result.accountID.count, 32)
        XCTAssertEqual(result.model, CloudflareTranslationService.defaultModel)
        XCTAssertEqual(CloudflareProtocol.requests.first?.url?.path, "/v1/models")
    }
    func testImportedConnectionIsPrivateAndLegacyProfilesStillDecode() throws {
        let data = try AIHTTP.encode(["version": 1, "endpoint": CloudflareTranslationService.defaultEndpoint, "token": token, "accountID": String(repeating: "a", count: 32), "accountName": "Personal", "model": CloudflareTranslationService.defaultModel])
        let connection = try CloudflareConnection.decode(data)
        var prefs = TranslationPreferences(); prefs.engine = .cloudflare; prefs.cloudflare = connection.configuration
        let exported = String(decoding: try JSONEncoder().encode(prefs), as: UTF8.self)
        XCTAssertFalse(exported.contains(token)); XCTAssertFalse(exported.contains("token"))
        let old = try JSONDecoder().decode(TranslationPreferences.self, from: Data("{\"engine\":\"googleWeb\",\"target\":\"ar\",\"suggest\":true,\"automatic\":false,\"dynamicContent\":true,\"excludedHosts\":[]}".utf8))
        XCTAssertNil(old.cloudflare); XCTAssertTrue(old.keepsTranslations)
        for invalid in ["http://example.com", "https://user:pass@example.com", "https://example.com?token=secret"] {
            var object = try XCTUnwrap(AIHTTP.json(data) as? [String: Any]); object["endpoint"] = invalid
            XCTAssertThrowsError(try CloudflareConnection.decode(AIHTTP.encode(object)))
        }
        XCTAssertThrowsError(try CloudflareConnection.decode(Data(repeating: 32, count: 16385)))
    }
    func testCacheSeparatesCloudflareAccountModelEndpointAndStyleAndPersists() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var prefs = TranslationPreferences(); prefs.engine = .cloudflare; prefs.cloudflare = CloudflareTranslationConfiguration()
        let page = "https://example.com/chapter/1", original = [TranslationSegment(id: "new-id", text: "The book")]
        let base = TranslationMemory.namespace(page: page, preferences: prefs, provider: nil)
        let saved = await TranslationMemory().save(["The book": "الكتاب"], namespace: base, folder: folder); XCTAssertTrue(saved)
        let reopened = await TranslationMemory().lookup(original, namespace: base, folder: folder); XCTAssertEqual(reopened["The book"], "الكتاب")
        for field in ["model", "account", "endpoint", "style"] {
            var changed = prefs
            switch field {
            case "model": changed.cloudflare?.model = "@cf/another/model"
            case "account": changed.cloudflare?.accountID = String(repeating: "b", count: 32)
            case "endpoint": changed.cloudflare?.endpoint = "https://other.workers.dev"
            default: changed.cloudflare?.instruction = "Narrative style"
            }
            XCTAssertNotEqual(base, TranslationMemory.namespace(page: page, preferences: changed, provider: nil))
        }
        prefs.engine = .ai; XCTAssertNotEqual(base, TranslationMemory.namespace(page: page, preferences: prefs, provider: nil))
    }
    func testKeyIsSeparateFromGoogleAndAIKeysAndUnicodeChunksRespectWorkerLimit() throws {
        var prefs = TranslationPreferences(); let provider = AIProviderConfiguration(); prefs.engine = .cloudflare
        XCTAssertEqual(prefs.secretKey(provider: provider), "cloudflare-workers-ai")
        prefs.engine = .googleCloud; XCTAssertEqual(prefs.secretKey(provider: provider), "google-cloud")
        prefs.engine = .ai; XCTAssertEqual(prefs.secretKey(provider: provider), provider.id.uuidString)
        let text = String(repeating: "Hello 👨‍👩‍👦 مرحبا. ", count: 3000)
        let parts = TextTranslationService.splitCloudflare(text, limit: 16000)
        XCTAssertEqual(parts.joined(), text); XCTAssertTrue(parts.allSatisfy { $0.utf16.count <= 16000 })
    }
}

private final class CloudflareProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captured: [URLRequest] = []
    private static var payloads: [[String: Any]] = []
    private static var mode = "normal"
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    static var bodies: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return payloads }
    static func reset(mode: String = "normal") { lock.lock(); captured = []; payloads = []; self.mode = mode; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "zeus-translation.cookies-studio-36c499.workers.dev" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(contentsOf: buffer.prefix(n)) }
            }
            let object = (try? AIHTTP.json(body)) as? [String: Any] ?? [:]
            Self.lock.lock(); Self.captured.append(request); Self.payloads.append(object); let mode = Self.mode; Self.lock.unlock()
            var status = 200, response: [String: Any]
            if request.url?.path == "/v1/models" {
                response = ["version": 1, "accountID": String(repeating: "a", count: 32), "accountName": "Personal", "models": [["id": CloudflareTranslationService.defaultModel, "name": "Gemma 4"], ["id": "@cf/meta/llama-3.3-70b-instruct-fp8-fast", "name": "Llama 3.3"]], "defaultModel": CloudflareTranslationService.defaultModel]
            } else {
                var texts = (object["segments"] as? [[String: String]] ?? []).reversed().map { ["id": $0["id"] ?? "", "text": "ترجمة: " + ($0["text"] ?? "")] }
                if mode == "partial" { texts = Array(texts.dropFirst()) }
                response = ["version": 1, "model": mode == "wrong-model" ? "other" : object["model"] ?? "", "translations": texts]
                if mode == "quota" { status = 429; response = ["error": "daily_quota"] }
            }
            let data = try AIHTTP.encode(response)
            let headers = mode == "oversized" ? ["Content-Type": "application/json", "Content-Length": "2000001"] : ["Content-Type": "application/json"]
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
