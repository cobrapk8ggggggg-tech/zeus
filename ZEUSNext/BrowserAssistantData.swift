import Foundation

enum BrowserAssistantRole: String, Codable { case user, assistant, system }

struct BrowserAssistantMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var role: BrowserAssistantRole
    var text: String
    var created = Date()
}

struct BrowserAssistantConversation: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = "محادثة جديدة"
    var messages: [BrowserAssistantMessage] = []
    var providerID: UUID?
    var updated = Date()
}

struct BrowserAssistantPreferences: Codable, Equatable {
    var approvedContext = false
    var currentPage = true
    var openTabs = true
    var bookmarks = true
    var recentHistory = false
    var profileSummary = true
    var allowedNavigationHosts: [String] = []
}

struct BrowserAssistantArchive: Codable {
    var version = 1
    var conversations: [BrowserAssistantConversation] = []
    var selectedID: UUID?
    var preferences = BrowserAssistantPreferences()
}

enum BrowserAssistantAction: Equatable, Identifiable {
    case open(URL)
    case selectTab(UUID, String)

    var id: String {
        switch self {
        case .open(let url): return "open:" + url.absoluteString
        case .selectTab(let id, _): return "tab:" + id.uuidString
        }
    }
    var title: String {
        switch self {
        case .open(let url): return "فتح " + (url.host ?? url.absoluteString)
        case .selectTab(_, let title): return "الانتقال إلى " + title
        }
    }
    var detail: String {
        switch self {
        case .open(let url): return url.absoluteString
        case .selectTab: return "سيصبح هذا التبويب هو التبويب النشط."
        }
    }
}
