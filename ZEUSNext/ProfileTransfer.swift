import SwiftUI
import UniformTypeIdentifiers

struct ProfileBackup: Codable {
    var version = 1
    var name: String
    var data: ProfileData
    var avatar: Data?
    func validated() throws -> ProfileBackup {
        guard version == 1, data.bookmarks.count <= 5000, data.history.count <= 5000, data.scripts.count <= 100, data.tabs.count <= 30, (avatar?.count ?? 0) < 2_000_000 else { throw URLError(.cannotParseResponse) }
        guard data.bookmarks.allSatisfy({ URL(string: $0.url).map(BrowserURL.isWeb) == true }), data.tabs.allSatisfy({ $0.url == "zeus://home" || URL(string: $0.url).map(BrowserURL.isWeb) == true }), data.scripts.allSatisfy({ $0.code.utf8.count <= 100_000 && ($0.domain == "*" || FilterRules.validDomain($0.domain)) }), (0.5...2).contains(data.settings.textScale) else { throw URLError(.cannotParseResponse) }
        if let o = data.settings.advanced {
            guard (1...5000).contains(o.historyLimit), (1...500).contains(o.searchHistoryLimit), (1...8).contains(o.downloadsWiFiLimit), (1...5).contains(o.downloadsCellularLimit), (0.5...1).contains(o.screenshotQuality), (1...2).contains(o.screenshotScale), (0...100).contains(o.printMargin), o.userAgent.count <= 500, !o.userAgent.contains("\r"), !o.userAgent.contains("\n"), o.customSearchEngines.count <= 30 else { throw URLError(.cannotParseResponse) }
        }
        if let theme = data.settings.theme, !theme.isValid { throw URLError(.cannotParseResponse) }
        if let r = data.settings.reading { guard (14...40).contains(r.fontSize), (0.1...1).contains(r.textOpacity), (0.2...1).contains(r.imageScale), (100...1000).contains(r.scrollDistance), r.blockedWords.count <= 1000 else { throw URLError(.cannotParseResponse) } }
        let groups = data.tabGroups ?? []
        guard Set(data.tabs.map(\.id)).count == data.tabs.count,
              groups.count <= 30, Set(groups.map(\.id)).count == groups.count,
              groups.allSatisfy({ $0.name.count <= 100 && $0.color.count <= 32 }),
              (data.tabScrollOffsets ?? [:]).values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              data.history.allSatisfy({ URL(string: $0.url).map(BrowserURL.isWeb) == true }) else { throw URLError(.cannotParseResponse) }
        return self
    }
    func merged(into existing: ProfileData, importSettings: Bool, restoreTabs: Bool) throws -> ProfileData {
        _ = try validated()
        var result = existing
        for site in data.bookmarks where !result.bookmarks.contains(where: { $0.url == site.url }) {
            var item = site; item.id = UUID(); result.bookmarks.append(item)
        }
        for script in data.scripts where !result.scripts.contains(where: { $0.code == script.code && $0.domain == script.domain }) {
            var item = script; item.id = UUID(); item.isActive = false; result.scripts.append(item)
        }
        guard result.bookmarks.count <= 5000, result.scripts.count <= 100 else { throw URLError(.dataLengthExceedsMaximum) }
        var visits = Set(result.history.map(\.id))
        result.history += data.history.filter { visits.insert($0.id).inserted }
        result.history = Array(result.history.sorted { $0.date > $1.date }.prefix(5000))
        var searches = Set<String>()
        result.searches = Array(((data.searches ?? []) + (result.searches ?? [])).filter { searches.insert($0).inserted }.prefix(500))
        if importSettings { result.settings = data.settings; result.settings.backupFiltersEnabled = false }
        if restoreTabs {
            result.tabs = data.tabs.isEmpty ? [SavedTab()] : data.tabs
            result.selectedTabID = result.tabs.contains { $0.id == data.selectedTabID } ? data.selectedTabID : result.tabs.first?.id
            result.tabGroups = data.tabGroups
            result.tabScrollOffsets = data.tabScrollOffsets
            let ids = Set((result.tabGroups ?? []).map(\.id))
            for index in result.tabs.indices where result.tabs[index].groupID.map({ !ids.contains($0) }) == true { result.tabs[index].groupID = nil }
        }
        return result
    }
}
struct ProfileTransferPage: View {
    @Environment(\.browserTheme) private var theme
    @ObservedObject var context: ProfileSettingsContext
    @StateObject private var lan = LANProfileTransfer()
    @Environment(\.scenePhase) private var scenePhase
    @State private var includeHistory = false
    @State private var includeScripts = false
    @State private var importSettings = true
    @State private var importing = false
    @State private var readingBackup = false
    @State private var restoreTabs = true
    @State private var exported: ShareItem?
    @State private var backup: ProfileBackup?
    @State private var message: String?
    var body: some View {
        Form {
            ThemedSection("تصدير هذا الحساب") { Toggle("تضمين سجل التصفح والبحث", isOn: $includeHistory); Toggle("تضمين السكربتات", isOn: $includeScripts); Button("تصدير إلى الملفات أو تطبيق آخر", systemImage: "square.and.arrow.up") { export() } }
            ThemedSection("تصدير واستيراد عبر WLAN") {
                if lan.running {
                    if let address = lan.address { Text(address).font(.footnote.monospaced()).textSelection(.enabled); Button("نسخ رابط النقل المحلي") { UIPasteboard.general.string = address } } else { ProgressView("بانتظار الشبكة المحلية…") }
                    Button("إيقاف المشاركة") { lan.stop() }
                } else { Button("بدء النقل على شبكة Wi-Fi") { do { lan.start(snapshot: try exportBytes()) } catch { message = error.localizedDescription } } }
                if let error = lan.error { Text(error).font(.caption) }
                Text("افتح الرابط من جهاز على شبكة Wi-Fi نفسها. الرابط يتغير عند كل تشغيل، والاستيراد يحتاج مراجعتك هنا. النقل المحلي عبر HTTP؛ استخدم شبكة تثق بها. تنتهي المشاركة عند مغادرة هذه الصفحة أو انتقال التطبيق للخلفية.").font(.footnote)
            }
            ThemedSection("استيراد") {
                Button("اختيار نسخة من الملفات أو iCloud Drive", systemImage: "folder") { importing = true }.disabled(readingBackup)
                if readingBackup { ProgressView("قراءة النسخة…") }
                if let backup {
                    LabeledContent("الحساب المصدر", value: backup.name)
                    Text("\(backup.data.bookmarks.count) موقع · \(backup.data.scripts.count) سكربت · \(backup.data.tabs.count) تبويب")
                    Toggle("استيراد إعدادات التصفح", isOn: $importSettings)
                    Toggle("استعادة التبويبات وترتيبها بدل الحالية", isOn: $restoreTabs)
                    Button("استيراد البيانات في هذا الحساب") { apply(backup) }
                    Text("السكربتات المستوردة تكون متوقفة حتى تراجعها وتفعّلها بنفسك.").font(.footnote)
                }
            }
            ThemedSection { Text("تتضمن النسخة الإعدادات والمفضلة والتبويبات وصورة الحساب، مع السجل والسكربتات إذا اخترتهما. لا تتضمن كلمات مرور الحساب أو النماذج المحفوظة أو جلسات المواقع أو ملفات التنزيلات. يمكنك تصدير الملفات من مدير التنزيلات.").font(.footnote) }
            if let message { Text(message).font(.footnote) }
        }.settingsPage("تصدير واستيراد")
            .onDisappear { lan.stop() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { lan.stop() } }
            .onReceive(lan.$received) { bytes in if let bytes { do { backup = try JSONDecoder().decode(ProfileBackup.self, from: bytes).validated(); message = "استُلمت نسخة عبر الشبكة. راجع محتواها قبل الاستيراد." } catch { message = error.localizedDescription }; lan.received = nil } }
            .sheet(isPresented: $importing) {
                BackupDocumentPicker(selected: { url in importing = false; readBackup(url) }, cancelled: { importing = false })
            }
            .sheet(item: $exported) { item in FileExporter(url: item.url).onDisappear { try? FileManager.default.removeItem(at: item.url) } }
    }
    private func exportBytes() throws -> Data {
        guard context.permitted else { throw AccountError.permission }
        if context.isActive { context.model.persist() }
        var data = context.isActive ? context.model.data : context.model.profiles.load(context.profile)
        data.forms = []
        if !includeHistory { data.history = []; data.searches = [] }
        if !includeScripts { data.scripts = [] }
        let avatar = context.model.profiles.avatarURL(context.profile).flatMap { try? Data(contentsOf: $0) }
        let backup = ProfileBackup(name: context.profile.name, data: data, avatar: avatar)
        let bytes = try JSONEncoder().encode(backup)
        guard bytes.count <= 6_000_000 else { throw URLError(.dataLengthExceedsMaximum) }; return bytes
    }
    private func export() {
        do { let bytes = try exportBytes(); let url = FileManager.default.temporaryDirectory.appendingPathComponent("ZEUS-Profile-" + UUID().uuidString + ".json"); try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]); exported = ShareItem(url: url) }
        catch { message = error.localizedDescription }
    }
    private func apply(_ backup: ProfileBackup) {
        guard context.permitted else { message = AccountError.permission.localizedDescription; return }
        guard context.profile.role != .guest, context.profile.role != .kiosk else { message = "استيراد بيانات دائمة غير متاح في حساب الضيف أو الكشك."; return }
        do {
            if context.isActive { context.model.persist() }
            let old = context.isActive ? context.model.data : context.model.profiles.load(context.profile)
            let data = try backup.merged(into: old, importSettings: importSettings, restoreTabs: restoreTabs)
            if context.isActive { try context.model.importProfileData(data, restoreOpenTabs: restoreTabs) }
            else { try BrowserDisk.write(data, to: context.model.profiles.folder(for: context.profile).appendingPathComponent("browser.json")) }
            context.settings = data.settings
        } catch { message = "تعذر استيراد النسخة: " + error.localizedDescription; return }
        if let bytes = backup.avatar, let image = UIImage(data: bytes), let jpeg = image.jpegData(compressionQuality: 0.85) {
            do { let folder = context.model.profiles.configurationFolder(context.profile); try BrowserDisk.ensure(folder); try jpeg.write(to: folder.appendingPathComponent("avatar.jpg"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]); var profile = context.profile; var account = profile.account ?? AccountOptions(); account.avatarFilename = "avatar.jpg"; profile.account = account; context.model.profiles.update(profile) } catch { message = error.localizedDescription; return }
        }
        self.backup = nil; message = "استُوردت البيانات" + (restoreTabs ? " والتبويبات وترتيبها" : "") + ". السكربتات المستوردة متوقفة."
    }
    private func readBackup(_ url: URL) {
        guard context.permitted, !readingBackup else { return }
        readingBackup = true; message = nil
        Task { @MainActor in
            defer { readingBackup = false }
            do {
                let value = try await BackupFileReader.load(url)
                guard context.permitted else { throw AccountError.permission }
                backup = value
            } catch { message = "تعذر قراءة النسخة: " + error.localizedDescription }
        }
    }
}
