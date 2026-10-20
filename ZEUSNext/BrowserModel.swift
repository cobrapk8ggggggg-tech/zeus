import SwiftUI
import WebKit
import LocalAuthentication

@MainActor final class BrowserTab: Identifiable {
    let id: UUID
    let profileID: UUID
    var title: String
    var url: String
    var webView: WKWebView?
    var driver: WebDriver?
    var loading = false
    var progress: Double = 0
    var error: String?
    var snapshot: UIImage?
    var lastUsed = Date()
    init(saved: SavedTab, profileID: UUID) { id = saved.id; title = saved.title; url = saved.url; self.profileID = profileID }
    var saved: SavedTab { SavedTab(id: id, title: title, url: url) }
    var isHome: Bool { url == "zeus://home" }
    func dispose() {
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "zeusConsole")
        webView?.navigationDelegate = nil; webView?.uiDelegate = nil
        driver?.observations.removeAll(); driver = nil; webView = nil; loading = false
    }
}

struct BrowserNotice: Identifiable { let id = UUID(); var text: String }
struct ReaderArticle: Identifiable { let id = UUID(); var title: String; var paragraphs: [String] }
struct GalleryArticle: Identifiable { let id = UUID(); var images: [String] }
struct ConsoleEntry: Identifiable { let id = UUID(); var text: String; var kind: String; let date = Date() }
struct ShareItem: Identifiable { let id = UUID(); var url: URL }
struct WebDialog: Identifiable {
    enum Kind: Equatable { case alert, confirm, prompt }
    let id = UUID(); var kind: Kind; var text: String; var initial = ""
    var complete: (String?) -> Void
}

@MainActor final class BrowserModel: ObservableObject {
    let profiles: ProfileStore
    let downloads: DownloadService
    let shield: ShieldEngine
    @Published var data: ProfileData
    @Published var tabs: [BrowserTab] = []
    @Published var selectedTabID: UUID?
    @Published var notice: BrowserNotice?
    @Published var article: ReaderArticle?
    @Published var gallery: GalleryArticle?
    @Published var console: [ConsoleEntry] = []
    @Published var share: ShareItem?
    @Published var dialog: WebDialog?
    @Published var pendingPopup: URLRequest?
    @Published var requiresUnlock = false
    @Published var switching = false
    @Published var address = ""
    @Published var blockedNavigations = 0
    @Published var chromeHidden = false
    private var leftAt: Date?
    init(profiles: ProfileStore? = nil, useBackgroundDownloads: Bool = true) {
        let store = profiles ?? ProfileStore()
        self.profiles = store; downloads = DownloadService(store: store, useBackground: useBackgroundDownloads)
        shield = ShieldEngine(root: store.root); data = store.load(store.active)
        restoreTabs(); requiresUnlock = store.active.locked || AccountVault.exists(store.activeID)
    }
    var profile: BrowserProfile { profiles.active }
    var current: BrowserTab? { tabs.first { $0.id == selectedTabID } }
    var webView: WKWebView? { current?.webView }
    var currentHost: String { URL(string: current?.url ?? "")?.host ?? "" }
    var siteCompatible: Bool { data.settings.siteExceptions.contains { BrowserURL.hostMatches(currentHost, domain: $0) } }
    private func restoreTabs() {
        tabs = (data.tabs.isEmpty ? [SavedTab()] : Array(data.tabs.prefix(30))).map { BrowserTab(saved: $0, profileID: profiles.activeID) }
        selectedTabID = tabs.contains { $0.id == data.selectedTabID } ? data.selectedTabID : tabs.first?.id
        address = current?.isHome == false ? current?.url ?? "" : ""
    }
    func persist() {
        guard !requiresUnlock else { return }
        data.tabs = tabs.map(\.saved); data.selectedTabID = selectedTabID
        profiles.save(data, for: profile)
    }
    func changed() { objectWillChange.send() }
    func notify(_ text: String) { notice = BrowserNotice(text: text) }
    func prepare(_ tab: BrowserTab, supplied: WKWebViewConfiguration? = nil) async -> WKWebView? {
        if let view = tab.webView { return view }
        guard tab.profileID == profile.id, !requiresUnlock else { return nil }
        let owner = profile, settings = data.settings
        let config = supplied ?? WKWebViewConfiguration()
        config.websiteDataStore = profiles.websiteDataStore(for: owner)
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.preferredContentMode = settings.desktopMode ? .desktop : .mobile
        config.allowsInlineMediaPlayback = true
        let controller = WKUserContentController(); config.userContentController = controller
        do { if let list = try await shield.list(profile: owner, settings: settings) { controller.add(list) } }
        catch { notify("تعذر تحميل قواعد الحجب: \(error.localizedDescription)") }
        guard owner.id == profile.id, tabs.contains(where: { $0.id == tab.id }) else { return nil }
        for script in data.scripts where script.isActive && owner.account?.allowScripts != false {
            let domain = script.domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard domain == "*" || FilterRules.validDomain(domain) else { continue }
            let encoded = (try? JSONEncoder().encode(domain)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
            let source = "(()=>{const d=\(encoded);const h=location.hostname.toLowerCase();if(d==='*'||h===d||h.endsWith('.'+d)){\n\(script.code)\n}})();"
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true; view.allowsLinkPreview = true
        view.isFindInteractionEnabled = true; view.isInspectable = settings.developerTools && owner.account?.allowDeveloperTools != false
        view.pageZoom = settings.textScale
        view.scrollView.contentInsetAdjustmentBehavior = .never
        let driver = WebDriver(model: self, tab: tab)
        view.navigationDelegate = driver; view.uiDelegate = driver
        view.scrollView.delegate = driver
        if settings.developerTools && owner.account?.allowDeveloperTools != false {
            controller.add(driver, name: "zeusConsole")
            controller.addUserScript(WKUserScript(source: BrowserTools.consoleScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        tab.webView = view; tab.driver = driver; driver.observe(view)
        let keep = tabs.filter { $0.webView != nil && $0.id != tab.id }.sorted { $0.lastUsed > $1.lastUsed }
        for old in keep.dropFirst(3) { old.dispose() }
        changed(); return view
    }
    func ensureCurrentLoaded() async {
        guard let tab = current, !tab.isHome, tab.webView == nil, let url = URL(string: tab.url), let view = await prepare(tab) else { return }
        view.load(URLRequest(url: url))
    }
    func open(_ text: String) {
        guard let url = BrowserURL.resolve(text, provider: data.settings.searchProvider) else { notify("اكتب رابطًا أو عبارة بحث."); return }
        open(URLRequest(url: url))
    }
    func open(_ request: URLRequest) {
        guard let tab = current, let url = request.url else { return }
        if url.scheme == "zeus" { home(); return }
        guard BrowserURL.isWeb(url) else { notify("هذا النوع من الروابط يُفتح من قائمة التطبيقات الخارجية."); return }
        guard permits(url) else { notify("هذا النطاق خارج المواقع المسموح بها لهذا الحساب."); return }
        tab.url = url.absoluteString; tab.error = nil; address = tab.url; tab.lastUsed = Date(); changed(); persist()
        Task { if let view = await prepare(tab), profile.id == tab.profileID { view.load(request) } }
    }
    @discardableResult func newTab(url: URL? = nil) -> BrowserTab? {
        guard tabs.count < 30 else { notify("الحد الحالي 30 تبويبًا لحماية ذاكرة الجهاز."); return nil }
        snapshotCurrent()
        let tab = BrowserTab(saved: SavedTab(), profileID: profile.id)
        tabs.append(tab); selectedTabID = tab.id; address = ""; persist()
        if let url { open(URLRequest(url: url)) }
        return tab
    }
    func selectTab(_ tab: BrowserTab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        snapshotCurrent(); selectedTabID = tab.id; tab.lastUsed = Date(); address = tab.isHome ? "" : tab.url; persist()
        Task { await ensureCurrentLoaded() }
    }
    func closeTab(_ tab: BrowserTab) {
        tab.dispose(); tabs.removeAll { $0.id == tab.id }
        if tabs.isEmpty { _ = newTab() }
        else if selectedTabID == tab.id { selectTab(tabs[tabs.count - 1]) }
        persist()
    }
    func closeAllTabs() { for tab in tabs { tab.dispose() }; tabs.removeAll(); _ = newTab() }
    func home() { current?.dispose(); current?.url = "zeus://home"; current?.title = "بداية جديدة"; address = ""; changed(); persist() }
    func reload() { current?.error = nil; if let view = webView { view.reload() } else { Task { await ensureCurrentLoaded() } } }
    func snapshotCurrent() {
        guard let tab = current, let view = tab.webView, !tab.isHome, view.bounds.width > 0 else { return }
        let config = WKSnapshotConfiguration(); config.snapshotWidth = 240
        view.takeSnapshot(with: config) { [weak self, weak tab] image, _ in tab?.snapshot = image; self?.changed() }
    }
    func addVisit(tab: BrowserTab) {
        guard profile.id == tab.profileID, !profile.isPrivate, let url = URL(string: tab.url), BrowserURL.isWeb(url) else { return }
        if data.history.first?.url == tab.url { data.history.removeFirst() }
        data.history.insert(Visit(title: tab.title, url: tab.url), at: 0)
        data.history = Array(data.history.prefix(1000)); persist()
    }
    func bookmarkCurrent() {
        guard profile.role != .guest, profile.role != .kiosk else { notify("هذا الحساب لا يحفظ مفضلة جديدة."); return }
        guard let tab = current, !tab.isHome else { return }
        if !data.bookmarks.contains(where: { $0.url == tab.url }) { data.bookmarks.insert(Bookmark(title: tab.title, url: tab.url), at: 0); persist(); notify("حُفظت الصفحة في هذه المساحة.") }
    }
    func switchProfile(to target: BrowserProfile, password: String = "") async {
        guard !switching, target.account?.enabled != false, target.id != profile.id || requiresUnlock else { return }; switching = true; defer { switching = false }
        if AccountVault.exists(target.id), !(await AccountVault.verify(password, id: target.id)) { notify(AccountError.password.localizedDescription); return }
        if target.locked, !(await authenticate(reason: "فتح مساحة \(target.name)")) { return }
        let previous = profile; if !requiresUnlock { persist() }
        for tab in tabs { tab.dispose() }; console.removeAll(); pendingPopup = nil
        dialog?.complete(nil); dialog = nil; article = nil; gallery = nil; share = nil
        if previous.isPrivate { downloads.removeAll(profileID: previous.id); await profiles.clearEphemeral(previous) }
        profiles.select(target.id); data = profiles.load(target); blockedNavigations = 0; requiresUnlock = false; chromeHidden = false; restoreTabs()
        if target.role == .kiosk, let home = target.account?.homePage, home != "zeus://home" { open(home) }
        await ensureCurrentLoaded()
    }
    func authenticate(reason: String) async -> Bool {
        let context = LAContext(); var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { notify(error?.localizedDescription ?? "فعّل رمز قفل الجهاز أولًا."); return false }
        do { return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) }
        catch { return false }
    }
    func unlock() async { if await authenticate(reason: "فتح مساحة \(profile.name)") { requiresUnlock = false; await ensureCurrentLoaded() } }
    func setProfileLock(_ locked: Bool) async {
        guard await authenticate(reason: locked ? "حماية هذه المساحة" : "إلغاء حماية المساحة") else { return }
        var changed = profile; changed.locked = locked; profiles.update(changed)
    }
    func backgrounded() {
        leftAt = Date()
        persist(); if profile.locked { requiresUnlock = true }
        if profile.isPrivate {
            for tab in tabs { tab.dispose() }; downloads.removeAll(profileID: profile.id)
            let owner = profile
            Task { await profiles.clearEphemeral(owner); data = ProfileData(); restoreTabs() }
        }
    }
    func applySettings(reload: Bool = true) {
        persist(); shield.invalidate(profile.id)
        guard reload else { return }
        for tab in tabs { tab.dispose() }; Task { await ensureCurrentLoaded() }; changed()
    }
    func toggleCompatibility() {
        guard !currentHost.isEmpty else { return }
        if siteCompatible { data.settings.siteExceptions.removeAll { BrowserURL.hostMatches(currentHost, domain: $0) } }
        else { data.settings.siteExceptions.append(currentHost) }
        applySettings(); notify(siteCompatible ? "وضع التوافق مفعّل لهذا الموقع؛ الحجب متوقف فيه." : "أعيد تفعيل الحجب لهذا الموقع.")
    }
    func allowPendingPopup() {
        guard let request = pendingPopup else { return }; pendingPopup = nil
        if let tab = newTab(), let url = request.url { tab.url = url.absoluteString; open(request) }
    }
    func clearWebsiteData(cacheOnly: Bool) async {
        for tab in tabs { tab.dispose() }
        let types: Set<String> = cacheOnly ? [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache] : WKWebsiteDataStore.allWebsiteDataTypes()
        await profiles.websiteDataStore(for: profile).removeData(ofTypes: types, modifiedSince: .distantPast)
        await ensureCurrentLoaded(); notify(cacheOnly ? "مُسحت الملفات المؤقتة لهذه المساحة." : "مُسحت بيانات المواقع والجلسات لهذه المساحة.")
    }
    func deleteProfile(_ target: BrowserProfile) async {
        guard profile.isAdmin, !target.isAdmin else { notify("الحذف للحساب الرئيسي فقط، ولا يمكن حذف الحساب الرئيسي."); return }
        guard profiles.profiles.count > 1 else { notify("أبقِ مساحة واحدة على الأقل."); return }
        if target.id == profile.id, let other = profiles.profiles.first(where: { $0.id != target.id }) { await switchProfile(to: other); if profile.id == target.id { return } }
        downloads.removeAll(profileID: target.id)
        do { try await profiles.delete(target) } catch { notify(error.localizedDescription) }
    }
    func permits(_ url: URL) -> Bool {
        let domains = profile.account?.allowedDomains ?? []
        return domains.isEmpty || domains.contains { BrowserURL.hostMatches(url.host ?? "", domain: $0) }
    }
    func becameActive() {
        if let leftAt, let timeout = profile.account?.logoutAfter, timeout >= 0, Date().timeIntervalSince(leftAt) >= timeout { logout() }
        leftAt = nil
    }
    func logout() {
        if !requiresUnlock { persist() }
        for tab in tabs { tab.dispose() }; tabs.removeAll(); data = ProfileData(); console.removeAll(); article = nil; gallery = nil; share = nil; pendingPopup = nil; address = ""; requiresUnlock = true
        if profile.isPrivate { let owner = profile; downloads.removeAll(profileID: owner.id); Task { await profiles.clearEphemeral(owner) } }
    }
}
