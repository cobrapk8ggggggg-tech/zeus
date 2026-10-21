import SwiftUI
import WebKit
import UniformTypeIdentifiers

enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case translation, ai, account, appearance, tabs, launch, privacy, personalData, websites, network, tools, services, other, help
    var id: String { rawValue }
    var title: String {
        switch self { case .translation: return "ترجمة الصفحات"; case .ai: return "الذكاء الاصطناعي"; case .account: return "الحساب"; case .appearance: return "واجهة المستخدم والأشرطة"; case .tabs: return "التبويبات"; case .launch: return "بدء التطبيق"; case .privacy: return "الخصوصية"; case .personalData: return "البيانات الشخصية"; case .websites: return "مواقع الويب"; case .network: return "الشبكة"; case .tools: return "الأدوات"; case .services: return "الخدمات"; case .other: return "أخرى"; case .help: return "المساعدة والخصوصية" }
    }
    var symbol: String {
        switch self { case .translation: return "translate"; case .ai: return "sparkles"; case .account: return "person.2"; case .appearance: return "macwindow.on.rectangle"; case .tabs: return "square.on.square"; case .launch: return "play"; case .privacy: return "hand.raised"; case .personalData: return "tray"; case .websites: return "character.book.closed"; case .network: return "antenna.radiowaves.left.and.right"; case .tools: return "wrench.and.screwdriver"; case .services: return "cloud"; case .other: return "archivebox"; case .help: return "questionmark.circle" }
    }
    var group: Int { switch self { case .account: return 0; case .appearance, .tabs, .launch: return 1; case .privacy, .personalData: return 2; case .translation, .ai, .websites, .network, .tools, .services: return 3; case .other: return 4; case .help: return 5 } }
}

struct SettingsSheet: View {
    private var theme: BrowserTheme { context.settings.theme ?? .standard }
    @StateObject private var context: ProfileSettingsContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selection: SettingsCategory? = .account
    @State private var path: [SettingsCategory]
    @State private var search = ""
    private let activeAtOpening: UUID
    init(model: BrowserModel, profile: BrowserProfile? = nil) {
        activeAtOpening = model.profiles.activeID
        _context = StateObject(wrappedValue: ProfileSettingsContext(model: model, profile: profile))
        _path = State(initialValue: profile == nil ? [] : [.account])
    }
    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    categoryList.navigationSplitViewColumnWidth(min: 250, ideal: 320, max: 380)
                } detail: { NavigationStack { if let selection { detail(selection) } } }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationStack(path: $path) {
                    categoryList.navigationDestination(for: SettingsCategory.self) { detail($0) }
                }
            }
        }.tint(theme.buttonTextColor).foregroundStyle(theme.textColor).preferredColorScheme(theme.light ? .light : .dark).environment(\.layoutDirection, .rightToLeft).browserTheme(theme)
            .onReceive(context.model.profiles.$activeID) { id in if id != activeAtOpening { dismiss() } }
            .onReceive(context.model.$requiresUnlock) { locked in if locked { dismiss() } }
    }
    private var categoryList: some View {
        List {
            ForEach(0..<6) { group in
                ThemedSection {
                    ForEach(SettingsCategory.allCases.filter { $0.group == group && (context.profile.account?.allowSettings != false || context.model.profile.isAdmin || [.account, .help].contains($0)) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }) { category in
                        if sizeClass == .regular {
                            Button { selection = category } label: { categoryLabel(category) }.buttonStyle(.plain).listRowBackground(theme.backgroundColor).overlay(alignment: .leading) { if selection == category { Rectangle().fill(theme.accentColor).frame(width: 2) } }
                        } else { NavigationLink(value: category) { categoryLabel(category) }.listRowBackground(theme.backgroundColor) }
                    }
                }
            }
        }.listStyle(.insetGrouped).scrollContentBackground(.hidden).background(theme.backgroundColor).navigationTitle("الإعدادات").navigationBarTitleDisplayMode(.inline).searchable(text: $search, prompt: "بحث")
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("تم") { dismiss() } } }
    }
    private func categoryLabel(_ category: SettingsCategory) -> some View { Label(category.title, systemImage: category.symbol).labelStyle(BrowserSettingsLabelStyle()).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).accessibilityIdentifier("category-" + category.rawValue) }
    @ViewBuilder private func detail(_ category: SettingsCategory) -> some View {
        Group { switch category {
        case .translation: TranslationSettingsPage(context: context)
        case .ai: AISettingsPage(context: context)
        case .account: AccountSettingsView(model: context.model, profile: context.profile, embedded: true)
        case .appearance: appearance
        case .tabs: tabSettings
        case .launch: launchSettings
        case .privacy: privacy
        case .personalData: StorageSettingsPage(context: context)
        case .websites: websites
        case .network: NetworkSettingsPage(context: context)
        case .tools: ToolSettingsPage(context: context)
        case .services: ProfileTransferPage(context: context)
        case .other: other
        case .help: help
        } }.toolbar { ToolbarItem(placement: .topBarTrailing) { Button("تم") { dismiss() } } }
    }
    private var appearance: some View {
        Form {
            ThemedSection { NavigationLink { ThemeEditor(context: context) } label: { Label("الألوان والمظهر", systemImage: "paintpalette") }.accessibilityIdentifier("themeEditorButton") }
            ThemedSection("توزيع الأشرطة") {
                ForEach(ChromeLayout.allCases) { layout in Button { context.settings.chromeLayout = layout; context.save(); context.model.chromeHidden = false } label: { HStack { Text(layout.title); Spacer(); if (context.settings.chromeLayout ?? .original) == layout { Image(systemName: "checkmark") } } }.accessibilityIdentifier("layout-" + layout.rawValue) }
            }
            ThemedSection("الأشرطة") { Toggle("إخفاء الأشرطة عند التمرير", isOn: context.option(\.hideChromeOnScroll)); Toggle("شريط المفضلة في توزيع iCab", isOn: context.option(\.showBookmarksBar)); Toggle("شريط التبويبات في توزيع iCab", isOn: context.option(\.showTabsBar)); Toggle("السحب للتنقل بين الصفحات", isOn: context.option(\.swipeNavigation, reload: true)) }
            ThemedSection { Text("في ZEUS الأصلي: اسحب من اليمين للأدوات، ومن الأعلى للتبويبات. الأوامر نفسها متاحة في التوزيعات الثلاثة. الواجهة سوداء والأيقونات والنصوص بيضاء.").font(.footnote) }
        }.settingsPage("واجهة المستخدم")
    }
    private var tabSettings: some View {
        Form { ThemedSection("فتح التبويبات وإغلاقها") { Toggle("فتح التبويب الجديد في الخلفية", isOn: context.option(\.openTabsInBackground)); Toggle("فتح التبويب بجانب الحالي", isOn: context.option(\.openTabsNextToActive)); Toggle("تحديد التبويب السابق عند الإغلاق", isOn: context.option(\.selectLeftAfterClosing)) }; ThemedSection { Text("تُحفظ تبويبات كل حساب بصورة مستقلة. يحتفظ المتصفح بأربع صفحات WebKit حية ويعيد تحميل بقية التبويبات عند اختيارها لتقليل استهلاك الذاكرة.").font(.footnote) } }.settingsPage("التبويبات")
    }
    private var launchSettings: some View {
        Form { ThemedSection("عند فتح التطبيق") { Picker("بدء التطبيق", selection: context.option(\.launchBehavior)) { Text("استعادة التبويبات").tag(LaunchBehavior.restore); Text("صفحة البداية").tag(LaunchBehavior.home) } }; ThemedSection("صفحة بداية الحساب") { TextField("zeus://home أو رابط HTTPS", text: Binding(get: { context.profile.account?.homePage ?? "zeus://home" }, set: { var profile = context.profile; var options = profile.account ?? AccountOptions(); options.homePage = $0; profile.account = options; context.model.profiles.update(profile) })).textInputAutocapitalization(.never).autocorrectionDisabled() } }.settingsPage("بدء التطبيق")
    }
    private var privacy: some View {
        Form {
            ThemedSection("السجل والكوكيز") { Toggle("حفظ سجل التصفح", isOn: context.option(\.saveHistory)); Picker("الحد الأقصى للسجل", selection: context.option(\.historyLimit)) { ForEach([100, 500, 1000, 5000], id: \.self) { Text("\($0)").tag($0) } }; Toggle("حجب كوكيز طلبات الأطراف الخارجية", isOn: context.option(\.blockThirdPartyCookies, reload: true)); NavigationLink("كوكيز الحساب") { CookieSettingsPage(context: context) } }
            ThemedSection("عند تسجيل الخروج أو مغادرة التطبيق") { Toggle("مسح الملفات المؤقتة", isOn: context.option(\.clearCacheOnExit)); Toggle("مسح سجل التصفح", isOn: context.option(\.clearHistoryOnExit)); Toggle("مسح الكوكيز", isOn: context.option(\.clearCookiesOnExit)) }
            ThemedSection("حجب الإعلانات") {
                Toggle("حجب ZEUS الأصلي", isOn: context.setting(\.shieldsEnabled, reload: true))
                Toggle("إخفاء عناصر الإعلانات", isOn: context.setting(\.cosmeticFiltering, reload: true))
                NavigationLink("القواعد الاحتياطية والمساحة") { BackupFiltersPage(context: context) }
                ForEach(context.settings.siteExceptions, id: \.self) { host in HStack { Text(host); Spacer(); Button("إزالة") { context.settings.siteExceptions.removeAll { $0 == host }; context.save(reload: true) } } }
            }
        }.settingsPage("الخصوصية")
    }
    private var websites: some View {
        Form {
            ThemedSection("محتوى الصفحات") { Toggle("JavaScript", isOn: context.option(\.javaScriptEnabled, reload: true)); Toggle("عرض الصور", isOn: context.option(\.showImages, reload: true)); Toggle("السماح بالتشغيل التلقائي للوسائط", isOn: context.option(\.autoplayMedia, reload: true)); Toggle("السماح بطلب إذن الكاميرا والميكروفون", isOn: context.option(\.allowMediaCapture)); Toggle("خلفيات داكنة للصفحات", isOn: context.option(\.forceDarkWebPages, reload: true)) }
            ThemedSection("حجم الصفحة") { Toggle("عرض سطح المكتب", isOn: context.setting(\.desktopMode, reload: true)); Slider(value: context.setting(\.textScale), in: 0.65...1.75, step: 0.05) { editing in if !editing { context.save(reload: true) } }; Text("\(Int(context.settings.textScale * 100))٪") }
        }.settingsPage("مواقع الويب")
    }
    private var other: some View {
        Form { ThemedSection("التطبيق") { Text("ZEUS 2.2.1"); Text("ألوان ومظهر مستقلان لكل حساب"); Text("SwiftUI · WebKit") }; ThemedSection("التراخيص") { NavigationLink("قوائم الحجب ومصادرها") { ScrollView { Text(Bundle.main.url(forResource: "FILTER-NOTICES", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "الحجب الافتراضي هو محرك ZEUS الأصلي. إشعارات EasyList وEasyPrivacy ترافق الحزمة الاختيارية المنفصلة؛ راجع ترخيص مصدر أي قواعد تستوردها.").font(.footnote.monospaced()).textSelection(.enabled).padding() }.background(theme.backgroundColor).navigationTitle("التراخيص") } } }.settingsPage("أخرى")
    }
    private var help: some View {
        Form {
            ThemedSection("الحسابات") { Text("الحساب الرئيسي يدير الحسابات. كلمات مرور الحسابات لا تُعرض ولا يتجاوزها الحساب الرئيسي. الضيف يستخدم مخزنًا مؤقتًا تُحذف بياناته عند الخروج.") }
            ThemedSection("الأدوات") { Text("اسحب من اليمين لإظهار أدوات ZEUS الأصلية، ومن الأعلى للتبويبات. افتح صورة من المعرض لقراءة الصور عموديًا. إعدادات القارئ والصور تخص الحساب الحالي.") }
            ThemedSection("التوافق") { Text("أكمل اختبارات CAPTCHA داخل الصفحة. إذا تعطّل تسجيل الدخول، جرّب وضع توافق الموقع أو Safari. جلسة Safari مستقلة عن حسابات ZEUS.") }
            ThemedSection("خيارات iCab التي لا يتيحها WebKit") { Text("لا توفر واجهات iOS العامة حدًا دقيقًا لحجم كاش WebKit، أو تعطيلًا كاملًا لمحرك WebRTC، أو تثبيت شهادات جذر داخل مخزن الثقة من التطبيق. يستخدم ZEUS تحقق TLS ومخزن شهادات النظام. لا نعرض مفاتيح وهمية لهذه القدرات.") }
            ThemedSection("الخصوصية") { Text("لا تُرسل سجل التصفح أو كلمات المرور إلى خدمة ZEUS. تتصل الصفحة بالمواقع التي تفتحها، ويجري تحديث قوائم الحجب من مصادرها عند طلبك. التصدير والمشاركة لا يحدثان إلا عندما تختارهما.") }
        }.settingsPage("المساعدة والخصوصية")
    }
}

extension View {
    func settingsPage(_ title: String) -> some View { modifier(SettingsPageStyle(title: title)) }
}

struct NetworkSettingsPage: View {
    @Environment(\.browserTheme) private var theme
    @ObservedObject var context: ProfileSettingsContext
    var body: some View {
        Form {
            ThemedSection("هوية المتصفح") { Toggle("عرض سطح المكتب", isOn: context.setting(\.desktopMode, reload: true)); TextField("User-Agent مخصص، فارغ للهوية الأصلية", text: context.option(\.userAgent)).textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit { context.save(reload: true) }; NavigationLink("الكوكيز") { CookieSettingsPage(context: context) }; Toggle("ترقية HTTP إلى HTTPS", isOn: context.option(\.upgradeHTTPS)) }
            ThemedSection("ذاكرة الويب المؤقتة") { Text("الحجم الأقصى يديره iOS").foregroundStyle(theme.secondaryTextColor); Button("مسح الملفات المؤقتة الآن") { Task { await context.model.profiles.websiteDataStore(for: context.profile).removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache], modifiedSince: .distantPast) } }.accessibilityIdentifier("clearCacheButton") }
            ThemedSection("التنزيلات") { Toggle("التنزيل عبر Wi-Fi فقط", isOn: context.option(\.downloadsWiFiOnly)); Picker("التنزيلات المتزامنة عبر Wi-Fi", selection: context.option(\.downloadsWiFiLimit)) { ForEach(1...8, id: \.self) { Text("\($0)").tag($0) } }; Picker("التنزيلات المتزامنة عبر الخلوي", selection: context.option(\.downloadsCellularLimit)) { ForEach(1...5, id: \.self) { Text("\($0)").tag($0) } }; Toggle("تأكيد قبل التنزيل", isOn: context.option(\.confirmDownloads)); Toggle("تضمين التنزيلات في نسخة iCloud الاحتياطية", isOn: context.option(\.downloadsInBackup)); if context.isActive { NavigationLink("الملفات والتنزيلات") { DownloadsSheet(model: context.model) } } }
            ThemedSection { Text("نظام iOS يتحقق من شهادات TLS. عدد التنزيلات المتزامنة يحدد الملفات النشطة؛ الاتصالات الداخلية وHTTP/2 يديرها WebKit وURLSession.").font(.footnote) }
        }.settingsPage("الشبكة")
    }
}

private struct CookieRow: Identifiable {
    let cookie: HTTPCookie
    var id: String { cookie.domain + "|" + cookie.path + "|" + cookie.name }
}
struct CookieSettingsPage: View {
    @Environment(\.browserTheme) private var theme
    @ObservedObject var context: ProfileSettingsContext
    @State private var cookies: [HTTPCookie] = []
    @State private var search = ""
    @State private var revealed: Set<String> = []
    var body: some View {
        List {
            ForEach(cookies.filter { search.isEmpty || $0.domain.localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search) }.map { CookieRow(cookie: $0) }) { row in
                let cookie = row.cookie
                VStack(alignment: .leading, spacing: 6) {
                    Text(cookie.name).font(.headline); Text(cookie.domain + cookie.path).font(.caption).foregroundStyle(theme.secondaryTextColor)
                    Text(revealed.contains(key(cookie)) ? cookie.value : "••••••••").font(.caption.monospaced()).textSelection(.enabled)
                    HStack { Text(cookie.isHTTPOnly ? "HttpOnly" : "JavaScript"); Text(cookie.isSecure ? "Secure" : "HTTP"); if let expiry = cookie.expiresDate { Text(expiry, style: .date) } }.font(.caption2).foregroundStyle(theme.secondaryTextColor)
                }.padding(.vertical, 5).onTapGesture { if revealed.contains(key(cookie)) { revealed.remove(key(cookie)) } else { revealed.insert(key(cookie)) } }
                    .swipeActions { Button("حذف") { context.model.profiles.websiteDataStore(for: context.profile).httpCookieStore.delete(cookie) { Task { @MainActor in await reload() } } } }
            }.listRowBackground(theme.backgroundColor)
        }.settingsPage("الكوكيز (\(cookies.count))").searchable(text: $search, prompt: "النطاق أو الاسم").task { await reload() }
    }
    private func key(_ cookie: HTTPCookie) -> String { cookie.domain + cookie.path + cookie.name }
    private func reload() async { guard context.permitted else { cookies = []; return }; cookies = await withCheckedContinuation { c in context.model.profiles.websiteDataStore(for: context.profile).httpCookieStore.getAllCookies { c.resume(returning: $0.sorted { ($0.domain, $0.name) < ($1.domain, $1.name) }) } } }
}

struct StorageSettingsPage: View {
    @Environment(\.browserTheme) private var theme
    @ObservedObject var context: ProfileSettingsContext
    @State private var bytes: Int64 = 0
    @State private var sites = 0
    @State private var freeBytes: Int64 = 0
    @State private var action: String?
    @State private var busy = false
    @State private var result: String?
    var body: some View {
        Form {
            ThemedSection("البيانات") { LabeledContent("ملفات الحساب", value: byteText(bytes)); LabeledContent("مواقع خزّنت بيانات", value: "\(sites)"); LabeledContent("المساحة المتاحة بالجهاز", value: byteText(freeBytes)); Button("مسح الملفات المؤقتة") { action = "cache" }.accessibilityIdentifier("clearCacheButton"); Button("مسح الكوكيز وبيانات المواقع") { action = "web" }; Button("مسح سجل التصفح") { action = "history" }; Button("مسح سجل البحث") { action = "search" }; Button("حذف التنزيلات") { action = "downloads" } }
            if context.isActive { ThemedSection { NavigationLink("المفضلة والسجل") { LibrarySheet(model: context.model) }; NavigationLink("السكربتات") { ScriptsSheet(model: context.model) } } }
            if context.model.profile.isAdmin { ThemedSection { Button("مسح كاش الصور من إصدار ZEUS القديم") { action = "legacy" }; Button("إعادة ضبط التطبيق وكل الحسابات") { action = "reset" } } }
            if let result { Text(result).font(.footnote) }
        }.settingsPage("البيانات الشخصية").disabled(busy).task { await refresh() }
            .confirmationDialog("تأكيد حذف البيانات المحددة؟ حذف بيانات المواقع يسجل خروجك منها. لا يمكن التراجع عن حذف الملفات.", isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } }), titleVisibility: .visible) { Button("مسح") { let selected = action; action = nil; Task { await perform(selected) } } }
    }
    private func refresh() async {
        let folder = context.model.profiles.folder(for: context.profile), downloads = context.model.profiles.downloads(for: context.profile)
        freeBytes = ((try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())[.systemFreeSize]) as? NSNumber)?.int64Value ?? 0
        bytes = await Task.detached { BrowserDisk.size(at: folder) + BrowserDisk.size(at: downloads) }.value
        let records: [WKWebsiteDataRecord] = await withCheckedContinuation { c in context.model.profiles.websiteDataStore(for: context.profile).fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { c.resume(returning: $0) } }; sites = records.count
    }
    private func perform(_ selected: String?) async {
        guard context.permitted else { return }
        busy = true; defer { busy = false }
        let model = context.model
        switch selected {
        case "cache", "web": let types: Set<String> = selected == "cache" ? [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache] : WKWebsiteDataStore.allWebsiteDataTypes(); if context.isActive { for tab in model.tabs { tab.dispose() } }; await model.profiles.websiteDataStore(for: context.profile).removeData(ofTypes: types, modifiedSince: .distantPast); if context.isActive { await model.ensureCurrentLoaded() }
        case "history", "search": if context.isActive { if selected == "history" { model.data.history = [] } else { model.data.searches = [] }; model.persist() } else { var data = model.profiles.load(context.profile); if selected == "history" { data.history = [] } else { data.searches = [] }; model.profiles.save(data, for: context.profile) }
        case "downloads": model.downloads.removeAll(profileID: context.profileID)
        case "legacy": do { let removed = try await BrowserDisk.clearLegacyImageCache(); FaviconMemory.purge(); result = "مُسح كاش الصور القديم: " + byteText(removed) } catch { result = error.localizedDescription }; await refresh(); return
        case "reset": await model.resetApplication()
        default: break
        }
        result = "اكتمل المسح."; await refresh()
    }
}

struct ToolSettingsPage: View {
    @Environment(\.browserTheme) private var theme
    @ObservedObject var context: ProfileSettingsContext
    var body: some View {
        Form {
            ThemedSection { NavigationLink("تصدير واستيراد عبر الملفات والتطبيقات") { ProfileTransferPage(context: context) }; NavigationLink("تصدير واستيراد عبر WLAN") { ProfileTransferPage(context: context) } }
            ThemedSection("البحث") { Picker("محرك البحث", selection: context.setting(\.searchProvider)) { ForEach(SearchProvider.allCases) { Text($0.rawValue).tag($0) } }; Toggle("فتح البحث في تبويب جديد", isOn: context.option(\.searchInNewTab)); Picker("حجم سجل البحث", selection: context.option(\.searchHistoryLimit)) { ForEach([10, 25, 50, 100], id: \.self) { Text("\($0)").tag($0) } }; NavigationLink("محركات البحث المخصصة") { SearchEnginesPage(context: context) } }
            ThemedSection("الطباعة") { Toggle("عنوان الصفحة في رأس الورقة", isOn: context.option(\.printHeader)); Toggle("ترقيم الصفحات", isOn: context.option(\.printFooter)); Picker("الهوامش", selection: context.option(\.printMargin)) { Text("بدون").tag(Double(0)); Text("ضيقة").tag(Double(12)); Text("عادية").tag(Double(24)); Text("واسعة").tag(Double(36)) } }
            ThemedSection("لقطات الشاشة") { Picker("التنسيق", selection: context.option(\.screenshotJPEG)) { Text("PNG").tag(false); Text("JPEG").tag(true) }; Slider(value: context.option(\.screenshotQuality), in: 0.5...1); Picker("الدقة", selection: context.option(\.screenshotScale)) { Text("عادية").tag(Double(1)); Text("مرتفعة").tag(Double(2)) } }
            ThemedSection("PDF") { Toggle("تقسيم PDF إلى أوراق", isOn: context.option(\.paperSizedPDF)) }
            if context.isActive { ThemedSection("أدوات الصفحة") { NavigationLink("القارئ والمعرض والحفظ والطباعة") { ToolsSheet(model: context.model) } } }
        }.settingsPage("الأدوات")
    }
}

struct SearchEnginesPage: View {
    @Environment(\.browserTheme) private var theme
    @ObservedObject var context: ProfileSettingsContext
    @State private var name = ""
    @State private var template = ""
    @State private var issue: String?
    var body: some View {
        Form {
            ThemedSection("المحركات") { Button("استخدام المحرك الافتراضي") { var options = context.options; options.selectedSearchEngineID = nil; context.settings.advanced = options; context.save() }; ForEach(context.options.customSearchEngines) { engine in HStack { Button(engine.name) { var options = context.options; options.selectedSearchEngineID = engine.id; context.settings.advanced = options; context.save() }; Spacer(); if context.options.selectedSearchEngineID == engine.id { Image(systemName: "checkmark") }; Button { var options = context.options; options.customSearchEngines.removeAll { $0.id == engine.id }; if options.selectedSearchEngineID == engine.id { options.selectedSearchEngineID = nil }; context.settings.advanced = options; context.save() } label: { Image(systemName: "trash") } } } }
            ThemedSection("إضافة محرك") { TextField("الاسم", text: $name); TextField("https://example.com/search?q={query}", text: $template).textInputAutocapitalization(.never).autocorrectionDisabled(); Button("إضافة") { guard !name.isEmpty, template.components(separatedBy: "{query}").count == 2, let url = URL(string: template.replacingOccurrences(of: "{query}", with: "test")), BrowserURL.isWeb(url) else { issue = "أدخل رابطًا صالحًا يحتوي {query} مرة واحدة."; return }; var options = context.options; options.customSearchEngines.append(CustomSearchEngine(name: name, template: template)); context.settings.advanced = options; context.save(); name = ""; template = "" } }
            if let issue { Text(issue) }
        }.settingsPage("محركات البحث")
    }
}
