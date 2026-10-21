import Foundation
import Security

enum TranslationEngine: String, Codable, CaseIterable { case googleWeb, googleCloud, ai, cloudflare
    var title: String { switch self { case .googleWeb: return "Google Translate — خدمة الويب"; case .googleCloud: return "Google Cloud Translation — رسمي"; case .ai: return "الذكاء الاصطناعي"; case .cloudflare: return "Cloudflare Workers AI" } }
}
struct TranslationPreferences: Codable, Equatable {
    var engine: TranslationEngine = .googleWeb
    var target = "ar"
    var suggest = true
    var automatic = false
    var dynamicContent = true
    var excludedHosts: [String] = []
    var providerID: UUID?
    var cloudflare: CloudflareTranslationConfiguration?
    var retainTranslations: Bool?
    var keepsTranslations: Bool { retainTranslations ?? true }
    var usesAIBatches: Bool { engine == .ai || engine == .cloudflare }
    func secretKey(provider: AIProviderConfiguration?) -> String {
        switch engine {
        case .googleCloud: return "google-cloud"
        case .cloudflare: return "cloudflare-workers-ai"
        default: return provider?.id.uuidString ?? ""
        }
    }
    static let languages = [("ar", "العربية"), ("en", "English"), ("fr", "Français"), ("es", "Español"), ("de", "Deutsch"), ("tr", "Türkçe"), ("fa", "فارسی"), ("ur", "اردو"), ("he", "עברית"), ("ru", "Русский"), ("ja", "日本語"), ("ko", "한국어"), ("zh-CN", "中文"), ("pt", "Português"), ("it", "Italiano"), ("id", "Indonesia")]
    static func rtl(_ language: String) -> Bool { ["ar", "fa", "ur", "he", "ps", "yi"].contains(language.components(separatedBy: "-")[0]) }
}
enum AIProviderKind: String, Codable, CaseIterable {
    case chatGPTAccount, geminiAccount, openAICompatible, geminiAPI
    var title: String { switch self { case .chatGPTAccount: return "حساب ChatGPT"; case .geminiAccount: return "حساب Gemini"; case .openAICompatible: return "OpenAI / مزود متوافق"; case .geminiAPI: return "Gemini API الرسمي" } }
    var account: Bool { self == .chatGPTAccount || self == .geminiAccount }
}
struct AIChoice: Codable, Identifiable, Equatable { var id: String; var name: String; var metadata: String? }
struct AIProject: Codable, Identifiable, Equatable { var id: String; var name: String; var chats: [AIChoice] }
struct AIProviderConfiguration: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var kind: AIProviderKind = .openAICompatible
    var baseURL = "https://api.openai.com/v1"
    var model = ""
    var models: [AIChoice] = []
    var chats: [AIChoice] = []
    var projects: [AIProject] = []
    var projectID: String?
    var conversationID: String?
    var googleAccountIndex = 0
    var instruction = ""
    var lastChecked: Date?
    var discoveryNotice: String?
}
struct TranslationSegment: Codable, Equatable { var id: String; var text: String }
enum TranslationFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let value): return value } }
}
// Credentials never enter browser.json, profile exports, diagnostics, or prompts.
enum AISecretVault {
    private static func query(profile: UUID, provider: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "tools.zeus.ai." + profile.uuidString, kSecAttrAccount as String: provider]
    }
    static func read(profile: UUID, provider: String) -> String {
        var q = query(profile: profile, provider: provider); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?; guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String, profile: UUID, provider: String) throws {
        let q = query(profile: profile, provider: provider)
        if value.isEmpty { SecItemDelete(q as CFDictionary); return }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { var item = q; item.merge(attributes) { _, n in n }; let added = SecItemAdd(item as CFDictionary, nil); guard added == errSecSuccess else { throw AccountError.keychainStatus(added) } }
        else if status != errSecSuccess { throw AccountError.keychainStatus(status) }
    }
    static func removeAll(profile: UUID) { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "tools.zeus.ai." + profile.uuidString] as CFDictionary) }
}

// Public connection metadata only; the Workers AI token lives in AISecretVault.
struct CloudflareTranslationConfiguration: Codable, Equatable {
    var endpoint = CloudflareTranslationService.defaultEndpoint
    var accountID = ""
    var accountName = ""
    var model = CloudflareTranslationService.defaultModel
    var models: [AIChoice] = []
    var instruction = ""
    var lastChecked: Date?
}
