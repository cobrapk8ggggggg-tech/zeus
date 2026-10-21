import SwiftUI
import UIKit

final class BrowserAppDelegate: NSObject, UIApplicationDelegate {
    private var privacyWindows: [String: UIWindow] = [:]
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        NotificationCenter.default.addObserver(self, selector: #selector(hideAppContent), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(revealAppContent), name: UIApplication.didBecomeActiveNotification, object: nil)
        return true
    }
    @objc private func hideAppContent() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            let key = scene.session.persistentIdentifier
            let window = privacyWindows[key] ?? UIWindow(windowScene: scene)
            let controller = UIViewController(); controller.view.backgroundColor = .black
            window.rootViewController = controller; window.windowLevel = .alert + 2; window.isUserInteractionEnabled = false; window.isHidden = false
            privacyWindows[key] = window
        }
    }
    @objc private func revealAppContent() { for window in privacyWindows.values { window.isHidden = true }; privacyWindows.removeAll() }

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
            let model = BrowserModel(profiles: ProfileStore(root: root, downloadsRoot: root.appendingPathComponent("Downloads")), useBackgroundDownloads: false)
            if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--layout=") }), let layout = ChromeLayout(rawValue: String(argument.dropFirst(9))) { model.data.settings.chromeLayout = layout }
            _browser = StateObject(wrappedValue: model)
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
