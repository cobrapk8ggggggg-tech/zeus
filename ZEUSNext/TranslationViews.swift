import SwiftUI
import WebKit

struct TranslationCard: View {
    @ObservedObject var page: PageTranslation
    let settings: () -> Void
    @Environment(\.browserTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if page.offered {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "translate").font(.title2).foregroundStyle(theme.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(page.running ? "جارٍ ترجمة الصفحة…" : page.translated ? "تمت ترجمة الصفحة" : "هل تريد ترجمة هذه الصفحة؟").font(.subheadline.bold())
                        Text(page.running || page.translated ? "\(page.completed) مقطع · \(page.preferences.engine.title)" : "\(Locale.current.localizedString(forLanguageCode: page.sourceLanguage) ?? page.sourceLanguage) ← \(Locale.current.localizedString(forLanguageCode: page.preferences.target) ?? page.preferences.target)").font(.caption).foregroundStyle(theme.secondaryTextColor)
                    }
                    Spacer(minLength: 0)
                    Button { page.dismiss() } label: { Image(systemName: "xmark").padding(8) }.accessibilityLabel("إخفاء بطاقة الترجمة")
                }
                if let error = page.error { Text(error).font(.caption).textSelection(.enabled).accessibilityIdentifier("translationError") }
                HStack {
                    if page.running {
                        ProgressView().controlSize(.small); Button("إيقاف") { page.stop() }
                    } else if page.translated {
                        Button("عرض الأصل") { Task { await page.restore() } }.accessibilityIdentifier("restoreTranslationButton")
                        if page.error != nil { Button("متابعة") { page.resume() } }
                    } else { Button("ترجمة") { page.translate() }.accessibilityIdentifier("confirmTranslationButton").fontWeight(.bold) }
                    Spacer()
                    Menu {
                        Button("إعدادات الترجمة", systemImage: "gearshape") { settings() }
                        Button("عدم الترجمة لهذا الموقع", systemImage: "globe.badge.chevron.backward") { page.excludeSite() }
                        if page.translated { Button("استعادة الأصل") { Task { await page.restore() } } }
                    } label: { Image(systemName: "ellipsis.circle").padding(6) }.accessibilityLabel("خيارات الترجمة")
                }.font(.subheadline).buttonStyle(.borderless)
                if !page.running && !page.translated { Text("تُرسل نصوص الصفحة إلى الخدمة المختارة عند الترجمة.").font(.caption2).foregroundStyle(theme.secondaryTextColor) }
            }.padding(15).glassSurface(22).padding(.horizontal, 14).padding(.top, 40)
                .environment(\.layoutDirection, .rightToLeft).accessibilityIdentifier("translationSuggestionCard")
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.82), value: page.running)
        }
    }
}

struct TranslationSettingsPage: View {
    @ObservedObject var context: ProfileSettingsContext
    @State private var cloudKey = ""
    @State private var message: String?
    private var prefs: TranslationPreferences { context.settings.translation ?? TranslationPreferences() }
    var body: some View {
        Form {
            ThemedSection("لغة الصفحة") {
                Picker("الترجمة إلى", selection: binding(\.target)) { ForEach(TranslationPreferences.languages, id: \.0) { code, name in Text(name).tag(code) } }
                Toggle("اقتراح ترجمة الصفحات الأجنبية", isOn: binding(\.suggest))
                Toggle("الترجمة التلقائية دون سؤال", isOn: binding(\.automatic)).accessibilityIdentifier("automaticPageTranslation")
                Toggle("ترجمة المحتوى الذي يظهر لاحقًا", isOn: binding(\.dynamicContent))
                Text("يُكتشف اختلاف لغة الصفحة على الجهاز. عند إيقاف الترجمة التلقائية تظهر البطاقة في كل صفحة أجنبية جديدة. العربية والفارسية والعبرية والأردية تُعرض باتجاه من اليمين إلى اليسار.").font(.footnote)
            }
            ThemedSection("محرك الترجمة") {
                Picker("الخدمة", selection: binding(\.engine)) { ForEach(TranslationEngine.allCases, id: \.self) { Text($0.title).tag($0) } }
                if prefs.engine == .googleWeb { Text("خدمة Google العامة دون مفتاح. غير رسمية وقد ترفض الطلبات أو تتغير؛ يمكن اختيار Cloud أو الذكاء الاصطناعي عند الحاجة.").font(.footnote) }
                if prefs.engine == .googleCloud {
                    SecureField("مفتاح Cloud Translation API", text: $cloudKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("حفظ المفتاح في Keychain") { do { try AISecretVault.save(cloudKey, profile: context.profileID, provider: "google-cloud"); message = "حُفظ المفتاح." } catch { message = error.localizedDescription } }
                    Text("واجهة Google الرسمية. يلزم تفعيل Cloud Translation API وفوترة حسابك؛ تُحتسب تكلفة النصوص لدى Google.").font(.footnote)
                }
                if prefs.engine == .ai {
                    Picker("المزود", selection: binding(\.providerID)) {
                        Text("اختر مزودًا").tag(nil as UUID?)
                        ForEach(context.settings.aiProviders ?? []) { p in Text(p.name).tag(Optional(p.id)) }
                    }
                    NavigationLink { AISettingsPage(context: context) } label: { Label("إدارة مزودي الذكاء الاصطناعي", systemImage: "sparkles") }
                    Text("تُرسل النصوص على دفعات مع الحفاظ على ترتيبها. الحسابات المرتبطة قد تحفظ طلبات الترجمة في المحادثة المختارة؛ اختيار «محادثة جديدة» ينشئ سياقًا مستقلًا للصفحة.").font(.footnote)
                }
                if let message { Text(message).font(.footnote) }
            }
            if !prefs.excludedHosts.isEmpty {
                ThemedSection("المواقع المستثناة") {
                    ForEach(prefs.excludedHosts, id: \.self) { host in HStack { Text(host); Spacer(); Button("إزالة") { var p = prefs; p.excludedHosts.removeAll { $0 == host }; context.settings.translation = p; context.save() } } }
                }
            }
            ThemedSection("في الصفحة والقارئ") { Text("افتح «القراءة والعرض ← ترجمة الصفحة» من أدوات المتصفح. زر الترجمة موجود أيضًا داخل قارئ الروايات. يمكنك إيقاف العملية أو استعادة الأصل في أي وقت؛ لا تُترجم كلمات المرور أو حقول الكتابة أو الأكواد.").font(.footnote) }
        }.settingsPage("ترجمة الصفحات").onAppear { cloudKey = AISecretVault.read(profile: context.profileID, provider: "google-cloud") }
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
                Text("يمكن إضافة عدة حسابات من كل نوع. تُجلب النماذج والمحادثات والمشاريع المتاحة من الخدمة؛ لا تحتاج كتابة معرّفاتها. المفاتيح والجلسات محفوظة في Keychain لهذا البروفايل، وتُستثنى من النسخ المصدرة.").font(.footnote)
                Text("تكامل حسابي ChatGPT وGemini تجريبي ويعتمد على واجهات خاصة قد تتغير. واجهتا OpenAI المتوافقة وGemini API هما البديل الرسمي. لا يتم تعطيل فحص شهادات TLS.").font(.footnote)
            }
        }.settingsPage("الذكاء الاصطناعي")
    }
    private func remove(_ provider: AIProviderConfiguration) {
        guard context.permitted else { return }
        try? AISecretVault.save("", profile: context.profileID, provider: provider.id.uuidString)
        context.settings.aiProviders?.removeAll { $0.id == provider.id }; context.save()
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
                if config.kind == .geminiAccount {
                    Stepper("رقم حساب Google: \(config.googleAccountIndex)", value: $config.googleAccountIndex, in: 0...9)
                    Text("ترويسة Cookie كاملة من جلستك. الحساب الأول رقمه 0؛ يطابق /u/0/ في موقع Gemini.").font(.footnote)
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
                    if config.kind == .geminiAccount { Text("يسترجع Gemini المحادثات الحديثة والمثبّتة. لا يوفّر مشاريع ChatGPT. تبقى معرّفات سياق الخادم داخليًا دون كتابتها يدويًا.").font(.footnote) }
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
    @State private var thread = UUID()
    @State private var task: Task<Void, Never>?
    var body: some View {
        Form {
            ThemedSection("المزود") { Picker("الحساب", selection: $selected) { Text("اختر مزودًا").tag(nil as UUID?); ForEach(context.settings.aiProviders ?? []) { Text($0.name).tag(Optional($0.id)) } }; Button("محادثة جديدة") { reset() } }
            ThemedSection("رسالتك") {
                TextField("اكتب رسالتك", text: $prompt, axis: .vertical).lineLimit(4...12)
                Button(busy ? "إيقاف" : "إرسال") { if busy { task?.cancel(); busy = false } else { send() } }.disabled(selected == nil || prompt.isEmpty)
            }
            if !response.isEmpty { ThemedSection("الرد") { Text(response).textSelection(.enabled) } }
        }.settingsPage("مساحة الذكاء الاصطناعي").onAppear { selected = context.settings.translation?.providerID }
            .onChange(of: selected) { _, _ in reset() }.onDisappear { reset() }
    }
    private func reset() { task?.cancel(); busy = false; let old = thread; thread = UUID(); response = ""; Task { await AIProviderService.shared.end(old) } }
    private func send() {
        guard let config = context.settings.aiProviders?.first(where: { $0.id == selected }), context.permitted else { return }
        let secret = AISecretVault.read(profile: context.profileID, provider: config.id.uuidString), id = thread
        busy = true; response = ""
        task = Task { do { let value = try await AIProviderService.shared.generate(prompt, config: config, secret: secret, context: id); if !Task.isCancelled { response = value } } catch { if !Task.isCancelled { response = error.localizedDescription } }; if id == thread { busy = false } }
    }
}

struct TranslationSettingsSheet: View {
    @StateObject private var context: ProfileSettingsContext
    @Environment(\.dismiss) private var dismiss
    init(model: BrowserModel) { _context = StateObject(wrappedValue: ProfileSettingsContext(model: model, profile: nil)) }
    var body: some View { NavigationStack { TranslationSettingsPage(context: context).toolbar { Button("تم") { dismiss() } } }.environment(\.layoutDirection, .rightToLeft) }
}
