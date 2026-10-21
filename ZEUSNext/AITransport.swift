import Foundation

final class AIRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward an account cookie or bearer to a different origin, or downgrade TLS.
        guard let old = task.originalRequest?.url, let next = request.url,
              old.scheme == next.scheme, old.host == next.host, old.port == next.port else { completionHandler(nil); return }
        completionHandler(request)
    }
}
struct AIHTTP {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 180
        return URLSession(configuration: config, delegate: AIRedirectPolicy(), delegateQueue: nil)
    }()
    static func endpoint(_ base: String, path: String = "") throws -> URL {
        guard var url = URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw TranslationFailure.message("أدخل عنوان HTTPS صالحًا للمزود. HTTP متاح للخادم المحلي فقط.")
        }
        if !path.isEmpty { url.append(path: path) }; return url
    }
    static func json(_ data: Data) throws -> Any { try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
    static func encode(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys]) }
    static func string(_ object: Any) throws -> String { String(decoding: try encode(object), as: UTF8.self) }
    static func request(_ url: URL, method: String = "GET", body: Any? = nil, headers: [String: String] = [:]) throws -> URLRequest {
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body { request.httpBody = try encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
    static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw TranslationFailure.message("رد غير صالح من خدمة الترجمة.") }
        switch response.statusCode {
        case 200..<300: return
        case 401: throw TranslationFailure.message("انتهت الجلسة أو مفتاح المزود غير صحيح. حدّث بيانات الاتصال.")
        case 403: throw TranslationFailure.message("رفض المزود الطلب. افتح موقعه لإكمال تسجيل الدخول أو تحقق من صلاحيات الحساب.")
        case 429: throw TranslationFailure.message("وصلت إلى حد استخدام المزود. انتظر قليلًا أو اختر مزودًا آخر.")
        default: throw TranslationFailure.message("تعذر الاتصال بالمزود (HTTP \(response.statusCode)).")
        }
    }
    static func data(_ request: URLRequest, session: URLSession = shared) async throws -> Data {
        // Stream into a bounded buffer instead of accepting unbounded HTML/error responses.
        let (bytes, response) = try await session.bytes(for: request); try validate(response)
        if response.expectedContentLength > 8_000_000 { throw TranslationFailure.message("رد المزود أكبر من الحد المسموح.") }
        var data = Data(); data.reserveCapacity(32_768)
        for try await byte in bytes { try Task.checkCancellation(); data.append(byte); if data.count > 8_000_000 { throw TranslationFailure.message("رد المزود أكبر من الحد المسموح.") } }
        return data
    }
    static func object(_ request: URLRequest, session: URLSession = shared) async throws -> Any { try json(await data(request, session: session)) }
    static func form(_ values: [String: String]) -> Data {
        var components = URLComponents(); components.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }
    static func nested(_ object: Any, _ path: [Int]) -> Any? {
        var result: Any = object
        for index in path { guard let array = result as? [Any], array.indices.contains(index) else { return nil }; result = array[index] }
        return result
    }
    static func rpc(_ data: Data, id: String) -> [Any] {
        // Google frames use anti-XSSI + byte counts followed by nested JSON lines.
        var out: [Any] = []
        func visit(_ value: Any) {
            guard let a = value as? [Any] else { return }
            if a.count > 2, a[0] as? String == "wrb.fr", a[1] as? String == id, let s = a[2] as? String, let decoded = try? json(Data(s.utf8)) { out.append(decoded); return }
            for v in a { visit(v) }
        }
        for line in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines) { if let value = try? json(Data(line.utf8)) { visit(value) } }
        return out
    }
}
