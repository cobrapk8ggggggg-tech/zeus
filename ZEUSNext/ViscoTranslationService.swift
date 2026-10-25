import Foundation

/// The user-supplied proxy, not Microsoft's official authenticated endpoint.
/// This request carries text/language only; no AI, browser or account secrets.
enum ViscoTranslationService {
    static let endpoint = "https://viscodev.x10.mx/trans/api.php"
    static func split(_ text: String) throws -> [String] {
        var result: [String] = [], part = "", bytes = 0
        for character in text {
            let count = String(character).utf8.count
            guard count <= 1200 else { throw TranslationFailure.message("يوجد محرف أكبر من سعة رابط خدمة Visco. اختر مزودًا آخر لهذا النص.") }
            if bytes + count > 1200 && !part.isEmpty { result.append(part); part = ""; bytes = 0 }
            part.append(character); bytes += count
        }
        if !part.isEmpty { result.append(part) }; return result
    }
    static func request(text: String, target: String) -> URLRequest {
        var url = URLComponents(string: endpoint)!
        url.queryItems = [URLQueryItem(name: "text", value: text), URLQueryItem(name: "to", value: target == "zh-CN" ? "zh-Hans" : target)]
        var request = URLRequest(url: url.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    static func parse(_ object: Any) throws -> String {
        guard let value = object as? [String: Any], value["ok"] as? Bool == true,
              let translated = value["translated"] as? String,
              !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationFailure.message("لم تُرجع خدمة Visco ترجمة صالحة. أعد المحاولة أو اختر مزودًا آخر.")
        }
        return translated
    }
    static func translate(_ segments: [TranslationSegment], target: String, session: URLSession) async throws -> [TranslationSegment] {
        var results: [TranslationSegment] = []
        for segment in segments {
            try Task.checkCancellation()
            let object = try await AIHTTP.object(request(text: segment.text, target: target), session: session)
            results.append(TranslationSegment(id: segment.id, text: try parse(object)))
        }
        return results
    }
}
