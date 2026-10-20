import SwiftUI
import UIKit

final class BrowserAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        if identifier == DownloadService.sessionIdentifier { DownloadService.backgroundCompletion = completionHandler }
        else { completionHandler() }
    }
}

@main struct ZEUSNextApp: App {
    @UIApplicationDelegateAdaptor(BrowserAppDelegate.self) var delegate
    @StateObject private var browser: BrowserModel
    init() {
        if CommandLine.arguments.contains("--uitesting") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZEUS-UITesting")
            try? FileManager.default.removeItem(at: root)
            _browser = StateObject(wrappedValue: BrowserModel(profiles: ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("Downloads")), useBackgroundDownloads: false))
        } else { _browser = StateObject(wrappedValue: BrowserModel()) }
    }
    var body: some Scene {
        WindowGroup {
            BrowserRoot(model: browser)
                .preferredColorScheme(.dark)
                .environment(\.layoutDirection, .rightToLeft)
        }
    }
}
