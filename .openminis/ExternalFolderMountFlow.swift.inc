
/// One SwiftUI sheet owns both steps. The system Files controller is presented
/// over it; selection reveals the confirmation form in this same sheet instead
/// of racing to present another sheet from the settings list.
private struct ZeusExternalFolderMountFlow: View {
    let onMount: (URL, String, Bool) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selecting = false
    @State private var started = false
    @State private var pending: PendingMount?
    @State private var errorText: String?

    var body: some View {
        Group {
            if let value = pending {
                AddMountSheet(
                    sourceURL: value.url,
                    name: Binding(get: { pending?.name ?? value.name }, set: { pending?.name = $0 }),
                    allowWrite: Binding(get: { pending?.allowWrite ?? value.allowWrite }, set: { pending?.allowWrite = $0 }),
                    onCancel: { dismiss() },
                    onConfirm: {
                        let current = pending ?? value
                        do {
                            try onMount(current.url, current.name, current.allowWrite)
                            dismiss()
                        } catch { errorText = error.localizedDescription }
                    }
                )
            } else {
                NavigationStack {
                    ProgressView(AppLocalized("Choose a folder"))
                        .navigationTitle("Mount External Folders")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(AppLocalized("Cancel")) { dismiss() }
                            }
                        }
                }
            }
        }
        .interactiveDismissDisabled(selecting)
        .zeusFileImporter(isPresented: $selecting, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                // Retain the provider grant while the user edits the name or
                // permissions. Release it on cancellation or after add() has
                // created and activated the persistent bookmark.
                pending = PendingMount(url: url, name: MountedFoldersSettingsView.defaultMountName(for: url),
                                       allowWrite: true, scope: ZeusExternalFolderAccess(url))
            case .failure(let error):
                if (error as? CocoaError)?.code == .userCancelled { dismiss() }
                else { errorText = error.localizedDescription }
            }
        }
        .onChange(of: selecting) { _, shown in
            if started && !shown && pending == nil && errorText == nil { dismiss() }
        }
        .task {
            guard !started else { return }
            started = true; selecting = true
        }
        .alert(AppLocalized("Error"), isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button(AppLocalized("OK")) {
                errorText = nil
                if pending == nil { dismiss() }
            }
        } message: { Text(errorText ?? "") }
    }
}

private final class ZeusExternalFolderAccess {
    private let url: URL
    private let active: Bool
    init(_ url: URL) { self.url = url; active = url.startAccessingSecurityScopedResource() }
    deinit { if active { url.stopAccessingSecurityScopedResource() } }
}
