import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct TranslationCard: View {
    @ObservedObject var page: PageTranslation
    let settings: () -> Void
    @Environment(\.browserTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var interacted = false
    var body: some View {
        Group { if page.offered {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) {
                    Image(systemName: "translate").font(.title3)
                    Text(page.running ? "جارٍ الترجمة…" : page.translated ? "تمت الترجمة" : "ترجمة الصفحة؟").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if page.running { ProgressView().controlSize(.small); Button("إيقاف") { page.pause() } }
                    else if page.translated { Button("الأصل") { Task { await page.restore() } }.accessibilityIdentifier("restoreTranslationButton"); if page.error != nil { Button("متابعة") { page.resume() } } }
                    else { Button("ترجمة") { page.translate() }.fontWeight(.bold).accessibilityIdentifier("confirmTranslationButton") }
                    Menu {
                        Button("إعدادات الترجمة", systemImage: "gearshape") { settings() }
                        Button("عدم الترجمة لهذا الموقع") { page.excludeSite() }
                        if page.translated { Button("إعادة الترجمة") { Task { await page.restore(); page.translate() } } }
                    } label: { Image(systemName: "ellipsis.circle").frame(width: 30, height: 36) }.accessibilityLabel("خيارات الترجمة")
                    Button { page.dismiss() } label: { Image(systemName: "xmark").font(.caption).frame(width: 30, height: 36) }.accessibilityLabel("إخفاء بطاقة الترجمة")
                }.font(.subheadline).buttonStyle(.borderless)
                if let error = page.error { Text(error).font(.caption).textSelection(.enabled).accessibilityIdentifier("translationError") }
                if let notice = page.storageNotice { Text(notice).font(.caption) }
            }.padding(.horizontal, 12).padding(.vertical, 5).glassSurface(16).frame(maxWidth: 540).padding(.horizontal, 12).padding(.top, 12)
                .simultaneousGesture(TapGesture().onEnded { interacted = true })
                .task(id: "\(interacted)-\(page.offered)-\(page.running)-\(page.translated)-\(page.error ?? "")") {
                    guard !interacted, page.offered, !page.running, !page.translated, page.error == nil else { return }
                    let seconds = page.preferences.suggestionSeconds
                    guard seconds > 0 else { return }
                    do { try await Task.sleep(for: .seconds(seconds)); guard !Task.isCancelled, !page.running, !page.translated, page.error == nil else { return }; withAnimation { page.dismiss() } } catch { }
                }
                .environment(\.layoutDirection, .rightToLeft).accessibilityElement(children: .contain).accessibilityIdentifier("translationSuggestionCard")
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.82), value: page.running)
        } }.animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.82), value: page.offered)
    }
}

struct TranslationSettingsPage: View {
    @ObservedObject var context: ProfileSettingsContext
    @State private var cloudKey = ""
    @State private var savedCount = 0
    @State private var savedBytes: Int64 = 0
    @State private var message: String?
    private var prefs: TranslationPreferences { context.settings.translation ?? TranslationPreferences() }
    var body: some View {
        Form {
            ThemedSection("لغة الصفحة") {
                Picker("الترجمة إلى", selection: binding(\.target)) { ForEach(TranslationPreferences.languages, id: \.0) { code, name in Text(name).tag(code) } }
                Toggle("اقتراح ترجمة الصفحات الأجنبية", isOn: binding(\.suggest))
                Picker("مدة ظهور الاقتراح", selection: Binding(get: { prefs.suggestionSeconds }, set: { var p = prefs; p.suggestionDuration = $0; context.settings.translation = p; context.save() })) { Text("ثانية ونصف").tag(1.5); Text("3 ثوانٍ").tag(3.0); Text("5 ثوانٍ").tag(5.0); Text("10 ثوانٍ").tag(10.0); Text("حتى أغلقها").tag(0.0) }
                Toggle("الترجمة التلقائية دون سؤال", isOn: binding(\.automatic)).accessibilityIdentifier("automaticPageTranslation")
                Toggle("ترجمة المحتوى الذي يظهر لاحقًا", isOn: binding(\.dynamicContent))
            }
            ThemedSection("محرك الترجمة") {
                Picker("الخدمة", selection: binding(\.engine)) { ForEach(TranslationEngine.allCases, id: \.self) { Text($0.title).tag($0) } }.accessibilityIdentifier("translationEngine")
                if prefs.engine == .googleCloud {
                    SecureField("مفتاح Cloud Translation API", text: $cloudKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("حفظ المفتاح في Keychain") { do { try AISecretVault.save(cloudKey, profile: context.profileID, provider: "google-cloud"); message = "حُفظ المفتاح." } catch { message = error.localizedDescription } }
                }
                if prefs.engine == .cloudflare {
                    NavigationLink { CloudflareTranslationSettings(context: context) } label: { Label("ربط وإعداد Cloudflare", systemImage: "cloud") }.accessibilityIdentifier("cloudflareTranslationSettings")
                }
                if prefs.engine == .ai {
                    Picker("المزود", selection: binding(\.providerID)) {
                        Text("اختر مزودًا").tag(nil as UUID?)
                        ForEach(context.settings.aiProviders ?? []) { p in Text(p.name).tag(Optional(p.id)) }
                    }
                    NavigationLink { AISettingsPage(context: context) } label: { Label("إدارة مزودي الذكاء الاصطناعي", systemImage: "sparkles") }
                }
                if let message { Text(message).font(.footnote) }
            }
            if !prefs.excludedHosts.isEmpty {
                ThemedSection("المواقع المستثناة") {
                    ForEach(prefs.excludedHosts, id: \.self) { host in HStack { Text(host); Spacer(); Button("إزالة") { var p = prefs; p.excludedHosts.removeAll { $0 == host }; context.settings.translation = p; context.save() } } }
                }
            }
            ThemedSection("حفظ الترجمة على الجهاز") {
                Text("\(savedCount) مقطع · " + ByteCountFormatter.string(fromByteCount: savedBytes, countStyle: .file)).font(.caption).accessibilityIdentifier("translationMemoryUsage")
                Toggle("الاحتفاظ بالترجمة لتقليل استهلاك الحصة", isOn: Binding(get: { prefs.keepsTranslations }, set: { var value = prefs; value.retainTranslations = $0; context.settings.translation = value; context.save() })).accessibilityIdentifier("retainPageTranslations")
                Button("مسح الترجمات المحفوظة لهذا البروفايل", role: .destructive) {
                    if context.isActive { for tab in context.model.tabs { tab.translation?.clearSessionCache() } }
                    let folder = context.model.profiles.folder(for: context.profile)
                    Task { do { try await TranslationMemory.shared.clear(folder: folder); message = "مُسحت الترجمات المحفوظة. ترجمة هذه النصوص لاحقًا ستستهلك طلبات جديدة." } catch { message = error.localizedDescription }; await refreshMemory() }
                }.accessibilityIdentifier("clearTranslationMemory")
                if let message { Text(message).font(.footnote) }
            }
        }.settingsPage("ترجمة الصفحات").onAppear { cloudKey = AISecretVault.read(profile: context.profileID, provider: "google-cloud") }.task { await refreshMemory() }
    }
    private func refreshMemory() async {
        let stats = await TranslationMemory.shared.stats(folder: context.model.profiles.folder(for: context.profile))
        savedCount = stats.entries; savedBytes = stats.bytes
    }
    private func binding<T>(_ key: WritableKeyPath<TranslationPreferences,T>) -> Binding<T> {
        Binding(get: { prefs[keyPath: key] }, set: { var value = prefs; value[keyPath: key] = $0; context.settings.translation = value; context.save() })
    }
}

struct AISettingsPage: View {
    @ObservedObject var context: ProfileSettingsContext
    @State private var adding = false
    var body: some View {
        Form {
            ThemedSection("مزودو هذا البروفايل") {
                ForEach(context.settings.aiProviders ?? []) { provider in
                    NavigationLink { AIProviderEditor(context: context, original: provider) } label: {
                        VStack(alignment: .leading, spacing: 5) { Text(provider.name).font(.headline); Text(provider.kind.title + " · " + provider.model).font(.caption).foregroundStyle(.secondary) }
                    }.contextMenu { Button("حذف المزود", role: .destructive) { remove(provider) } }
                }.onDelete { indices in for i in indices.sorted(by: >) { if let p = context.settings.aiProviders?[i] { remove(p) } } }
                NavigationLink { AIProviderEditor(context: context, original: AIProviderConfiguration()) } label: { Label("إضافة مزود", systemImage: "plus.circle") }.accessibilityIdentifier("addAIProvider")
            }
            ThemedSection("مساحة الذكاء الاصطناعي") {
                NavigationLink { AIWorkspace(context: context) } label: { Label("اختبار ومحادثة مع المزود", systemImage: "bubble.left.and.bubble.right") }
            }
        }.settingsPage("الذكاء الاصطناعي")
    }
    private func remove(_ provider: AIProviderConfiguration) {
        guard context.permitted else { return }
        try? AISecretVault.save("", profile: context.profileID, provider: provider.id.uuidString)
        context.settings.aiProviders?.removeAll { $0.id == provider.id }
        if context.settings.translation?.providerID == provider.id { context.settings.translation?.providerID = nil }
        if context.isActive { for tab in context.model.tabs { tab.translation?.pause() } }
        Task { await AIProviderService.shared.clearRuntime() }; context.save()
    }
}

struct AIProviderEditor: View {
    @ObservedObject var context: ProfileSettingsContext
    let original: AIProviderConfiguration
    @State private var config: AIProviderConfiguration
    @State private var secret = ""
    @State private var connecting = false
    @State private var message = ""
    @State private var connectionTask: Task<Void, Never>?
    @State private var chatLimit = 50
    @State private var testing = false
    @Environment(\.dismiss) private var dismiss
    init(context: ProfileSettingsContext, original: AIProviderConfiguration) { self.context = context; self.original = original; _config = State(initialValue: original) }
    private var availableChats: [AIChoice] { if let id = config.projectID { return config.projects.first { $0.id == id }?.chats ?? [] }; return config.chats }
    var body: some View {
        Form {
            ThemedSection("الاتصال") {
                TextField("اسم المزود", text: $config.name)
                Picker("النوع", selection: $config.kind) { ForEach(AIProviderKind.allCases, id: \.self) { Text($0.title).tag($0) } }.disabled(original.lastChecked != nil)
                if config.kind == .openAICompatible { TextField("Base URL مثل https://api.openai.com/v1", text: $config.baseURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().environment(\.layoutDirection, .leftToRight) }
                SecureField(config.kind == .geminiAccount ? "Cookie لحساب Google" : config.kind == .chatGPTAccount ? "ChatGPT Access Token" : "API Key", text: $secret).textInputAutocapitalization(.never).autocorrectionDisabled().environment(\.layoutDirection, .leftToRight).accessibilityIdentifier("aiProviderSecret")
                if config.kind.account {
                    Button("استخدام جلسة الموقع داخل هذا البروفايل") { importBrowserSession() }.disabled(connecting || !context.permitted)
                }
                if config.kind == .geminiAccount {
                    Stepper("رقم حساب Google: \(config.googleAccountIndex)", value: $config.googleAccountIndex, in: 0...9)
                }
                Button { connect() } label: { HStack { if connecting { ProgressView() }; Text(connecting ? "جارٍ جلب خيارات الحساب…" : "اتصال وجلب النماذج والخيارات") } }.disabled(connecting || !context.permitted).accessibilityIdentifier("discoverAIProvider")
                if !message.isEmpty { Text(message).font(.footnote).textSelection(.enabled) }
                if let notice = config.discoveryNotice { Text(notice).font(.footnote) }
            }
            if !config.models.isEmpty {
                ThemedSection("النموذج") { Picker("النموذج المتاح", selection: $config.model) { ForEach(config.models) { Text($0.name).tag($0.id) } }; Button(testing ? "جارٍ اختبار رد النموذج…" : "اختبار توليد رد حقيقي") { testGeneration() }.disabled(testing || connecting) }
            }
            if config.kind.account {
                ThemedSection("سياق المحادثة") {
                    if config.kind == .chatGPTAccount {
                        Picker("المشروع", selection: $config.projectID) { Text("بدون مشروع").tag(nil as String?); ForEach(config.projects) { Text($0.name).tag(Optional($0.id)) } }
                    }
                    Picker("المحادثة", selection: $config.conversationID) { Text("محادثة جديدة لكل صفحة").tag(nil as String?); ForEach(availableChats) { Text($0.name).tag(Optional($0.id)) } }
                    Button("جلب محادثات أكثر (حتى \(min(chatLimit + 50, 500)))") { chatLimit = min(chatLimit + 50, 500); connect() }.disabled(connecting || chatLimit >= 500)
                }
            }
            ThemedSection("الترجمة") { TextField("توجيه أسلوبي اختياري، مثل: أسلوب روائي سلس", text: $config.instruction, axis: .vertical).lineLimit(3...6) }
            ThemedSection { Button("حفظ المزود") { save() }.fontWeight(.bold).disabled(config.model.isEmpty || connecting || !context.permitted).accessibilityIdentifier("saveAIProvider") }
        }.settingsPage("إعداد المزود")
            .task { secret = AISecretVault.read(profile: context.profileID, provider: config.id.uuidString) }
            .onChange(of: config.baseURL) { _, _ in schedule() }
            .onChange(of: secret) { _, _ in if !secret.isEmpty { schedule() } }
            .onChange(of: config.googleAccountIndex) { _, _ in schedule() }
            .onChange(of: config.kind) { _, _ in connectionTask?.cancel(); config.models = []; config.model = ""; config.chats = []; config.projects = []; config.projectID = nil; config.conversationID = nil; config.lastChecked = nil; secret = ""; message = "" }
            .onChange(of: config.projectID) { _, _ in config.conversationID = nil }
            .onDisappear { connectionTask?.cancel() }
    }
    private func importBrowserSession() {
        guard context.permitted else { return }
        Task {
            let cookies: [HTTPCookie] = await withCheckedContinuation { c in context.model.profiles.websiteDataStore(for: context.profile).httpCookieStore.getAllCookies { c.resume(returning: $0) } }
            let address = config.kind == .geminiAccount ? "https://gemini.google.com/u/\(config.googleAccountIndex)/app" : "https://chatgpt.com/api/auth/session"
            guard let url = URL(string: address), let cookie = DownloadFiles.cookieHeaders(cookies, for: url)["Cookie"], !cookie.isEmpty else { message = "لم توجد جلسة لهذا الموقع في البروفايل الحالي. سجّل الدخول إليه داخل ZEUS أولًا."; return }
            do {
                if config.kind == .geminiAccount { secret = cookie }
                else {
                    let response = try await AIHTTP.object(AIHTTP.request(url, headers: ["Cookie": cookie])) as? [String: Any]
                    guard let token = response?["accessToken"] as? String, !token.isEmpty else { throw TranslationFailure.message("لم يُرجع الموقع رمز جلسة. أعد تسجيل الدخول إلى ChatGPT داخل ZEUS.") }; secret = token
                }
                message = "استُوردت الجلسة؛ جارٍ جلب خيارات الحساب."
            } catch { message = error.localizedDescription }
        }
    }
    private func schedule() {
        connectionTask?.cancel()
        connectionTask = Task { try? await Task.sleep(for: .seconds(1.5)); guard !Task.isCancelled else { return }; await discover() }
    }
    private func connect() { connectionTask?.cancel(); connectionTask = Task { await discover() } }
    @MainActor private func discover() async {
        guard context.permitted else { return }
        connecting = true; message = ""
        let input = config, token = secret
        do {
            let discovered = try await AIProviderService.shared.discover(input, secret: token, chatLimit: chatLimit)
            guard !Task.isCancelled, config.id == input.id, config.kind == input.kind, config.baseURL == input.baseURL, secret == token else { return }
            config = discovered
            if config.name.isEmpty { config.name = config.kind.title }
            message = "اتصل الحساب: \(config.models.count) نموذج، \(config.chats.count) محادثة، \(config.projects.count) مشروع."
            if config.kind == .openAICompatible {
                let testContext = UUID()
                do {
                    let answer = try await AIProviderService.shared.generate("Reply with exactly OK.", config: discovered, secret: token, context: testContext)
                    if !Task.isCancelled { message += "\nاختبار توليد حقيقي: " + String(answer.prefix(80)) }
                } catch { if !Task.isCancelled { message += "\nجُلبت النماذج، لكن اختبار التوليد فشل: " + error.localizedDescription } }
                await AIProviderService.shared.end(testContext)
            }
        } catch { if !Task.isCancelled { message = error.localizedDescription } }
        if !Task.isCancelled { connecting = false }
    }
    private func testGeneration() {
        testing = true
        Task {
            let id = UUID(); var probe = config; probe.conversationID = nil; probe.projectID = nil
            do { let result = try await AIProviderService.shared.generate("Reply with exactly OK.", config: probe, secret: secret, context: id); message = "رد فعلي من النموذج: " + String(result.prefix(120)) }
            catch { message = error.localizedDescription }; await AIProviderService.shared.end(id); testing = false
        }
    }
    private func save() {
        guard context.permitted else { return }
        do {
            try AISecretVault.save(secret, profile: context.profileID, provider: config.id.uuidString)
            if config.name.isEmpty { config.name = config.kind.title }
            var providers = context.settings.aiProviders ?? []; providers.removeAll { $0.id == config.id }; providers.append(config)
            context.settings.aiProviders = providers
            var p = context.settings.translation ?? TranslationPreferences(); if p.providerID == nil { p.providerID = config.id }; context.settings.translation = p
            context.save(); dismiss()
        } catch { message = error.localizedDescription }
    }
}

struct AIWorkspace: View {
    @ObservedObject var context: ProfileSettingsContext
    @State private var selected: UUID?
    @State private var prompt = ""
    @State private var response = ""
    @State private var busy = false
    @State private var attachments: [AIAttachment] = []
    @State private var selectingFiles = false
    @State private var thread = UUID()
    @State private var task: Task<Void, Never>?
    var body: some View {
        Form {
            ThemedSection("المزود") { Picker("الحساب", selection: $selected) { Text("اختر مزودًا").tag(nil as UUID?); ForEach(context.settings.aiProviders ?? []) { Text($0.name).tag(Optional($0.id)) } }; Button("محادثة جديدة") { reset() } }
            ThemedSection("رسالتك") {
                TextField("اكتب رسالتك", text: $prompt, axis: .vertical).lineLimit(4...12)
                Button("إرفاق صور أو ملفات", systemImage: "paperclip") { selectingFiles = true }.disabled(busy)
                ForEach(attachments) { item in HStack { Image(systemName: item.isImage ? "photo" : "doc"); Text(item.name).lineLimit(1); Spacer(); Button { attachments.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark.circle") } }.font(.caption) }
                Button(busy ? "إيقاف" : "إرسال") { if busy { task?.cancel(); busy = false } else { send() } }.disabled(selected == nil || prompt.isEmpty)
            }
            if !response.isEmpty { ThemedSection("الرد") { Text(response).textSelection(.enabled) } }
        }.settingsPage("مساحة الذكاء الاصطناعي")
            .fileImporter(isPresented: $selectingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                do { let urls = try result.get(); let items = try urls.map { try AIAttachment.load($0) }; guard (attachments + items).reduce(0, { $0 + $1.data.count }) <= 20_000_000 else { throw TranslationFailure.message("مجموع المرفقات يتجاوز 20 ميجابايت.") }; attachments += items }
                catch { response = error.localizedDescription }
            }.onAppear { selected = context.settings.translation?.providerID }
            .onChange(of: selected) { _, _ in reset() }.onDisappear { reset() }
    }
    private func reset() { task?.cancel(); busy = false; let old = thread; thread = UUID(); response = ""; attachments = []; Task { await AIProviderService.shared.end(old) } }
    private func send() {
        guard let config = context.settings.aiProviders?.first(where: { $0.id == selected }), context.permitted else { return }
        let secret = AISecretVault.read(profile: context.profileID, provider: config.id.uuidString), id = thread
        busy = true; response = ""
        task = Task { do { let value = try await AIProviderService.shared.generate(prompt, config: config, secret: secret, context: id, attachments: attachments); if !Task.isCancelled { response = value; attachments = [] } } catch { if !Task.isCancelled { response = error.localizedDescription } }; if id == thread { busy = false } }
    }
}

struct TranslationSettingsSheet: View {
    @StateObject private var context: ProfileSettingsContext
    @Environment(\.dismiss) private var dismiss
    init(model: BrowserModel) { _context = StateObject(wrappedValue: ProfileSettingsContext(model: model, profile: nil)) }
    var body: some View { NavigationStack { TranslationSettingsPage(context: context).toolbar { Button("تم") { dismiss() } } }.environment(\.layoutDirection, .rightToLeft) }
}
