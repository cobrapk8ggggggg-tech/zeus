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
        workspace.bypass = true; XCTAssertNil(workspace.active(for: .original)); XCTAssertEqual(workspace.designs.count, 4)
        workspace.bypass = false
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
    func testAgentLayoutChangesPreserveSavedDesignsAndRejectInvalidGeometry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let browser = BrowserModel(profiles: ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("downloads")), useBackgroundDownloads: false)
        var design = ChromeDesign.preset(.icab); design.base = nil
        var workspace = ChromeWorkspace(designs: [design], selected: design.id)
        browser.data.settings.chromeWorkspace = workspace
        _ = try await NativeBrowserControl.execute("browser_settings", args: ["action": "set", "key": "chromeLayout", "value": "\"dualBars\""], browser: browser)
        XCTAssertNil(browser.data.settings.chromeWorkspace?.selected)
        XCTAssertEqual(browser.data.settings.chromeWorkspace?.designs.first?.id, design.id)
        XCTAssertEqual(browser.data.settings.chromeLayout, .dualBars)
        workspace.designs[0].landscape.blocks[0].fontSize = 999
        let invalid = String(decoding: try JSONEncoder().encode(workspace), as: UTF8.self)
        do {
            _ = try await NativeBrowserControl.execute("browser_settings", args: ["action": "set", "key": "chromeWorkspace", "value": invalid], browser: browser)
            XCTFail("Invalid saved layouts must never reach the live browser")
        } catch { }
        XCTAssertEqual(browser.data.settings.chromeWorkspace?.designs[0].landscape.blocks[0].fontSize, design.landscape.blocks[0].fontSize)
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
    func testFilesPresentationDismissesBeforeImportAndCanBeOpenedAgain() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first { $0.isKeyWindow }
        let state = ZeusPickerProbeState(), window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ZeusPickerProbe(state: state))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(300))
        state.presented = true
        var controller: UIDocumentPickerViewController?
        for _ in 0..<100 {
            if let found = picker(in: host) { controller = found; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let first = try XCTUnwrap(controller)
        let selected = [URL(fileURLWithPath: "/tmp/one.txt"), URL(fileURLWithPath: "/tmp/two.txt")]
        first.delegate?.documentPicker?(first, didPickDocumentsAt: selected)
        for _ in 0..<100 where state.deliveries.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(state.deliveries, [selected]); XCTAssertFalse(state.presented)
        XCTAssertNil(host.presentedViewController, "Import work must start only after UIKit dismissal")
        state.presented = true; controller = nil
        for _ in 0..<100 {
            if let found = picker(in: host) { controller = found; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let second = try XCTUnwrap(controller)
        second.delegate?.documentPickerWasCancelled?(second)
        for _ in 0..<100 where state.presented || host.presentedViewController != nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(state.presented); XCTAssertEqual(state.deliveries.count, 1)
    }
    private func picker(in controller: UIViewController) -> UIDocumentPickerViewController? {
        if let picker = controller as? UIDocumentPickerViewController { return picker }
        if let presented = controller.presentedViewController, let match = picker(in: presented) { return match }
        for child in controller.children { if let match = picker(in: child) { return match } }
        return nil
    }
    func testPersonalizationScreensAtPhoneAndIPadSizes() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalKey = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        defer { originalKey?.makeKeyAndVisible() }
        let browser = BrowserModel()
        for size in [CGSize(width: 1024, height: 768), CGSize(width: 390, height: 844)] {
            let controller = UIHostingController(rootView: ChromeStudioEditor(design: .preset(.icab), model: browser, save: { _ in }).browserTheme(.standard).environment(\.horizontalSizeClass, size.width < 600 ? .compact : .regular))
            controller.overrideUserInterfaceStyle = .dark
            let window = UIWindow(windowScene: scene); window.frame = CGRect(origin: .zero, size: size); window.rootViewController = controller; window.makeKeyAndVisible()
            controller.view.frame = window.bounds; controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            let image = UIGraphicsImageRenderer(size: size).image { _ in controller.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "ChromeStudio-\(Int(size.width))x\(Int(size.height))"; attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertGreaterThan(try XCTUnwrap(image.pngData()).count, 10_000)
            window.isHidden = true; window.rootViewController = nil
        }
    }
    func testConversationFilesGalleryScreens() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let session = UUID().uuidString, root = AIChatViewModel.minisWorkspacePersistentDir(for: session)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("تقارير"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Data("# تقرير المشروع\nتم إنشاء هذا الملف في مساحة المحادثة.".utf8).write(to: root.appendingPathComponent("تقارير/ملخص.md"))
        try Data("export const ready = true;".utf8).write(to: root.appendingPathComponent("project.js"))
        for index in 0..<3 {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 500, height: 320)).image { context in
                UIColor(hue: CGFloat(index) / 3 + 0.1, saturation: 0.6, brightness: 0.8, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 500, height: 320))
                UIColor.white.withAlphaComponent(0.3).setFill(); context.cgContext.fillEllipse(in: CGRect(x: CGFloat(80 + index * 20), y: 60, width: 210, height: 210))
            }
            try XCTUnwrap(image.pngData()).write(to: root.appendingPathComponent("تصميم-\(index + 1).png"))
        }
        let original = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        defer { original?.makeKeyAndVisible() }
        let size = CGSize(width: 1024, height: 768)
        let host = UIHostingController(rootView: ZeusConversationFiles(sessionID: session))
        host.overrideUserInterfaceStyle = .dark
        let window = UIWindow(windowScene: scene); window.frame = CGRect(origin: .zero, size: size); window.rootViewController = host; window.makeKeyAndVisible()
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(800))
        let image = UIGraphicsImageRenderer(size: size).image { _ in host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "ConversationFiles-IPad"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertGreaterThan(try XCTUnwrap(image.pngData()).count, 10_000)
        window.isHidden = true; window.rootViewController = nil
    }
}

@MainActor private final class ZeusPickerProbeState: ObservableObject {
    @Published var presented = false
    var deliveries: [[URL]] = []
}
private struct ZeusPickerProbe: View {
    @ObservedObject var state: ZeusPickerProbeState
    var body: some View {
        Color.clear.zeusFileImporter(isPresented: $state.presented, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { state.deliveries.append(urls) }
        }
    }
}
