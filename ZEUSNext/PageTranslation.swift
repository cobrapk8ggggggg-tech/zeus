import Foundation
import WebKit
import NaturalLanguage

@MainActor private final class TranslationMessageRouter: NSObject, WKScriptMessageHandler {
    static let shared = TranslationMessageRouter()
    let pages = NSMapTable<WKWebView, PageTranslation>.weakToWeakObjects()
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let view = message.webView, let page = pages.object(forKey: view) { page.userContentController(controller, didReceive: message) }
    }
}

@MainActor final class PageTranslation: NSObject, ObservableObject, WKScriptMessageHandler {
    static let world = WKContentWorld.world(name: "ZEUS.Translation")
    static let script = Bundle.main.url(forResource: "translation", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    weak var model: BrowserModel?
    weak var tab: BrowserTab?
    @Published var offered = false
    @Published var running = false
    @Published var translated = false
    @Published var sourceLanguage = ""
    @Published var completed = 0
    @Published var error: String?
    private var frames: [String: WKFrameInfo] = [:]
    private var mainDocument = ""
    private var epoch = UUID()
    private var context = UUID()
    private var work: Task<Void, Never>?
    private var cache: [String: String] = [:]
    private var pending = false
    private var sessionPreferences: TranslationPreferences?
    private var dismissed = false
    init(model: BrowserModel, tab: BrowserTab) { self.model = model; self.tab = tab }
    var preferences: TranslationPreferences { model?.data.settings.translation ?? TranslationPreferences() }
    func attach(to view: WKWebView, installScript: Bool = true) {
        let controller = view.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "zeusTranslation", contentWorld: Self.world)
        TranslationMessageRouter.shared.pages.setObject(self, forKey: view)
        controller.add(TranslationMessageRouter.shared, contentWorld: Self.world, name: "zeusTranslation")
        if installScript { controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: Self.world)) }
    }
    func navigationStarted() {
        stop(); frames.removeAll(); mainDocument = ""; sourceLanguage = ""; offered = false; translated = false; completed = 0; error = nil; cache.removeAll(); dismissed = false; sessionPreferences = nil
    }
    func stop() { epoch = UUID(); work?.cancel(); work = nil; running = false; pending = false; let old = context; context = UUID(); Task { await AIProviderService.shared.end(old) } }
    func pause() { stop(); error = "أُوقفت الترجمة. يمكنك المتابعة أو عرض الأصل." }
    func dismiss() { offered = false; dismissed = true }
    func becameVisible() { if offered && !translated && preferences.automatic { translate() } }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let model, let tab, model.profile.id == tab.profileID, !model.requiresUnlock, message.webView === tab.webView,
              let body = message.body as? [String: String], let id = body["documentID"], let kind = body["kind"], id.count < 80 else { return }
        frames[id] = message.frameInfo
        if message.frameInfo.isMainFrame {
            if mainDocument != id { mainDocument = id }
            if !translated && !running && !dismissed {
                sourceLanguage = Self.detect(sample: body["sample"] ?? "", hint: body["lang"] ?? "")
                let target = preferences.target.components(separatedBy: "-")[0]
                let excluded = preferences.excludedHosts.contains { BrowserURL.hostMatches(tab.webView?.url?.host ?? "", domain: $0) }
                offered = !sourceLanguage.isEmpty && sourceLanguage != target && !excluded && (preferences.suggest || preferences.automatic)
                if offered && preferences.automatic && model.current?.id == tab.id { translate() }
            }
        }
        if (kind == "changed" || kind == "ready") && translated && sessionPreferences?.dynamicContent == true {
            if running { pending = true } else { translate(continuing: true) }
        }
    }
    static func detect(sample: String, hint: String) -> String {
        guard sample.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 25 else { return "" }
        let recognizer = NLLanguageRecognizer(); recognizer.processString(String(sample.prefix(3500)))
        if let language = recognizer.dominantLanguage { return language.rawValue.components(separatedBy: "-")[0] }
        return hint.lowercased().components(separatedBy: "-")[0]
    }
    private func call(_ script: String, arguments: [String: Any] = [:], frame: WKFrameInfo?) async throws -> Any {
        guard let view = tab?.webView else { throw CancellationError() }
        return try await view.callAsyncJavaScript(script, arguments: arguments, in: frame, contentWorld: Self.world)
    }
    func translate(continuing: Bool = false) {
        guard !running, let model, let tab, !tab.isHome, !model.requiresUnlock, model.profile.id == tab.profileID else { return }
        if !continuing, translated { Task { await restore() }; return }
        let prefs = continuing ? sessionPreferences ?? preferences : preferences
        sessionPreferences = prefs
        let provider = model.data.settings.aiProviders?.first { $0.id == prefs.providerID }
        let secret = AISecretVault.read(profile: tab.profileID, provider: prefs.engine == .googleCloud ? "google-cloud" : provider?.id.uuidString ?? "")
        let ticket = epoch
        running = true; offered = true; error = nil
        work = Task { [weak self] in
            guard let self else { return }
            do {
                // didFinish recovery also supports windows created with an opener configuration.
                if frames.isEmpty {
                    _ = try await call(Self.script, frame: nil)
                    _ = try await call("return zeusTranslate.documentID", frame: nil)
                }
                var processedCharacters = 0
                repeat {
                    pending = false
                    for (documentID, frame) in frames {
                        try Task.checkCancellation(); guard ticket == epoch else { throw CancellationError() }
                        _ = try await call("zeusTranslate.start(language)", arguments: ["language": prefs.target], frame: frame)
                        while true {
                            let raw: Any
                            do { raw = try await call("return zeusTranslate.collect()", frame: frame) }
                            catch { if frame.isMainFrame { throw error } else { break } }
                            guard let value = raw as? [String: Any], value["documentID"] as? String == documentID, let array = value["segments"] as? [[String: String]], !array.isEmpty else { break }
                            let segments = array.compactMap { m -> TranslationSegment? in guard let id = m["id"], let text = m["text"] else { return nil }; return TranslationSegment(id: id, text: text) }
                            processedCharacters += segments.reduce(0) { $0 + $1.text.count }
                            guard processedCharacters < 500_000 else { throw TranslationFailure.message("توقفت الدفعة بعد نص طويل جدًا لتقليل الاستهلاك. اضغط متابعة لإكمال بقية الصفحة.") }
                            var results = segments.compactMap { s in cache[s.text].map { TranslationSegment(id: s.id, text: $0) } }
                            let missing = segments.filter { cache[$0.text] == nil }
                            if !missing.isEmpty {
                                let fresh = try await TextTranslationService.translate(missing, preferences: prefs, provider: provider, secret: secret, context: context)
                                try Task.checkCancellation(); guard ticket == epoch else { throw CancellationError() }
                                let originals = Dictionary(uniqueKeysWithValues: missing.map { ($0.id, $0.text) })
                                for value in fresh { if let text = originals[value.id], cache.count < 8000 { cache[text] = value.text } }; results += fresh
                            }
                            try Task.checkCancellation(); guard ticket == epoch else { throw CancellationError() }
                            let items = results.map { ["id": $0.id, "text": $0.text] }
                            let applied = try await call("return zeusTranslate.apply(items, expected)", arguments: ["items": items, "expected": documentID], frame: frame) as? Int ?? 0
                            guard applied > 0 else { break }; completed += applied; translated = true
                        }
                    }
                } while pending && prefs.dynamicContent
                if !translated { error = "لم تُعثر على نصوص قابلة للترجمة في الصفحة الحالية." }
            } catch is CancellationError { }
            catch { if ticket == epoch { self.error = error.localizedDescription } }
            if ticket == epoch { running = false; work = nil }
        }
    }
    func resume() { translate(continuing: true) }
    func restore() async {
        stop()
        for frame in frames.values { _ = try? await call("zeusTranslate.restore()", frame: frame) }
        translated = false; completed = 0; error = nil; offered = false; dismissed = true; cache.removeAll(); sessionPreferences = nil
    }
    func excludeSite() {
        guard let model, let host = tab?.webView?.url?.host else { return }
        var p = preferences; if !p.excludedHosts.contains(host) { p.excludedHosts.append(host) }; model.data.settings.translation = p; model.persist(); dismiss()
    }
}
