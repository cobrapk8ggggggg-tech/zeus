import Foundation
import CryptoKit
import SQLite3

// Application Support, rather than Caches: iOS must not purge paid translations.
// One database per profile. Keys are hashes; no original URL, text or credential
// is written. Entries survive restarts until explicitly cleared or the size cap.
actor TranslationMemory {
    static let shared = TranslationMemory()
    static let maximumBytes: Int64 = 32 * 1024 * 1024
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    struct Stats { var entries: Int; var bytes: Int64 }
    nonisolated static func namespace(page: String, preferences: TranslationPreferences, provider: AIProviderConfiguration?) -> String {
        var url = URLComponents(string: page); url?.fragment = nil
        var identity = ["v2", url?.string ?? page, preferences.engine.rawValue, preferences.target,
                        preferences.engine == .ai ? provider?.id.uuidString ?? "" : "",
                        preferences.engine == .ai ? provider?.baseURL ?? "" : "",
                        preferences.engine == .ai ? provider?.model ?? "" : "",
                        preferences.engine == .ai ? provider?.instruction ?? "" : "",
                        preferences.engine == .ai ? provider?.projectID ?? "" : "",
                        preferences.engine == .ai ? provider?.conversationID ?? "" : ""]
        // Preserve existing Google/AI cache keys. Cloudflare account/model/style
        // changes must never reuse another connection's paid translations.
        if preferences.engine == .cloudflare {
            let config = preferences.cloudflare ?? CloudflareTranslationConfiguration()
            identity += [config.endpoint, config.accountID, config.model, config.instruction]
        }
        return digest((try? JSONEncoder().encode(identity)) ?? Data())
    }
    nonisolated private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    nonisolated private static func key(_ text: String, namespace: String) -> String { digest(Data((namespace + "\0" + text).utf8)) }
    private func location(_ folder: URL) -> URL { folder.appendingPathComponent("Translations.sqlite") }
    private func open(_ folder: URL, create: Bool) -> OpaquePointer? {
        let url = location(folder)
        if !create && !FileManager.default.fileExists(atPath: url.path) { return nil }
        if create {
            do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return nil }
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0), nil) == SQLITE_OK, let db else { if let db { sqlite3_close(db) }; return nil }
        sqlite3_busy_timeout(db, 1500)
        guard sqlite3_exec(db, "PRAGMA journal_mode=DELETE; PRAGMA secure_delete=ON; PRAGMA max_page_count=8192; CREATE TABLE IF NOT EXISTS translations (key TEXT PRIMARY KEY, text TEXT NOT NULL, used REAL NOT NULL, bytes INTEGER NOT NULL); CREATE INDEX IF NOT EXISTS translation_lru ON translations(used);", nil, nil, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        if create {
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            var protected = url; var values = URLResourceValues(); values.isExcludedFromBackup = true; try? protected.setResourceValues(values)
        }
        return db
    }
    func lookup(_ segments: [TranslationSegment], namespace: String, folder: URL) -> [String: String] {
        guard let db = open(folder, create: false) else { return [:] }; defer { sqlite3_close(db) }
        var query: OpaquePointer?, touch: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT text FROM translations WHERE key=?", -1, &query, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(query); sqlite3_finalize(touch) }
        sqlite3_prepare_v2(db, "UPDATE translations SET used=? WHERE key=?", -1, &touch, nil)
        // Update LRU timestamps in one transaction, not one disk sync per paragraph.
        let transaction = sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK
        defer { if transaction { sqlite3_exec(db, "COMMIT", nil, nil, nil) } }
        var result: [String: String] = [:]
        for segment in segments {
            let key = Self.key(segment.text, namespace: namespace)
            sqlite3_bind_text(query, 1, key, -1, transient)
            if sqlite3_step(query) == SQLITE_ROW, let value = sqlite3_column_text(query, 0) {
                result[segment.text] = String(cString: value)
                if transaction, let touch { sqlite3_bind_double(touch, 1, Date().timeIntervalSince1970); sqlite3_bind_text(touch, 2, key, -1, transient); sqlite3_step(touch); sqlite3_reset(touch) }
            }
            sqlite3_reset(query)
        }
        return result
    }
    func save(_ values: [String: String], namespace: String, folder: URL) -> Bool {
        guard !values.isEmpty else { return true }
        guard let db = open(folder, create: true) else { return false }; defer { sqlite3_close(db) }
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO translations(key,text,used,bytes) VALUES(?,?,?,?)", -1, &query, nil) == SQLITE_OK else { return false }; defer { sqlite3_finalize(query) }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
        // Leave room for the index and the incoming batch. The oldest entries are
        // evicted only at this explicit bounded capacity, never by a time-to-live.
        var size: OpaquePointer?; var bytes: Int64 = 0
        if sqlite3_prepare_v2(db, "SELECT COALESCE(SUM(bytes),0) FROM translations", -1, &size, nil) == SQLITE_OK, sqlite3_step(size) == SQLITE_ROW { bytes = sqlite3_column_int64(size, 0) }; sqlite3_finalize(size)
        let incoming = values.reduce(Int64(0)) { $0 + Int64($1.value.utf8.count + 256) }
        if bytes + incoming > 24 * 1024 * 1024 { sqlite3_exec(db, "DELETE FROM translations WHERE key IN (SELECT key FROM translations ORDER BY used LIMIT MAX(256,(SELECT COUNT(*)/4 FROM translations)))", nil, nil, nil) }
        for (source, text) in values {
            guard text.utf8.count < 1_000_000 else { continue }
            sqlite3_bind_text(query, 1, Self.key(source, namespace: namespace), -1, transient); sqlite3_bind_text(query, 2, text, -1, transient)
            sqlite3_bind_double(query, 3, Date().timeIntervalSince1970); sqlite3_bind_int64(query, 4, Int64(text.utf8.count + 256))
            guard sqlite3_step(query) == SQLITE_DONE else { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); return false }; sqlite3_reset(query)
        }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); return false }; return true
    }
    func stats(folder: URL) -> Stats {
        guard let db = open(folder, create: false) else { return Stats(entries: 0, bytes: 0) }; defer { sqlite3_close(db) }
        var query: OpaquePointer?; var count = 0
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM translations", -1, &query, nil) == SQLITE_OK, sqlite3_step(query) == SQLITE_ROW { count = Int(sqlite3_column_int64(query, 0)) }; sqlite3_finalize(query)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: location(folder).path)[.size] as? NSNumber)?.int64Value ?? 0
        return Stats(entries: count, bytes: bytes)
    }
    func clear(folder: URL) throws {
        let url = location(folder)
        for suffix in ["", "-journal", "-wal", "-shm"] { let file = URL(fileURLWithPath: url.path + suffix); if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) } }
    }
}
