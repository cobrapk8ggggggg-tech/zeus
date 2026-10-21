import Foundation

// Calls the personal AI-bound Worker, never the account management API.
// Only a translation-scoped connection key is imported into Keychain.
enum CloudflareTranslationService {
    static let defaultEndpoint = "https://zeus-translation.cookies-studio-36c499.workers.dev"
    static let defaultModel = "@cf/google/gemma-4-26b-a4b-it"
    static let maximumResponseBytes = 2_000_000

    static func translate(_ segments: [TranslationSegment], target: String, config: CloudflareTranslationConfiguration, secret: String, session: URLSession = AIHTTP.shared) async throws -> [TranslationSegment] {
        let body: [String: Any] = ["model": config.model, "target": target, "instruction": config.instruction, "segments": segments.map { ["id": $0.id, "text": $0.text] }]
        let request = try request(config.endpoint, path: "v1/translate", secret: secret, body: body)
        let object = try await object(request, session: session)
        guard object["version"] as? Int == 1, object["model"] as? String == config.model, let values = object["translations"] as? [[String: Any]] else { throw TranslationFailure.message("رد Cloudflare لا يطابق النموذج المطلوب؛ بقيت النصوص الأصلية.") }
        return try TextTranslationService.validateAIResponse(AIHTTP.string(values), originals: segments)
    }
    static func discover(_ config: CloudflareTranslationConfiguration, secret: String, session: URLSession = AIHTTP.shared) async throws -> CloudflareTranslationConfiguration {
        let object = try await object(request(config.endpoint, path: "v1/models", secret: secret), session: session)
        guard object["version"] as? Int == 1, let rows = object["models"] as? [[String: Any]], rows.count <= 100 else { throw TranslationFailure.message("الخادم لا يوفّر واجهة ترجمة ZEUS المتوافقة.") }
        let models = rows.compactMap { row -> AIChoice? in
            guard let id = row["id"] as? String, id.hasPrefix("@cf/"), let name = row["name"] as? String else { return nil }
            return AIChoice(id: id, name: name)
        }
        guard !models.isEmpty, models.count == rows.count, Set(models.map(\.id)).count == models.count else { throw TranslationFailure.message("لم يُرجع الخادم قائمة نماذج صالحة.") }
        var result = config; result.models = models
        result.accountID = object["accountID"] as? String ?? ""; result.accountName = object["accountName"] as? String ?? "Cloudflare"
        if !models.contains(where: { $0.id == result.model }) {
            let suggested = object["defaultModel"] as? String
            result.model = models.first(where: { $0.id == suggested })?.id ?? models[0].id
        }
        result.lastChecked = nil // Listing models does not prove that inference works.
        return result
    }
    static func request(_ endpoint: String, path: String, secret: String, body: Any? = nil) throws -> URLRequest {
        guard secret.count == 43, secret.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }) else {
            throw TranslationFailure.message("استورد ملف ربط Cloudflare لهذا البروفايل من إعدادات الترجمة أولًا.")
        }
        return try AIHTTP.request(AIHTTP.endpoint(endpoint, path: path), method: body == nil ? "GET" : "POST", body: body, headers: ["Authorization": "Bearer " + secret, "User-Agent": "ZEUSBrowser/2.3.0 (iOS; Translation)"])
    }
    static func object(_ request: URLRequest, session: URLSession) async throws -> [String: Any] {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw TranslationFailure.message("تعذر قراءة رد خادم Cloudflare.") }
        if response.expectedContentLength > Int64(maximumResponseBytes) { throw TranslationFailure.message("رد Cloudflare أكبر من الحد المسموح.") }
        var data = Data(); data.reserveCapacity(16384)
        for try await byte in bytes {
            try Task.checkCancellation(); data.append(byte)
            if data.count > maximumResponseBytes { throw TranslationFailure.message("رد Cloudflare أكبر من الحد المسموح.") }
        }
        let value = (try? AIHTTP.json(data)) as? [String: Any]
        if !(200..<300).contains(response.statusCode) {
            throw TranslationFailure.message(errorMessage(code: value?["error"] as? String, status: response.statusCode))
        }
        guard let value, value["error"] == nil else { throw TranslationFailure.message("أعاد Cloudflare استجابة غير صالحة؛ لم تُعد المحاولة تلقائيًا.") }
        return value
    }
    static func errorMessage(code: String?, status: Int) -> String {
        switch code {
        case "daily_quota": return "نفدت حصة Cloudflare اليومية المجانية. تُجدّد عند 00:00 UTC. الترجمات المحفوظة تظل متاحة؛ يمكنك اختيار محرك آخر."
        case "capacity": return "نموذج Cloudflare مشغول حاليًا. أعد المحاولة لاحقًا أو اختر نموذجًا آخر؛ لم نكرر الطلب تلقائيًا."
        case "rate_limit": return "بلغ اتصال Cloudflare حد الطلبات خلال الدقيقة. انتظر قليلًا ثم تابع."
        case "paid_plan_required": return "يتطلب هذا النموذج خطة Cloudflare مدفوعة. اختر نموذجًا آخر؛ لم يغيّر ZEUS خطة حسابك."
        case "model_terms": return "يلزم قبول شروط هذا النموذج في لوحة Workers AI بحساب Cloudflare."
        case "invalid_connection": return "رمز ربط Cloudflare غير صالح أو أُلغي. استورد ملف الربط الصحيح لهذا البروفايل."
        case "incomplete_translation", "invalid_translation": return "لم يُرجع Cloudflare كل النصوص بالصيغة المطلوبة. بقي الأصل دون تغيير ولم نكرر الطلب؛ يمكنك تجربة النموذج الآخر."
        case "request_too_large": return "تجاوزت دفعة الترجمة حد Cloudflare. جرّب النموذج الآخر أو أعد فتح الصفحة."
        case "provider_timeout": return "انتهت مهلة نموذج Cloudflare. لم تُعد المحاولة تلقائيًا لتجنّب استهلاك الحصة مرتين."
        default: return "تعذر الاتصال بترجمة Cloudflare (HTTP \(status)). بقيت النصوص الأصلية."
        }
    }
}

// Imported separately from profile exports. Validate everything before storing
// any credential, and never echo it into the UI, logs, or an error message.
struct CloudflareConnection: Decodable {
    var version: Int
    var endpoint: String
    var token: String
    var accountID: String
    var accountName: String
    var model: String
    static func decode(_ data: Data) throws -> CloudflareConnection {
        guard data.count <= 16_384, let value = try? JSONDecoder().decode(Self.self, from: data), value.version == 1,
              value.accountID.count == 32, value.accountID.allSatisfy({ $0.isHexDigit }),
              value.accountName.count <= 200, value.model.hasPrefix("@cf/"), value.model.count <= 200 else { throw TranslationFailure.message("ملف ربط Cloudflare غير صالح.") }
        _ = try CloudflareTranslationService.request(value.endpoint, path: "v1/models", secret: value.token)
        return value
    }
    var configuration: CloudflareTranslationConfiguration {
        var config = CloudflareTranslationConfiguration(); config.endpoint = endpoint; config.accountID = accountID; config.accountName = accountName; config.model = model; return config
    }
}
