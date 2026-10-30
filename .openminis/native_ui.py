"""Small, context-checked UI additions to the pinned native source."""

def apply(source, replace):
    # Shared Files presentation, with explicit binding reset and post-dismiss
    # delivery. Keep the original consumers and their security-scoped reads.
    for file in source.rglob('*.swift'):
        text = file.read_text()
        if '.fileImporter(' in text:
            text = 'import ZEUSBrowser\n' + text.replace('.fileImporter(', '.zeusFileImporter(')
            file.write_text(text)

    folders = source / 'Views/Settings/MountedFoldersSettingsView.swift'
    # Present the full system Files controller through the same retained UIKit
    # host as working chat imports. Deliver the URL after dismissal, then open
    # the stock mount confirmation. Never embed Files in a SwiftUI sheet.
    folders.write_text('import ZEUSBrowser\n' + folders.read_text())
    replace(folders, 'private struct PendingMount: Identifiable {', '''private final class ZeusMountFolderLease {
    let url: URL
    let active: Bool
    init(_ url: URL) { self.url = url; active = url.startAccessingSecurityScopedResource() }
    deinit { if active { url.stopAccessingSecurityScopedResource() } }
}

private struct PendingMount: Identifiable {''')
    replace(folders, '    var allowWrite: Bool\n}', '    var allowWrite: Bool\n    var access: ZeusMountFolderLease? = nil\n}')
    text = folders.read_text()
    start = text.index('        .sheet(isPresented: $showingPicker) {')
    end = text.index('        .sheet(item: $pendingMount)', start)
    folders.write_text(text[:start] + '''        .zeusFileImporter(isPresented: $showingPicker, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                pendingMount = PendingMount(url: url, name: Self.defaultMountName(for: url), allowWrite: true, access: ZeusMountFolderLease(url))
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { errorText = error.localizedDescription }
            }
        }
''' + text[end:])
    replace(folders, '.disabled(model.isAtCapacity)', '.accessibilityIdentifier("mountExternalFolder")\n                .disabled(model.isAtCapacity)')
    replace(folders, 'Button(AppLocalized("Mount"), action: onConfirm)', 'Button(AppLocalized("Mount"), action: onConfirm)\n                        .accessibilityIdentifier("confirmExternalMount")')
    replace(folders, 'TextField("name", text: $name)', 'TextField("name", text: $name).accessibilityIdentifier("externalMountName")')
    files = source / 'Views/Rootfs/FileBrowserView.swift'
    replace(files, '''        .sheet(isPresented: $showImportPicker) {
            FileImportPicker { urls in
                viewModel.importFiles(urls)
            }
        }''', '''        .zeusFileImporter(isPresented: $showImportPicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { viewModel.importFiles(urls) }
        }''')
    files.write_text('import ZEUSBrowser\n' + files.read_text())
    replace(files, 'private struct FilePreviewSheet: View', 'struct FilePreviewSheet: View')
    destination = source / 'Views/Settings/BackupDestinationPicker.swift'
    destination.write_text('import ZEUSBrowser\n' + destination.read_text())
    replace(destination, '''            .sheet(isPresented: $showFolderPicker) {
                BackupFolderPicker { url in''', '''            .zeusFileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {''')

    skills = source / 'Views/Skills/SkillsManagementView.swift'
    skills.write_text('import ZEUSBrowser\n' + skills.read_text())
    replace(skills, '''.sheet(isPresented: $showFilePicker) {
                SkillFileDocumentPicker { result in
                    do {''', '''.zeusFileImporter(isPresented: $showFilePicker, allowedContentTypes: [.plainText, .zip, UTType(filenameExtension: "skill", conformingTo: .zip) ?? .zip]) { pick in
                if case .success(let url) = pick {
                    do {
                        let result = try zeusReadSkillPick(url)''')
    replace(skills, '''.sheet(isPresented: $showFilePicker) {
            SkillFileDocumentPicker { result in
                do {''', '''.zeusFileImporter(isPresented: $showFilePicker, allowedContentTypes: [.plainText, .zip, UTType(filenameExtension: "skill", conformingTo: .zip) ?? .zip]) { pick in
            if case .success(let url) = pick {
                do {
                    let result = try zeusReadSkillPick(url)''')
    replace(skills, 'private enum SkillFilePickResult {', '''private func zeusReadSkillPick(_ url: URL) throws -> SkillFilePickResult {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    if ["zip", "skill"].contains(url.pathExtension.lowercased()) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: copy)
        return .archiveURL(copy)
    }
    return .text(try String(contentsOf: url, encoding: .utf8))
}
private enum SkillFilePickResult {''')

    chat = source / 'Views/Chat/AIChatView.swift'
    replace(chat, '''                for url in urls {
                    vm.addFileAttachment(from: url)
                }''', '''                vm.zeusAddPickedFiles(urls)''')
    replace(chat, '    @State private var showFileBrowser = false',
            '    @State private var showFileBrowser = false\n    @State private var zeusShowArtifacts = false\n    @State private var zeusShowAndroid = false')
    replace(chat, '        .sheet(isPresented: $showBrowserSheet) {', '''        .fullScreenCover(isPresented: $zeusShowAndroid) {
            ZeusAndroidLabView(session: vm.sessionId,
                chatPanel: AnyView(VStack(spacing: 0) { messagesArea; inputBar }),
                stopAgent: { vm.cancel() })
        }
        .sheet(isPresented: $zeusShowArtifacts) {
            ZeusConversationFiles(sessionID: vm.sessionId)
        }
        .sheet(isPresented: $showBrowserSheet) {''')
    replace(chat, 'showFileBrowser || showBrowserSheet || showTerminal || showCamera',
            'showFileBrowser || showBrowserSheet || zeusShowArtifacts || zeusShowAndroid || showTerminal || showCamera')
    replace(chat, '    private func dismissAllOwnedImmersiveCovers() {', '''    private func dismissAllOwnedImmersiveCovers() {
        if showBrowserSheet { showBrowserSheet = false }''')
    for file in [chat, source / 'Views/ContentView.swift', source / 'Views/Chat/ToolLiveSheet.swift']:
        replace(file, 'BrowserSheetView(pool:', 'ZeusAgentBrowserWindow(pool:')
    replace(chat, '            onBrowseFiles: { showFileBrowser = true },',
            '            onBrowseFiles: { showFileBrowser = true },\n            onArtifacts: { zeusShowArtifacts = true },\n            onAndroid: { zeusShowAndroid = true },')
    replace(chat, '    let onBrowseFiles: () -> Void', '    let onBrowseFiles: () -> Void\n    let onArtifacts: () -> Void\n    let onAndroid: () -> Void', count=2)
    replace(chat, '''            UIAction(title: AppLocalized("Browse Chat Files"),
                     image: UIImage(systemName: "folder")) { _ in coordinator.parent.onBrowseFiles() },''', '''            UIAction(title: "مختبر Android", image: UIImage(systemName: "apps.iphone")) { _ in coordinator.parent.onAndroid() },
            UIAction(title: "ملفات هذه المحادثة", image: UIImage(systemName: "square.grid.2x2")) { _ in coordinator.parent.onArtifacts() },
            UIAction(title: AppLocalized("Browse Chat Files"),
                     image: UIImage(systemName: "folder")) { _ in coordinator.parent.onBrowseFiles() },''')
    # The old button only hid chrome inside the form sheet. Move the same pool
    # to a real fullScreenCover, after the prior presentation fully dismisses.
    browser = source / 'Agent/BrowserUse/BrowserSheetView.swift'
    replace(browser, '    var onTakeover: (() -> Void)? = nil',
            '    var onTakeover: (() -> Void)? = nil\n    var onWindowResize: (() -> Void)? = nil\n    var windowExpanded = false\n    var onWindowClose: (() -> Void)? = nil')
    replace(browser, '                ToolbarItem(placement: .topBarTrailing) {\n                    Button("Done") { dismiss() }\n                }', '''                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        if let onWindowResize {
                        Button(action: onWindowResize) {
                            Image(systemName: windowExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        }.accessibilityLabel(windowExpanded ? "استعادة نافذة المتصفح" : "ملء الشاشة")
                            .accessibilityIdentifier("agentBrowserWindowResize")
                        }
                        Button("Done") { if let onWindowClose { onWindowClose() } else { dismiss() } }
                    }
                }''')

