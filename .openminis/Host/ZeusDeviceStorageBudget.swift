import Foundation
import CryptoKit
import ZEUSBrowser

enum ZeusPristineRootfs {
    private static let managedMounts: Set<String> = Set(["attachments", "offloads", "workspace", "memory", "skills", "shared", "mcp-servers"].map { "data/var/minis/" + $0 })
    static func reclaim(at root: URL, baseline: [String: String]) -> Bool {
        RootfsManager.zeusLifecycleLock.lock(); defer { RootfsManager.zeusLifecycleLock.unlock() }
        return (try? remove(at: root, baseline: baseline, allowed: { NativeLocalExecutionBoundary.shared.isAllowed })) ?? false
    }
    /// Only remove an OS tree whose every payload is reproducible. Unknown or
    /// edited files and real symlinks preserve the whole tree, without uploading
    /// bundled OS files or guessing whether a filename is user data.
    static func remove(at root: URL, baseline: [String: String], allowed: () -> Bool) throws -> Bool {
        let fm = FileManager.default
        guard !allowed(), fm.fileExists(atPath: root.path), !baseline.isEmpty,
              try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { return false }
        var complete = true
        guard let entries = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], errorHandler: { _, _ in complete = false; return false }) else { return false }
        for case let file as URL in entries {
            let attrs = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            let name = String(file.path.dropFirst(root.path.count + 1))
            if attrs.isSymbolicLink == true {
                // These are the app's mount placeholders, not stored payloads.
                // Removing the link never traverses or removes its destination.
                guard managedMounts.contains(name) else { return false }
                entries.skipDescendants(); continue
            }
            if attrs.isDirectory == true {
                guard baseline[name + "/"] != nil || name == "data/var/minis" || managedMounts.contains(name) else { return false }
                continue
            }
            guard attrs.isRegularFile == true else { return false }
            if ["meta.db", "meta.db-wal", "meta.db-shm"].contains(name) { continue }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            if name == ".arch", String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "aarch64" { continue }
            if name == "data/etc/resolv.conf", data.count <= 4096 {
                let lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
                if lines.allSatisfy({ line in
                    let text = line.trimmingCharacters(in: .whitespaces)
                    return text.isEmpty || text.hasPrefix("#") || ["nameserver ", "search ", "domain ", "options "].contains(where: text.hasPrefix)
                }) { continue }
            }
            guard baseline[name] == SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() else { return false }
        }
        guard complete, !allowed() else { return false }
        try fm.removeItem(at: root)
        return true
    }
}

@MainActor enum ZeusDeviceStorageBudget {
    static func prepare() async {
        URLCache.shared.removeAllCachedResponses()
        URLCache.shared = URLCache(memoryCapacity: 2 * 1024 * 1024, diskCapacity: 0, diskPath: nil)
        if !CommandLine.arguments.contains("-loggingEnabled") {
            let optedIn = UserDefaults.standard.bool(forKey: "zeus.logging.userOptIn")
            if !optedIn { LoggingManager.shared.isEnabled = false }
            if !UserDefaults.standard.bool(forKey: "zeus.storageBudget.v1") {
                let enabled = LoggingManager.shared.isEnabled
                LoggingManager.shared.isEnabled = false
                LoggingManager.shared.deleteAllLogs()
                if enabled { LoggingManager.shared.isEnabled = true }
                UserDefaults.standard.set(true, forKey: "zeus.storageBudget.v1")
            }
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let catalog = caches.appendingPathComponent("com.openminis.app.models-dev-cache")
        _ = await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: catalog) }.value
        NativeCloudAccountAPI.trimDeviceCaches()
        if SessionActivityTracker.shared.activeSessions.isEmpty { await ChatStore.shared.zeusTrimJournal() }
        await reclaimUnusedLocalEnvironment()
    }
    static func reclaimUnusedLocalEnvironment() async {
        guard NativeCloudAccountAPI.ownerID != nil, NativeCloudAccountAPI.usesCloud, !ISHKernel.shared.isBooted,
              let file = Bundle.main.url(forResource: "zeus-rootfs-baseline", withExtension: "json"),
              let bytes = try? Data(contentsOf: file), let manifest = try? JSONDecoder().decode([String: String].self, from: bytes) else { return }
        let root = RootfsManager.shared.rootfsPath
        _ = await Task.detached(priority: .utility) { ZeusPristineRootfs.reclaim(at: root, baseline: manifest) }.value
    }
}
