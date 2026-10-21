import Foundation
import CryptoKit
import CommonCrypto
import Security

enum AccountRole: String, Codable, CaseIterable, Identifiable {
    case administrator, standard, guest, kiosk
    var id: String { rawValue }
    var title: String {
        switch self { case .administrator: return "الحساب الرئيسي"; case .standard: return "حساب عادي"; case .guest: return "ضيف"; case .kiosk: return "كشك" }
    }
}
struct AccountOptions: Codable, Equatable {
    var role: AccountRole = .standard
    var enabled = true
    var avatarFilename: String?
    var logoutAfter: Double = -1
    var allowDownloads = true
    var allowScripts = true
    var allowDeveloperTools = true
    var allowSettings = true
    var allowedDomains: [String] = []
    var homePage = "zeus://home"
}
enum AccountError: LocalizedError {
    case permission, password, keychain
    case keychainStatus(Int32)
    var errorDescription: String? {
        switch self { case .permission: return "هذا الإجراء متاح للحساب الرئيسي فقط."; case .password: return "كلمة المرور غير صحيحة."; case .keychain: return "تعذر حفظ كلمة المرور في سلسلة مفاتيح الجهاز."; case .keychainStatus(let code): return "تعذر الوصول إلى سلسلة مفاتيح الجهاز (\(code)). تحقق من قفل الجهاز وتوقيع التطبيق وصلاحية Keychain." }
    }
}
enum AccountVault {
    private struct Credential: Codable { var salt: Data; var digest: Data }
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "tools.zeus.accounts", kSecAttrAccount as String: id.uuidString]
    }
    private static func read(_ id: UUID) -> Credential? {
        var q = query(id); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(Credential.self, from: data)
    }
    static func exists(_ id: UUID) -> Bool { read(id) != nil }
    private static func derive(_ password: String, salt: Data) -> Data {
        let bytes = Array(password.utf8); var output = [UInt8](repeating: 0, count: 32)
        salt.withUnsafeBytes { saltBytes in
            bytes.withUnsafeBytes { passwordBytes in
                _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.bindMemory(to: Int8.self).baseAddress, bytes.count, saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 210_000, &output, 32)
            }
        }
        return Data(output)
    }
    static func verify(_ password: String, id: UUID) async -> Bool {
        guard let credential = read(id) else { return false }
        guard credential.salt.count == 32, credential.digest.count == 32 else { return false }
        return await Task.detached(priority: .userInitiated) {
            let actual = derive(password, salt: credential.salt)
            return zip(actual, credential.digest).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
        }.value
    }
    static func set(_ password: String, id: UUID) async throws {
        guard !password.isEmpty else { remove(id); return }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AccountError.keychain }
        let salt = Data(bytes)
        let digest = await Task.detached(priority: .userInitiated) { derive(password, salt: salt) }.value
        let data = try JSONEncoder().encode(Credential(salt: salt, digest: digest))
        var q = query(id); q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updated = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard updated == errSecSuccess else { throw AccountError.keychainStatus(updated) }
        } else if status != errSecSuccess { throw AccountError.keychainStatus(status) }
    }
    static func remove(_ id: UUID) { SecItemDelete(query(id) as CFDictionary) }
}

enum ChromeLayout: String, Codable, CaseIterable, Identifiable {
    case original, dualBars, icab
    var id: String { rawValue }
    var title: String { switch self { case .original: return "ZEUS الأصلي"; case .dualBars: return "شريطان متحركان"; case .icab: return "توزيع iCab" } }
}
struct ReadingPreferences: Codable {
    var fontSize: Double = 20
    var textOpacity: Double = 1
    var blockedWords: [String] = []
    var imageScale: Double = 1
    var scrollDistance: Double = 300
    var fontName: String?
    var backgroundHex: String?
    var textHex: String?
}

extension ProfileStore {
    func configurationFolder(_ profile: BrowserProfile) -> URL { root.appendingPathComponent("Accounts").appendingPathComponent(profile.id.uuidString) }
    func guestTemplate(_ profile: BrowserProfile) -> ProfileData {
        BrowserDisk.read(ProfileData.self, from: configurationFolder(profile).appendingPathComponent("template.json")) ?? ProfileData()
    }
    func saveTemplate(_ data: ProfileData, profile: BrowserProfile) throws {
        guard active.isAdmin else { throw AccountError.permission }
        try BrowserDisk.write(data, to: configurationFolder(profile).appendingPathComponent("template.json"))
    }
    func avatarURL(_ profile: BrowserProfile) -> URL? {
        guard profile.account?.avatarFilename != nil else { return nil }
        return configurationFolder(profile).appendingPathComponent("avatar.jpg")
    }
}
