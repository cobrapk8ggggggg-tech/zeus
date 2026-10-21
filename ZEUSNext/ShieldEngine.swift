import Foundation
import WebKit
import CryptoKit

struct FilterRules {
    var domains = Set<String>()
    var allowed = Set<String>()
    var selectors = Set<String>()
    var unsupported = 0
    static func parse(_ text: String) -> FilterRules {
        var result = FilterRules()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") || line.hasPrefix("#") { continue }
            var value = line; let exception = value.hasPrefix("@@")
            if exception { value.removeFirst(2) }
            if value.hasPrefix("||"), let caret = value.firstIndex(of: "^") {
                let host = String(value[value.index(value.startIndex, offsetBy: 2)..<caret]).lowercased()
                let options = String(value[value.index(after: caret)...])
                if validDomain(host) && options.isEmpty {
                    if exception { result.allowed.insert(host) } else { result.domains.insert(host) }
                } else { result.unsupported += 1 }
            } else if validDomain(value) { result.domains.insert(value.lowercased()) }
            else { result.unsupported += 1 }
        }
        return result
    }
    static func validDomain(_ value: String) -> Bool {
        value.contains(".") && value.count < 254 && !value.contains("..") && value.utf8.allSatisfy { (45...46).contains($0) || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }
    static func regex(for domain: String) -> String {
        "^https?://([^/:]+\\.)?" + NSRegularExpression.escapedPattern(for: domain) + "(?::[0-9]+)?/"
    }
}

@MainActor final class ShieldEngine: ObservableObject {
    @Published private(set) var domains = OriginalShield.domains
    @Published private(set) var updating = false
    @Published var status = "حجب ZEUS الأصلي جاهز؛ الحزمة الكبيرة اختيارية"
    private let root: URL
    private var compiled: [String: WKContentRuleList] = [:]
    private var pending: [String: Task<WKContentRuleList, Error>] = [:]
    private var generations: [UUID: Int] = [:]
    init(root: URL = BrowserDisk.applicationRoot) {
        self.root = root
        // Earlier versions compiled a large bundle automatically. Remove only
        // that obsolete cache; account cookies and website data are untouched.
        WKContentRuleListStore.default().getAvailableContentRuleListIdentifiers { identifiers in
            for id in identifiers ?? [] where id.hasPrefix("zeus-v2-") { WKContentRuleListStore.default().removeContentRuleList(forIdentifier: id) { _ in } }
        }
        try? FileManager.default.removeItem(at: root.appendingPathComponent("Filters/easylist.txt"))
    }
    private func backupURL(_ profile: BrowserProfile) -> URL {
        let folder = profile.isPrivate ? FileManager.default.temporaryDirectory.appendingPathComponent("ZEUS-Private-" + profile.id.uuidString) : root.appendingPathComponent("Profiles").appendingPathComponent(profile.id.uuidString)
        return folder.appendingPathComponent("backup-rules.json")
    }
    func hasBackup(_ profile: BrowserProfile) -> Bool { FileManager.default.fileExists(atPath: backupURL(profile).path) }
    func backupBytes(_ profile: BrowserProfile) -> Int64 { Int64((try? backupURL(profile).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    func blocks(_ host: String) -> Bool {
        if OriginalShield.allowedDomains.contains(where: { BrowserURL.hostMatches(host, domain: $0) }) { return false }
        return domains.contains(where: { BrowserURL.hostMatches(host, domain: $0) })
    }
    static func originalRules(settings: BrowserSettings) -> [[String: Any]] {
        let options = settings.advanced ?? AdvancedSettings()
        var rules: [[String: Any]] = []
        if settings.shieldsEnabled {
            for domain in OriginalShield.domains.sorted() { rules.append(["trigger": ["url-filter": FilterRules.regex(for: domain)], "action": ["type": "block"]]) }
            for domain in OriginalShield.allowedDomains.sorted() { rules.append(["trigger": ["url-filter": FilterRules.regex(for: domain)], "action": ["type": "ignore-previous-rules"]]) }
            if settings.cosmeticFiltering { for selector in OriginalShield.cssSelectors { rules.append(["trigger": ["url-filter": ".*"], "action": ["type": "css-display-none", "selector": selector]]) } }
            // WebKit content filters reject regex disjunctions (a|b). Keep
            // the original media matching as separate supported rules.
            for marker in ["ad", "ads", "preroll", "midroll"] { rules.append(["trigger": ["url-filter": ".*" + marker + ".*mp4", "resource-type": ["media"]], "action": ["type": "block"]]) }
        }
        for host in settings.siteExceptions.filter(FilterRules.validDomain) { rules.append(["trigger": ["url-filter": ".*", "if-top-url": [FilterRules.regex(for: host)]], "action": ["type": "ignore-previous-rules"]]) }
        if !options.showImages { rules.append(["trigger": ["url-filter": ".*", "resource-type": ["image"]], "action": ["type": "block"]]) }
        if options.blockThirdPartyCookies { rules.append(["trigger": ["url-filter": ".*", "load-type": ["third-party"]], "action": ["type": "block-cookies"]]) }
        return rules
    }
    func list(profile: BrowserProfile, settings: BrowserSettings) async throws -> WKContentRuleList? {
        var rules = Self.originalRules(settings: settings)
        if settings.shieldsEnabled && settings.backupFiltersEnabled == true {
            guard hasBackup(profile) else { status = "استورد حزمة احتياطية أولًا. الحجب الأصلي مستمر."; return try await originalList(profile: profile, settings: settings) }
            let path = backupURL(profile)
            let backup = try await Task.detached(priority: .utility) { try Self.validatedBackup(Data(contentsOf: path)) }.value
            rules = (settings.cosmeticFiltering ? backup : backup.filter { ($0["action"] as? [String: Any])?["type"] as? String != "css-display-none" }) + rules
        }
        guard !rules.isEmpty else { return nil }
        do { let result = try await compile(rules, profile: profile, backup: settings.backupFiltersEnabled == true); status = settings.backupFiltersEnabled == true ? "الحجب الأصلي والحزمة الاحتياطية مفعّلان" : "حجب ZEUS الأصلي مفعّل"; return result }
        catch { status = "تعذر تجهيز الحزمة الاختيارية؛ الحجب الأصلي مستمر. \(error.localizedDescription)"; if settings.backupFiltersEnabled == true { return try await originalList(profile: profile, settings: settings) }; throw error }
    }
    private func originalList(profile: BrowserProfile, settings: BrowserSettings) async throws -> WKContentRuleList? {
        let rules = Self.originalRules(settings: settings); return rules.isEmpty ? nil : try await compile(rules, profile: profile, backup: false)
    }
    private func compile(_ rules: [[String: Any]], profile: BrowserProfile, backup: Bool) async throws -> WKContentRuleList {
        let generation = generations[profile.id, default: 0]
        let bytes = try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let identifier = "zeus-v4-" + profile.id.uuidString + "-" + digest
        if let cached = compiled[identifier] { return cached }
        if let existing = pending[identifier] { return try await existing.value }
        let operation = Task { @MainActor () throws -> WKContentRuleList in
            let saved: WKContentRuleList? = await withCheckedContinuation { c in WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: identifier) { list, _ in c.resume(returning: list) } }
            if let saved { return saved }
            return try await withCheckedThrowingContinuation { c in
                let gate = RuleCompilerGate(c)
                DispatchQueue.main.asyncAfter(deadline: .now() + (backup ? 60 : 8)) { gate.finish(nil, URLError(.timedOut)) }
                WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: String(decoding: bytes, as: UTF8.self)) { list, error in
                    Task { @MainActor in
                        if !gate.finish(list, error), list != nil { WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { _ in } }
                    }
                }
            }
        }
        pending[identifier] = operation
        defer { pending.removeValue(forKey: identifier) }
        let result = try await operation.value
        guard generations[profile.id, default: 0] == generation else { WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { _ in }; throw CancellationError() }
        compiled[identifier] = result; return result
    }
    nonisolated static func validatedBackup(_ data: Data) throws -> [[String: Any]] {
        guard data.count <= 20_000_000, let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], !rows.isEmpty, rows.count <= 140_000,
              rows.allSatisfy({ row in guard let trigger = row["trigger"] as? [String: Any], let pattern = trigger["url-filter"] as? String, pattern.count <= 10_000, let action = row["action"] as? [String: Any], let type = action["type"] as? String else { return false }; return ["block", "block-cookies", "css-display-none", "ignore-previous-rules", "make-https"].contains(type) }) else { throw URLError(.cannotParseResponse) }
        return rows
    }
    func importBackup(_ source: URL, profile: BrowserProfile) async throws {
        let scoped = source.startAccessingSecurityScopedResource(); defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let target = backupURL(profile)
        try await Task.detached(priority: .utility) {
            guard ((try source.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0) <= 20_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
            let data = try Data(contentsOf: source); _ = try Self.validatedBackup(data)
            try BrowserDisk.ensure(target.deletingLastPathComponent()); try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }.value
        status = "استُوردت الحزمة. تفعيلها اختياري من المفتاح أدناه."
    }
    func removeBackup(_ profile: BrowserProfile) { try? FileManager.default.removeItem(at: backupURL(profile)); erase(profile.id); status = "حُذفت الحزمة وكاش قواعدها؛ حجب ZEUS الأصلي مستمر" }
    func erase(_ profile: UUID) { generations[profile, default: 0] += 1; compiled = compiled.filter { !$0.key.contains(profile.uuidString) }; removeCachedRules { $0.contains(profile.uuidString) && ($0.hasPrefix("zeus-v2-") || $0.hasPrefix("zeus-v4-")) } }
    func invalidate(_ profile: UUID) { compiled = compiled.filter { !$0.key.contains(profile.uuidString) } }
    private func removeCachedRules(matching: @escaping (String) -> Bool) { WKContentRuleListStore.default().getAvailableContentRuleListIdentifiers { ids in for id in ids ?? [] where matching(id) { WKContentRuleListStore.default().removeContentRuleList(forIdentifier: id) { _ in } } } }
    func update() async { status = "الحجب الأصلي محلي ولا ينزّل قوائم تلقائيًا. يمكنك استيراد حزمة Safari JSON اختيارية." }
}

@MainActor private final class RuleCompilerGate {
    private var continuation: CheckedContinuation<WKContentRuleList, Error>?
    init(_ continuation: CheckedContinuation<WKContentRuleList, Error>) { self.continuation = continuation }
    @discardableResult func finish(_ value: WKContentRuleList?, _ error: Error?) -> Bool {
        guard let continuation else { return false }; self.continuation = nil
        if let value { continuation.resume(returning: value) } else { continuation.resume(throwing: error ?? URLError(.cannotParseResponse)) }; return true
    }
}
