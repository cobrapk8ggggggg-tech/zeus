import Foundation
import WebKit

/// Disk caches are expendable; cookies, local storage and IndexedDB are not.
/// Enumerating existing stores avoids creating WebKit profiles during backup.
@MainActor enum WebsiteCacheBudget {
    private static var cleanup: Task<Void, Never>?
    private static var lastCleanup = Date.distantPast
    static func existingIdentifiers() async -> Set<UUID> {
        guard hasLegacyStore else { return [] }
        return await withCheckedContinuation { continuation in
            WKWebsiteDataStore.fetchAllDataStoreIdentifiers { continuation.resume(returning: Set($0)) }
        }
    }
    static var hasLegacyStore: Bool {
        FileManager.default.fileExists(atPath: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("WebKit").path)
    }
    static func schedule(force: Bool = false) {
        guard cleanup == nil, force || Date().timeIntervalSince(lastCleanup) >= 60 else { return }
        cleanup = Task { @MainActor in
            defer { cleanup = nil; lastCleanup = Date() }
            let ids = await existingIdentifiers()
            var stores = ids.map { WKWebsiteDataStore(forIdentifier: $0) }
            if hasLegacyStore { stores.append(.default()) }
            let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeFetchCache]
            for store in stores {
                await store.removeData(ofTypes: types, modifiedSince: .distantPast)
            }
        }
    }
}
