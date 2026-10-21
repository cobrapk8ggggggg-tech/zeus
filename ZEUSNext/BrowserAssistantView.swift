import SwiftUI
import UniformTypeIdentifiers

struct BrowserAssistantView: View {
    @ObservedObject var model: BrowserModel
    let fullScreen: Bool
    let close: () -> Void
    let toggleFullScreen: () -> Void
    @StateObject private var controller: BrowserAssistantController
    @State private var importing = false
    @State private var renaming: BrowserAssistantConversation?
    @State private var renameText = ""
    @FocusState private var composerFocused: Bool

    init(model: BrowserModel, fullScreen: Bool, close: @escaping () -> Void, toggleFullScreen: @escaping () -> Void) {
        self.model = model; self.fullScreen = fullScreen; self.close = close; self.toggleFullScreen = toggleFullScreen
        _controller = StateObject(wrappedValue: BrowserAssistantController(model: model))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if controller.showingHistory { history }
                else if controller.showingSettings { settings }
                else { chat }
            }
            if let action = controller.pendingAction { actionCard(action).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .foregroundStyle(.white).tint(.white).preferredColorScheme(.dark)
        .environment(\.layoutDirection, .rightToLeft)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            do {
                let urls = try result.get(), incoming = try urls.map { try AIAttachment.load($0) }
                guard (controller.attachments + incoming).reduce(0, { $0 + $1.data.count }) <= 20_000_000 else { throw TranslationFailure.message("مجموع المرفقات يتجاوز 20 ميجابايت.") }
                controller.attachments += incoming
            } catch { controller.error = error.localizedDescription }
        }
        .alert("تسمية المحادثة", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("الاسم", text: $renameText)
            Button("حفظ") { if let conversation = renaming { controller.rename(conversation, to: renameText) }; renaming = nil }
            Button("إلغاء", role: .cancel) { renaming = nil }
        }
        .onDisappear { controller.cancel() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: close) { Image(systemName: "xmark") }.accessibilityLabel("إغلاق المساعد")
            Button { withAnimation(.snappy) { controller.showingHistory.toggle(); controller.showingSettings = false } } label: { Image(systemName: "sidebar.leading") }.accessibilityLabel("المحادثات")
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.current?.title ?? "ZEUS AI").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(providerName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { controller.newConversation(); controller.showingHistory = false; controller.showingSettings = false } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("محادثة جديدة")
            Button { withAnimation(.snappy) { controller.showingSettings.toggle(); controller.showingHistory = false } } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("إعدادات المساعد")
            Button(action: toggleFullScreen) { Image(systemName: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }.accessibilityLabel(fullScreen ? "تصغير المساعد" : "تكبير المساعد")
        }
        .font(.system(size: 17, weight: .medium)).padding(.horizontal, 16).frame(height: 54)
        .background(Color(white: 0.055)).overlay(alignment: .bottom) { Divider().overlay(.white.opacity(0.12)) }
    }

    private var providerName: String {
        controller.providers.first(where: { $0.id == controller.selectedProviderID })?.name ?? "اختر مزودًا"
    }

    private var chat: some View {
        VStack(spacing: 0) {
            if !controller.preferences.approvedContext { contextConsent }
            else if controller.current?.messages.isEmpty != false { emptyState }
            else { messages }
            if let error = controller.error {
                HStack { Image(systemName: "exclamationmark.triangle"); Text(error).font(.caption); Spacer(); Button { controller.error = nil } label: { Image(systemName: "xmark") } }
                    .padding(10).background(Color.red.opacity(0.16))
            }
            composer
        }
    }

    private var contextConsent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Spacer(minLength: 35)
                Image(systemName: "sparkles.rectangle.stack").font(.system(size: 44, weight: .light))
                Text("مساعد داخل المتصفح").font(.title2.bold())
                Text("اختر السياق الذي يستطيع المساعد استخدامه. لا تُرسل كلمات المرور أو حقول الكتابة أو الكوكيز.").foregroundStyle(.secondary)
                permissionRow("نص الصفحة الحالية", "doc.text", $controller.preferences.currentPage)
                permissionRow("عناوين وروابط التبويبات", "square.on.square", $controller.preferences.openTabs)
                permissionRow("المفضلة", "bookmark", $controller.preferences.bookmarks)
                permissionRow("اسم البروفايل ونوعه", "person.crop.circle", $controller.preferences.profileSummary)
                permissionRow("آخر 50 زيارة", "clock", $controller.preferences.recentHistory)
                Button("متابعة") { controller.approveContext() }
                    .fontWeight(.semibold).frame(maxWidth: .infinity).padding(14).background(.white).foregroundStyle(.black).clipShape(Capsule())
                    .accessibilityIdentifier("approveAssistantContext")
            }.padding(24)
        }
    }

    private func permissionRow(_ title: String, _ symbol: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) { Label(title, systemImage: symbol) }.tint(.green)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack { Circle().fill(.white.opacity(0.08)).frame(width: 78, height: 78); Image(systemName: "sparkles").font(.system(size: 31)) }
            Text("ماذا تريد أن نفعل؟").font(.title2.bold())
            Text("اسأل عن الصفحة، قارن التبويبات، لخّص فصلًا، أو اطلب فتح موقع.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack { suggestion("لخّص الصفحة"); suggestion("قارن التبويبات") }
            HStack { suggestion("استخرج أهم النقاط"); suggestion("افتح موقع GitHub") }
            Spacer()
        }.padding(24)
    }

    private func suggestion(_ text: String) -> some View {
        Button(text) { controller.draft = text; composerFocused = true }
            .font(.caption).padding(.horizontal, 13).padding(.vertical, 9).background(Color(white: 0.10), in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.12)))
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    ForEach(controller.current?.messages ?? []) { message in
                        BrowserAssistantMessageView(message: message).id(message.id)
                    }
                    if controller.busy { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("يفكر…").font(.caption).foregroundStyle(.secondary); Spacer() }.padding(.horizontal, 18).id("thinking") }
                }.padding(.vertical, 20)
            }
            .onChange(of: controller.current?.messages.count) { _, _ in
                if let id = controller.current?.messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
            .onChange(of: controller.busy) { _, value in if value { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } } }
        }
    }

    private var composer: some View {
        VStack(spacing: 9) {
            if !controller.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(controller.attachments) { item in HStack(spacing: 6) { Image(systemName: item.isImage ? "photo" : "doc"); Text(item.name).lineLimit(1); Button { controller.attachments.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark.circle.fill") } }.font(.caption).padding(8).background(Color(white: 0.14), in: Capsule()) } }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button { importing = true } label: { Image(systemName: "plus").frame(width: 36, height: 36).background(Color(white: 0.14), in: Circle()) }.accessibilityLabel("إرفاق ملف")
                TextField("رسالة إلى ZEUS…", text: $controller.draft, axis: .vertical)
                    .lineLimit(1...7).focused($composerFocused).padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 20)).accessibilityIdentifier("browserAssistantComposer")
                Button {
                    if controller.busy { controller.cancel() } else { controller.send() }
                } label: {
                    Image(systemName: controller.busy ? "stop.fill" : "arrow.up").font(.system(size: 15, weight: .bold)).frame(width: 38, height: 38)
                        .background(controller.busy || !controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .white : Color(white: 0.18), in: Circle())
                        .foregroundStyle(controller.busy || !controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .black : .gray)
                }.disabled(!controller.busy && controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("sendBrowserAssistant")
            }
        }.padding(.horizontal, 14).padding(.vertical, 10).background(Color.black.overlay(alignment: .top) { Divider().overlay(.white.opacity(0.1)) })
    }

    private var history: some View {
        VStack(spacing: 0) {
            HStack { Text("المحادثات").font(.title3.bold()); Spacer(); Button("جديدة", systemImage: "plus") { controller.newConversation(); controller.showingHistory = false } }.padding(18)
            if controller.conversations.isEmpty { ContentUnavailableView("لا توجد محادثات", systemImage: "bubble.left.and.bubble.right") }
            else {
                List {
                    ForEach(controller.conversations) { conversation in
                        Button { controller.select(conversation) } label: {
                            HStack(spacing: 12) { Image(systemName: "bubble.left"); VStack(alignment: .leading, spacing: 4) { Text(conversation.title).lineLimit(1); Text(conversation.updated, style: .relative).font(.caption).foregroundStyle(.secondary) }; Spacer() }
                        }.buttonStyle(.plain).listRowBackground(Color(white: 0.055))
                            .contextMenu {
                                Button("إعادة التسمية", systemImage: "pencil") { renameText = conversation.title; renaming = conversation }
                                Button("حذف", systemImage: "trash", role: .destructive) { controller.delete(conversation) }
                            }
                    }
                }.scrollContentBackground(.hidden)
            }
        }
    }

    private var settings: some View {
        Form {
            Section("المزوّد") {
                Picker("النموذج والحساب", selection: Binding(get: { controller.selectedProviderID }, set: { controller.selectedProviderID = $0 })) {
                    Text("اختر مزودًا").tag(nil as UUID?)
                    ForEach(controller.providers) { Text($0.name + " · " + $0.model).tag(Optional($0.id)) }
                }
                if controller.providers.isEmpty { Text("أضف مزودًا من الإعدادات ← الذكاء الاصطناعي.").foregroundStyle(.secondary) }
            }
            Section("سياق المتصفح") {
                Toggle("نص الصفحة الحالية", isOn: $controller.preferences.currentPage)
                Toggle("التبويبات المفتوحة", isOn: $controller.preferences.openTabs)
                Toggle("المفضلة", isOn: $controller.preferences.bookmarks)
                Toggle("اسم البروفايل ونوعه", isOn: $controller.preferences.profileSummary)
                Toggle("سجل التصفح الحديث", isOn: $controller.preferences.recentHistory)
            }
            Section("المواقع المسموح فتحها دائمًا") {
                if controller.preferences.allowedNavigationHosts.isEmpty { Text("لا توجد مواقع").foregroundStyle(.secondary) }
                ForEach(controller.preferences.allowedNavigationHosts, id: \.self) { host in HStack { Text(host); Spacer(); Button { controller.preferences.allowedNavigationHosts.removeAll { $0 == host }; controller.savePreferences() } label: { Image(systemName: "xmark.circle") } } }
            }
        }.scrollContentBackground(.hidden).onDisappear { controller.savePreferences() }
    }

    private func actionCard(_ action: BrowserAssistantAction) -> some View {
        VStack(spacing: 14) {
            HStack { Image(systemName: "safari").font(.title2); VStack(alignment: .leading) { Text("المساعد يطلب إجراءً").font(.headline); Text(action.title).font(.subheadline) }; Spacer() }
            Text(action.detail).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).environment(\.layoutDirection, .leftToRight)
            HStack {
                Button("رفض") { controller.denyAction() }.frame(maxWidth: .infinity)
                Button("هذه المرة") { controller.approveOnce() }.frame(maxWidth: .infinity).buttonStyle(.bordered)
                if case .open(_) = action { Button("دائمًا للموقع") { controller.approveAlways() }.frame(maxWidth: .infinity).buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black) }
            }.font(.caption.bold())
        }.padding(18).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24)).overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.16))).padding(16).frame(maxHeight: .infinity, alignment: .bottom)
    }
}

private struct BrowserAssistantMessageView: View {
    let message: BrowserAssistantMessage
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .user { Spacer(minLength: 38) }
            if message.role == .assistant { Image(systemName: "sparkles").frame(width: 28, height: 28).background(.white.opacity(0.08), in: Circle()) }
            BrowserMarkdownView(source: message.text)
                .padding(message.role == .user ? 13 : 0)
                .background(message.role == .user ? Color(white: 0.13) : .clear, in: RoundedRectangle(cornerRadius: 18))
            if message.role == .assistant { Spacer(minLength: 25) }
        }.padding(.horizontal, 16).environment(\.layoutDirection, .rightToLeft)
    }
}

private struct BrowserMarkdownView: View {
    let source: String
    private var blocks: [MarkdownBlock] { MarkdownBlock.parse(source) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                switch block.kind {
                case .text:
                    Text(attributed(block.content)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                case .code(let language):
                    VStack(spacing: 0) {
                        HStack { Text(language.isEmpty ? "code" : language).font(.caption.monospaced()).foregroundStyle(.secondary); Spacer(); Button { UIPasteboard.general.string = block.content } label: { Label("نسخ", systemImage: "doc.on.doc").font(.caption) } }
                            .padding(.horizontal, 12).frame(height: 36).background(Color(white: 0.12))
                        ScrollView(.horizontal, showsIndicators: true) { Text(block.content).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading).environment(\.layoutDirection, .leftToRight) }
                    }.background(Color(white: 0.075)).clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12)))
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func attributed(_ value: String) -> AttributedString {
        (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .full))) ?? AttributedString(value)
    }
}

private struct MarkdownBlock: Identifiable {
    enum Kind { case text, code(String) }
    let id = UUID(); var kind: Kind; var content: String
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: "\n"); var result: [MarkdownBlock] = [], text: [String] = [], code: [String] = [], language = "", inCode = false
        func flushText() { if !text.isEmpty { result.append(MarkdownBlock(kind: .text, content: text.joined(separator: "\n"))); text = [] } }
        func flushCode() { result.append(MarkdownBlock(kind: .code(language), content: code.joined(separator: "\n"))); code = []; language = "" }
        for line in lines {
            if line.hasPrefix("```") {
                if inCode { flushCode(); inCode = false } else { flushText(); language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces); inCode = true }
            } else if inCode { code.append(line) } else { text.append(line) }
        }
        if inCode { flushCode() } else { flushText() }
        return result.isEmpty ? [MarkdownBlock(kind: .text, content: source)] : result
    }
}
