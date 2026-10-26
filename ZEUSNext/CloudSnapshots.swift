import Foundation
import CryptoKit

struct CloudObjectReference: Codable, Equatable {
    let sha256: String
    let bytes: Int
    func path(owner: UUID) throws -> String {
        guard bytes >= 0, bytes <= 8 * 1024 * 1024,
              sha256.count == 64, sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw CloudAccountError.invalidResponse }
        return owner.uuidString.lowercased() + "/objects/" + sha256
    }
}

struct CloudBrowserPayload: Codable {
    struct Entry: Codable { var profile: BrowserProfile; var data: ProfileData; var avatar: Data? }
    let version: Int
    var profiles: [Entry]
    let activeID: UUID
    func validated() throws -> CloudBrowserPayload {
        guard version == 1, !profiles.isEmpty, profiles.count <= 50,
              Set(profiles.map { $0.profile.id }).count == profiles.count,
              profiles.contains(where: { $0.profile.isAdmin }),
              profiles.contains(where: { $0.profile.id == activeID }) else { throw CloudAccountError.invalidResponse }
        for entry in profiles {
            guard !entry.profile.isPrivate, !entry.profile.name.isEmpty, entry.profile.name.count <= 200 else { throw CloudAccountError.invalidResponse }
            _ = try ProfileBackup(name: entry.profile.name, data: entry.data, avatar: entry.avatar).validated()
        }
        return self
    }
}

struct CloudSnapshotManifest: Codable {
    let version: Int
    let deviceID: UUID
    let created: Date
    let browser: CloudObjectReference
    var coverage: [String]
    var native: CloudObjectReference? = nil
    var executionTarget: String? = nil
}

struct CloudSnapshotHead: Codable {
    let revision: Int64
    let manifest: CloudSnapshotManifest
    let operationID: UUID
    enum CodingKeys: String, CodingKey { case revision, manifest; case operationID = "operation_id" }
}

/// Immutable content-addressed objects. A checkpoint is committed only after
/// every uploaded object has been downloaded and its actual SHA-256 checked.
@MainActor final class CloudSnapshotTransport {
    let account: CloudAccount
    let owner: UUID
    private let network: URLSession
    init(account: CloudAccount, owner: UUID, network: URLSession = .shared) { self.account = account; self.owner = owner; self.network = network }
    static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func head() async throws -> CloudSnapshotHead? {
        let bytes = try await request("rest/v1/zeus_cloud_heads", query: [
            URLQueryItem(name: "user_id", value: "eq." + owner.uuidString.lowercased()),
            URLQueryItem(name: "select", value: "revision,manifest,operation_id"), URLQueryItem(name: "limit", value: "1")])
        return try JSONDecoder().decode([CloudSnapshotHead].self, from: bytes).first
    }
    func put(_ data: Data) async throws -> CloudObjectReference {
        guard data.count <= 8 * 1024 * 1024 else { throw CloudAccountError.incomplete("حجم سجل المتصفح أكبر من حد النقل الآمن؛ بقيت بيانات الجهاز محفوظة.") }
        let ref = CloudObjectReference(sha256: Self.fingerprint(data), bytes: data.count)
        let path = "storage/v1/object/zeus-private/" + (try ref.path(owner: owner))
        _ = try await request(path, method: "POST", body: data, type: "application/octet-stream", acceptable: [200, 201, 409])
        // A name/ETag/409 response is not evidence that the stored contents match.
        guard try await get(ref) == data else { throw CloudAccountError.invalidResponse }
        return ref
    }
    func get(_ ref: CloudObjectReference) async throws -> Data {
        let data = try await request("storage/v1/object/authenticated/zeus-private/" + ref.path(owner: owner), maximumBytes: ref.bytes)
        guard data.count == ref.bytes, Self.fingerprint(data) == ref.sha256 else { throw CloudAccountError.invalidResponse }
        return data
    }
    func commit(_ manifest: CloudSnapshotManifest, expected: Int64, operation: UUID) async throws -> CloudSnapshotHead {
        struct Input: Encodable { let expected_revision: Int64; let operation_id: UUID; let snapshot: CloudSnapshotManifest }
        let data = try await request("rest/v1/rpc/zeus_commit_checkpoint", method: "POST",
                                     body: JSONEncoder().encode(Input(expected_revision: expected, operation_id: operation, snapshot: manifest)))
        return try JSONDecoder().decode(CloudSnapshotHead.self, from: data)
    }
    private func request(_ path: String, method: String = "GET", body: Data? = nil, type: String = "application/json",
                         query: [URLQueryItem] = [], acceptable: Set<Int> = [200, 201, 204], maximumBytes: Int = 8 * 1024 * 1024) async throws -> Data {
        var components = URLComponents(url: ZeusCloudConfiguration.projectURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!); request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 90
        request.setValue(ZeusCloudConfiguration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer " + (try await account.authorization(for: owner)), forHTTPHeaderField: "Authorization")
        request.setValue(type, forHTTPHeaderField: "Content-Type"); request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        // The private bucket enforces the same 8 MiB object ceiling; metadata
        // RPCs are bounded by SQL. Avoid a per-byte loop on the UI executor.
        let (result, response) = try await network.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CloudAccountError.invalidResponse }
        guard acceptable.contains(response.statusCode) else {
            if response.statusCode == 409 { throw CloudAccountError.conflict }
            throw CloudAccountError.incomplete("تعذر الحفظ في الحساب (HTTP \(response.statusCode)). بقيت البيانات المحلية محفوظة.")
        }
        if response.expectedContentLength > Int64(maximumBytes) { throw CloudAccountError.invalidResponse }
        guard result.count <= maximumBytes else { throw CloudAccountError.invalidResponse }
        // Discard a response received after device sign-out/account change.
        guard account.phase == .ready, account.identity?.id == owner else { throw CloudAccountError.wrongOwner }
        return result
    }
}

@MainActor final class BrowserCloudSync: ObservableObject {
    @Published private(set) var prepared = false
    @Published private(set) var busy = false
    @Published private(set) var pending = false
    @Published private(set) var lastSaved: Date?
    @Published private(set) var issue: String?
    private weak var browser: BrowserModel?
    private var listener: NSObjectProtocol?
    private var pendingTask: Task<Void, Never>?
    private var transport: CloudSnapshotTransport?
    private var state: State?
    private var generation = 0
    private var confirmedRevision = false
    private struct State: Codable { let userID: UUID; let deviceID: UUID; var revision: Int64; var fingerprint: String; var saved: Date? }
    init(browser: BrowserModel) { self.browser = browser }
    deinit { if let listener { NotificationCenter.default.removeObserver(listener) }; pendingTask?.cancel() }
    private var stateURL: URL? { browser?.profiles.root.appendingPathComponent("cloud-sync-state.json") }

    func prepare() async {
        guard !prepared, !busy else { return }
        guard let browser, CloudAccount.shared.phase == .ready, let id = CloudAccount.shared.identity?.id else { prepared = true; return }
        busy = true; issue = nil
        var preparationSucceeded = false
        defer {
            busy = false; prepared = preparationSucceeded || browser.profiles.loadedExistingIndex
            if prepared && listener == nil {
                listener = NotificationCenter.default.addObserver(forName: .zeusBrowserDataChanged, object: nil, queue: .main) { [weak self] note in
                    guard let root = note.object as? URL else { return }
                    Task { @MainActor in guard self?.browser?.profiles.root == root else { return }; self?.changed() }
                }
            }
        }
        do {
            let loaded = stateURL.flatMap { BrowserDisk.read(State.self, from: $0) }
            if let loaded, loaded.userID != id { throw CloudAccountError.wrongOwner }
            state = loaded ?? State(userID: id, deviceID: UUID(), revision: 0, fingerprint: "", saved: nil)
            lastSaved = state?.saved
            let api = CloudSnapshotTransport(account: .shared, owner: id); transport = api
            if let remote = try await api.head() {
                if !browser.profiles.loadedExistingIndex {
                    let payload = try JSONDecoder().decode(CloudBrowserPayload.self, from: await api.get(remote.manifest.browser)).validated()
                    try browser.profiles.installCloudBrowser(payload)
                    try browser.reloadCloudProfiles()
                    try NativeCloudAccountAPI.adoptPreference(remote.manifest.executionTarget)
                    state?.revision = remote.revision; state?.fingerprint = try fingerprint()
                    state?.saved = remote.manifest.created; lastSaved = remote.manifest.created
                    try saveState()
                } else if state?.revision != remote.revision {
                    throw CloudAccountError.conflict
                }
            }
            try await NativeCloudAccountAPI.dataDelegate?.restoreAccountIfNeeded(progress: { _ in })
            confirmedRevision = true; preparationSucceeded = true
            changed()
        } catch { issue = error.localizedDescription; pending = true }
    }
    func changed() {
        generation += 1; pending = true
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)); try Task.checkCancellation(); await self?.saveNow() } catch { }
        }
    }
    func saveNow() async {
        guard !busy, let transport, let browser, var state else { return }
        busy = true; issue = nil; let started = generation
        defer { busy = false }
        await CloudCheckpointGate.shared.enter()
        defer { Task { await CloudCheckpointGate.shared.leave() } }
        do {
            let remote = try await transport.head()
            if (remote?.revision ?? 0) != state.revision {
                // A native-agent archive may advance the account checkpoint
                // without changing this device's saved browser object.
                guard remote?.manifest.browser.sha256 == state.fingerprint else { throw CloudAccountError.conflict }
                state.revision = remote!.revision
            }
            confirmedRevision = true
            browser.persist()
            let data = try encodedPayload()
            let digest = CloudSnapshotTransport.fingerprint(data)
            if digest == state.fingerprint { pending = false; return }
            let ref = try await transport.put(data)
            var manifest = CloudSnapshotManifest(version: 1, deviceID: state.deviceID, created: Date(), browser: ref,
                                                 coverage: ["browser_profiles", "browser_settings", "browser_records"])
            manifest.native = remote?.manifest.native
            manifest.executionTarget = remote?.manifest.executionTarget
            manifest.coverage = Array(Set(manifest.coverage + (remote?.manifest.coverage.filter { !$0.hasPrefix("browser_") } ?? [])))
            let head = try await transport.commit(manifest, expected: state.revision, operation: UUID())
            state.revision = head.revision; state.fingerprint = digest; state.saved = manifest.created
            self.state = state; try saveState(); lastSaved = manifest.created
            pending = generation != started
            if pending { changed() }
        } catch { issue = error.localizedDescription; pending = true }
    }
    private func fingerprint() throws -> String { CloudSnapshotTransport.fingerprint(try encodedPayload()) }
    private func encodedPayload() throws -> Data {
        guard let browser else { throw CloudAccountError.invalidResponse }
        let profiles = browser.profiles.profiles.filter { !$0.isPrivate }.map { profile in
            CloudBrowserPayload.Entry(profile: profile, data: browser.profiles.load(profile),
                                      avatar: browser.profiles.avatarURL(profile).flatMap { try? Data(contentsOf: $0) })
        }
        let active = profiles.contains(where: { $0.profile.id == browser.profile.id }) ? browser.profile.id : profiles.first!.profile.id
        let payload = try CloudBrowserPayload(version: 1, profiles: profiles, activeID: active).validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }
    private func saveState() throws {
        guard let state, let stateURL else { throw CloudAccountError.invalidResponse }
        try BrowserDisk.write(state, to: stateURL)
    }
}
