import Foundation
import SwiftUI
import WebKit

enum SearchProvider: String, Codable, CaseIterable, Identifiable {
    case google = "Google", duckDuckGo = "DuckDuckGo", bing = "Bing"
    var id: String { rawValue }
    var baseURL: String {
        switch self {
        case .google: return "https://www.google.com/search"
        case .duckDuckGo: return "https://duckduckgo.com/"
        case .bing: return "https://www.bing.com/search"
        }
    }
}

enum ProfileKind: String, Codable { case standard, ephemeral }

struct BrowserProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var symbol = "person.crop.circle.fill"
    var accent = "cyan"
    var kind: ProfileKind = .standard
    var locked = false
    var isPrivate: Bool { kind == .ephemeral }
    var account: AccountOptions?
    var role: AccountRole { account?.role ?? .standard }
    var isAdmin: Bool { role == .administrator }
    var color: Color { .white }

}

struct Bookmark: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var url: String
    var created = Date()
}

struct Visit: Codable, Identifiable {
    var id = UUID()
    var title: String
    var url: String
    var date = Date()
}

struct BrowserScript: Codable, Identifiable {
    var id = UUID()
    var name: String
    var domain: String
    var code: String
    var isActive = true
}

struct BrowserSettings: Codable {
    var searchProvider: SearchProvider = .google
    var shieldsEnabled = true
    var cosmeticFiltering = true
    var desktopMode = false
    var textScale: Double = 1
    var siteExceptions: [String] = []
    var popupExceptions: [String] = []
    var developerTools = false
    var chromeLayout: ChromeLayout?
    var reading: ReadingPreferences?
}

struct SavedTab: Codable, Identifiable {
    var id = UUID()
    var title = "بداية جديدة"
    var url = "zeus://home"
}

struct ProfileData: Codable {
    var bookmarks: [Bookmark] = []
    var history: [Visit] = []
    var scripts: [BrowserScript] = []
    var tabs: [SavedTab] = [SavedTab()]
    var selectedTabID: UUID?
    var settings = BrowserSettings()
    var searches: [String]?
}

enum BrowserURL {
    static func resolve(_ text: String, provider: SearchProvider) -> URL? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        if input == "zeus://home" { return URL(string: input) }
        if let url = URL(string: input), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme), url.host != nil {
            return url
        }
        if !input.contains(where: { $0.isWhitespace }), input.contains("."), !input.contains("://"),
           let url = URL(string: "https://" + input), url.host != nil { return url }
        var components = URLComponents(string: provider.baseURL)
        components?.queryItems = [URLQueryItem(name: "q", value: input)]
        return components?.url
    }

    static func hostMatches(_ host: String, domain: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let domain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return !domain.isEmpty && (host == domain || host.hasSuffix("." + domain))
    }

    static func isWeb(_ url: URL) -> Bool { ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil }
    static func displayHost(_ text: String) -> String { URL(string: text)?.host ?? text }
}

enum BrowserDisk {
    static var applicationRoot: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("ZEUSNext", isDirectory: true)
    }
    static var downloadsRoot: URL {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("ZEUS Downloads", isDirectory: true)
    }
    static func ensure(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try ensure(url.deletingLastPathComponent())
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func size(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        return enumerator.reduce(Int64(0)) { total, item in
            guard let item = item as? URL, let info = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), info.isRegularFile == true else { return total }
            return total + Int64(info.fileSize ?? 0)
        }
    }
}

@MainActor final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [BrowserProfile]
    @Published private(set) var activeID: UUID
    @Published var errorMessage: String?
    let root: URL
    let downloadsRoot: URL
    private var stores: [UUID: WKWebsiteDataStore] = [:]
    private struct Index: Codable { var profiles: [BrowserProfile]; var activeID: UUID }

    init(root: URL = BrowserDisk.applicationRoot, downloadsRoot: URL = BrowserDisk.downloadsRoot) {
        self.root = root; self.downloadsRoot = downloadsRoot
        if let index = BrowserDisk.read(Index.self, from: root.appendingPathComponent("profiles.json")), !index.profiles.isEmpty {
            profiles = index.profiles
            activeID = index.profiles.contains(where: { $0.id == index.activeID }) ? index.activeID : index.profiles[0].id
            if !profiles.contains(where: { $0.isAdmin }) { profiles[0].account = AccountOptions(role: .administrator); persistIndex() }
        } else {
            var initial = BrowserProfile(name: "الرئيسي")
            initial.account = AccountOptions(role: .administrator)
            profiles = [initial]; activeID = initial.id
            persistIndex()
            migrateLegacy(into: initial)
        }
    }

    var active: BrowserProfile { profiles.first(where: { $0.id == activeID }) ?? profiles[0] }
    func profile(_ id: UUID) -> BrowserProfile? { profiles.first(where: { $0.id == id }) }
    func folder(for profile: BrowserProfile) -> URL {
        if profile.isPrivate { return FileManager.default.temporaryDirectory.appendingPathComponent("ZEUS-Private-" + profile.id.uuidString) }
        return root.appendingPathComponent("Profiles").appendingPathComponent(profile.id.uuidString)
    }
    func downloads(for profile: BrowserProfile) -> URL {
        profile.isPrivate ? folder(for: profile).appendingPathComponent("Downloads") : downloadsRoot.appendingPathComponent(profile.id.uuidString)
    }
    func websiteDataStore(for profile: BrowserProfile) -> WKWebsiteDataStore {
        if let store = stores[profile.id] { return store }
        let store = profile.isPrivate ? WKWebsiteDataStore.nonPersistent() : WKWebsiteDataStore(forIdentifier: profile.id)
        stores[profile.id] = store
        return store
    }
    func load(_ profile: BrowserProfile) -> ProfileData {
        guard !profile.isPrivate else { return guestTemplate(profile) }
        return BrowserDisk.read(ProfileData.self, from: folder(for: profile).appendingPathComponent("browser.json")) ?? ProfileData()
    }
    func save(_ data: ProfileData, for profile: BrowserProfile) {
        guard !profile.isPrivate else { return }
        do { try BrowserDisk.write(data, to: folder(for: profile).appendingPathComponent("browser.json")) }
        catch { errorMessage = "تعذر حفظ بيانات المساحة: \(error.localizedDescription)" }
    }
    @discardableResult func add(name: String, accent: String, isPrivate: Bool) -> BrowserProfile {
        guard active.isAdmin else { errorMessage = AccountError.permission.localizedDescription; return active }
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
        let profile = BrowserProfile(name: name.isEmpty ? "مساحة جديدة" : name, symbol: isPrivate ? "theatermasks.fill" : "person.crop.circle.fill", accent: accent, kind: isPrivate ? .ephemeral : .standard)
        profiles.append(profile); persistIndex(); return profile
    }
    func select(_ id: UUID) { guard profile(id) != nil else { return }; activeID = id; persistIndex() }
    func update(_ profile: BrowserProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile; persistIndex()
    }
    func clearEphemeral(_ profile: BrowserProfile) async {
        guard profile.isPrivate else { return }
        let store = websiteDataStore(for: profile)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        stores.removeValue(forKey: profile.id)
        try? FileManager.default.removeItem(at: folder(for: profile))
    }
    func delete(_ profile: BrowserProfile) async throws {
        guard active.isAdmin, !profile.isAdmin, profiles.count > 1 else { throw AccountError.permission }
        let store = websiteDataStore(for: profile)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        stores.removeValue(forKey: profile.id)
        if !profile.isPrivate {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                WKWebsiteDataStore.remove(forIdentifier: profile.id) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }
        for path in [folder(for: profile), downloads(for: profile), configurationFolder(profile)] where FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        AccountVault.remove(profile.id)
        profiles.removeAll { $0.id == profile.id }
        if activeID == profile.id { activeID = profiles[0].id }
        persistIndex()
    }
    func resetAll() async throws {
        guard active.isAdmin else { throw AccountError.permission }
        let old = profiles
        for profile in old {
            await websiteDataStore(for: profile).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            if !profile.isPrivate {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in WKWebsiteDataStore.remove(forIdentifier: profile.id) { if let error = $0 { c.resume(throwing: error) } else { c.resume() } } }
            }
            AccountVault.remove(profile.id)
            for path in [folder(for: profile), downloads(for: profile), configurationFolder(profile)] where FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        }
        stores.removeAll()
        var initial = BrowserProfile(name: "الرئيسي"); initial.account = AccountOptions(role: .administrator)
        profiles = [initial]; activeID = initial.id; persistIndex()
        let filters = root.appendingPathComponent("Filters"); if FileManager.default.fileExists(atPath: filters.path) { try FileManager.default.removeItem(at: filters) }
    }
    private func persistIndex() {
        do { try BrowserDisk.write(Index(profiles: profiles, activeID: activeID), to: root.appendingPathComponent("profiles.json")) }
        catch { errorMessage = "تعذر حفظ البروفايلات: \(error.localizedDescription)" }
    }
    private func migrateLegacy(into profile: BrowserProfile) {
        var data = ProfileData()
        let defaults = UserDefaults.standard
        struct LegacyWebsite: Decodable { var id: UUID; var name: String; var url: String; var dateAdded: Date }
        if let raw = defaults.data(forKey: "saved_websites"), let sites = try? JSONDecoder().decode([LegacyWebsite].self, from: raw) { data.bookmarks = sites.map { Bookmark(id: $0.id, title: $0.name, url: $0.url, created: $0.dateAdded) } }
        if let raw = defaults.data(forKey: "browser_history_data"), let visits = try? JSONDecoder().decode([Visit].self, from: raw) { data.history = visits }
        if let raw = defaults.data(forKey: "browser_saved_tabs_list"), let tabs = try? JSONDecoder().decode([SavedTab].self, from: raw), !tabs.isEmpty { data.tabs = tabs; data.selectedTabID = defaults.string(forKey: "browser_last_active_tab_id").flatMap(UUID.init(uuidString:)) }
        data.searches = defaults.stringArray(forKey: "user_search_history_list")
        var reading = ReadingPreferences(); if defaults.object(forKey: "reader_fontSize") != nil { reading.fontSize = defaults.double(forKey: "reader_fontSize") }; if defaults.object(forKey: "reader_textOpacity") != nil { reading.textOpacity = defaults.double(forKey: "reader_textOpacity") }; reading.blockedWords = (defaults.string(forKey: "reader_blacklist") ?? "").split(separator: ",").map(String.init); if defaults.object(forKey: "gallery_image_scale") != nil { reading.imageScale = defaults.double(forKey: "gallery_image_scale") }; if defaults.object(forKey: "gallery_scroll_distance") != nil { reading.scrollDistance = defaults.double(forKey: "gallery_scroll_distance") }; data.settings.reading = reading
        if let raw = defaults.data(forKey: "user_custom_scripts"), let scripts = try? JSONDecoder().decode([BrowserScript].self, from: raw) { data.scripts = scripts }
        if let engine = defaults.string(forKey: "user_preferred_search_engine"), let value = SearchProvider(rawValue: engine) { data.settings.searchProvider = value }
        save(data, for: profile)
    }
}
