import SwiftUI
import QuickLook

/// Storage operations are scoped to the application's data container. Links are
/// visible but never traversed: a workspace symlink must not expose another root.
enum ZeusStorageFiles {
    struct Entry: Identifiable, Sendable {
        let url: URL
        let directory: Bool
        let link: Bool
        let bytes: Int64
        let modified: Date
        var id: String { url.path }
    }
    static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
    static func canonicalPath(_ url: URL) -> String {
        url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
    }
    static func excluded(_ url: URL, roots: [URL]) -> Bool {
        guard !roots.isEmpty else { return false }
        let path = canonicalPath(url)
        return roots.contains { let root = canonicalPath($0); return path == root || path.hasPrefix(root + "/") }
    }
    static func size(_ url: URL, excluding: [URL] = []) throws -> Int64 {
        if excluded(url, roots: excluding) { return 0 }
        let value = try url.resourceValues(forKeys: keys)
        if value.isSymbolicLink == true || value.isDirectory != true {
            return Int64(value.totalFileAllocatedSize ?? value.fileSize ?? 0)
        }
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys)).reduce(0) { try $0 + size($1, excluding: excluding) }
    }
    static func children(_ root: URL, container: URL, excluding: [URL] = []) throws -> [Entry] {
        try validate(root, container: container)
        guard try root.resourceValues(forKeys: keys).isSymbolicLink != true else { throw failure("لا يمكن الدخول إلى رابط رمزي.") }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)).filter { !excluded($0, roots: excluding) }.map { url in
            let v = try url.resourceValues(forKeys: keys)
            return Entry(url: url, directory: v.isDirectory == true && v.isSymbolicLink != true,
                         link: v.isSymbolicLink == true, bytes: try size(url, excluding: excluding), modified: v.contentModificationDate ?? .distantPast)
        }
    }
    static func validate(_ url: URL, container: URL) throws {
        let root = container.resolvingSymlinksInPath().standardizedFileURL.path
        // Resolve the parent, not the leaf, so removing a link removes the link.
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        guard parent == root || parent.hasPrefix(root + "/") else { throw failure("المسار خارج مساحة التطبيق.") }
    }
    static func validateDeletion(_ url: URL, container: URL, protected: [URL], structuralRoots: [URL]) throws {
        try validate(url, container: container)
        let path = url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
        guard !structuralRoots.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL.path == path }) else {
            throw failure("لا يمكن حذف جذر بيئة التنفيذ كملف عادي. استخدم إعادة ضبط البيئة من إعداداتها؛ يمكنك حذف الملفات والمجلدات داخلها بشكل انتقائي.")
        }
        for item in protected {
            let p = item.resolvingSymlinksInPath().standardizedFileURL.path
            if path == p || path.hasPrefix(p + "/") || p.hasPrefix(path + "/") {
                throw failure("هذا العنصر قيد الاستخدام أو تديره قاعدة بيانات. أوقف المهمة، أو استخدم إدارة المحادثات أو بيانات المواقع لحذفه.")
            }
        }
    }
    static func delete(_ url: URL, container: URL, protected: [URL]) throws {
        try validateDeletion(url, container: container, protected: protected, structuralRoots: [RootfsManager.shared.dataPath])
        let path = url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
        try FileManager.default.removeItem(at: url)
        let guestRoot = RootfsManager.shared.dataPath.resolvingSymlinksInPath().standardizedFileURL.path
        if path.hasPrefix(guestRoot + "/") {
            RootfsManager.shared.removeFakefsPath(String(path.dropFirst(guestRoot.count)))
        }
    }
    static func failure(_ text: String) -> NSError { NSError(domain: "ZeusStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    static func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

@MainActor enum ZeusStorageScope {
    static var container: URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }
    static var library: URL { FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0] }
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var protected: [URL] {
        var paths = ["minis.db", "minis.db-wal", "minis.db-shm"].map { library.appendingPathComponent("MinisChat/" + $0) }
        paths.append(library.appendingPathComponent("Preferences"))
        // WebKit databases are live; use the browser's per-site data manager.
        paths.append(library.appendingPathComponent("WebKit"))
        paths.append(library.appendingPathComponent("HTTPStorages"))
        let shell = documents.appendingPathComponent("alpine-rootfs")
        paths += ["meta.db", "meta.db-wal", "meta.db-shm", ".arch"].map { shell.appendingPathComponent($0) }
        let active = SessionActivityTracker.shared.activeSessions
        if !active.isEmpty { paths.append(documents.appendingPathComponent("alpine-rootfs")) }
        paths += active.map { library.appendingPathComponent("MinisChat/minis/" + $0) }
        return paths
    }
    static func roots(_ category: String) -> [URL] {
        switch category {
        case "Shell Container": return [documents.appendingPathComponent("alpine-rootfs")]
        case "Session Files", "Orphaned Session Files": return [library.appendingPathComponent("MinisChat/minis")]
        case "Logs & Caches": return [library.appendingPathComponent("Logs"), library.appendingPathComponent("Caches")]
        case "Temporary Files": return [FileManager.default.temporaryDirectory]
        case "Stale Shell Leftovers": return ((try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix(".alpine-rootfs-broken-") }
        default: return [documents, library]
        }
    }
    static var otherExclusions: [URL] {
        var roots = [documents.appendingPathComponent("alpine-rootfs"), library.appendingPathComponent("Logs"), library.appendingPathComponent("Caches"), library.appendingPathComponent("MinisChat/minis")]
        roots += ((try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix(".alpine-rootfs-broken-") }
        let chat = library.appendingPathComponent("MinisChat")
        roots += ((try? FileManager.default.contentsOfDirectory(at: chat, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix("minis.db") }
        return roots
    }
    static func title(_ category: String) -> String {
        switch category {
        case "Shell Container": return "بيئة الوكيل المحلية"
        case "Chat Database": return "المحادثات وقاعدة البيانات"
        case "Session Files": return "ملفات الجلسات"
        case "Logs & Caches": return "السجلات والذاكرة المؤقتة"
        case "Temporary Files": return "الملفات المؤقتة"
        case "Orphaned Session Files": return "ملفات الجلسات المتبقية"
        case "Stale Shell Leftovers": return "بقايا بيئات سابقة"
        default: return "بقية بيانات التطبيق"
        }
    }
}

struct ZeusStorageCategoryView: View {
    let category: String
    var body: some View {
        Group {
            if category == "Chat Database" { ZeusStorageConversationsView() }
            else if ZeusStorageScope.roots(category).count == 1, let root = ZeusStorageScope.roots(category).first {
                directory(root)
            } else {
                List {
                    ForEach(ZeusStorageScope.roots(category), id: \.path) { root in
                        NavigationLink { directory(root) } label: {
                            Label(root.lastPathComponent, systemImage: "folder")
                        }
                    }
                }
            }
        }.navigationTitle(ZeusStorageScope.title(category)).navigationBarTitleDisplayMode(.inline)
    }
    private func directory(_ root: URL) -> ZeusStorageDirectoryView {
        ZeusStorageDirectoryView(root: root, excluding: category == "Other" ? ZeusStorageScope.otherExclusions : [], orphanedOnly: category == "Orphaned Session Files")
    }
}

struct ZeusStorageDirectoryView: View {
    let root: URL
    let excluding: [URL]
    let orphanedOnly: Bool
    init(root: URL, excluding: [URL] = [], orphanedOnly: Bool = false) {
        self.root = root; self.excluding = excluding; self.orphanedOnly = orphanedOnly
    }
    @State private var entries: [ZeusStorageFiles.Entry] = []
    @State private var selection = Set<String>()
    @State private var query = ""
    @State private var order = 0
    @State private var busy = false
    @State private var error: String?
    @State private var confirm = false
    @State private var selecting = false
    @State private var preview: URL?
    private var visible: [ZeusStorageFiles.Entry] {
        entries.filter { query.isEmpty || $0.url.lastPathComponent.localizedCaseInsensitiveContains(query) }.sorted {
            if order == 1 { return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
            if order == 2 { return $0.modified > $1.modified }
            return $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes
        }
    }
    private var selectedSize: Int64 { entries.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.bytes } }
    var body: some View {
        List {
            Section {
                Text(root.path.replacingOccurrences(of: NSHomeDirectory(), with: "ZEUS"))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack { Text("الحجم"); Spacer(); Text(ZeusStorageFiles.format(entries.reduce(0) { $0 + $1.bytes })) }
                Picker("الترتيب", selection: $order) {
                    Text("الأكبر أولاً").tag(0); Text("الاسم").tag(1); Text("الأحدث").tag(2)
                }
            }
            Section {
                if busy { ProgressView() }
                else if visible.isEmpty { Text("لا توجد ملفات").foregroundStyle(.secondary) }
                ForEach(visible) { entry in
                    HStack {
                        if selecting {
                            Button { if !selection.insert(entry.id).inserted { selection.remove(entry.id) } } label: {
                                Image(systemName: selection.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                            }.buttonStyle(.borderless)
                        }
                        if entry.directory {
                            NavigationLink { ZeusStorageDirectoryView(root: entry.url, excluding: excluding) } label: { row(entry) }
                        } else {
                            Button { if !entry.link { preview = entry.url } } label: { row(entry) }.foregroundStyle(.primary)
                        }
                    }
                    .swipeActions { Button(role: .destructive) { selection = [entry.id]; confirm = true } label: { Label("حذف", systemImage: "trash") } }
                }
            } footer: { Text("حذف الملفات نهائي. ملفات المحادثات النشطة وقاعدة البيانات محمية؛ تُدار المحادثات من قسمها.") }
            if selecting {
                Button("تحديد العناصر الظاهرة") { selection = Set(visible.map(\.id)) }
                Button(role: .destructive) { confirm = true } label: { Text("حذف المحدد (\(selection.count)) · \(ZeusStorageFiles.format(selectedSize))") }
                    .disabled(selection.isEmpty || busy)
            }
        }
        .navigationTitle(root.lastPathComponent).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "بحث في هذا المجلد")
        .toolbar { Button(selecting ? "تم" : "تحديد") { selecting.toggle(); selection = [] } }
        .task(id: root) { await reload() }
        .refreshable { await reload() }
        .alert("حذف \(selection.count) عنصر؟", isPresented: $confirm) {
            Button("حذف نهائياً", role: .destructive) { Task { await removeSelected() } }
            Button("إلغاء", role: .cancel) { }
        } message: { Text("سيُحذف \(ZeusStorageFiles.format(selectedSize)). لا يمكن التراجع عن الحذف.") }
        .alert("التخزين", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("موافق") { error = nil } } message: { Text(error ?? "") }
        .quickLookPreview($preview)
    }
    private func row(_ entry: ZeusStorageFiles.Entry) -> some View {
        HStack {
            Image(systemName: entry.link ? "link" : entry.directory ? "folder" : "doc")
            VStack(alignment: .leading) {
                Text(entry.url.lastPathComponent).lineLimit(2)
                Text(entry.modified, style: .date).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ZeusStorageFiles.format(entry.bytes)).font(.caption).foregroundStyle(.secondary)
        }
    }
    @MainActor private func reload() async {
        busy = true
        let directory = root, container = ZeusStorageScope.container
        var exclusions = excluding
        if orphanedOnly {
            let known = await ChatStore.shared.listSessions()
            exclusions += known.map { directory.appendingPathComponent($0.id) }
        }
        let finalExclusions = exclusions
        let result = await Task.detached(priority: .utility) { Result { try ZeusStorageFiles.children(directory, container: container, excluding: finalExclusions) } }.value
        switch result { case .success(let value): entries = value; selection.formIntersection(Set(value.map(\.id)))
        case .failure(let failure): error = failure.localizedDescription }
        busy = false
    }
    @MainActor private func removeSelected() async {
        busy = true
        let targets = entries.filter { selection.contains($0.id) }.map(\.url)
        // Obtain active-session protections immediately before deletion.
        var protected = ZeusStorageScope.protected
        let container = ZeusStorageScope.container
        if orphanedOnly {
            // Recheck classification at delete time, including sessions restored
            // by sync since the initial scan. Known conversations are not orphans.
            let known = await ChatStore.shared.listSessions()
            protected += known.map { root.appendingPathComponent($0.id) }
        }
        let finalProtected = protected
        let failures = await Task.detached(priority: .utility) {
            targets.compactMap { url -> String? in
                do { try ZeusStorageFiles.delete(url, container: container, protected: finalProtected); return nil }
                catch { return url.lastPathComponent + ": " + error.localizedDescription }
            }
        }.value
        selection = []; await reload()
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
    }
}

struct ZeusStorageConversationsView: View {
    @State private var sessions: [ChatSession] = []
    @State private var query = ""
    @State private var pending: ChatSession?
    @State private var error: String?
    var body: some View {
        List {
            Section {
                ForEach(sessions.filter { query.isEmpty || ($0.title ?? "").localizedCaseInsensitiveContains(query) }, id: \.id) { session in
                    HStack {
                        Text(session.title ?? "محادثة بلا عنوان").lineLimit(2)
                        Spacer()
                        Button(role: .destructive) { pending = session } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            } footer: { Text("حذف المحادثة يحذف رسائلها والجلسات الفرعية التابعة لها، وتتم مزامنة الحذف عند تفعيل iCloud. لحذف الملفات فقط، استخدم قسم ملفات الجلسات.") }
        }
        .navigationTitle("إدارة المحادثات")
        .searchable(text: $query, prompt: "بحث في المحادثات")
        .task { sessions = await ChatStore.shared.listSessions().filter { !$0.isChild } }
        .alert("حذف المحادثة ومحتوياتها؟", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("حذف", role: .destructive) {
                guard let session = pending else { return }
                pending = nil
                Task {
                    let all = await ChatStore.shared.listSessions()
                    var children: [String: [String]] = [:]
                    for item in all { if let parent = item.parentSessionId { children[parent, default: []].append(item.id) } }
                    let family = SessionTree.withDescendants([session.id]) { children[$0] ?? [] }
                    if !SessionActivityTracker.shared.activeSessions.isDisjoint(with: Set(family)) {
                        error = "أوقف المهمة النشطة قبل حذف المحادثة."
                    } else {
                        await ChatStore.shared.deleteSession(session.id)
                        sessions = await ChatStore.shared.listSessions().filter { !$0.isChild }
                    }
                }
            }
            Button("إلغاء", role: .cancel) { pending = nil }
        }
        .alert("التخزين", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("موافق") { error = nil } } message: { Text(error ?? "") }
    }
}
