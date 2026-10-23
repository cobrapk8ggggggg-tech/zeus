import SwiftUI
import UniformTypeIdentifiers

/// Copying through the document provider lets iCloud finish downloading before
/// handing us a readable URL, including backups with an unregistered extension.
struct BackupDocumentPicker: UIViewControllerRepresentable {
    var selected: (URL) -> Void
    var cancelled: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {
        context.coordinator.parent = self
    }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: BackupDocumentPicker
        init(parent: BackupDocumentPicker) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { parent.selected(url) } else { parent.cancelled() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { parent.cancelled() }
    }
}

enum BackupFileReader {
    static let maximumBytes = 6_000_000
    static func load(_ url: URL) async throws -> ProfileBackup {
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var result: Result<ProfileBackup, Error>?
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                result = Result {
                    let handle = try FileHandle(forReadingFrom: readable)
                    defer { try? handle.close() }
                    var bytes = Data()
                    while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                        guard bytes.count + chunk.count <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
                        bytes.append(chunk)
                    }
                    return try JSONDecoder().decode(ProfileBackup.self, from: bytes).validated()
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw URLError(.cannotOpenFile) }
            return try result.get()
        }.value
    }
}
