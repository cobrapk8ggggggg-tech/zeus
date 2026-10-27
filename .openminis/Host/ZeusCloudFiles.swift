import SwiftUI
import CryptoKit
import ZEUSBrowser

@MainActor enum ZeusCloudFiles {
    struct Entry: Identifiable {
        let path: String
        let bytes: Int64
        let digest: String
        let origin: String
        let sourcePath: String
        let mode: Int
        var id: String { path }
    }
    struct Snapshot { let files: [Entry]; let hash: String }
    private static func fail() -> NSError { NSError(domain: "ZEUSCloud", code: 3, userInfo: [NSLocalizedDescriptionKey: "ملف سحابي غير صالح أو تغير أثناء التنزيل. أعد المحاولة."]) }
    static func list(session: String) async throws -> [Entry] {
        try await snapshot(session: session).files
    }
    static func snapshot(session: String) async throws -> Snapshot {
        guard UUID(uuidString: session) != nil else { throw fail() }
        let data = try await NativeCloudAccountAPI.runtime("v1/conversations/\(session)/files")
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let files = try (value?["files"] as? [[String: Any]] ?? []).map { file in
            guard let path = file["path"] as? String, let bytes = file["bytes"] as? Int64, let sha = file["sha256"] as? String,
                  bytes >= 0, bytes <= 128 * 1024 * 1024, sha.count == 64 else { throw fail() }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else { throw fail() }
            let origin = file["origin"] as? String ?? "workspace"
            let source = file["source_path"] as? String ?? path
            let sourceParts = source.split(separator: "/", omittingEmptySubsequences: false)
            guard !source.hasPrefix("/"), sourceParts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else { throw fail() }
            return Entry(path: path, bytes: bytes, digest: sha, origin: origin, sourcePath: source, mode: (file["mode"] as? Int ?? 0o600) & 0o777)
        }
        guard let hash = value?["workspace_hash"] as? String, hash.count == 64 else { throw fail() }
        return Snapshot(files: files, hash: hash)
    }
    static func download(_ entry: Entry, session: String, to destination: URL? = nil) async throws -> URL {
        let fm = FileManager.default
        let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ZEUSCloudFiles/\(session)/\(entry.digest)")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let result = cache.appendingPathComponent(URL(fileURLWithPath: entry.path).lastPathComponent)
        if !fm.fileExists(atPath: result.path) {
            let stage = cache.appendingPathComponent(UUID().uuidString)
            fm.createFile(atPath: stage.path, contents: nil)
            defer { try? fm.removeItem(at: stage) }
            let handle = try FileHandle(forWritingTo: stage); defer { try? handle.close() }
            let grant = try await NativeCloudAccountAPI.fileGrant(conversation: session)
            var offset: Int64 = 0, digest = SHA256()
            while offset < entry.bytes {
                let body = try JSONSerialization.data(withJSONObject: ["path": entry.path, "offset": offset, "file_grant": grant])
                let data = try await NativeCloudAccountAPI.runtime("v1/conversations/\(session)/file", method: "POST", body: body)
                guard !data.isEmpty, offset + Int64(data.count) <= entry.bytes else { throw fail() }
                digest.update(data: data); try handle.write(contentsOf: data); offset += Int64(data.count)
            }
            try handle.synchronize()
            guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == entry.digest else { throw fail() }
            try fm.moveItem(at: stage, to: result)
        }
        if let destination {
            var parent = destination.deletingLastPathComponent()
            while parent.path != "/" {
                if fm.fileExists(atPath: parent.path), try parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw fail() }
                parent.deleteLastPathComponent()
            }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: result) }
            else { try fm.copyItem(at: result, to: destination) }
            try fm.setAttributes([.posixPermissions: entry.mode], ofItemAtPath: destination.path)
            return destination
        }
        // One byte budget across conversations, with an exception for the
        // file the user is currently opening. Remote originals are untouched.
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: result.path)
        let cacheRoot = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ZEUSCloudFiles")
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var files: [(URL, Int64, Date)] = []
        if let scan = fm.enumerator(at: cacheRoot, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) {
            for case let url as URL in scan {
                guard let value = try? url.resourceValues(forKeys: keys), value.isRegularFile == true, value.isSymbolicLink != true else { continue }
                files.append((url, Int64(value.fileSize ?? 0), value.contentModificationDate ?? .distantPast))
            }
        }
        var used = files.reduce(Int64(0)) { $0 + $1.1 }
        for file in files.sorted(by: { $0.2 < $1.2 }) where used > 64 * 1024 * 1024 && file.0 != result {
            do { try fm.removeItem(at: file.0); used -= file.1 } catch { }
        }
        return result
    }
    static func downloadAll(session: String) async throws {
        let manifest = try await snapshot(session: session)
        for entry in manifest.files {
            let base = entry.origin == "input" ? AIChatViewModel.minisPersistentBase.appendingPathComponent(session) : AIChatViewModel.minisWorkspacePersistentDir(for: session)
            _ = try await download(entry, session: session, to: base.appendingPathComponent(entry.sourcePath))
        }
        guard try await snapshot(session: session).hash == manifest.hash else { throw fail() }
        try ZeusCloudRuntime.shared.recordBaseHash(session: session, hash: manifest.hash)
    }
}

struct ZeusCloudFilesView: View {
    let session: String?
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ZeusCloudFiles.Entry] = []
    @State private var query = ""
    @State private var issue: String?
    @State private var busy: String?
    @State private var preview: FileItem?
    @State private var showInputs = false
    @State private var folders: Bool
    @State private var kind: ZeusOutputKind?
    init(session: String?, folders: Bool = false) { self.session = session; _folders = State(initialValue: folders) }
    private var filtered: [ZeusCloudFiles.Entry] {
        entries.filter { (showInputs || $0.origin != "input") && (query.isEmpty || $0.path.localizedCaseInsensitiveContains(query)) && (kind == nil || ZeusOutputKind.classify(URL(fileURLWithPath: $0.path)) == kind) }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        chip("الكل", value: nil)
                        ForEach(ZeusOutputKind.allCases, id: \.self) { chip($0.title, value: $0) }
                    }.padding(.horizontal, 18).padding(.vertical, 12)
                }
                if let issue { Text(issue).font(.footnote).foregroundStyle(.orange).padding(.horizontal) }
                if folders {
                    ZeusCloudDirectory(entries: filtered, prefix: "", busy: busy, open: open)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 155, maximum: 230), spacing: 14)], spacing: 14) {
                            ForEach(filtered) { entry in
                                Button { open(entry) } label: {
                                    VStack(alignment: .leading, spacing: 13) {
                                        HStack {
                                            Image(systemName: ZeusOutputKind.classify(URL(fileURLWithPath: entry.path)).symbol)
                                                .font(.system(size: 32, weight: .light)).foregroundStyle(.primary)
                                            Spacer()
                                            if busy == entry.id { ProgressView() } else { Image(systemName: "icloud.and.arrow.down").foregroundStyle(.secondary) }
                                        }.frame(height: 48)
                                        Text(URL(fileURLWithPath: entry.path).lastPathComponent).font(.subheadline.weight(.semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                        Text(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                                    }.padding(17).frame(maxWidth: .infinity, minHeight: 152, alignment: .topLeading)
                                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                                        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.07)))
                                }.buttonStyle(.plain).disabled(busy != nil)
                            }
                        }.padding(18)
                    }.background(Color(uiColor: .systemGroupedBackground))
                }
            }
            .overlay { if filtered.isEmpty && issue == nil { ContentUnavailableView("لا توجد ملفات مطابقة", systemImage: "icloud") } }
            .navigationTitle(folders ? "مجلدات المحادثة" : "ملفات المحادثة")
            .searchable(text: $query)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Toggle("استعراض المجلدات", isOn: $folders)
                        Toggle("إظهار ملفات الإدخال والمرفقات", isOn: $showInputs)
                    } label: { Image(systemName: folders ? "folder" : "square.grid.2x2") }
                }
            }
            .sheet(item: $preview) { FilePreviewSheet(item: $0) }
            .task { await refresh() }.refreshable { await refresh() }
        }
    }
    private func chip(_ title: String, value: ZeusOutputKind?) -> some View {
        Button { kind = value } label: {
            Text(title).font(.subheadline.weight(.medium)).padding(.horizontal, 15).padding(.vertical, 8)
                .background(kind == value ? Color.primary.opacity(0.13) : Color.secondary.opacity(0.06), in: Capsule())
        }.buttonStyle(.plain)
    }
    @MainActor private func open(_ entry: ZeusCloudFiles.Entry) {
        guard let session, busy == nil else { return }; busy = entry.id
        Task {
            defer { busy = nil }
            do { preview = FileItem(url: try await ZeusCloudFiles.download(entry, session: session)) }
            catch { issue = error.localizedDescription }
        }
    }
    @MainActor private func refresh() async {
        guard let session else { return }
        do { entries = try await ZeusCloudFiles.list(session: session); issue = nil } catch { issue = error.localizedDescription }
    }
}

private struct ZeusCloudDirectory: View {
    let entries: [ZeusCloudFiles.Entry]
    let prefix: String
    let busy: String?
    let open: (ZeusCloudFiles.Entry) -> Void
    private var directories: [String] {
        Array(Set(entries.filter { $0.path.hasPrefix(prefix) }.compactMap { entry -> String? in
            let suffix = String(entry.path.dropFirst(prefix.count)); guard let slash = suffix.firstIndex(of: "/") else { return nil }
            return String(suffix[..<slash])
        })).sorted()
    }
    var body: some View {
        List {
            ForEach(directories, id: \.self) { folder in
                NavigationLink {
                    AnyView(ZeusCloudDirectory(entries: entries, prefix: prefix + folder + "/", busy: busy, open: open).navigationTitle(folder))
                } label: { Label(folder, systemImage: "folder.fill") }
            }
            ForEach(entries.filter { $0.path.hasPrefix(prefix) && !$0.path.dropFirst(prefix.count).contains("/") }) { entry in
                Button { open(entry) } label: {
                    HStack {
                        Label(String(entry.path.dropFirst(prefix.count)), systemImage: ZeusOutputKind.classify(URL(fileURLWithPath: entry.path)).symbol)
                        Spacer()
                        if busy == entry.id { ProgressView() } else { Text(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                    }
                }.disabled(busy != nil)
            }
        }
    }
}

/// A real remote PTY with bounded replay and a fifteen-minute maximum lease.
/// Closing the screen stops it and checkpoints its files, allowing idle sleep.
struct ZeusCloudTerminalView: View {
    let session: String?
    let initialCommand: String?
    @Environment(\.dismiss) private var dismiss
    @State private var terminal: String?
    @State private var output = ""
    @State private var input = ""
    @State private var issue: String?
    @State private var offset = 0
    @State private var conversation = UUID().uuidString.lowercased()
    init(session: String? = nil, initialCommand: String? = nil) {
        self.session = session; self.initialCommand = initialCommand
        _input = State(initialValue: initialCommand ?? "")
    }
    var body: some View {
        NavigationStack {
            VStack {
                Text("طرفية Linux سحابية — تتوقف تلقائيًا بعد 15 دقيقة، وتُحفظ ملفاتها في الحساب.").font(.caption).foregroundStyle(.secondary)
                if let issue { Text(issue).foregroundStyle(.orange) }
                ScrollView { Text(output).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.background(.black.opacity(0.07))
                HStack {
                    TextField("أمر الطرفية", text: $input, axis: .vertical).font(.system(.body, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("إرسال") { send(input + "\n"); input = "" }.disabled(terminal == nil)
                    Button("⌃C") { send("\u{03}") }.disabled(terminal == nil)
                }
            }.padding().navigationTitle("الطرفية السحابية")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("إغلاق وحفظ") { Task { await stop(); dismiss() } } } }
                .task { await start() }.onDisappear { Task { await stop() } }
        }
    }
    private func send(_ text: String) {
        guard let terminal else { return }
        Task { do { _ = try await NativeCloudAccountAPI.runtime("v1/terminals/\(terminal)/input", method: "POST", body: JSONSerialization.data(withJSONObject: ["chars": text])) } catch { issue = error.localizedDescription } }
    }
    @MainActor private func start() async {
        do {
            // One stable account-owned terminal workspace, reusable on reinstall.
            conversation = session?.lowercased() ?? "00000000-0000-4000-8000-000000000002"
            let grant = try await NativeCloudAccountAPI.fileGrant(conversation: conversation)
            let body = try JSONSerialization.data(withJSONObject: ["conversation": conversation, "file_grant": grant])
            let data = try await NativeCloudAccountAPI.runtime("v1/terminals", method: "POST", body: body)
            terminal = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String
            while let terminal, !Task.isCancelled {
                if UIApplication.shared.applicationState == .active {
                    let data = try await NativeCloudAccountAPI.runtime("v1/terminals/\(terminal)?offset=\(offset)")
                    let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    output += value?["output"] as? String ?? ""; output = String(output.suffix(64 * 1024))
                    offset = value?["next_offset"] as? Int ?? offset
                    if value?["exit_code"] is Int { break }
                }
                try await Task.sleep(for: .milliseconds(500))
            }
        } catch is CancellationError { }
        catch { issue = error.localizedDescription }
    }
    @MainActor private func stop() async {
        guard let id = terminal else { return }; terminal = nil
        _ = try? await NativeCloudAccountAPI.runtime("v1/terminals/\(id)/close", method: "POST", body: Data("{}".utf8))
    }
}
