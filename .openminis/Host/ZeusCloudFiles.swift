import SwiftUI
import CryptoKit
import ZEUSBrowser

@MainActor enum ZeusCloudFiles {
    struct Entry: Identifiable {
        let path: String
        let bytes: Int64
        let digest: String
        var id: String { path }
    }
    private static func fail() -> NSError { NSError(domain: "ZEUSCloud", code: 3, userInfo: [NSLocalizedDescriptionKey: "ملف سحابي غير صالح أو تغير أثناء التنزيل. أعد المحاولة."]) }
    static func list(session: String) async throws -> [Entry] {
        guard UUID(uuidString: session) != nil else { throw fail() }
        let data = try await NativeCloudAccountAPI.runtime("v1/conversations/\(session)/files")
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try (value?["files"] as? [[String: Any]] ?? []).map { file in
            guard let path = file["path"] as? String, let bytes = file["bytes"] as? Int64, let sha = file["sha256"] as? String,
                  bytes >= 0, bytes <= 128 * 1024 * 1024, sha.count == 64 else { throw fail() }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else { throw fail() }
            return Entry(path: path, bytes: bytes, digest: sha)
        }
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
        for entry in try await list(session: session) {
            let special = ["attachments/", "offloads/", "browser/"]
            let base = special.contains(where: entry.path.hasPrefix) ? AIChatViewModel.minisPersistentBase.appendingPathComponent(session) : AIChatViewModel.minisWorkspacePersistentDir(for: session)
            _ = try await download(entry, session: session, to: base.appendingPathComponent(entry.path))
        }
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
    var body: some View {
        NavigationStack {
            List {
                if let issue { Text(issue).foregroundStyle(.orange) }
                ForEach(entries.filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) }) { entry in
                    Button {
                        Task {
                            guard let session else { return }; busy = entry.id; defer { busy = nil }
                            do { preview = FileItem(url: try await ZeusCloudFiles.download(entry, session: session)) }
                            catch { issue = error.localizedDescription }
                        }
                    } label: {
                        HStack {
                            Image(systemName: ZeusOutputKind.classify(URL(fileURLWithPath: entry.path)).symbol).font(.title2)
                            VStack(alignment: .leading) { Text(entry.path).lineLimit(2); Text(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                            Spacer(); if busy == entry.id { ProgressView() } else { Image(systemName: "icloud.and.arrow.down") }
                        }.padding(.vertical, 5)
                    }.disabled(busy != nil)
                }
            }.overlay { if entries.isEmpty && issue == nil { ContentUnavailableView("لا توجد ملفات سحابية بعد", systemImage: "icloud") } }
                .navigationTitle("ملفات المحادثة السحابية").searchable(text: $query)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
                .sheet(item: $preview) { FilePreviewSheet(item: $0) }
                .task { await refresh() }.refreshable { await refresh() }
        }
    }
    @MainActor private func refresh() async {
        guard let session else { return }
        do { entries = try await ZeusCloudFiles.list(session: session); issue = nil } catch { issue = error.localizedDescription }
    }
}

/// A real remote PTY with bounded replay and a fifteen-minute maximum lease.
/// Closing the screen stops it and checkpoints its files, allowing idle sleep.
struct ZeusCloudTerminalView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var terminal: String?
    @State private var output = ""
    @State private var input = ""
    @State private var issue: String?
    @State private var offset = 0
    @State private var conversation = UUID().uuidString.lowercased()
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
            let sessions = await ChatStore.shared.listSessions()
            if let first = sessions.first { conversation = first.id }
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
