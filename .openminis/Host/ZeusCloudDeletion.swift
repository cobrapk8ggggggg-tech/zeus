import Foundation
import ZEUSBrowser

@MainActor final class ZeusCloudDeletion {
    static let shared = ZeusCloudDeletion()
    private var syncing = false
    func enqueue(_ id: String) async {
        guard NativeCloudAccountAPI.ownerID != nil else { return }
        // ChatStore's durable tombstone is the retry queue; keep the deletion
        // pending while offline and drain it before restoring any cloud index.
        try? await Task.sleep(for: .milliseconds(50))
        try? await sync()
    }
    func sync(fetchRemote: Bool = false) async throws {
        guard !syncing, NativeCloudAccountAPI.ownerID != nil else { return }
        syncing = true; defer { syncing = false }
        guard let owner = NativeCloudAccountAPI.ownerID else { return }
        let file = AIChatViewModel.minisConfigRoot.appendingPathComponent("deletion-acks-" + owner + ".json")
        var acknowledged = ((try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) }) ?? []
        for id in await ChatStore.shared.tombstonedSessionIds() where UUID(uuidString: id) != nil && !acknowledged.contains(id) {
            _ = try await NativeCloudAccountAPI.runtime("v1/conversations/" + id.lowercased(), method: "DELETE")
            acknowledged.insert(id)
            try JSONEncoder().encode(acknowledged).write(to: file, options: .atomic)
        }
        guard fetchRemote else { return }
        let bytes = try await NativeCloudAccountAPI.runtime("v1/deletions")
        let data = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        for id in data?["conversations"] as? [String] ?? [] {
            if await ChatStore.shared.getSession(id) != nil { await ChatStore.shared.deleteSessionLocalOnly(id) }
            let upper = id.uppercased()
            if await ChatStore.shared.getSession(upper) != nil { await ChatStore.shared.deleteSessionLocalOnly(upper) }
        }
    }
}
