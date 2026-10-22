// Adapted from naruto00o9n-max/OpenMinis 6339bfcb2519.
// The original native Markdown, text editor, message surfaces, thinking and
// tool capsule views are retained; BrowserAgent supplies ZEUS' live browser tools.
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct AIChatView: View {
    @ObservedObject var vm: BrowserAgent
    let fullScreen: Bool
    let canResize: Bool
    let close: () -> Void
    let resize: () -> Void
    @State private var history = false
    @State private var settings = false
    @State private var importFile = false
    @State private var photoPicker = false
    @State private var camera = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var inputFocused = false
    @State private var hasSelection = false
    @State private var isScrollable = false
    @State private var isAtBottom = true
    @State private var detailBlock: AssistantBlock?
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var search = ""
    @State private var share: ShareItem?
    @State private var composerHeight: CGFloat = 120
    @ObservedObject private var speech = SpeechRecognitionManager.shared
    @State private var recognizedLength = 0

    var body: some View {
        NavigationStack {
            ZStack(alignment: .leading) {
                ChatColors.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    if !vm.preferences.contextApproved { consent }
                    else { messageList }
                    if let error = vm.errorMessage { errorBanner(error) }
                    if !vm.messages.flatMap(\.blocks).filter({ $0.toolStatus != nil }).isEmpty { OpenMinisFloatingTools(vm: vm).padding(.horizontal, 12).padding(.bottom, 8) }
                    inputBar
                }
                if history { historyPanel.transition(.move(edge: .leading)) }
            }
            .toolbar { navigationToolbar }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(ChatColors.background, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 4) }
        }
        .preferredColorScheme(.dark).tint(.white).foregroundStyle(ChatColors.primaryText)
        .environment(\.layoutDirection, .leftToRight)
        .sheet(isPresented: $settings) { settingsSheet }
        .sheet(item: $detailBlock) { ToolLiveSheet(vm: vm, selected: $0).presentationDetents([.medium, .large]) }
        .sheet(item: $share) { ActivitySheet(url: $0.url) }
        .sheet(item: $vm.approval) { request in OffloadPermissionDialogContent(request: request) { allow, always in vm.answerApproval(allow, always: always) }.presentationDetents([.medium, .large]).interactiveDismissDisabled().environment(\.layoutDirection, .rightToLeft).preferredColorScheme(.dark) }
        .fileImporter(isPresented: $importFile, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            do { for url in try result.get() { addFile(url) } } catch { vm.errorMessage = error.localizedDescription }
        }
        .photosPicker(isPresented: $photoPicker, selection: $photos, maxSelectionCount: 6, matching: .images)
        .onChange(of: photos) { _, values in
            Task { for item in values { if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { addImage(image) } }; photos = [] }
        }
        .sheet(isPresented: $camera) { CameraPicker { image in camera = false; if let image { addImage(image) } }.ignoresSafeArea() }
        .sheet(isPresented: $speech.showLanguagePicker) { SpeechLanguagePickerSheet(speechManager: speech).preferredColorScheme(.dark) }
        .onReceive(speech.$recognizedText) { text in
            guard speech.state == .recording else { return }
            if text.count > recognizedLength { vm.inputText += String(text.dropFirst(recognizedLength)) }
            recognizedLength = text.count
        }
        .alert("تسمية المحادثة", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("الاسم", text: $renameText)
            Button("حفظ") { if let id = renaming { vm.rename(id, to: renameText) }; renaming = nil }
            Button("إلغاء", role: .cancel) { renaming = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatInputAppendRequested)) { note in if let text = note.userInfo?["text"] as? String { vm.inputText += "\n" + text; inputFocused = true } }
        .onDisappear { speech.stopRecording(); vm.save() }
        .accessibilityIdentifier("openMinisAssistant")
    }
    @ToolbarContentBuilder private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { Button { inputFocused = false; withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { history.toggle() } } label: { Image(systemName: "sidebar.leading") }.accessibilityLabel("المحادثات") }
        ToolbarItem(placement: .principal) {
            VStack(spacing: -2) {
                Button { if let session = vm.current { renameText = session.title; renaming = session.id } } label: { Text(vm.current?.title ?? "ZEUS").font(.system(size: 16, weight: .semibold)).lineLimit(1) }
                Menu {
                    ForEach(vm.providers) { provider in
                        Menu(provider.name) {
                            ForEach(provider.models) { model in Button(model.name) { vm.chooseProvider(provider.id); vm.chooseModel(model.id) } }
                        }
                    }
                } label: { HStack(spacing: 3) { Text(vm.modelName.isEmpty ? "اختر نموذجًا" : vm.modelName).font(.system(size: 10)); Image(systemName: "chevron.down").font(.system(size: 8)) }.foregroundStyle(.secondary).padding(.top, 4) }.disabled(vm.isProcessing)
            }.frame(maxWidth: 200)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("محادثة جديدة", systemImage: "square.and.pencil") { vm.newSession(); history = false }
                Button("التعليمات والذاكرة والصلاحيات", systemImage: "slider.horizontal.3") { settings = true }
                Button("تصدير المحادثة", systemImage: "square.and.arrow.up") { if let url = vm.export() { share = ShareItem(url: url) } }
                if canResize { Button(fullScreen ? "تصغير" : "ملء الشاشة", systemImage: fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", action: resize) }
                Button("إغلاق المساعد", systemImage: "xmark", action: close)
            } label: { Image(systemName: "ellipsis") }.accessibilityLabel("خيارات المساعد")
        }
    }
    private var consent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                Text("سياق المتصفح").font(.title2.bold())
                Toggle("قراءة الصفحة المفتوحة", isOn: $vm.preferences.currentPage)
                Toggle("قراءة تبويبات البروفايل", isOn: $vm.preferences.tabs)
                Toggle("معلومات البروفايل", isOn: $vm.preferences.profile)
                Toggle("المفضلة", isOn: $vm.preferences.library)
                Toggle("سجل التصفح", isOn: $vm.preferences.history)
                Button("متابعة") { vm.approveContext() }.buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black).accessibilityIdentifier("approveAgentContext")
            }.tint(.green).environment(\.layoutDirection, .rightToLeft).padding(24)
        }
    }
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if vm.messages.isEmpty { emptyState }
                    ForEach(vm.messages) { message in
                        OpenMinisMessageRow(message: message, active: vm.isProcessing && vm.messages.last?.id == message.id, stop: { vm.cancel() }, retry: { vm.retry(message) }, edit: { vm.inputText = message.content; inputFocused = true }, detailBlock: $detailBlock)
                    }
                    Color.clear.frame(height: 10).id("bottom")
                }.padding(.top, 10)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: vm.revision) { _, _ in if isAtBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: vm.messages.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .scrollDismissesKeyboard(.interactively)
        }
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ZEUS").font(.system(size: 30, weight: .semibold))
            Text("ماذا تريد أن نفعل؟").font(.system(size: 19)).foregroundStyle(.secondary)
            ForEach(["لخّص الصفحة المفتوحة", "قارن الصفحات في تبويباتي", "افتح موقعًا وابحث فيه"], id: \.self) { prompt in
                Button { vm.inputText = prompt; inputFocused = true } label: { HStack { Text(prompt).font(.subheadline); Spacer(); Image(systemName: "arrow.up.left") }.padding(14).background(ChatColors.secondaryBg, in: RoundedRectangle(cornerRadius: 14)) }
            }
        }.padding(.horizontal, 24).padding(.vertical, 55)
    }
    // Original OpenMinis composer layout: attachment chips, multiline native
    // PastableTextView, then + / slash / send under the field, inside one card.
    private var inputBar: some View {
        VStack(spacing: 5) {
            if !vm.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(vm.attachments) { file in HStack { Image(systemName: file.isImage ? "photo" : "doc"); Text(file.name).lineLimit(1); Button { vm.attachments.removeAll { $0.id == file.id } } label: { Image(systemName: "xmark.circle.fill") } }.font(.caption).padding(8).background(ChatColors.secondaryBg, in: RoundedRectangle(cornerRadius: 8)) } }.padding(.horizontal, 16)
                }.padding(.top, 8)
            }
            PastableTextView(text: $vm.inputText, isFocused: $inputFocused, hasSelection: $hasSelection, isScrollable: $isScrollable, isAtScrollBottom: $isAtBottom, placeholder: "Message ZEUS…", onPasteImage: addImage, onPasteFile: addFile, onReturnKey: { vm.send() }, maxHeightOverride: composerHeight)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)
            HStack(spacing: 12) {
                Menu {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) { Button("التقاط صورة", systemImage: "camera") { camera = true } }
                    Button("اختيار صور", systemImage: "photo.on.rectangle") { photoPicker = true }
                    Button("إضافة ملف", systemImage: "doc") { importFile = true }
                } label: { inputIcon("plus") }
                Menu {
                    Button("/new — محادثة جديدة") { vm.newSession() }
                    Button("/page — الصفحة الحالية") { vm.inputText = "اقرأ الصفحة الحالية ولخّصها" }
                    Button("/tabs — التبويبات") { vm.inputText = "اعرض تبويباتي الحالية" }
                    Button("/memory — الذاكرة") { settings = true }
                } label: { Text("/").font(.system(size: 18, weight: .semibold, design: .rounded)).italic().foregroundStyle(ChatColors.secondaryText).frame(width: 34, height: 34).background(ChatColors.inputIconBg, in: Circle()).overlay(Circle().stroke(ChatColors.inputIconBorder, lineWidth: 0.5)) }
                Spacer()
                MicButton(speechManager: speech, inputFocused: $inputFocused, onTap: {
                    if speech.state == .recording { speech.stopRecording() }
                    else { Task { if await speech.requestPermissions() { do { recognizedLength = 0; try speech.startRecording() } catch { vm.errorMessage = error.localizedDescription } } else { vm.errorMessage = "لم تُمنح صلاحية الميكروفون والتعرف على الكلام." } } }
                }, isVoiceActive: speech.state == .recording)
                if speech.state == .recording { Button(speech.languageLabel) { speech.showLanguagePicker = true }.font(.caption) }
                if vm.isProcessing { Text("\(vm.step)").font(.caption.monospaced()).foregroundStyle(.secondary); Button { vm.cancel() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 34)).foregroundStyle(.red) }.accessibilityLabel("إيقاف الوكيل") }
                else { Button { inputFocused = false; vm.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 34)).foregroundStyle(vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ChatColors.sendButtonDisabled : ChatColors.sendButton) }.disabled(vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("sendAgentMessage") }
            }.padding(.horizontal, 12).padding(.bottom, 10)
        }.modifier(ComposerSurface()).padding(.horizontal, 12).padding(.bottom, 8)
    }
    private func inputIcon(_ symbol: String) -> some View { Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(ChatColors.secondaryText).frame(width: 34, height: 34).background(ChatColors.inputIconBg, in: Circle()).overlay(Circle().stroke(ChatColors.inputIconBorder, lineWidth: 0.5)) }
    private var historyPanel: some View {
        VStack(spacing: 0) {
            HStack { Text("ZEUS").font(.title2.bold()); Spacer(); Button { vm.newSession(); history = false } label: { Image(systemName: "square.and.pencil").font(.title3) } }.padding(20)
            TextField("بحث في المحادثات", text: $search).padding(12).background(ChatColors.secondaryBg, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 16)
            List {
                ForEach(vm.sessions.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }.sorted { $0.pinned != $1.pinned ? $0.pinned : $0.updated > $1.updated }) { session in
                    Button { vm.select(session); withAnimation { history = false } } label: {
                        HStack { if session.pinned { Image(systemName: "pin.fill").font(.caption) }; VStack(alignment: .leading, spacing: 5) { Text(session.title).font(.subheadline).lineLimit(1); Text(session.updated, style: .date).font(.caption2).foregroundStyle(.secondary) }; Spacer() }.padding(.vertical, 8)
                    }.buttonStyle(.plain).listRowBackground(vm.selectedID == session.id ? Color(white: 0.12) : .clear)
                        .contextMenu {
                            Button("إعادة التسمية", systemImage: "pencil") { renameText = session.title; renaming = session.id }
                            Button(session.pinned ? "إلغاء التثبيت" : "تثبيت", systemImage: "pin") { vm.pin(session.id) }
                            Button("حذف", systemImage: "trash", role: .destructive) { vm.delete(session.id) }
                        }
                }
            }.listStyle(.plain).scrollContentBackground(.hidden)
            Button("الإعدادات", systemImage: "gearshape") { settings = true }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }.background(ChatColors.background).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("سياق المتصفح") {
                    Toggle("نص الصفحة", isOn: $vm.preferences.currentPage); Toggle("التبويبات", isOn: $vm.preferences.tabs); Toggle("البروفايل", isOn: $vm.preferences.profile); Toggle("المفضلة", isOn: $vm.preferences.library); Toggle("السجل", isOn: $vm.preferences.history)
                }
                Section("تعليمات الوكيل") { TextEditor(text: $vm.preferences.instructions).frame(minHeight: 100) }
                Section("ذاكرة هذا البروفايل") { TextEditor(text: $vm.preferences.memory).frame(minHeight: 120) }
                Section("التنفيذ") { Stepper("الحد الأقصى: \(vm.preferences.maximumSteps) خطوة", value: $vm.preferences.maximumSteps, in: 1...40); Toggle("زر الرجوع يرسل الرسالة", isOn: Binding(get: { UserDefaults.standard.integer(forKey: "returnKeyBehavior") == 1 }, set: { UserDefaults.standard.set($0 ? 1 : 0, forKey: "returnKeyBehavior") })) }
                Section("الأدوات") { ForEach(BrowserAgentTools.tools, id: \.name) { Label($0.title, systemImage: "checkmark.circle").font(.subheadline) } }
                Section("الصلاحيات الدائمة") { ForEach(vm.preferences.grants, id: \.self) { grant in HStack { Text(grant).font(.caption); Spacer(); Button("إلغاء") { vm.preferences.grants.removeAll { $0 == grant }; vm.save() } } } }
                Section("حجم النص") { Picker("الرسائل", selection: $fontSettings.messageBaseScale) { ForEach(FontScaleLevel.allCases) { Text($0.label).tag($0) } }; Picker("الكتابة", selection: $fontSettings.chatInputScale) { ForEach(FontScaleLevel.allCases) { Text($0.label).tag($0) } } }
            }.tint(.green).navigationTitle("إعدادات الوكيل").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { vm.save(); settings = false } } }
        }.environment(\.layoutDirection, .rightToLeft).preferredColorScheme(.dark).onDisappear { vm.save() }
    }
    @ObservedObject private var fontSettings = FontSettings.shared
    private func errorBanner(_ error: String) -> some View { HStack(spacing: 8) { Image(systemName: "exclamationmark.triangle.fill"); Text(error).font(.caption); Spacer(); Button { vm.errorMessage = nil } label: { Image(systemName: "xmark") } }.foregroundStyle(.red).padding(.horizontal, 16).padding(.vertical, 8).background(Color.red.opacity(0.12)) }
    private func addFile(_ url: URL) { do { let file = try AIAttachment.load(url); guard vm.attachments.reduce(file.data.count, { $0 + $1.data.count }) <= 20_000_000 else { throw AgentFailure.message("الحد الأقصى للمرفقات 20 ميجابايت.") }; vm.attachments.append(file) } catch { vm.errorMessage = error.localizedDescription } }
    private func addImage(_ image: UIImage) { guard let data = image.jpegData(compressionQuality: 0.85), data.count < 16_000_000 else { vm.errorMessage = "الصورة كبيرة جدًا."; return }; vm.attachments.append(AIAttachment(name: "photo.jpg", mime: "image/jpeg", data: data, width: Int(image.size.width), height: Int(image.size.height))) }
}

private struct OpenMinisMessageRow: View {
    @ObservedObject var message: ChatMessage
    let active: Bool
    let stop: () -> Void
    let retry: () -> Void
    let edit: () -> Void
    @Binding var detailBlock: AssistantBlock?
    @State private var attachmentPreview: ShareItem?
    var body: some View {
        Group {
            if message.role == .user {
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(message.inputAttachments) { file in Button { attachmentPreview = ShareItem(url: file.cacheURL) } label: { Label(file.fileName, systemImage: file.kind == .image ? "photo" : "doc").font(.caption).padding(10).background(ChatColors.secondaryBg, in: RoundedRectangle(cornerRadius: 10)) } }
                    HStack { Spacer(minLength: 60); Text(message.content).font(.system(size: FontSettings.shared.scaledMessage(16.5))).padding(.horizontal, 14).padding(.vertical, 10).modifier(UserBubbleSurface(isQueued: false)).contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18)).contextMenu { Button("نسخ", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.content }; Button("تعديل", systemImage: "square.and.pencil", action: edit); if !active { Button("إعادة المحاولة", systemImage: "arrow.counterclockwise", action: retry) } } preview: { MessageContextMenuPreview(text: message.content) } }
                }.frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 16).padding(.vertical, 4).sheet(item: $attachmentPreview) { FilePreview(url: $0.url).ignoresSafeArea() }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(message.blocks) { block in OpenMinisBlockRow(block: block, active: active, stop: stop, detailBlock: $detailBlock) }
                    if active && message.shouldShowTypingIndicator { LoadingDotsView(dotSize: 6, color: ChatColors.secondaryText).padding(.vertical, 10) }
                    if !active && !message.blocks.isEmpty { HStack(spacing: 17) { Button { UIPasteboard.general.string = message.blocks.filter { $0.kind == .text }.map(\.content).joined(separator: "\n") } label: { Image(systemName: "doc.on.doc") }; Button { VoiceOutputPlayer.shared.enqueueSegmented(message.blocks.filter { $0.kind == .text }.map(\.content).joined(separator: "\n"), sessionId: VoiceOutputPlayer.manualOwnerId) } label: { Image(systemName: "speaker.wave.2") }; Button(action: retry) { Image(systemName: "arrow.counterclockwise") } }.font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 4) }
                }.padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct OpenMinisFloatingTools: View {
    @ObservedObject var vm: BrowserAgent
    @State private var expanded = false
    @State private var selectedIdx: Int?
    private var blocks: [AssistantBlock] { vm.messages.flatMap(\.blocks).filter { $0.toolStatus != nil } }
    private var displayedIdx: Int { min(max(0, selectedIdx ?? blocks.count - 1), blocks.count - 1) }
    var body: some View {
        if !blocks.isEmpty {
            ToolStatusBar(block: blocks[displayedIdx], toolBlocks: blocks, displayedIdx: displayedIdx, expanded: $expanded, selectedIdx: $selectedIdx)
                .sheet(isPresented: $expanded) { ToolLiveSheet(vm: vm, selected: blocks[displayedIdx]).presentationDetents([.medium, .large]) }
        }
    }
}
private struct OpenMinisBlockRow: View {
    @ObservedObject var block: AssistantBlock
    let active: Bool
    let stop: () -> Void
    @Binding var detailBlock: AssistantBlock?
    var body: some View {
        switch block.kind {
        case .text: SelectableMarkdownView(markdown: block.content, blockId: block.id).fixedSize(horizontal: false, vertical: true)
        case .thinking: ThinkingBlockView(block: block, isStreaming: active)
        default: ToolCapsuleView(block: block, icon: "globe", accentColor: .blue, onStop: stop, detailBlock: $detailBlock)
        }
    }
}
