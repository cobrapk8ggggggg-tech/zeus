import Foundation
import WebKit

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
    @Published private(set) var domains: Set<String> = []
    @Published private(set) var updating = false
    @Published var status = "قواعد محلية جاهزة"
    private var allowed: Set<String> = []
    private var compiled: [UUID: WKContentRuleList] = [:]
    private let updatesURL: URL
    init(root: URL = BrowserDisk.applicationRoot) {
        updatesURL = root.appendingPathComponent("Filters/easylist.txt")
        let bundled = Bundle.main.url(forResource: "block-domains", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "doubleclick.net\ngooglesyndication.com\npopads.net\n"
        domains = FilterRules.parse(bundled).domains
        if let update = try? String(contentsOf: updatesURL, encoding: .utf8) { merge(update) }
    }
    private func merge(_ text: String) {
        let parsed = FilterRules.parse(text)
        domains.formUnion(parsed.domains); allowed.formUnion(parsed.allowed)
        status = "\(domains.count) نطاق · \(parsed.unsupported) قاعدة متقدمة غير مدعومة"
        compiled.removeAll()
    }
    func blocks(_ host: String) -> Bool {
        if allowed.contains(where: { BrowserURL.hostMatches(host, domain: $0) }) { return false }
        return domains.contains(where: { BrowserURL.hostMatches(host, domain: $0) })
    }
    func list(profile: BrowserProfile, settings: BrowserSettings) async throws -> WKContentRuleList? {
        guard settings.shieldsEnabled else { return nil }
        if let cached = compiled[profile.id] { return cached }
        let exceptions = settings.siteExceptions.filter(FilterRules.validDomain)
        var rules: [[String: Any]] = domains.sorted().prefix(28000).map { domain in
            var trigger: [String: Any] = ["url-filter": FilterRules.regex(for: domain)]
            if !exceptions.isEmpty { trigger["unless-top-url"] = exceptions.map(FilterRules.regex(for:)) }
            return ["trigger": trigger, "action": ["type": "block"]]
        }
        for host in allowed.sorted().prefix(2000) {
            rules.append(["trigger": ["url-filter": FilterRules.regex(for: host)], "action": ["type": "ignore-previous-rules"]])
        }
        if settings.cosmeticFiltering {
            var trigger: [String: Any] = ["url-filter": ".*"]
            if !exceptions.isEmpty { trigger["unless-top-url"] = exceptions.map(FilterRules.regex(for:)) }
            rules.append(["trigger": trigger, "action": ["type": "css-display-none", "selector": ".adsbygoogle,[id^='google_ads_'],[data-ad-slot],iframe[src*='doubleclick.net']"]])
        }
        guard let json = String(data: try JSONSerialization.data(withJSONObject: rules), encoding: .utf8) else { return nil }
        let value: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "zeus-v2-" + profile.id.uuidString, encodedContentRuleList: json) { list, error in
                if let list { continuation.resume(returning: list) }
                else { continuation.resume(throwing: error ?? URLError(.cannotParseResponse)) }
            }
        }
        compiled[profile.id] = value; return value
    }
    func invalidate(_ profile: UUID) { compiled.removeValue(forKey: profile) }
    func update() async {
        guard !updating else { return }; updating = true; defer { updating = false }
        do {
            let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
            let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.data(from: URL(string: "https://easylist.to/easylist/easylist.txt")!)
            guard (response as? HTTPURLResponse)?.statusCode == 200, bytes.count <= 12_000_000, let text = String(data: bytes, encoding: .utf8), FilterRules.parse(text).domains.count > 100 else { throw URLError(.cannotParseResponse) }
            try BrowserDisk.ensure(updatesURL.deletingLastPathComponent()); try bytes.write(to: updatesURL, options: .atomic)
            merge(text)
        } catch { status = "لم يكتمل التحديث: \(error.localizedDescription)" }
    }
}
