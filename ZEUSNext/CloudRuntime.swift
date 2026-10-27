import Foundation
import SwiftUI
import Security
import WebKit

public struct NativeCloudBlob: Codable, Sendable {
    public let sha256: String
    public let bytes: Int
    public init(sha256: String, bytes: Int) { self.sha256 = sha256; self.bytes = bytes }
}

public struct NativeCloudHTTPError: LocalizedError {
    public let statusCode: Int
    public let message: String
    public var errorDescription: String? { message }
}

public struct NativeCloudFile: Codable, Sendable {
    public let scope: String
    public let path: String
    public let bytes: Int64
    public let parts: [NativeCloudBlob]
    public let sha256: String
    public let mode: Int?
    public init(scope: String, path: String, bytes: Int64, parts: [NativeCloudBlob], sha256: String, mode: Int? = nil) {
        self.scope = scope; self.path = path; self.bytes = bytes; self.parts = parts; self.sha256 = sha256
        self.mode = mode.map { $0 & 0o777 }
    }
}

public struct NativeCloudArchive: Codable, Sendable {
    public let version: Int
    public let files: [NativeCloudFile]
    public let secrets: NativeCloudBlob
    public let created: Date
    public let deletionEpoch: Int?
    public init(files: [NativeCloudFile], secrets: NativeCloudBlob, deletionEpoch: Int? = nil) { version = 1; self.files = files; self.secrets = secrets; self.deletionEpoch = deletionEpoch; created = Date() }
}

struct CloudExecutionPreference: Codable {
    let owner: UUID
    let enabled: Bool
    var choiceVersion: Int? = nil
    var pendingCommit: Bool? = nil
    static func resolved(owner: UUID, secure: Self?, disk: Self?) -> Bool {
        for candidate in [secure, disk] {
            if let candidate, candidate.owner == owner, candidate.choiceVersion == 2 { return candidate.enabled }
        }
        return true
    }
}

@MainActor public protocol NativeCloudDataDelegate: AnyObject {
    func restoreBrowserFile(at url: URL) async throws -> URL?
    func validateLocalExecutionIdle() throws
    func prepareCloudExecution(progress: @escaping (String) -> Void) async throws
    func migrateToCloud(progress: @escaping (String) -> Void) async throws
    func prepareLocalExecution(progress: @escaping (String) -> Void) async throws
    func restoreAccountIfNeeded(progress: @escaping (String) -> Void) async throws
    func backupAccount(progress: @escaping (String) -> Void) async throws
    func validateExecutionTransition() async throws
    func finishExecutionTransition(enabled: Bool?) async throws
    func restoreUsingCloudExecution(progress: @escaping (String) -> Void) async throws
}

@MainActor public final class NativeCloudBackupStatus: ObservableObject {
    public static let shared = NativeCloudBackupStatus()
    @Published public private(set) var busy = false
    @Published public private(set) var progress = ""
    @Published public private(set) var issue: String?
    @Published public private(set) var saved: Date?
    @Published public private(set) var storageUsed: Int64?
    @Published public private(set) var storageLimit: Int64?
    public func refreshUsage() async {
        do {
            let value = try await NativeCloudAccountAPI.storageUsage()
            storageUsed = value.used; storageLimit = value.limit
        } catch { if issue == nil { issue = error.localizedDescription } }
    }
    public func save() async {
        guard !busy, NativeCloudAccountAPI.ownerID != nil, let delegate = NativeCloudAccountAPI.dataDelegate else { return }
        busy = true; issue = nil; defer { busy = false }
        do { try await delegate.backupAccount { self.progress = $0 }; saved = Date(); progress = "اكتملت نسخة الوكيل والملفات والأسرار المشفرة."; await refreshUsage() }
        catch { issue = error.localizedDescription }
    }
}

/// A single transaction lane for browser checkpoints and native-agent backups.
/// The server still rejects a stale revision from another device.
actor CloudCheckpointGate {
    static let shared = CloudCheckpointGate()
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        if occupied { await withCheckedContinuation { waiters.append($0) } }
        else { occupied = true }
    }
    func leave() {
        if waiters.isEmpty { occupied = false } else { waiters.removeFirst().resume() }
    }
}

@MainActor public enum NativeCloudAccountAPI {
    public static let runtimeURL = URL(string: "https://zeus-cloud-production.up.railway.app")!
    public static weak var dataDelegate: NativeCloudDataDelegate?
    public static var sharedFilesView: (() -> AnyView)?
    public static var browserFilesDidChange: (() -> Void)?
    public static var prepareBrowserBackup: (() async throws -> Void)?
    public static var isMigrating = false
    public static var ownerID: String? { CloudAccount.shared.phase == .ready ? CloudAccount.shared.identity?.id.uuidString.lowercased() : nil }
    private static var preferencesURL: URL { BrowserDisk.applicationRoot.appendingPathComponent("cloud-execution.json") }
    private typealias Preference = CloudExecutionPreference
    public static var usesCloud: Bool {
        guard let id = CloudAccount.shared.identity?.id, CloudAccount.shared.phase == .ready else { return false }
        let secure = (try? CloudSessionStorage().retrieve(key: "zeus-execution:" + id.uuidString)).flatMap { try? JSONDecoder().decode(Preference.self, from: $0) }
        return Preference.resolved(owner: id, secure: secure, disk: BrowserDisk.read(Preference.self, from: preferencesURL))
    }
    public static func setEnabled(_ value: Bool) async throws {
        guard let id = CloudAccount.shared.identity?.id, CloudAccount.shared.phase == .ready else { throw CloudAccountError.wrongOwner }
        // Persist the user's selection before any network request. A suspended
        // transfer must never turn cloud execution back into local execution.
        let preference = Preference(owner: id, enabled: value, choiceVersion: 2, pendingCommit: true)
        try CloudSessionStorage().store(key: "zeus-execution:" + id.uuidString, value: JSONEncoder().encode(preference))
        try? BrowserDisk.write(preference, to: preferencesURL)
        try await prepareBrowserBackup?()
        await CloudCheckpointGate.shared.enter()
        do {
            let api = try transport()
            guard let head = try await api.head() else { throw CloudAccountError.incomplete("لم تكتمل نسخة الحساب بعد.") }
            var manifest = head.manifest; manifest.executionTarget = value ? "cloud" : "local"; manifest.executionChoiceVersion = 2
            if value { manifest.coverage = Array(Set(manifest.coverage + ["cloud_runtime"])) }
            _ = try await api.commit(manifest, expected: head.revision, operation: UUID())
            try markPreferenceCommitted(value)
            await CloudCheckpointGate.shared.leave()
        } catch { await CloudCheckpointGate.shared.leave(); throw error }
    }
    static func adoptPreference(_ value: String?, version: Int?) throws {
        guard version == 2, let value, let id = CloudAccount.shared.identity?.id else { return }
        if let data = try? CloudSessionStorage().retrieve(key: "zeus-execution:" + id.uuidString),
           let local = try? JSONDecoder().decode(Preference.self, from: data), local.owner == id, local.pendingCommit == true { return }
        let preference = Preference(owner: id, enabled: value == "cloud", choiceVersion: 2)
        try CloudSessionStorage().store(key: "zeus-execution:" + id.uuidString, value: JSONEncoder().encode(preference))
        try? BrowserDisk.write(preference, to: preferencesURL)
    }
    static func markPreferenceCommitted(_ enabled: Bool) throws {
        guard let id = CloudAccount.shared.identity?.id, usesCloud == enabled else { return }
        let preference = Preference(owner: id, enabled: enabled, choiceVersion: 2, pendingCommit: false)
        try CloudSessionStorage().store(key: "zeus-execution:" + id.uuidString, value: JSONEncoder().encode(preference))
        try? BrowserDisk.write(preference, to: preferencesURL)
    }
    public struct FileRoot {
        public let scope: String
        public let url: URL
        public init(scope: String, url: URL) { self.scope = scope; self.url = url }
    }
    public static var browserFileRoots: [FileRoot] {
        [FileRoot(scope: "browser_profiles", url: BrowserDisk.applicationRoot.appendingPathComponent("Profiles")),
         FileRoot(scope: "browser_accounts", url: BrowserDisk.applicationRoot.appendingPathComponent("Accounts")),
         FileRoot(scope: "browser_downloads", url: BrowserDisk.downloadsRoot)]
    }
    private struct BrowserSecret: Codable { let service: String; let account: String; let data: Data }
    private struct CookieRecord: Codable { let profile: UUID; let properties: Data }
    private struct BrowserSecrets: Codable { let version: Int; let keychain: [BrowserSecret]; let cookies: [CookieRecord] }
    private static func allowedSecret(_ service: String) -> Bool {
        service == "tools.zeus.accounts" || service.hasPrefix("tools.zeus.forms.") || service.hasPrefix("tools.zeus.ai.") || service == "com.openminis.app.mcp-oauth"
    }
    public static func browserSecrets() async throws -> Data {
        var value: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecReturnAttributes as String: true,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitAll, kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudAccountError.keychain(status) }
        let secrets = (value as? [[String: Any]] ?? []).compactMap { row -> BrowserSecret? in
            guard let service = row[kSecAttrService as String] as? String, allowedSecret(service),
                  let account = row[kSecAttrAccount as String] as? String, let data = row[kSecValueData as String] as? Data else { return nil }
            return BrowserSecret(service: service, account: account, data: data)
        }
        let store = ProfileStore(); var cookies: [CookieRecord] = []
        for profile in store.profiles where !profile.isPrivate {
            let entries: [HTTPCookie] = await withCheckedContinuation { continuation in
                store.websiteDataStore(for: profile).httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
            }
            for cookie in entries {
                var properties: [String: Any] = [:]
                for (key, value) in cookie.properties ?? [:] { properties[key.rawValue] = (value as? URL)?.absoluteString ?? value }
                let data = try PropertyListSerialization.data(fromPropertyList: properties, format: .binary, options: 0)
                cookies.append(CookieRecord(profile: profile.id, properties: data))
            }
        }
        return try JSONEncoder().encode(BrowserSecrets(version: 1, keychain: secrets, cookies: cookies))
    }
    public static func restoreBrowserSecrets(_ data: Data) async throws {
        let bundle = try JSONDecoder().decode(BrowserSecrets.self, from: data)
        guard bundle.version == 1 else { throw CloudAccountError.invalidResponse }
        for secret in bundle.keychain {
            guard allowedSecret(secret.service) else { throw CloudAccountError.invalidResponse }
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: secret.service, kSecAttrAccount as String: secret.account]
            var item = query; item[kSecValueData as String] = secret.data; item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            // An existing secret may have been rotated after the backup.
            guard status == errSecSuccess || status == errSecDuplicateItem else { throw CloudAccountError.keychain(status) }
        }
        let store = ProfileStore()
        for entry in bundle.cookies {
            guard let profile = store.profile(entry.profile), !profile.isPrivate,
                  let raw = try PropertyListSerialization.propertyList(from: entry.properties, format: nil) as? [String: Any] else { continue }
            let properties = Dictionary(uniqueKeysWithValues: raw.map { (HTTPCookiePropertyKey(rawValue: $0.key), $0.value) })
            if let cookie = HTTPCookie(properties: properties) {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    store.websiteDataStore(for: profile).httpCookieStore.setCookie(cookie) { continuation.resume() }
                }
            }
        }
    }
    private static func transport() throws -> CloudSnapshotTransport {
        guard let id = CloudAccount.shared.identity?.id, CloudAccount.shared.phase == .ready else { throw CloudAccountError.wrongOwner }
        return CloudSnapshotTransport(account: .shared, owner: id)
    }
    public static func putObject(_ data: Data) async throws -> NativeCloudBlob {
        let ref = try await transport().put(data)
        return NativeCloudBlob(sha256: ref.sha256, bytes: ref.bytes)
    }
    public static func getObject(_ value: NativeCloudBlob) async throws -> Data {
        try await transport().get(CloudObjectReference(sha256: value.sha256, bytes: value.bytes))
    }
    public static func sealSecrets(_ data: Data) async throws -> Data {
        guard data.count <= 1024 * 1024 else { throw CloudAccountError.incomplete("حزمة الأسرار أكبر من حد النقل الآمن.") }
        return try await callFiles("seal", body: data)
    }
    public struct StorageUsage: Decodable { public let used: Int64; public let limit: Int64 }
    public static func storageUsage() async throws -> StorageUsage {
        var url = URLComponents(url: ZeusCloudConfiguration.projectURL.appendingPathComponent("functions/v1/zeus-files"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "op", value: "usage")]
        return try JSONDecoder().decode(StorageUsage.self, from: await request(url.url!, method: "GET", body: nil))
    }
    public static func unsealSecrets(_ data: Data) async throws -> Data { try await callFiles("unseal", body: data) }
    public static func fileGrant(conversation: String) async throws -> String {
        guard UUID(uuidString: conversation) != nil else { throw CloudAccountError.invalidResponse }
        let bytes = try await callFiles("issue", body: JSONSerialization.data(withJSONObject: ["conversation_id": conversation]))
        guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], let token = value["token"] as? String else { throw CloudAccountError.invalidResponse }
        return token
    }
    private static func callFiles(_ operation: String, body: Data) async throws -> Data {
        var components = URLComponents(url: ZeusCloudConfiguration.projectURL.appendingPathComponent("functions/v1/zeus-files"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "op", value: operation)]
        return try await request(components.url!, method: "POST", body: body)
    }
    public static func runtime(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        // Callers are native adapters, not model-supplied URLs. The access token
        // is only ever sent to the configured HTTPS runtime or Supabase project.
        guard path.hasPrefix("v1/"), !path.contains("://"), !path.contains("..") else { throw CloudAccountError.invalidResponse }
        let components = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var url = URLComponents(url: runtimeURL.appendingPathComponent(String(components[0])), resolvingAgainstBaseURL: false)!
        if components.count == 2 { url.percentEncodedQuery = String(components[1]) }
        return try await request(url.url!, method: method, body: body)
    }
    private static func request(_ url: URL, method: String, body: Data?) async throws -> Data {
        guard let id = CloudAccount.shared.identity?.id else { throw CloudAccountError.wrongOwner }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 90
        request.setValue("Bearer " + (try await CloudAccount.shared.authorization(for: id)), forHTTPHeaderField: "Authorization")
        request.setValue(ZeusCloudConfiguration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw NativeCloudHTTPError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0,
                message: detail ?? "تعذر الاتصال بالخادم. تبقى بياناتك المحلية محفوظة؛ أعد المحاولة بعد التحقق من الاتصال.")
        }
        guard data.count <= 8 * 1024 * 1024, CloudAccount.shared.identity?.id == id, CloudAccount.shared.phase == .ready else { throw CloudAccountError.wrongOwner }
        return data
    }
    public static func publishArchive(_ archive: NativeCloudArchive) async throws {
        let api = try transport()
        let ref = try await api.put(JSONEncoder().encode(archive))
        await CloudCheckpointGate.shared.enter()
        do {
            guard let head = try await api.head() else { throw CloudAccountError.incomplete("احفظ نسخة المتصفح في الحساب قبل نقل الوكيل.") }
            var manifest = head.manifest; manifest.native = ref; manifest.deletionEpoch = archive.deletionEpoch
            manifest.coverage = Array(Set(manifest.coverage + ["agent_archive", "encrypted_secrets"]))
            _ = try await api.commit(manifest, expected: head.revision, operation: UUID())
            await CloudCheckpointGate.shared.leave()
        } catch { await CloudCheckpointGate.shared.leave(); throw error }
    }
    public static func archive() async throws -> NativeCloudArchive? {
        let api = try transport()
        guard let ref = try await api.head()?.manifest.native else { return nil }
        let archive = try JSONDecoder().decode(NativeCloudArchive.self, from: await api.get(ref))
        guard archive.version == 1 else { throw CloudAccountError.invalidResponse }
        return archive
    }
    public static func hasCloudHistory() async throws -> Bool { try await transport().head()?.manifest.coverage.contains("cloud_runtime") == true }
}

public struct NativeCloudExecutionSettings: View {
    @State private var enabled = NativeCloudAccountAPI.usesCloud
    @State private var busy = false
    @State private var progress = ""
    @State private var issue: String?
    public init() {}
    public var body: some View {
        Form {
            Section("مكان تشغيل الوكيل") {
                Picker("التشغيل", selection: $enabled) { Text("محلي على الجهاز").tag(false); Text("سحابي").tag(true) }
                    .pickerStyle(.segmented).disabled(busy).accessibilityIdentifier("cloudExecutionTarget")
                Text(enabled ? "الوكيل والطرفية والمهام تعمل على الخادم. المتصفح وأدوات الجهاز متاحة عندما يكون جهازك حاضرًا فقط." : "يعمل الوكيل بأدواته وبيئة iSH المحلية الحالية.").font(.footnote)
            }
            Section("النقل والمساحة") {
                if enabled, let files = NativeCloudAccountAPI.sharedFilesView {
                    NavigationLink { files() } label: { Label("الملفات المشتركة والمهارات والذاكرة", systemImage: "folder.badge.gearshape") }
                }
                if busy { ProgressView(progress) }
                else if !progress.isEmpty { Text(progress) }
                if let issue { Text(issue).foregroundStyle(.orange).textSelection(.enabled) }
                Text("اختيار السحابي لا ينقل ملفات الجهاز. المحادثات الجديدة تُحفظ في الحساب وتستخدم Linux السحابي مباشرة. نقل المشاريع المحلية إجراء مستقل تختاره أدناه.").font(.footnote)
            }
            Section("المشاريع المحلية السابقة") {
                Text("الملفات المحلية تبقى على جهازك. استخدم النقل فقط إذا أردت متابعة مشروع محلي موجود على الخادم؛ مهارات التطبيق الجاهزة لا تُرفع.").font(.footnote)
                Button("نقل البيانات المحلية الموجودة إلى الحساب") {
                    Task {
                        busy = true; issue = nil
                        defer { busy = false }
                        do {
                            guard let delegate = NativeCloudAccountAPI.dataDelegate else { return }
                            try await delegate.migrateToCloud { progress = $0 }
                            try await delegate.finishExecutionTransition(enabled: nil)
                            progress = "اكتمل النقل والتحقق. الملفات الأصلية محفوظة على الجهاز."
                        } catch {
                            try? await NativeCloudAccountAPI.dataDelegate?.finishExecutionTransition(enabled: nil)
                            issue = error.localizedDescription
                        }
                    }
                }.disabled(busy)
            }
            Section("الخادم") {
                LabeledContent("التنفيذ المتزامن", value: "مهمة واحدة، والباقي في الطابور")
                Text("موارد محدودة، دون متصفح سحابي. تُغلق الاتصالات عند الخمول ليتمكن Railway من النوم بعد انتهاء العمل.").font(.footnote)
                Text("تستخدم أدوات Linux الخادم، وأدوات المتصفح والجهاز نفس التنفيذ الأصلي عند اتصال جهازك. إن احتاجت المهمة جهازًا غير متصل، تنتظر عودته وتُظهر السبب.").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("التشغيل والتخزين")
            .onChange(of: enabled) { previous, requested in
                guard !busy, requested != NativeCloudAccountAPI.usesCloud else { return }
                Task { await change(to: requested, previous: previous) }
            }
    }
    @MainActor private func change(to value: Bool, previous: Bool) async {
        busy = true; issue = nil; progress = "جارٍ التحقق…"
        defer { busy = false }
        do {
            guard let delegate = NativeCloudAccountAPI.dataDelegate else { throw CloudAccountError.incomplete("مسار نقل بيانات الوكيل غير متاح حاليًا.") }
            if value {
                try delegate.validateLocalExecutionIdle()
                try await NativeCloudAccountAPI.setEnabled(true)
                let data = try await NativeCloudAccountAPI.runtime("v1/capabilities")
                guard let capability = try JSONSerialization.jsonObject(with: data) as? [String: Any], capability["ready"] as? Bool == true else {
                    throw CloudAccountError.incomplete("الخادم غير جاهز للتنفيذ بعد؛ بقي الوضع المحلي كما هو.")
                }
                try await delegate.prepareCloudExecution { progress = $0 }
            } else { try await delegate.prepareLocalExecution { progress = $0 } }
            try await delegate.validateExecutionTransition()
            if !value { try await NativeCloudAccountAPI.setEnabled(false) }
            try await delegate.finishExecutionTransition(enabled: value)
            progress = value ? "فُعّل التشغيل السحابي بعد التحقق من النقل." : "فُعّل التشغيل المحلي. النسخة السحابية محفوظة."
        } catch {
            try? await NativeCloudAccountAPI.dataDelegate?.finishExecutionTransition(enabled: nil)
            enabled = NativeCloudAccountAPI.usesCloud; issue = error.localizedDescription
            progress = enabled == previous ? "لم يُغيّر مكان التنفيذ." : "تغير مكان التنفيذ؛ بقيت بعض النسخ المحلية حتى اكتمال تحرير المساحة."
        }
    }
}
