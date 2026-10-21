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
            if CommandLine.arguments.contains("--translation-fixture") {
                var provider = AIProviderConfiguration(); provider.name = "مزود الاختبار المحلي"; provider.baseURL = "http://127.0.0.1:8765/v1"; provider.model = "fixture-translator"
                model.data.settings.aiProviders = [provider]
                var prefs = TranslationPreferences(); prefs.suggestionDuration = CommandLine.arguments.contains("--timed-translation-suggestion") ? 1.5 : 0; prefs.engine = .ai; prefs.providerID = provider.id; prefs.automatic = CommandLine.arguments.contains("--automatic-translation")
                model.data.settings.translation = prefs
            }
            if CommandLine.arguments.contains("--tabs-polish-fixture") {
                model.current?.title = "التبويب الأول — عنوان طويل لا يخفي أيقونة الموقع"
                _ = model.newTab(); model.current?.title = "التبويب الثاني"
                _ = model.newTab(); model.current?.title = "التبويب الثالث"
            }
            if CommandLine.arguments.contains("--reader-polish-fixture") {
                model.article = ReaderArticle(title: "ليلة في المكتبة", paragraphs: ["في هدوء الليل تبدأ حكاية جديدة، وتظهر الكلمات بمحاذاة اليمين.", "A new story begins tonight. English paragraphs share the same right aligned reading layout."])
            }
            _browser = StateObject(wrappedValue: model)
        } else { _browser = StateObject(wrappedValue: BrowserModel()) }
    }
    var body: some Scene {
        WindowGroup {
            BrowserRoot(model: browser)
                .preferredColorScheme(browser.data.settings.theme?.light == true ? .light : .dark)
                .environment(\.layoutDirection, .rightToLeft)
        }
    }
}
