import SwiftUI
import UniformTypeIdentifiers

/// UIKit picker adapter retained for integrations that manage their own host.
/// App import routes below use the system SwiftUI presenter.
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
        background(ZEUSSystemFilesPresentation(presented: isPresented, types: allowedContentTypes,
                                             multiple: allowsMultipleSelection, completion: onCompletion)
            .frame(width: 0, height: 0).accessibilityHidden(true))
    }
    func zeusFileImporter(isPresented: Binding<Bool>, allowedContentTypes: [UTType], asCopy: Bool = false,
                          onCompletion: @escaping (Result<URL, Error>) -> Void) -> some View {
        zeusFileImporter(isPresented: isPresented, allowedContentTypes: allowedContentTypes, allowsMultipleSelection: false, asCopy: asCopy) {
            onCompletion($0.flatMap { urls in urls.first.map(Result.success) ?? .failure(CocoaError(.fileReadUnknown)) })
        }
    }
}

/// Present the complete system controller modally, rather than embedding its
/// view as a SwiftUI cover. Files are imported as temporary copies: unlike
/// open-in-place bookmarks, this also works when a provider cannot resolve a
/// document bookmark. Folder selections retain their in-place access.
private struct ZEUSSystemFilesPresentation: UIViewControllerRepresentable {
    @Binding var presented: Bool
    let types: [UTType]
    let multiple: Bool
    let completion: (Result<[URL], Error>) -> Void
    func makeUIViewController(context: Context) -> Host { Host() }
    func updateUIViewController(_ host: Host, context: Context) {
        host.binding = $presented; host.types = types; host.multiple = multiple; host.completion = completion
        host.requested = presented; host.schedule()
    }
    static func dismantleUIViewController(_ host: Host, coordinator: ()) {
        host.requested = false
        if host.picker != nil { host.finish(nil) }
    }
    final class Host: UIViewController, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        var binding: Binding<Bool>?
        var types: [UTType] = [.item]
        var multiple = false
        var completion: ((Result<[URL], Error>) -> Void)?
        var requested = false
        var picker: UIDocumentPickerViewController?
        private var queued = false
        private var finishing = false
        override func loadView() { view = UIView(); view.backgroundColor = .clear; view.isUserInteractionEnabled = false }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); schedule() }
        func schedule() {
            guard !queued else { return }; queued = true
            DispatchQueue.main.async { [weak self] in self?.queued = false; self?.updatePresentation() }
        }
        private func updatePresentation() {
            guard !finishing else { return }
            if !requested { if picker != nil { finish(nil) }; return }
            guard picker == nil, let window = view.window, var presenter = window.rootViewController else { return }
            while let next = presenter.presentedViewController { presenter = next }
            if presenter.isBeingDismissed || presenter.isBeingPresented {
                if let transition = presenter.transitionCoordinator { transition.animate(alongsideTransition: nil) { [weak self] _ in self?.schedule() } }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.schedule() } }
                return
            }
            let folders = types.contains { $0.conforms(to: .folder) }
            let controller = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: !folders)
            controller.allowsMultipleSelection = multiple
            controller.shouldShowFileExtensions = true
            controller.delegate = self
            controller.modalPresentationStyle = .formSheet
            controller.preferredContentSize = CGSize(width: 900, height: 700)
            picker = controller
            #if DEBUG
            print("[ZEUS Files] present copy=\(!folders) multiple=\(multiple)")
            #endif
            presenter.present(controller, animated: true)
            controller.presentationController?.delegate = self
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard controller === picker else { return }
            #if DEBUG
            print("[ZEUS Files] selected count=\(urls.count)")
            #endif
            finish(urls.isEmpty ? .failure(CocoaError(.fileReadUnknown)) : .success(urls))
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { if controller === picker { finish(nil) } }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finish(nil) }
        func finish(_ result: Result<[URL], Error>?) {
            guard !finishing, let controller = picker else { return }
            finishing = true; requested = false
            let callback = completion
            let delivered = { [weak self] in
                guard let self else { return }
                self.picker = nil; self.binding?.wrappedValue = false; self.finishing = false
                if let result { callback?(result) }
            }
            if controller.presentingViewController == nil { delivered(); return }
            if controller.isBeingDismissed, let transition = controller.transitionCoordinator,
               transition.animate(alongsideTransition: nil, completion: { _ in DispatchQueue.main.async(execute: delivered) }) { return }
            controller.dismiss(animated: true, completion: delivered)
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
                            do {
                                if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                                    _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                                } else { _ = try Data(contentsOf: url) }
                                return true
                            } catch { return false }
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
