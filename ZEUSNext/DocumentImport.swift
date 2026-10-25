import SwiftUI
import UniformTypeIdentifiers

/// One presentation owner for Files on iPad and iPhone. Deliver URLs only after
/// the system controller has left the hierarchy, before callers open another UI
/// or start coordinated reads. Folder URLs remain security scoped (no copying).
public struct ZEUSFilePicker: UIViewControllerRepresentable {
    public let types: [UTType]
    public var asCopy: Bool
    public var multiple: Bool
    public var completion: (Result<[URL], Error>) -> Void
    public init(types: [UTType], asCopy: Bool = false, multiple: Bool = false,
                completion: @escaping (Result<[URL], Error>) -> Void) {
        self.types = types; self.asCopy = asCopy; self.multiple = multiple; self.completion = completion
    }
    public func makeCoordinator() -> Coordinator { Coordinator(completion) }
    public func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = multiple
        picker.shouldShowFileExtensions = true
        return picker
    }
    public func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {
        context.coordinator.completion = completion
    }
    public final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var completion: (Result<[URL], Error>) -> Void
        private var finished = false
        init(_ completion: @escaping (Result<[URL], Error>) -> Void) { self.completion = completion }
        func finish(_ result: Result<[URL], Error>) {
            guard !finished else { return }; finished = true; completion(result)
        }
        public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(urls.isEmpty ? .failure(CocoaError(.userCancelled)) : .success(urls))
        }
        public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish(.failure(CocoaError(.userCancelled)))
        }
    }
}

public extension View {
    func zeusFileImporter(isPresented: Binding<Bool>, allowedContentTypes: [UTType],
                          allowsMultipleSelection: Bool, asCopy: Bool = false,
                          onCompletion: @escaping (Result<[URL], Error>) -> Void) -> some View {
        // Let SwiftUI present the system document picker, including its Files
        // sidebar, providers, navigation and Cancel/Open controls. Embedding its
        // controller as a fullScreenCover root breaks that presentation on iPad.
        fileImporter(isPresented: isPresented, allowedContentTypes: allowedContentTypes,
                     allowsMultipleSelection: allowsMultipleSelection) { result in
            isPresented.wrappedValue = false
            onCompletion(result)
        }
    }
    func zeusFileImporter(isPresented: Binding<Bool>, allowedContentTypes: [UTType], asCopy: Bool = false,
                          onCompletion: @escaping (Result<URL, Error>) -> Void) -> some View {
        zeusFileImporter(isPresented: isPresented, allowedContentTypes: allowedContentTypes, allowsMultipleSelection: false, asCopy: asCopy) {
            onCompletion($0.flatMap { urls in urls.first.map(Result.success) ?? .failure(CocoaError(.fileReadUnknown)) })
        }
    }
}

#if DEBUG
/// Exercises the shipping importer through the system Files UI, without
/// injecting delegate selections. Available only to the UI test launch route.
public struct ZEUSFileImportDiagnostics: View {
    @State private var presented = false
    @State private var mode = 0
    @State private var result = ""
    public init() { }
    public var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Button("Single file") { mode = 0; presented = true }.accessibilityIdentifier("importSingle")
                Button("Multiple files") { mode = 1; presented = true }.accessibilityIdentifier("importMultiple")
                Button("Folder") { mode = 2; presented = true }.accessibilityIdentifier("importFolder")
                Text(result).accessibilityIdentifier("importResult")
            }.navigationTitle("Files import verification")
                .zeusFileImporter(isPresented: $presented, allowedContentTypes: mode == 2 ? [.folder] : [.item], allowsMultipleSelection: mode == 1) { value in
                    switch value {
                    case .success(let urls):
                        let readable = urls.allSatisfy { url in
                            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                            return FileManager.default.isReadableFile(atPath: url.path)
                        }
                        result = "\(urls.count):\(readable ? "readable" : "unreadable"):" + urls.map(\.lastPathComponent).sorted().joined(separator: ",")
                    case .failure(let error): result = "error:" + error.localizedDescription
                    }
                }
        }.task {
            let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ZEUS-Import-Test")
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? Data("first".utf8).write(to: root.appendingPathComponent("ZEUS-Picker-A.txt"))
            try? Data("second".utf8).write(to: root.appendingPathComponent("ZEUS-Picker-B.txt"))
        }
    }
}
#endif
