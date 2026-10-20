import SwiftUI
import WebKit
import SafariServices

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
        FaviconMemory.purge()
        _ = try? await BrowserDisk.clearLegacyImageCache()
        URLCache.shared.removeAllCachedResponses()
        for tab in tabs { tab.dispose() }
        for item in profiles.profiles { shield.erase(item.id); downloads.removeAll(profileID: item.id) }
        do { try await profiles.resetAll() } catch { notify(error.localizedDescription); return }
        await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        for cookie in HTTPCookieStorage.shared.cookies ?? [] { HTTPCookieStorage.shared.deleteCookie(cookie) }
        if let identifier = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: identifier) }
        requiresUnlock = false; data = ProfileData(); closeAllTabs(); persist(); notify("مُسحت بيانات التطبيق وأُنشئ حساب رئيسي جديد.")
    }
}
