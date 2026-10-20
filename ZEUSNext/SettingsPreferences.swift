import Foundation
import SwiftUI
import WebKit

enum LaunchBehavior: String, Codable, CaseIterable, Identifiable { case restore, home; var id: String { rawValue } }
struct CustomSearchEngine: Codable, Identifiable, Equatable { var id = UUID(); var name: String; var template: String }
struct AdvancedSettings: Codable {
    var swipeNavigation = true
    var hideChromeOnScroll = true
    var showBookmarksBar = true
    var showTabsBar = true
    var openTabsInBackground = false
    var openTabsNextToActive = false
    var selectLeftAfterClosing = false
    var launchBehavior: LaunchBehavior = .restore
    var saveHistory = true
    var historyLimit = 1000
    var searchHistoryLimit = 100
    var searchInNewTab = false
    var customSearchEngines: [CustomSearchEngine] = []
    var selectedSearchEngineID: UUID?
    var javaScriptEnabled = true
    var showImages = true
    var autoplayMedia = false
    var allowMediaCapture = true
    var forceDarkWebPages = false
    var userAgent = ""
    var upgradeHTTPS = false
    var blockThirdPartyCookies = false
    var clearCacheOnExit = false
    var clearHistoryOnExit = false
    var clearCookiesOnExit = false
    var downloadsWiFiOnly = false
    var downloadsWiFiLimit = 5
    var downloadsCellularLimit = 2
    var confirmDownloads = false
    var downloadsInBackup = false
    var screenshotJPEG = false
    var screenshotQuality: Double = 0.9
    var screenshotScale: Double = 1
    var printHeader = true
    var printFooter = true
    var printMargin: Double = 24
    var paperSizedPDF = true
}

@MainActor final class ProfileSettingsContext: ObservableObject {
    let model: BrowserModel
    let profileID: UUID
    @Published var settings: BrowserSettings
    init(model: BrowserModel, profile: BrowserProfile?) {
        self.model = model; let owner = profile ?? model.profile; profileID = owner.id
        settings = owner.id == model.profile.id ? model.data.settings : model.profiles.load(owner).settings
    }
    var profile: BrowserProfile { model.profiles.profile(profileID) ?? model.profile }
    var options: AdvancedSettings { settings.advanced ?? AdvancedSettings() }
    var isActive: Bool { model.profile.id == profileID }
    var permitted: Bool { !model.requiresUnlock && (isActive || model.profile.isAdmin && !AccountVault.exists(profileID)) }
    func save(reload: Bool = false) {
        guard permitted, !model.requiresUnlock, profile.account?.allowSettings != false || model.profile.isAdmin else { return }
        if isActive { model.data.settings = settings; if reload { model.applySettings() } else { model.persist() } }
        else {
            var data = model.profiles.load(profile); data.settings = settings
            if profile.isPrivate { do { try model.profiles.saveTemplate(data, profile: profile) } catch { model.notify(error.localizedDescription) } }
            else { model.profiles.save(data, for: profile) }
        }
        model.downloads.preferencesDidChange(profile)
    }
    func option<T>(_ key: WritableKeyPath<AdvancedSettings,T>, reload: Bool = false) -> Binding<T> {
        Binding(get: { self.options[keyPath: key] }, set: { var value = self.options; value[keyPath: key] = $0; self.settings.advanced = value; self.save(reload: reload) })
    }
    func setting<T>(_ key: WritableKeyPath<BrowserSettings,T>, reload: Bool = false) -> Binding<T> {
        Binding(get: { self.settings[keyPath: key] }, set: { self.settings[keyPath: key] = $0; self.save(reload: reload) })
    }
}
