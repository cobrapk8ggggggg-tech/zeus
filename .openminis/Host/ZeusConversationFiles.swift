import SwiftUI
import UniformTypeIdentifiers
import ImageIO

extension AIChatViewModel {
    /// Files providers may download or coordinate a large selection. Keep that
    /// work off the UI actor, use the original attachment cache and placeholders,
    /// and never attach the result to a different/new conversation after a move.
    func zeusAddPickedFiles(_ urls: [URL]) {
        for source in urls {
            let id = UUID(), owner = sessionId
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("InputAttachments")
            let target = directory.appendingPathComponent(UUID().uuidString + "_" + source.lastPathComponent)
            attachments.append(InputAttachment(id: id, fileName: source.lastPathComponent, cacheURL: target, kind: .document, loadState: .loading))
            Task { @MainActor [weak self] in
                do {
                    try await Task.detached(priority: .userInitiated) {
                        let accessed = source.startAccessingSecurityScopedResource()
                        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        var readError: Error?, coordinationError: NSError?
                        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
                            do { try FileManager.default.copyItem(at: readable, to: target) } catch { readError = error }
                        }
                        if let coordinationError { throw coordinationError }
                        if let readError { throw readError }
                    }.value
                    guard let self, self.sessionId == owner, let index = self.attachments.firstIndex(where: { $0.id == id }) else { try? FileManager.default.removeItem(at: target); return }
                    let type = UTType(filenameExtension: source.pathExtension)
                    self.attachments[index].kind = type?.conforms(to: .image) == true || Self.detectImageType(atFileURL: target) != nil ? .image : (type?.conforms(to: .movie) == true ? .video : .document)
                    self.attachments[index].loadState = .ready
                } catch {
                    try? FileManager.default.removeItem(at: target)
                    self?.markPlaceholderFailed(id: id)
                }
            }
        }
    }
}

enum ZeusOutputKind: String, CaseIterable, Identifiable, Sendable {
    case image, document, code, archive, other
    var id: String { rawValue }
    var title: String { switch self { case .image: return "الصور"; case .document: return "المستندات"; case .code: return "المشاريع والشفرة"; case .archive: return "الأرشيفات"; case .other: return "ملفات أخرى" } }
    var symbol: String { switch self { case .image: return "photo"; case .document: return "doc.richtext"; case .code: return "curlybraces"; case .archive: return "doc.zipper"; case .other: return "doc" } }
    static func classify(_ url: URL) -> Self {
        let ext = url.pathExtension.lowercased(), type = UTType(filenameExtension: ext)
        if type?.conforms(to: .image) == true { return .image }
        if ["zip", "tar", "gz", "7z", "rar", "ipa"].contains(ext) { return .archive }
        if ["swift", "js", "ts", "tsx", "jsx", "py", "rb", "sh", "html", "css", "json", "yaml", "yml", "sql", "c", "h", "cpp", "rs", "go"].contains(ext) { return .code }
        if type?.conforms(to: .text) == true || type?.conforms(to: .pdf) == true || ["docx", "xlsx", "pptx", "csv", "epub"].contains(ext) { return .document }
        return .other
    }
}
enum ZeusOutputIndex {
    struct Entry: Identifiable, Sendable {
        let url: URL
        let relativePath: String
        let bytes: Int64
        let date: Date
        let kind: ZeusOutputKind
        var id: String { relativePath }
    }
    struct Snapshot: Sendable { var entries: [Entry]; var truncated: Bool }
    /// This is the existing per-conversation workspace; uploads, browser
    /// snapshots, memory, credentials and other sessions are separate buckets.
    /// Never follow links into those buckets or external mounted directories.
    static func scan(_ root: URL) throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: root.path) else { return Snapshot(entries: [], truncated: false) }
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var error: Error?
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsPackageDescendants], errorHandler: { _, issue in error = issue; return false }) else { throw CocoaError(.fileReadUnknown) }
        var entries: [Entry] = [], visited = 0, truncated = false
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        for case let url as URL in walker {
            try Task.checkCancellation()
            visited += 1
            if visited > 40_000 || entries.count >= 10_000 { truncated = true; break }
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { walker.skipDescendants(); continue }
            if values.isDirectory == true {
                if [".git", "node_modules", ".venv", "__pycache__", ".build", ".cache"].contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base) else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            entries.append(Entry(url: url, relativePath: path, bytes: Int64(values.fileSize ?? 0), date: values.contentModificationDate ?? .distantPast, kind: .classify(url)))
        }
        if let error { throw error }
        return Snapshot(entries: entries, truncated: truncated)
    }
}

struct ZeusConversationFiles: View {
    let sessionID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ZeusOutputIndex.Entry] = []
    @State private var kind: ZeusOutputKind?
    @State private var query = ""
    @State private var grid = true
    @State private var newest = true
    @State private var loading = false
    @State private var message: String?
    @State private var truncated = false
    @State private var preview: FileItem?
    @State private var export: FileItem?
    @State private var reveal: FileItem?
    private var root: URL? {
        guard let sessionID, !sessionID.isEmpty, sessionID != ".", sessionID != "..", !sessionID.contains("/"), !sessionID.contains("\\") else { return nil }
        let root = AIChatViewModel.minisWorkspacePersistentDir(for: sessionID)
        let expectedSession = AIChatViewModel.minisPersistentBase.resolvingSymlinksInPath().appendingPathComponent(sessionID).standardizedFileURL.path
        guard root.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == expectedSession else { return nil }
        return root
    }
    private var filtered: [ZeusOutputIndex.Entry] {
        entries.filter { (kind == nil || $0.kind == kind) && (query.isEmpty || $0.relativePath.localizedCaseInsensitiveContains(query)) }
            .sorted { newest ? $0.date > $1.date : $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filters
                if loading && entries.isEmpty { Spacer(); ProgressView("قراءة ملفات المحادثة…"); Spacer() }
                else if let message { ContentUnavailableView { Label("تعذّر قراءة الملفات", systemImage: "exclamationmark.triangle") } description: { Text(message) } actions: { Button("إعادة المحاولة") { Task { await reload() } } } }
                else if filtered.isEmpty {
                    ContentUnavailableView(query.isEmpty && kind == nil ? "لا توجد ملفات ناتجة بعد" : "لا توجد نتائج", systemImage: "square.grid.2x2", description: Text("تظهر هنا ملفات مساحة عمل هذه المحادثة. المرفقات وملفات المحادثات الأخرى تبقى في أماكنها."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: grid ? [GridItem(.adaptive(minimum: 160), spacing: 14)] : [GridItem(.flexible())], spacing: 14) {
                            ForEach(filtered) { entry in outputCard(entry) }
                        }.padding(16)
                        if truncated { Text("العرض محدود بـ ١٠٬٠٠٠ ملف. افتح الشجرة للوصول إلى بقية الملفات.").font(.footnote).foregroundStyle(.secondary).padding() }
                    }.refreshable { await reload() }
                }
                Text("نفس الملفات الأصلية في الشجرة • \(entries.count) ملف • لا تُنشأ نسخ إضافية")
                    .font(.caption2).foregroundStyle(.secondary).padding(10)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("ملفات هذه المحادثة").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "اسم الملف أو مساره")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("تم") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { grid.toggle() } label: { Image(systemName: grid ? "list.bullet" : "square.grid.2x2") }.accessibilityLabel("تبديل طريقة العرض")
                    Menu { Button(newest ? "الترتيب بالاسم" : "الأحدث أولًا") { newest.toggle() }; Button("تحديث") { Task { await reload() } } } label: { Image(systemName: "line.3.horizontal.decrease") }
                }
            }
            .sheet(item: $preview) { FilePreviewSheet(item: $0) }
            .sheet(item: $export) { DocumentExportView(fileURL: $0.url) }
            .sheet(item: $reveal) { file in
                if let root { NavigationStack { FileBrowserView(rootPath: root, initialPath: file.url.deletingLastPathComponent(), rootLabel: "مساحة المحادثة", highlightFileName: file.name) } }
            }
            .task(id: sessionID) {
                await reload()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(4)) } catch { return }
                    await reload()
                }
            }
        }.environment(\.layoutDirection, .rightToLeft)
    }
    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filter("الكل", symbol: "square.grid.2x2", value: nil)
                ForEach(ZeusOutputKind.allCases) { filter($0.title, symbol: $0.symbol, value: $0) }
            }.padding(12)
        }
    }
    private func filter(_ title: String, symbol: String, value: ZeusOutputKind?) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { kind = value } } label: {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).padding(.horizontal, 13).padding(.vertical, 10)
                .background(kind == value ? Color.accentColor.opacity(0.18) : Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
        }.buttonStyle(.plain)
    }
    private func outputCard(_ entry: ZeusOutputIndex.Entry) -> some View {
        Button { preview = file(entry) } label: {
            VStack(alignment: .leading, spacing: 9) {
                if grid { ZeusOutputThumbnail(entry: entry).frame(height: 118).frame(maxWidth: .infinity).background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12)) }
                HStack {
                    Image(systemName: entry.kind.symbol).foregroundStyle(Color.accentColor)
                    Text(entry.url.lastPathComponent).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    if !grid { Spacer(); Text(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                }
                Text(entry.relativePath).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if grid { Text(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)).font(.caption2).foregroundStyle(.secondary) }
            }.padding(12).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.05)))
        }.buttonStyle(.plain).contextMenu {
            Button("معاينة", systemImage: "eye") { preview = file(entry) }
            Button("تصدير إلى الملفات", systemImage: "square.and.arrow.up") { export = file(entry) }
            Button("إظهار في الشجرة", systemImage: "folder") { reveal = file(entry) }
        }
    }
    private func file(_ entry: ZeusOutputIndex.Entry) -> FileItem? {
        guard let root, let values = try? entry.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              entry.url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { return nil }
        return FileItem(url: entry.url)
    }
    @MainActor private func reload() async {
        guard !loading else { return }; loading = true; defer { loading = false }
        guard let root else { entries = []; return }
        do {
            let worker = Task.detached(priority: .utility) { try ZeusOutputIndex.scan(root) }
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            entries = result.entries; truncated = result.truncated; message = nil
        } catch is CancellationError { } catch { message = error.localizedDescription }
    }
}

private struct ZeusOutputThumbnail: View {
    let entry: ZeusOutputIndex.Entry
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit().padding(4) }
            else { Image(systemName: entry.kind.symbol).font(.system(size: 32, weight: .light)).foregroundStyle(.secondary) }
        }.task(id: "\(entry.id):\(entry.bytes):\(entry.date.timeIntervalSince1970)") {
            image = nil
            guard entry.kind == .image else { return }
            let url = entry.url
            let rendered = await Task.detached(priority: .utility) { () -> UIImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 420, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
                return UIImage(cgImage: thumb)
            }.value
            guard !Task.isCancelled else { return }; image = rendered
        }
    }
}
