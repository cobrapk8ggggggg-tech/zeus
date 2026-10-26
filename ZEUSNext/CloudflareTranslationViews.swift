import SwiftUI
import UniformTypeIdentifiers

struct CloudflareTranslationSettings: View {
    @ObservedObject var context: ProfileSettingsContext
    @State private var config = CloudflareTranslationConfiguration()
    @State private var secret = ""
    @State private var importing = false
    @State private var checking = false
    @State private var message = ""
    @State private var verifiedConfig: CloudflareTranslationConfiguration?
    @State private var verifiedSecret = ""
    @State private var verifiedTarget = ""
    private var verified: Bool { verifiedConfig == config && verifiedSecret == secret && verifiedTarget == (context.settings.translation?.target ?? "ar") }
    @State private var task: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            ThemedSection("اتصال Cloudflare لهذا البروفايل") {
                Button { importing = true } label: { Label("استيراد ملف ربط Cloudflare", systemImage: "square.and.arrow.down") }.accessibilityIdentifier("importCloudflareConnection")
                TextField("عنوان خدمة الترجمة", text: $config.endpoint).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).environment(\.layoutDirection, .leftToRight).accessibilityIdentifier("cloudflareEndpoint")
                SecureField("رمز اتصال ZEUS", text: $secret).textInputAutocapitalization(.never).autocorrectionDisabled().environment(\.layoutDirection, .leftToRight).accessibilityIdentifier("cloudflareConnectionKey")
                Button(checking ? "جارٍ الاتصال والاختبار…" : "اتصال وجلب النماذج واختبار الترجمة") { connect() }.disabled(checking || secret.isEmpty || !context.permitted).accessibilityIdentifier("testCloudflareConnection")
                if checking { ProgressView() }
                if !message.isEmpty { Text(message).font(.footnote).textSelection(.enabled).accessibilityIdentifier("cloudflareConnectionResult") }
                if !config.accountName.isEmpty { LabeledContent("الحساب", value: config.accountName) }
            }
            if !config.models.isEmpty {
                ThemedSection("نموذج الترجمة") {
                    Picker("النموذج المفعّل في خادمك", selection: $config.model) { ForEach(config.models) { Text($0.name).tag($0.id) } }.accessibilityIdentifier("cloudflareTranslationModel")
                    TextField("توجيه أسلوبي اختياري للترجمة", text: $config.instruction, axis: .vertical).lineLimit(2...5)
                }
            }
            ThemedSection("الاستخدام والحفظ") {
                Link("متابعة الحصة في لوحة Cloudflare", destination: URL(string: "https://dash.cloudflare.com/?to=/:account/ai/workers-ai")!)
                Link("الأسعار الرسمية لـ Workers AI", destination: URL(string: "https://developers.cloudflare.com/workers-ai/platform/pricing/")!)
            }
            ThemedSection {
                Button("حفظ الاتصال واستخدام Cloudflare") { save() }.fontWeight(.bold).disabled(!verified || checking || !context.permitted).accessibilityIdentifier("saveCloudflareConnection")
                Button("إزالة اتصال هذا البروفايل", role: .destructive) { disconnect() }.disabled(checking || !context.permitted)
            }
        }.settingsPage("ترجمة Cloudflare")
            .onAppear {
                config = context.settings.translation?.cloudflare ?? CloudflareTranslationConfiguration()
                secret = AISecretVault.read(profile: context.profileID, provider: "cloudflare-workers-ai")
            }
            .onDisappear { task?.cancel() }
            .zeusFileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                guard context.permitted else { return }
                do {
                    let url = try result.get().first
                    guard let url else { return }
                    let accessed = url.startAccessingSecurityScopedResource(); defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 16384 else { throw TranslationFailure.message("ملف الربط أكبر من الحد المسموح.") }
                    let connection = try CloudflareConnection.decode(Data(contentsOf: url, options: [.mappedIfSafe]))
                    task?.cancel(); checking = false; config = connection.configuration; secret = connection.token; verifiedConfig = nil
                    message = "استُورد الملف. اضغط اتصال لجلب النماذج واختبار ترجمة حقيقية قبل الحفظ."
                } catch { message = "تعذر استيراد ملف الربط. " + error.localizedDescription }
            }
    }
    private func connect() {
        guard context.permitted else { return }
        task?.cancel(); checking = true; verifiedConfig = nil; message = ""
        let input = config, key = secret, target = context.settings.translation?.target ?? "ar"
        task = Task { @MainActor in
            do {
                let discovered = try await CloudflareTranslationService.discover(input, secret: key)
                let originals = [TranslationSegment(id: "test_1", text: "The traveler opened the ancient book."), TranslationSegment(id: "test_2", text: "Chapter 1: A new beginning.")]
                let answer = try await CloudflareTranslationService.translate(originals, target: target, config: discovered, secret: key)
                guard !Task.isCancelled, secret == key, config.endpoint == input.endpoint, config.model == input.model, config.instruction == input.instruction else { checking = false; return }
                config = discovered; config.lastChecked = Date()
                verifiedConfig = config; verifiedSecret = key; verifiedTarget = target; message = "نجح الاتصال والترجمة الحقيقية:\n" + answer.map(\.text).joined(separator: "\n")
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
            if !Task.isCancelled { checking = false }
        }
    }
    private func save() {
        guard context.permitted, verified, !checking else { return }
        do {
            try AISecretVault.save(secret, profile: context.profileID, provider: "cloudflare-workers-ai")
            pauseTranslations()
            var prefs = context.settings.translation ?? TranslationPreferences(); prefs.cloudflare = config; prefs.engine = .cloudflare
            context.settings.translation = prefs; context.save(); dismiss()
        } catch { message = error.localizedDescription }
    }
    private func disconnect() {
        do {
            try AISecretVault.save("", profile: context.profileID, provider: "cloudflare-workers-ai")
            pauseTranslations()
            var prefs = context.settings.translation ?? TranslationPreferences(); prefs.cloudflare = nil
            if prefs.engine == .cloudflare { prefs.engine = .googleWeb }; context.settings.translation = prefs; context.save()
            secret = ""; config = CloudflareTranslationConfiguration(); verifiedConfig = nil; message = "أُزيل اتصال Cloudflare من هذا البروفايل."
        } catch { message = error.localizedDescription }
    }
    private func pauseTranslations() { if context.isActive { for tab in context.model.tabs { tab.translation?.pause() } } }
}
