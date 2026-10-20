import SwiftUI
import WebKit
import SafariServices

struct SettingsSheet: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject private var shield: ShieldEngine
    @Environment(\.dismiss) private var dismiss
    @State private var action: String?
    @State private var busy = false
    @State private var fileBytes: Int64 = 0
    @State private var websiteCount = 0
    @State private var freeBytes: Int64 = 0
    @State private var editedName = ""
    init(model: BrowserModel) { self.model = model; shield = model.shield }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 15) {
                        Image(systemName: model.profile.symbol).font(.largeTitle).foregroundStyle(model.profile.color)
                        VStack(alignment: .leading, spacing: 5) { Text(model.profile.name).font(.headline); Text(model.profile.isPrivate ? "جلسة خاصة مؤقتة" : "مساحة مستقلة على هذا الجهاز").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 10)
                    TextField("اسم المساحة", text: $editedName).onSubmit { var profile = model.profile; if !editedName.trimmingCharacters(in: .whitespaces).isEmpty { profile.name = String(editedName.prefix(48)); model.profiles.update(profile) } }
                    NavigationLink("واجهة المستخدم والأشرطة") { AppearanceSettings(model: model) }
                    Button { Task { await model.setProfileLock(!model.profile.locked) } } label: { HStack { Label("قفل الجهاز والبصمة", systemImage: "faceid"); Spacer(); Text(model.profile.locked ? "مفعّل" : "غير مفعّل").foregroundStyle(.secondary) } }
                }
                Section("التصفح") {
                    Picker("محرك البحث", selection: Binding(get: { model.data.settings.searchProvider }, set: { model.data.settings.searchProvider = $0; model.persist() })) { ForEach(SearchProvider.allCases) { Text($0.rawValue).tag($0) } }
                    Toggle("عرض سطح المكتب", isOn: Binding(get: { model.data.settings.desktopMode }, set: { model.data.settings.desktopMode = $0; model.applySettings() }))
                    VStack(alignment: .leading) { Text("حجم الصفحة \(Int(model.data.settings.textScale * 100))٪").font(.subheadline); Slider(value: $model.data.settings.textScale, in: 0.65...1.75, step: 0.05) { editing in if !editing { model.webView?.pageZoom = model.data.settings.textScale; model.persist() } } }
                }
                Section {
                    Toggle("حجب الشبكات الإعلانية", isOn: Binding(get: { model.data.settings.shieldsEnabled }, set: { model.data.settings.shieldsEnabled = $0; model.applySettings() }))
                    Toggle("إخفاء مواضع الإعلانات المعروفة", isOn: Binding(get: { model.data.settings.cosmeticFiltering }, set: { model.data.settings.cosmeticFiltering = $0; model.applySettings() }))
                    Button { Task { await shield.update(); model.applySettings() } } label: { HStack { Label("تحديث قواعد EasyList", systemImage: "arrow.trianglehead.2.clockwise"); Spacer(); if shield.updating { ProgressView() } } }.disabled(shield.updating)
                    Text(shield.status).font(.caption).foregroundStyle(.secondary)
                    if !model.data.settings.siteExceptions.isEmpty {
                        ForEach(model.data.settings.siteExceptions, id: \.self) { host in HStack { Text(host).font(.caption).environment(\.layoutDirection, .leftToRight); Spacer(); Button { model.data.settings.siteExceptions.removeAll { $0 == host }; model.applySettings() } label: { Image(systemName: "minus.circle") }.accessibilityLabel("إزالة الاستثناء") } }
                    }
                } header: { Text("الحماية") } footer: { Text("الحجب قابل للتعطيل لكل موقع من رمز الدرع. لا تغيّر آلية التحقق أو الكوكيز؛ أكمِل CAPTCHA بنفسك داخل الصفحة. يُستورد الجزء المدعوم من قواعد EasyList، ولا تُنفّذ قواعدها كسكربتات.") }
                storageSection
                Section {
                    Toggle("أدوات المطور والكونسول", isOn: Binding(get: { model.data.settings.developerTools }, set: { model.data.settings.developerTools = $0; model.applySettings() }))
                    Text("ZEUS 2.0 · SwiftUI + WebKit\nLiquid Glass على iOS 26، مع واجهة زجاجية متوافقة مع iOS 18.").font(.caption).foregroundStyle(.secondary)
                }
            }.scrollContentBackground(.hidden).background { OrbitBackground(tint: model.profile.color) }
                .navigationTitle("التحكم الكامل").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("تم") { dismiss() } } }
                .disabled(busy)
                .overlay { if busy { ProgressView("جارٍ التنظيف…").padding(25).glassSurface() } }
                .confirmationDialog(confirmTitle, isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } }), titleVisibility: .visible) {
                    Button("تأكيد المسح", role: .destructive) { let selected = action; action = nil; Task { await perform(selected) } }
                    Button("إلغاء", role: .cancel) { action = nil }
                }
                .task { editedName = model.profile.name; await refreshStorage() }
        }
    }
    private var storageSection: some View {
        Section {
            HStack { Label("ملفات المساحة", systemImage: "externaldrive"); Spacer(); Text(byteText(fileBytes)).foregroundStyle(.secondary) }
            HStack { Label("مواقع خزّنت بيانات", systemImage: "globe"); Spacer(); Text("\(websiteCount)").foregroundStyle(.secondary) }
            HStack { Label("المساحة المتاحة بالجهاز", systemImage: "internaldrive"); Spacer(); Text(byteText(freeBytes)).foregroundStyle(.secondary) }
            Button("مسح الملفات المؤقتة", systemImage: "sparkles") { action = "cache" }.accessibilityIdentifier("clearCacheButton")
            Button("مسح كوكيز وبيانات المواقع", systemImage: "globe.badge.chevron.backward") { action = "web" }
            Button("مسح سجل التصفح", systemImage: "clock.arrow.circlepath") { action = "history" }
            Button("حذف تنزيلات هذه المساحة", systemImage: "trash") { action = "downloads" }.foregroundStyle(.white)
            Button("إعادة ضبط التطبيق وكل مساحاته", systemImage: "arrow.counterclockwise", role: .destructive) { action = "reset" }.accessibilityIdentifier("resetAppButton")
        } header: { Text("التخزين والبيانات") } footer: { Text("المسح العادي يخص المساحة الحالية فقط. حذف بيانات المواقع يسجّل خروجك منها. ملفات WebKit لا تتيح قياس حجم دقيق لكل موقع؛ الحجم المعروض للملفات المحفوظة والتنزيلات.") }
    }
    private var confirmTitle: String {
        switch action {
        case "web": return "مسح جلسات وبيانات مواقع \(model.profile.name) وتسجيل الخروج منها؟"
        case "downloads": return "إيقاف وحذف كل تنزيلات هذه المساحة؟ صدّر ما تحتاجه أولًا."
        case "history": return "مسح سجل هذه المساحة؟"
        case "reset": return "حذف جميع المساحات وسجلاتها وتنزيلاتها وبدء إعداد جديد؟ لا يمكن التراجع."
        default: return "مسح ذاكرة المواقع المؤقتة لهذه المساحة؟"
        }
    }
    private func refreshStorage() async {
        let folder = model.profiles.folder(for: model.profile), downloads = model.profiles.downloads(for: model.profile)
        fileBytes = await Task.detached { BrowserDisk.size(at: folder) + BrowserDisk.size(at: downloads) }.value
        let records: [WKWebsiteDataRecord] = await withCheckedContinuation { continuation in model.profiles.websiteDataStore(for: model.profile).fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { continuation.resume(returning: $0) } }
        websiteCount = records.count
        freeBytes = ((try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())[.systemFreeSize]) as? NSNumber)?.int64Value ?? 0
    }
    private func perform(_ selected: String?) async {
        busy = true; defer { busy = false }
        switch selected {
        case "cache": await model.clearWebsiteData(cacheOnly: true)
        case "web": await model.clearWebsiteData(cacheOnly: false)
        case "history": model.data.history.removeAll(); model.persist()
        case "downloads": model.downloads.removeAll(profileID: model.profile.id)
        case "reset": await model.resetApplication()
        default: break
        }
        await refreshStorage()
    }
}

struct ToolsSheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var scripts = false
    @State private var console = false
    @State private var find = ""
    @State private var systemURL: ShareItem?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(model.current?.title ?? "بداية جديدة", systemImage: "sparkles").font(.headline).lineLimit(2)
                    Text(model.currentHost).font(.caption).foregroundStyle(.secondary)
                }
                Section("الصفحة") {
                    Button("وضع القراءة", systemImage: "text.alignright") { afterDismiss { model.readerMode() } }
                    Button("معرض صور الصفحة", systemImage: "photo.on.rectangle.angled") { afterDismiss { model.galleryMode() } }
                    Button("إضافة للمفضلة", systemImage: "bookmark") { model.bookmarkCurrent() }
                    Button("مشاركة الرابط", systemImage: "square.and.arrow.up") { if let url = URL(string: model.current?.url ?? ""), BrowserURL.isWeb(url) { afterDismiss { model.share = ShareItem(url: url) } } }
                    HStack { TextField("بحث داخل الصفحة", text: $find).submitLabel(.search).onSubmit { findInPage() }; Button { findInPage() } label: { Image(systemName: "magnifyingglass") } }
                }.disabled(model.current?.isHome != false)
                Section("حفظ وتصدير") {
                    Button("حفظ PDF", systemImage: "doc.richtext") { afterDismiss { model.savePDF() } }
                    Button("لقطة للجزء المرئي", systemImage: "camera.viewfinder") { afterDismiss { model.saveScreenshot() } }
                    Button("طباعة", systemImage: "printer") { afterDismiss { model.printPage() } }
                    Button("تنزيل الرابط الحالي", systemImage: "arrow.down.circle") { if let url = model.webView?.url { Task { await model.downloads.start(url: url, profile: model.profile, webView: model.webView) } } }
                }.disabled(model.current?.isHome != false)
                Section {
                    Button(model.siteCompatible ? "إعادة الحماية لهذا الموقع" : "وضع توافق الموقع", systemImage: "shield.lefthalf.filled") { afterDismiss { model.toggleCompatibility() } }.disabled(model.currentHost.isEmpty)
                    Button("فتح في متصفح النظام", systemImage: "safari") { if let url = model.webView?.url, BrowserURL.isWeb(url) { UIApplication.shared.open(url) } }
                    Button("عرض باستخدام Safari داخل التطبيق", systemImage: "rectangle.on.rectangle") { if let url = model.webView?.url, BrowserURL.isWeb(url) { systemURL = ShareItem(url: url) } }
                    if model.blockedNavigations > 0 { Text("\(model.blockedNavigations) تنقّل أو نافذة أوقفها الحاجب في هذه الجلسة").font(.caption).foregroundStyle(.secondary) }
                } header: { Text("التوافق والحماية") } footer: { Text("بعض المواقع ترفض المتصفحات المدمجة. جلسة متصفح النظام مستقلة ولا تُنقل كوكيزها إلى البروفايل. يتيح وضع التوافق إكمال التحقق يدويًا دون تدخل الحاجب.") }
                Section("أدوات متقدمة") {
                    Button("سكربتات هذه المساحة", systemImage: "curlybraces") { scripts = true }
                    Button("الكونسول", systemImage: "terminal") { console = true }
                }
            }.scrollContentBackground(.hidden).background { OrbitBackground(tint: model.profile.color) }.navigationTitle("صندوق الأدوات").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("تم") { dismiss() } } }
                .fullScreenCover(isPresented: $scripts) { ScriptsSheet(model: model) }
                .fullScreenCover(isPresented: $console) { ConsoleSheet(model: model) }
                .sheet(item: $systemURL) { SystemBrowser(url: $0.url).ignoresSafeArea() }
        }
    }
    private func afterDismiss(_ action: @escaping () -> Void) { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: action) }
    private func findInPage() {
        let configuration = WKFindConfiguration(); configuration.caseSensitive = false; configuration.wraps = true
        model.webView?.find(find, configuration: configuration) { result in if !result.matchFound { model.notify("لا توجد مطابقة في الصفحة.") } }
    }
}

extension BrowserModel {
    func resetApplication() async {
        guard profile.isAdmin else { notify(AccountError.permission.localizedDescription); return }
        for tab in tabs { tab.dispose() }
        for item in profiles.profiles { downloads.removeAll(profileID: item.id) }
        do { try await profiles.resetAll() } catch { notify(error.localizedDescription); return }
        await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        for cookie in HTTPCookieStorage.shared.cookies ?? [] { HTTPCookieStorage.shared.deleteCookie(cookie) }
        if let identifier = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: identifier) }
        requiresUnlock = false; data = ProfileData(); closeAllTabs(); persist(); notify("مُسحت بيانات التطبيق وأُنشئ حساب رئيسي جديد.")
    }
}
