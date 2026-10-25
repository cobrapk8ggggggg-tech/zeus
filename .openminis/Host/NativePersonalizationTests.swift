import XCTest
import SwiftUI
import UniformTypeIdentifiers
@testable import ZEUSBrowser
@testable import Minis

@MainActor final class NativePersonalizationTests: XCTestCase {
    func testLayoutsSurviveProfileRoundTripAndKeepOriginalDefaults() throws {
        let legacy = try JSONDecoder().decode(BrowserSettings.self, from: JSONEncoder().encode(BrowserSettings()))
        XCTAssertNil(legacy.chromeWorkspace)
        var settings = BrowserSettings(), workspace = ChromeWorkspace()
        for base in ChromeLayout.allCases {
            let design = ChromeDesign.preset(base)
            XCTAssertTrue(design.validated(), base.rawValue)
            workspace.designs.append(design)
        }
        var custom = ChromeDesign.preset(.icab); custom.id = UUID(); custom.base = nil; custom.name = "التوزيع الرابع"
        custom.landscape.blocks[0].background = "556677"; custom.portrait.blocks[0].background = "112233"
        workspace.designs.append(custom); workspace.selected = custom.id
        XCTAssertTrue(workspace.validated()); settings.chromeWorkspace = workspace
        let decoded = try JSONDecoder().decode(BrowserSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.chromeWorkspace, workspace)
        XCTAssertEqual(decoded.chromeWorkspace?.active(for: .original)?.id, custom.id)
        workspace.selected = nil
        XCTAssertEqual(workspace.active(for: .original)?.base, .original)
        var profile = ProfileData(); profile.settings = settings
        let backup = try ProfileBackup(name: "Personalized", data: profile).validated()
        XCTAssertEqual(try backup.merged(into: ProfileData(), importSettings: true, restoreTabs: true).settings.chromeWorkspace, settings.chromeWorkspace)
        custom.landscape.blocks[0].x = .infinity; workspace.designs.append(custom)
        XCTAssertFalse(workspace.validated())
    }
    func testLayoutGeometryStaysReachableAcrossWindowSizes() {
        for base in ChromeLayout.allCases {
            let design = ChromeDesign.preset(base)
            for size in [CGSize(width: 390, height: 844), CGSize(width: 1024, height: 768), CGSize(width: 360, height: 600), CGSize(width: 834, height: 1194)] {
                let composition = design.composition(wide: size.width > size.height)
                for block in composition.blocks {
                    let frame = block.rect(in: size)
                    XCTAssertGreaterThanOrEqual(frame.minX, 0); XCTAssertGreaterThanOrEqual(frame.minY, 0)
                    XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.1); XCTAssertLessThanOrEqual(frame.maxY, size.height + 0.1)
                    if block.kind == .action { XCTAssertGreaterThanOrEqual(frame.width, 44); XCTAssertGreaterThanOrEqual(frame.height, 44) }
                }
            }
        }
    }
    func testOutputGalleryReadsOriginalWorkspaceWithoutFollowingLinks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = folder.appendingPathComponent("workspace"), outside = folder.appendingPathComponent("attachments")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("report"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: root.appendingPathComponent("report/result.md"))
        try Data("private input".utf8).write(to: outside.appendingPathComponent("private.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        let snapshot = try ZeusOutputIndex.scan(root)
        XCTAssertEqual(snapshot.entries.map(\.relativePath), ["report/result.md"])
        XCTAssertEqual(snapshot.entries.first?.kind, .document)
        XCTAssertEqual(snapshot.entries.first?.url, root.appendingPathComponent("report/result.md"))
        try Data("changed in tree".utf8).write(to: root.appendingPathComponent("report/result.md"))
        XCTAssertEqual(try ZeusOutputIndex.scan(root).entries.first?.bytes, 15)
        XCTAssertEqual(ZeusOutputKind.classify(URL(fileURLWithPath: "/tmp/test.png")), .image)
        XCTAssertEqual(ZeusOutputKind.classify(URL(fileURLWithPath: "/tmp/app.swift")), .code)
        XCTAssertEqual(ZeusOutputKind.classify(URL(fileURLWithPath: "/tmp/result.ipa")), .archive)
    }
    func testFilesDelegateDeliversSelectionExactlyOnceAndSupportsCancellation() throws {
        let urls = [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")]
        var received: [[URL]] = []
        let picker = ZEUSFilePicker(types: [.item], multiple: true) { if case .success(let value) = $0 { received.append(value) } }
        let coordinator = picker.makeCoordinator(), controller = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        coordinator.documentPicker(controller, didPickDocumentsAt: urls)
        coordinator.documentPicker(controller, didPickDocumentsAt: urls)
        coordinator.documentPickerWasCancelled(controller)
        XCTAssertEqual(received, [urls])
        var cancelled = false
        let folder = ZEUSFilePicker(types: [.folder]) { if case .failure(let error) = $0 { cancelled = (error as? CocoaError)?.code == .userCancelled } }
        folder.makeCoordinator().documentPickerWasCancelled(controller)
        XCTAssertTrue(cancelled)
    }
    func testAttachmentSelectionLoadsOffMainActorAndPreservesFileBytes() async throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        let data = Data(repeating: 65, count: 2_000_000); try data.write(to: input)
        let vm = AIChatViewModel(); vm.sessionId = UUID().uuidString
        defer { try? FileManager.default.removeItem(at: input); for file in vm.attachments { try? FileManager.default.removeItem(at: file.cacheURL) } }
        vm.zeusAddPickedFiles([input])
        XCTAssertEqual(vm.attachments.count, 1); XCTAssertTrue(vm.hasLoadingAttachments)
        for _ in 0..<100 where vm.hasLoadingAttachments { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(vm.attachments.first?.loadState, .ready)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(vm.attachments.first?.cacheURL)), data)
    }
    func testPersonalizationScreensAtPhoneAndIPadSizes() async throws {
        let originalKey = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        defer { originalKey?.makeKeyAndVisible() }
        let browser = BrowserModel()
        for size in [CGSize(width: 1024, height: 768), CGSize(width: 390, height: 844)] {
            let controller = UIHostingController(rootView: ChromeStudioEditor(design: .preset(.icab), model: browser, save: { _ in }).browserTheme(.standard))
            controller.overrideUserInterfaceStyle = .dark
            let window = UIWindow(frame: CGRect(origin: .zero, size: size)); window.rootViewController = controller; window.makeKeyAndVisible()
            controller.view.frame = window.bounds; controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            let image = UIGraphicsImageRenderer(size: size).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "ChromeStudio-\(Int(size.width))x\(Int(size.height))"; attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertGreaterThan(try XCTUnwrap(image.pngData()).count, 10_000)
            window.isHidden = true; window.rootViewController = nil
        }
    }
}
