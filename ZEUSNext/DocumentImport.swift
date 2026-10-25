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
