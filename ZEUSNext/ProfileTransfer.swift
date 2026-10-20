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
        if let r = data.settings.reading { guard (14...40).contains(r.fontSize), (0.1...1).contains(r.textOpacity), (0.2...1).contains(r.imageScale), (100...1000).contains(r.scrollDistance), r.blockedWords.count <= 1000 else { throw URLError(.cannotParseResponse) } }
        return self
    }
}
struct ProfileTransferPage: View {
    @ObservedObject var context: ProfileSettingsContext
    @State private var includeHistory = false
    @State private var includeScripts = false
    @State private var importSettings = true
    @State private var importing = false
    @State private var exported: ShareItem?
    @State private var backup: ProfileBackup?
    @State private var message: String?
    var body: some View {
        Form {
            Section("تصدير هذا الحساب") { Toggle("تضمين سجل التصفح والبحث", isOn: $includeHistory); Toggle("تضمين السكربتات", isOn: $includeScripts); Button("تصدير إلى الملفات أو تطبيق آخر", systemImage: "square.and.arrow.up") { export() } }
            Section("استيراد") { Button("اختيار نسخة من الملفات أو iCloud Drive", systemImage: "folder") { importing = true }; if let backup { LabeledContent("الحساب المصدر", value: backup.name); Text("\(backup.data.bookmarks.count) موقع · \(backup.data.scripts.count) سكربت"); Toggle("استيراد إعدادات التصفح", isOn: $importSettings); Button("دمج البيانات في هذا الحساب") { apply(backup) }; Text("السكربتات المستوردة تكون متوقفة حتى تراجعها وتفعّلها بنفسك.").font(.footnote) } }
            Section { Text("تتضمن النسخة الإعدادات والمفضلة والتبويبات وصورة الحساب، مع السجل والسكربتات إذا اخترتهما. لا تتضمن كلمات مرور الحساب أو جلسات المواقع أو ملفات التنزيلات. يمكنك تصدير الملفات من مدير التنزيلات.").font(.footnote) }
            if let message { Text(message).font(.footnote) }
        }.settingsPage("تصدير واستيراد")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data]) { result in
                do { let url = try result.get(); let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }; guard ((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0) <= 6_000_000 else { throw URLError(.dataLengthExceedsMaximum) }; backup = try JSONDecoder().decode(ProfileBackup.self, from: Data(contentsOf: url)).validated(); message = nil }
                catch { message = "تعذر قراءة النسخة: " + error.localizedDescription }
            }
            .sheet(item: $exported) { FileExporter(url: $0.url) }
    }
    private func export() {
        var data = context.isActive ? context.model.data : context.model.profiles.load(context.profile)
        if !includeHistory { data.history = []; data.searches = [] }
        if !includeScripts { data.scripts = [] }
        let avatar = context.model.profiles.avatarURL(context.profile).flatMap { try? Data(contentsOf: $0) }
        let backup = ProfileBackup(name: context.profile.name, data: data, avatar: avatar)
        do { let url = FileManager.default.temporaryDirectory.appendingPathComponent("ZEUS-Profile-" + UUID().uuidString + ".json"); try BrowserDisk.write(backup, to: url); exported = ShareItem(url: url) }
        catch { message = error.localizedDescription }
    }
    private func apply(_ backup: ProfileBackup) {
        guard context.profile.role != .guest, context.profile.role != .kiosk else { message = "استيراد بيانات دائمة غير متاح في حساب الضيف أو الكشك."; return }
        var data = context.isActive ? context.model.data : context.model.profiles.load(context.profile)
        for site in backup.data.bookmarks where !data.bookmarks.contains(where: { $0.url == site.url }) { var item = site; item.id = UUID(); data.bookmarks.append(item) }
        for script in backup.data.scripts { var item = script; item.id = UUID(); item.isActive = false; data.scripts.append(item) }
        if importSettings { data.settings = backup.data.settings; context.settings = data.settings }
        if context.isActive { context.model.data = data; context.model.applySettings() } else { context.model.profiles.save(data, for: context.profile) }
        if let bytes = backup.avatar, let image = UIImage(data: bytes), let jpeg = image.jpegData(compressionQuality: 0.85) {
            do { let folder = context.model.profiles.configurationFolder(context.profile); try BrowserDisk.ensure(folder); try jpeg.write(to: folder.appendingPathComponent("avatar.jpg"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]); var profile = context.profile; var account = profile.account ?? AccountOptions(); account.avatarFilename = "avatar.jpg"; profile.account = account; context.model.profiles.update(profile) } catch { message = error.localizedDescription; return }
        }
        self.backup = nil; message = "دُمجت البيانات. السكربتات المستوردة متوقفة."
    }
}
