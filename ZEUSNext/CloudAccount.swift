import Foundation
import Combine
import Auth
import Security

/// Public project configuration only. Administrative keys never belong in an IPA.
public enum ZeusCloudConfiguration {
    public static let projectURL = URL(string: "https://pdfzdcwkkgapcwsnezvn.supabase.co")!
    public static let publishableKey = "sb_publishable_ByPkZ3pyYzYJBY9QZz6aXg_YYqMe1Lu"
    public static let callback = URL(string: "zeus-account://auth/callback")!
}

enum CloudAccountError: LocalizedError {
    case keychain(OSStatus), wrongOwner, invalidResponse, conflict, incomplete(String)
    var errorDescription: String? {
        switch self {
        case .keychain(let status): return "تعذر الوصول الآمن إلى جلسة الحساب (\(status))."
        case .wrongOwner: return "بيانات هذا التثبيت مرتبطة بحساب آخر. سجّل بالحساب المالك؛ لم تُنقل بياناته للحساب الجديد."
        case .invalidResponse: return "استجابة الخدمة غير صالحة؛ لم تتغير بياناتك المحلية."
        case .conflict: return "توجد نسخة أحدث في الحساب. احتُفظ بتعديلات جهازك؛ راجع النسخ قبل الاستبدال."
        case .incomplete(let reason): return reason
        }
    }
}

/// Auth's session and PKCE verifier are isolated from provider/API key vaults.
struct CloudSessionStorage: AuthLocalStorage {
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "tools.zeus.cloud-auth.v1", kSecAttrAccount as String: key]
    }
    func retrieve(key: String) throws -> Data? {
        var q = query(key); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CloudAccountError.keychain(status) }
        return data
    }
    func store(key: String, value: Data) throws {
        var q = query(key); q[kSecValueData as String] = value
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updated = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: value] as CFDictionary)
            guard updated == errSecSuccess else { throw CloudAccountError.keychain(updated) }
        } else if status != errSecSuccess { throw CloudAccountError.keychain(status) }
    }
    func remove(key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudAccountError.keychain(status) }
    }
}

struct CloudIdentity: Codable, Equatable {
    let id: UUID
    let email: String
}

/// The native agent contains process-wide stores. Until those stores can be
/// safely unloaded, a second cloud owner cannot open the first owner's data.
/// This marker lives in the app sandbox (not Keychain) and survives sign-out.
struct CloudLocalOwner {
    let file: URL
    init(root: URL = BrowserDisk.applicationRoot) { file = root.appendingPathComponent("cloud-owner.json") }
    func read() throws -> UUID? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(UUID.self, from: Data(contentsOf: file))
    }
    func claim(_ id: UUID) throws {
        if let current = try read() { guard current == id else { throw CloudAccountError.wrongOwner }; return }
        try BrowserDisk.write(id, to: file)
    }
}

@MainActor final class CloudAccount: ObservableObject {
    static let shared = CloudAccount()
    enum Phase: Equatable { case loading, signedOut, claim, ready, blocked }
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var identity: CloudIdentity?
    @Published var busy = false
    @Published var issue: String?
    @Published var notice: String?
    @Published private(set) var passwordRecovery = false
    let auth: AuthClient
    private let owner: CloudLocalOwner
    private var observation: Task<Void, Never>?
    private var epoch = UUID()

    init(auth: AuthClient? = nil, owner: CloudLocalOwner = CloudLocalOwner()) {
        self.owner = owner
        self.auth = auth ?? AuthClient(configuration: .init(
            url: ZeusCloudConfiguration.projectURL.appendingPathComponent("auth/v1"),
            headers: ["apikey": ZeusCloudConfiguration.publishableKey], flowType: .pkce,
            redirectToURL: ZeusCloudConfiguration.callback, storageKey: "zeus-auth-v1",
            localStorage: CloudSessionStorage(), emitLocalSessionAsInitialSession: true))
    }

    func start() {
        guard observation == nil else { return }
        observation = Task { [weak self, auth] in
            for await (event, session) in auth.authStateChanges {
                guard let self else { return }
                if event == .passwordRecovery { self.passwordRecovery = true }
                self.accept(session)
            }
        }
    }
    private func accept(_ session: Session?) {
        let previous = identity?.id
        guard let session else {
            identity = nil; phase = .signedOut; epoch = UUID()
            if previous != nil { NotificationCenter.default.post(name: .zeusCloudSignedOut, object: nil) }
            return
        }
        let value = CloudIdentity(id: session.user.id, email: session.user.email ?? "")
        if previous != value.id { epoch = UUID() }
        identity = value
        do {
            if let current = try owner.read() {
                guard current == value.id else { throw CloudAccountError.wrongOwner }
                phase = .ready
            } else { phase = .claim }
        } catch { issue = error.localizedDescription; phase = .blocked }
    }
    func claimLocalData() throws {
        guard let identity else { throw CloudAccountError.invalidResponse }
        try owner.claim(identity.id); phase = .ready
    }
    func signIn(email: String, password: String) async {
        await perform { self.accept(try await self.auth.signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)) }
    }
    func signUp(email: String, password: String) async {
        await perform {
            guard password.count >= 12 else { throw CloudAccountError.incomplete("اختر كلمة مرور من 12 حرفًا على الأقل.") }
            let response = try await self.auth.signUp(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password,
                                                     redirectTo: ZeusCloudConfiguration.callback)
            if let session = response.session { self.accept(session) }
            else { self.notice = "راجع بريدك لتأكيد الحساب، ثم سجّل الدخول. إذا لم تصلك الرسالة، تحقق من مجلد الرسائل غير المرغوبة." }
        }
    }
    func recover(email: String) async {
        await perform {
            try await self.auth.resetPasswordForEmail(email.trimmingCharacters(in: .whitespacesAndNewlines), redirectTo: ZeusCloudConfiguration.callback)
            self.notice = "إذا كان البريد مسجلًا فستصلك خطوات استعادة الحساب."
        }
    }
    func updatePassword(_ password: String) async {
        await perform {
            guard password.count >= 12 else { throw CloudAccountError.incomplete("اختر كلمة مرور من 12 حرفًا على الأقل.") }
            _ = try await self.auth.update(user: UserAttributes(password: password))
            self.passwordRecovery = false; self.notice = "حُفظت كلمة المرور الجديدة."
        }
    }
    func handle(_ url: URL) async {
        guard url.scheme == ZeusCloudConfiguration.callback.scheme,
              url.host == ZeusCloudConfiguration.callback.host,
              url.path == ZeusCloudConfiguration.callback.path else { return }
        await perform { self.accept(try await self.auth.session(from: url)) }
    }
    /// Allows verification directly from the emailed Supabase link when the
    /// system mail app cannot return through the custom URL scheme.
    static func emailVerification(_ url: URL) throws -> (String, String) {
        guard url.scheme == "https", url.host == ZeusCloudConfiguration.projectURL.host,
              url.path == "/auth/v1/verify", url.user == nil, url.password == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw CloudAccountError.invalidResponse }
        let items = components.queryItems ?? []
        guard let token = items.first(where: { $0.name == "token_hash" || $0.name == "token" })?.value,
              (32...512).contains(token.count), let value = items.first(where: { $0.name == "type" })?.value,
              ["signup", "recovery", "email", "magiclink"].contains(value) else { throw CloudAccountError.invalidResponse }
        return (token, value)
    }
    func verifyEmailLink(_ value: String) async {
        await perform {
            guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw CloudAccountError.invalidResponse }
            let (token, name) = try Self.emailVerification(url)
            guard let type = EmailOTPType(rawValue: name) else { throw CloudAccountError.invalidResponse }
            let response = try await self.auth.verifyOTP(tokenHash: token, type: type)
            guard let session = response.session else { throw CloudAccountError.invalidResponse }
            self.accept(session); self.passwordRecovery = type == .recovery
        }
    }
    func signOut() async {
        await perform {
            // Device sign-out does not erase snapshots or cancel server-owned jobs.
            try await self.auth.signOut(scope: .local)
            self.accept(nil)
        }
    }
    func authorization(for expected: UUID) async throws -> String {
        let savedEpoch = epoch
        guard phase == .ready, identity?.id == expected else { throw CloudAccountError.wrongOwner }
        let session = try await auth.session
        guard savedEpoch == epoch, session.user.id == expected, identity?.id == expected,
              try owner.read() == expected else { throw CloudAccountError.wrongOwner }
        return session.accessToken
    }
    private func perform(_ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true; issue = nil; notice = nil
        defer { busy = false }
        do { try await operation() } catch { issue = error.localizedDescription }
    }
}

extension Notification.Name {
    static let zeusCloudSignedOut = Notification.Name("zeus.cloud.signedOut")
    static let zeusBrowserDataChanged = Notification.Name("zeus.browser.dataChanged")
}
