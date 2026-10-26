import XCTest
@testable import ZEUSBrowser

@MainActor final class NativeCloudAccountTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testOwnerClaimIsIdempotentAndRejectsAnotherCloudAccount() throws {
        let root = try temporary(), a = UUID(), b = UUID()
        let owner = CloudLocalOwner(root: root)
        XCTAssertNil(try owner.read()); try owner.claim(a); try owner.claim(a)
        XCTAssertThrowsError(try owner.claim(b)); XCTAssertEqual(try owner.read(), a)
    }
    func testCorruptOwnerMarkerFailsClosedInsteadOfReassigningData() throws {
        let owner = CloudLocalOwner(root: try temporary())
        try Data("broken".utf8).write(to: owner.file)
        XCTAssertThrowsError(try owner.claim(UUID()))
        XCTAssertEqual(try Data(contentsOf: owner.file), Data("broken".utf8))
    }
    func testObjectReferenceRejectsTraversalInvalidHashAndOversize() throws {
        let owner = UUID(), hash = String(repeating: "a", count: 64)
        XCTAssertEqual(try CloudObjectReference(sha256: hash, bytes: 1).path(owner: owner), owner.uuidString.lowercased() + "/objects/" + hash)
        for bad in ["../" + hash, String(repeating: "g", count: 64), "", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try CloudObjectReference(sha256: bad, bytes: 1).path(owner: owner))
        }
        XCTAssertThrowsError(try CloudObjectReference(sha256: hash, bytes: 8 * 1024 * 1024 + 1).path(owner: owner))
        XCTAssertThrowsError(try CloudObjectReference(sha256: hash, bytes: -1).path(owner: owner))
    }
    func testFreshRestorePreservesAllProfileIdentitiesAndActualSettings() throws {
        let root = try temporary(), store = ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("downloads"))
        var admin = BrowserProfile(name: "الرئيسي"); admin.account = AccountOptions(role: .administrator)
        let second = BrowserProfile(name: "العمل")
        var first = ProfileData(); first.bookmarks = [Bookmark(title: "Example", url: "https://example.org")]
        first.settings.chromeLayout = .icab; first.settings.textScale = 1.25
        var other = ProfileData(); other.settings.chromeLayout = .dualBars
        let payload = CloudBrowserPayload(version: 1, profiles: [
            .init(profile: admin, data: first), .init(profile: second, data: other)
        ], activeID: second.id)
        try store.installCloudBrowser(payload)
        let reopened = ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("downloads"))
        XCTAssertEqual(reopened.activeID, second.id)
        XCTAssertEqual(Set(reopened.profiles.filter { !$0.isPrivate }.map(\.id)), Set([admin.id, second.id]))
        XCTAssertEqual(reopened.load(admin).settings.chromeLayout, .icab)
        XCTAssertEqual(reopened.load(admin).settings.textScale, 1.25)
        XCTAssertEqual(reopened.load(admin).bookmarks.first?.id, first.bookmarks.first?.id)
        XCTAssertEqual(reopened.load(second).settings.chromeLayout, .dualBars)
        XCTAssertThrowsError(try reopened.installCloudBrowser(payload))
    }
    func testRestoreWriteFailureLeavesPreviousIndexAndProfilesVisible() throws {
        let root = try temporary(), store = ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("downloads"))
        let previousIDs = store.profiles.map(\.id)
        let previousIndex = try Data(contentsOf: root.appendingPathComponent("profiles.json"))
        var admin = BrowserProfile(name: "السحابي"); admin.account = AccountOptions(role: .administrator)
        let blocked = store.folder(for: admin)
        try BrowserDisk.ensure(blocked.deletingLastPathComponent()); try Data("file-not-directory".utf8).write(to: blocked)
        let payload = CloudBrowserPayload(version: 1, profiles: [.init(profile: admin, data: ProfileData())], activeID: admin.id)
        XCTAssertThrowsError(try store.installCloudBrowser(payload))
        XCTAssertEqual(store.profiles.map(\.id), previousIDs)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("profiles.json")), previousIndex)
    }
    func testRestoreRejectsPrivateDataDuplicateIDsAndMissingAdministrator() throws {
        let standard = BrowserProfile(name: "عادي")
        var admin = BrowserProfile(name: "رئيسي"); admin.account = AccountOptions(role: .administrator)
        var privateProfile = admin; privateProfile.kind = .ephemeral
        XCTAssertThrowsError(try CloudBrowserPayload(version: 1, profiles: [.init(profile: standard, data: ProfileData())], activeID: standard.id).validated())
        XCTAssertThrowsError(try CloudBrowserPayload(version: 1, profiles: [.init(profile: admin, data: ProfileData()), .init(profile: admin, data: ProfileData())], activeID: admin.id).validated())
        XCTAssertThrowsError(try CloudBrowserPayload(version: 1, profiles: [.init(profile: privateProfile, data: ProfileData())], activeID: admin.id).validated())
    }
}
