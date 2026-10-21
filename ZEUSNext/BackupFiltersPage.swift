import SwiftUI
import UniformTypeIdentifiers

struct BackupFiltersPage: View {
    @Environment(\.browserTheme) private var theme
    @ObservedObject var context: ProfileSettingsContext
    @ObservedObject private var shield: ShieldEngine
    @State private var importing = false
    @State private var busy = false
    @State private var message: String?
    init(context: ProfileSettingsContext) { self.context = context; shield = context.model.shield }
    var body: some View {
        Form {
            ThemedSection("الحجب الافتراضي") { Label("محرك ZEUS الأصلي", systemImage: "checkmark.shield"); Text("يعمل بقواعده المحلية وحقنته الأصلية، دون تنزيل تلقائي أو انتظار تجهيز قوائم كبيرة قبل فتح المواقع.").font(.footnote) }
            ThemedSection("حزمة احتياطية لهذا البروفايل") {
                Toggle("تفعيل الحزمة الاحتياطية", isOn: Binding(get: { context.settings.backupFiltersEnabled == true }, set: setEnabled)).disabled(busy || !shield.hasBackup(context.profile)).accessibilityIdentifier("backupFiltersToggle")
                LabeledContent("ملف القواعد", value: shield.hasBackup(context.profile) ? byteText(shield.backupBytes(context.profile)) : "غير مستورد")
                Button("استيراد قواعد Safari من ملف JSON", systemImage: "square.and.arrow.down") { importing = true }.disabled(busy).accessibilityIdentifier("importBackupRulesButton")
                if shield.hasBackup(context.profile) { Button("تعطيل الحزمة وحذف ملفها وكاش قواعدها", systemImage: "trash") { context.settings.backupFiltersEnabled = false; context.save(reload: true); shield.removeBackup(context.profile) } }
                Text("القوائم الكبيرة قد تحتاج وقتًا ومساحة إضافية لتجميعها. يستمر التصفح أثناء التجهيز. لا تُنزّل أو تُفعّل إلا باختيارك، ويمكن حذفها من هنا. يُعاد استخدام التجميع المحفوظ عند عدم تغيّر القواعد.").font(.footnote)
            }
            ThemedSection { Text(shield.status).font(.footnote); if let message { Text(message).font(.footnote) } }
        }.settingsPage("القواعد الاحتياطية").fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get(); guard context.permitted else { return }; busy = true
                let owner = context.profile
                Task { defer { busy = false }; do { try await shield.importBackup(url, profile: owner); guard context.permitted else { return }; context.settings.backupFiltersEnabled = false; context.save(reload: true); message = "استُوردت القواعد وهي غير مفعّلة. شغّلها فقط إن احتجتها." } catch { message = error.localizedDescription } }
            } catch { message = error.localizedDescription }
        }
    }
    private func setEnabled(_ enabled: Bool) {
        guard context.permitted else { return }
        if enabled {
            let free = ((try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())[.systemFreeSize]) as? NSNumber)?.int64Value ?? 0
            guard free >= 128 * 1_048_576 else { message = "المساحة المتاحة منخفضة. أبقِ الحجب الأصلي؛ تحتاج الحزمة الكبيرة مساحة إضافية للتجميع."; return }
        }
        context.settings.backupFiltersEnabled = enabled; context.save(reload: true)
    }
}
