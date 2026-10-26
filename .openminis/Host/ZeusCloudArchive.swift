import Foundation
import CryptoKit
import ZEUSBrowser

/// Portable database export from OpenMinis plus an encrypted, streamed overlay
/// for actual files (including dotfiles omitted by the stock ZIP exporter).
@MainActor final class ZeusCloudArchive: NativeCloudDataDelegate {
    static let shared = ZeusCloudArchive()
    private let fm = FileManager.default
    private let chunkSize = 8 * 1024 * 1024 - 28
    private var scheduled: Task<Void, Never>?
    private struct Secrets: Codable {
        let version: Int
        let fileKey: Data
        let passphrase: String
        let browser: Data
        let preferences: Data
    }
    private struct Item {
        let scope: String
        let path: String
        let url: URL
        let bytes: Int64
        let digest: String
    }
    private var marker: URL { AIChatViewModel.minisConfigRoot.appendingPathComponent("zeus-account-restored.json") }
    private var roots: [NativeCloudAccountAPI.FileRoot] {
        [ .init(scope: "agent_sessions", url: AIChatViewModel.minisPersistentBase),
          .init(scope: "agent_shared", url: AIChatViewModel.minisSharedPersistentDir),
          .init(scope: "agent_skills", url: AIChatViewModel.minisSkillsPersistentDir),
          .init(scope: "agent_memory", url: AIChatViewModel.minisMemoryPersistentDir),
          .init(scope: "agent_mcp_config", url: AIChatViewModel.minisMcpServersPersistentDir),
          .init(scope: "agent_task_notes", url: ZeusAgentHarness.shared.taskStorageDirectory) ] + NativeCloudAccountAPI.browserFileRoots
    }
    private func error(_ message: String) -> NSError { NSError(domain: "ZEUSCloud", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func requireIdle() throws {
        guard SessionActivityTracker.shared.activeSessions.isEmpty else { throw error("أوقف المهام المحلية قبل نقل بياناتها أو استعادتها.") }
    }
    private func keyBytes() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func inspect(_ url: URL) throws -> (Int64, String) {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var digest = SHA256(); var bytes: Int64 = 0
        while let part = try handle.read(upToCount: 1024 * 1024), !part.isEmpty { digest.update(data: part); bytes += Int64(part.count) }
        return (bytes, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
    private func inventory() throws -> [Item] {
        var items: [Item] = []
        for root in roots where fm.fileExists(atPath: root.url.path) {
            let rootInfo = try root.url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard rootInfo.isSymbolicLink != true else { throw error("جذر الملفات رابط رمزي؛ لم يُحذف أي ملف.") }
            var traversalError: Error?
            guard let enumerator = fm.enumerator(at: root.url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [], errorHandler: { _, issue in traversalError = issue; return false }) else { continue }
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw error("تحتوي الملفات على رابط رمزي يحتاج معالجة مستقلة: \(url.lastPathComponent). تبقى النسخة المحلية محفوظة.") }
                guard values.isRegularFile == true else { continue }
                let path = String(url.path.dropFirst(root.url.path.count + 1))
                let (bytes, digest) = try inspect(url)
                items.append(Item(scope: root.scope, path: path, url: url, bytes: bytes, digest: digest))
            }
            if let traversalError { throw traversalError }
        }
        return items.sorted { ($0.scope, $0.path) < ($1.scope, $1.path) }
    }
    private func same(_ lhs: [Item], _ rhs: [Item]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { a, b in a.scope == b.scope && a.path == b.path && a.bytes == b.bytes && a.digest == b.digest }
    }
    private func aad(_ digest: String, _ index: Int) throws -> Data {
        guard let owner = NativeCloudAccountAPI.ownerID else { throw error("انتهت جلسة الحساب.") }
        return Data("\(owner)|\(digest)|\(index)".utf8)
    }
    private func upload(_ item: Item, key: SymmetricKey, previous: [NativeCloudFile]) async throws -> NativeCloudFile {
        if let old = previous.first(where: { $0.sha256 == item.digest && $0.bytes == item.bytes }) {
            // Verify each referenced ciphertext still exists before reusing it.
            for ref in old.parts { _ = try await NativeCloudAccountAPI.getObject(ref) }
            return NativeCloudFile(scope: item.scope, path: item.path, bytes: item.bytes, parts: old.parts, sha256: item.digest)
        }
        let handle = try FileHandle(forReadingFrom: item.url); defer { try? handle.close() }
        var parts: [NativeCloudBlob] = []; var read: Int64 = 0
        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
            let box = try AES.GCM.seal(data, using: key, authenticating: aad(item.digest, parts.count))
            guard let sealed = box.combined else { throw error("تعذر تشفير الملف.") }
            parts.append(try await NativeCloudAccountAPI.putObject(sealed)); read += Int64(data.count)
        }
        guard read == item.bytes, try inspect(item.url).1 == item.digest else { throw error("تغير ملف أثناء النسخ؛ لم تُنشر نسخة ناقصة.") }
        return NativeCloudFile(scope: item.scope, path: item.path, bytes: item.bytes, parts: parts, sha256: item.digest)
    }
    private func secretBundle(_ archive: NativeCloudArchive) async throws -> Secrets {
        let sealed = try await NativeCloudAccountAPI.getObject(archive.secrets)
        let bundle = try JSONDecoder().decode(Secrets.self, from: await NativeCloudAccountAPI.unsealSecrets(sealed))
        guard bundle.version == 1, bundle.fileKey.count == 32 else { throw error("حزمة الحساب غير صالحة.") }
        return bundle
    }
    private func preferences() throws -> Data {
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) } ?? [:]
        let safe = domain.filter { key, _ in !key.hasPrefix("deviceIdentity.") && !key.hasPrefix("cloudSync.") && !key.hasPrefix("Apple") && !key.hasPrefix("NS") && !key.hasPrefix("debug.") && !key.hasPrefix("backup.") }
        return try PropertyListSerialization.data(fromPropertyList: safe, format: .binary, options: 0)
    }
    /// Also used for automatic account backup in local mode. Cleanup is a
    /// separate step, after the runtime has accepted the migrated workspaces.
    func backup(progress: @escaping (String) -> Void) async throws -> NativeCloudArchive {
        try requireIdle()
        guard !NativeCloudAccountAPI.isMigrating else { throw error("عملية نقل أخرى قيد التنفيذ.") }
        NativeCloudAccountAPI.isMigrating = true; defer { NativeCloudAccountAPI.isMigrating = false }
        progress("تجهيز نسخة مشفرة للمحادثات والإعدادات…")
        let old = try await NativeCloudAccountAPI.archive()
        let oldSecrets = try await old.mapAsync { try await self.secretBundle($0) }
        let keyData = oldSecrets?.fileKey ?? keyBytes(), passphrase = keyBytes().base64EncodedString()
        let summary = try await BackupExporter().export(options: .init(maxFileBytes: 0, includeCredentials: true, passphrase: passphrase))
        defer { try? fm.removeItem(at: summary.packageURL) }
        let before = try inventory()
        let package = try inspect(summary.packageURL)
        var files = [try await upload(Item(scope: "native_database", path: "account.minisbak", url: summary.packageURL, bytes: package.0, digest: package.1), key: SymmetricKey(data: keyData), previous: [])]
        for (index, item) in before.enumerated() {
            progress("تشفير الملفات والتحقق منها \(index + 1)/\(before.count)…")
            files.append(try await upload(item, key: SymmetricKey(data: keyData), previous: old?.files ?? []))
            await Task.yield()
        }
        try requireIdle()
        guard same(before, try inventory()) else { throw error("تغيرت الملفات أثناء النقل؛ تبقى النسخة المحلية محفوظة.") }
        let secrets = Secrets(version: 1, fileKey: keyData, passphrase: passphrase, browser: try await NativeCloudAccountAPI.browserSecrets(), preferences: try preferences())
        let raw = try JSONEncoder().encode(secrets)
        let sealed = try await NativeCloudAccountAPI.sealSecrets(raw)
        guard try await NativeCloudAccountAPI.unsealSecrets(sealed) == raw else { throw error("فشل التحقق من مفاتيح الاستعادة.") }
        let archive = NativeCloudArchive(files: files, secrets: try await NativeCloudAccountAPI.putObject(sealed))
        try await NativeCloudAccountAPI.publishArchive(archive)
        try markRestored()
        return archive
    }
    func migrateToCloud(progress: @escaping (String) -> Void) async throws {
        let archive = try await backup(progress: progress)
        // Import is idempotent. Keep the local originals until all conversations
        // and workspace manifests are present in the authenticated runtime.
        let secrets = try await secretBundle(archive)
        try await ZeusCloudRuntime.shared.importArchive(archive, fileKey: secrets.fileKey, progress: progress)
        progress("تم التحقق من النسخة السحابية. جارٍ تحرير ملفات الوكيل المنقولة…")
        try requireIdle()
        for entry in archive.files where entry.scope == "agent_sessions" {
            let url = try destination(entry)
            guard fm.fileExists(atPath: url.path) else { continue }
            if try inspect(url).1 == entry.sha256 { try fm.removeItem(at: url) }
        }
    }
    func backupAccount(progress: @escaping (String) -> Void) async throws {
        // In cloud mode the server owns changing workspaces. An empty device
        // cache must never replace its authoritative workspace manifest.
        _ = try await backup(progress: progress)
    }
    func scheduleBackup() {
        guard NativeCloudAccountAPI.ownerID != nil, !NativeCloudAccountAPI.usesCloud else { return }
        scheduled?.cancel()
        scheduled = Task {
            do { try await Task.sleep(for: .seconds(30)); try Task.checkCancellation() }
            catch { return }
            guard SessionActivityTracker.shared.activeSessions.isEmpty else { return }
            await NativeCloudBackupStatus.shared.save()
        }
    }
    private func destination(_ file: NativeCloudFile) throws -> URL {
        guard let root = roots.first(where: { $0.scope == file.scope }) else { throw error("نطاق ملفات غير معروف.") }
        let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
        guard !file.path.hasPrefix("/"), !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else { throw error("مسار استعادة غير آمن.") }
        var url = root.url
        for part in parts {
            url.appendPathComponent(String(part))
            if fm.fileExists(atPath: url.path), try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw error("رابط رمزي في مسار الاستعادة.") }
        }
        return url
    }
    private func download(_ file: NativeCloudFile, to destination: URL, key: SymmetricKey) async throws {
        let temp = fm.temporaryDirectory.appendingPathComponent("zeus-restore-" + UUID().uuidString)
        fm.createFile(atPath: temp.path, contents: nil)
        defer { try? fm.removeItem(at: temp) }
        let output = try FileHandle(forWritingTo: temp); defer { try? output.close() }
        var bytes: Int64 = 0
        for (index, part) in file.parts.enumerated() {
            let ciphertext = try await NativeCloudAccountAPI.getObject(part)
            let data = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key, authenticating: aad(file.sha256, index))
            bytes += Int64(data.count); guard bytes <= file.bytes else { throw error("حجم ملف الاستعادة غير صحيح.") }
            try output.write(contentsOf: data)
        }
        try output.synchronize()
        guard bytes == file.bytes, try inspect(temp).1 == file.sha256 else { throw error("فشل التحقق من ملف الاستعادة.") }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: destination.path) else { return }
        try fm.moveItem(at: temp, to: destination)
    }
    private func markRestored() throws {
        guard let owner = NativeCloudAccountAPI.ownerID else { throw error("انتهت جلسة الحساب.") }
        try Data(owner.utf8).write(to: marker, options: .atomic)
    }
    func restoreAccountIfNeeded(progress: @escaping (String) -> Void) async throws {
        guard let owner = NativeCloudAccountAPI.ownerID else { return }
        if (try? String(contentsOf: marker, encoding: .utf8)) == owner {
            if NativeCloudAccountAPI.usesCloud { try? await ZeusCloudRuntime.shared.restoreSessionIndex() }
            return
        }
        guard let archive = try await NativeCloudAccountAPI.archive() else { return }
        try await restore(archive, includeFiles: !NativeCloudAccountAPI.usesCloud, progress: progress)
        if NativeCloudAccountAPI.usesCloud { try await ZeusCloudRuntime.shared.restoreSessionIndex() }
        try markRestored()
    }
    func prepareLocalExecution(progress: @escaping (String) -> Void) async throws {
        try requireIdle()
        guard let archive = try await NativeCloudAccountAPI.archive() else { return }
        try await restore(archive, includeFiles: true, progress: progress)
        // Cloud jobs may have produced newer files after the installation backup.
        try await ZeusCloudRuntime.shared.restoreWorkspaces(progress: progress)
    }
    private func restore(_ archive: NativeCloudArchive, includeFiles: Bool, progress: @escaping (String) -> Void) async throws {
        try requireIdle()
        if includeFiles {
            let missing = try archive.files.filter { file in
                guard file.scope != "native_database" else { return false }
                let target = try destination(file)
                return !fm.fileExists(atPath: target.path)
            }
            let required = missing.reduce(Int64(64 * 1024 * 1024)) { $0 + $1.bytes }
            let available = try fm.urls(for: .documentDirectory, in: .userDomainMask)[0].resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            if let available, available < required { throw error("تحتاج استعادة الملفات محليًا إلى نحو \(required / 1_000_000) MB متاحة. بقيت النسخة السحابية محفوظة.") }
        }
        NativeCloudAccountAPI.isMigrating = true; defer { NativeCloudAccountAPI.isMigrating = false }
        progress("استعادة المحادثات والإعدادات المشفرة…")
        let secrets = try await secretBundle(archive), key = SymmetricKey(data: secrets.fileKey)
        guard let metadata = archive.files.first(where: { $0.scope == "native_database" }) else { throw error("نسخة المحادثات ناقصة.") }
        let package = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".minisbak")
        defer { try? fm.removeItem(at: package) }
        try await download(metadata, to: package, key: key)
        var options = BackupImporter.Options(); options.passphrase = secrets.passphrase
        let report = try await BackupImporter().import(from: package, options: options)
        guard report.integrityFailed.isEmpty, report.categories.allSatisfy({ $0.failed == nil && $0.unreadable == 0 && $0.missingBlobs == 0 }) else { throw error("لم تكتمل استعادة بعض فئات الحساب؛ أعد المحاولة.") }
        if includeFiles {
            for (index, file) in archive.files.filter({ $0.scope != "native_database" }).enumerated() {
                progress("استعادة الملفات \(index + 1)…")
                try await download(file, to: destination(file), key: key)
            }
        }
        if let preferences = try PropertyListSerialization.propertyList(from: secrets.preferences, format: nil) as? [String: Any] {
            for (name, value) in preferences where UserDefaults.standard.object(forKey: name) == nil { UserDefaults.standard.set(value, forKey: name) }
        }
        try await NativeCloudAccountAPI.restoreBrowserSecrets(secrets.browser)
    }
}

private extension Optional {
    func mapAsync<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }; return try await transform(value)
    }
}
