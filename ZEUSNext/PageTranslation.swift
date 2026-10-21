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
    private struct FrameUnavailable: Error {}
    var observedFrameCount: Int { frames.count }
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
    @Published var storageNotice: String?
    @Published var reused = 0
    private var cacheNamespace = ""
    private var frames: [String: WKFrameInfo] = [:]
    private var mainDocument = ""
    private var epoch = UUID()
    private var context = UUID()
    private var work: Task<Void, Never>?
    private var cache: [String: String] = [:]
    private var pending = false
    private var sessionPreferences: TranslationPreferences?
    private var dismissed = false
    private var autoAttempted = false
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
        stop(); frames.removeAll(); mainDocument = ""; sourceLanguage = ""; offered = false; translated = false; completed = 0; error = nil; cache.removeAll(); dismissed = false; autoAttempted = false; sessionPreferences = nil; reused = 0; storageNotice = nil; cacheNamespace = ""
    }
    func stop() { epoch = UUID(); work?.cancel(); work = nil; running = false; pending = false; let old = context; context = UUID(); Task { await AIProviderService.shared.end(old) } }
    func pause() { stop(); error = "أُوقفت الترجمة. يمكنك المتابعة أو عرض الأصل." }
    func dismiss() { offered = false; dismissed = true }
    func becameVisible() { if offered && !translated && !autoAttempted && preferences.automatic { translate() } }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let model, let tab, model.profile.id == tab.profileID, !model.requiresUnlock, message.webView === tab.webView,
              let body = message.body as? [String: String], let id = body["documentID"], let kind = body["kind"], id.count < 80 else { return }
        if frames.count >= 64, frames[id] == nil, let old = frames.keys.first(where: { $0 != mainDocument }) { frames.removeValue(forKey: old) }
        frames[id] = message.frameInfo
        if message.frameInfo.isMainFrame {
            if mainDocument != id { mainDocument = id }
            if !translated && !running && !dismissed {
                sourceLanguage = Self.detect(sample: body["sample"] ?? "", hint: body["lang"] ?? "")
                let target = preferences.target.components(separatedBy: "-")[0]
                let excluded = preferences.excludedHosts.contains { BrowserURL.hostMatches(tab.webView?.url?.host ?? "", domain: $0) }
                offered = !sourceLanguage.isEmpty && sourceLanguage != target && !excluded && (preferences.suggest || preferences.automatic)
                if offered && preferences.automatic && !autoAttempted && model.current?.id == tab.id { translate() }
            }
        }
        if (kind == "viewport" || ((kind == "changed" || kind == "ready") && sessionPreferences?.dynamicContent == true)) && translated && error == nil {
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
        // A cached main-frame WKFrameInfo can be invalidated by WebKit. nil always
        // addresses the live main frame; documentID still gates every application.
        let target = frame?.isMainFrame == true ? nil : frame
        do { return try await view.callAsyncJavaScript(script, arguments: arguments, in: target, contentWorld: Self.world) ?? NSNull() }
        catch {
            // Frames owned by ads/widgets routinely disappear during an await.
            // Only WebKit execution errors are isolated here; provider/HTTP failures
            // remain visible and are never swallowed as an iframe failure.
            if let frame, !frame.isMainFrame, (error as NSError).domain == WKError.errorDomain { throw FrameUnavailable() }
            throw error
        }
    }
    func translate(continuing: Bool = false) {
        guard !running, let model, let tab, !tab.isHome, !model.requiresUnlock, model.profile.id == tab.profileID else { return }
        if !continuing, translated { offered = true; return }
        let prefs = continuing ? sessionPreferences ?? preferences : preferences
        sessionPreferences = prefs
        let provider = model.data.settings.aiProviders?.first { $0.id == prefs.providerID }
        let secret = AISecretVault.read(profile: tab.profileID, provider: prefs.engine == .googleCloud ? "google-cloud" : provider?.id.uuidString ?? "")
        let namespace = TranslationMemory.namespace(page: tab.webView?.url?.absoluteString ?? tab.url, preferences: prefs, provider: provider)
        let folder: URL? = prefs.keepsTranslations && !model.profile.isPrivate ? model.profiles.folder(for: model.profile) : nil
        if cacheNamespace != namespace { cache.removeAll(); cacheNamespace = namespace }
        let ticket = epoch
        running = true; autoAttempted = true; if !continuing { offered = true }; error = nil
        work = Task { [weak self] in
            guard let self else { return }
            do {
                // Resolve the current document directly, rather than executing
                // through a WKFrameInfo retained from an earlier ready message.
                var liveID = try await call("return globalThis.zeusTranslate?.documentID ?? ''", frame: nil) as? String ?? ""
                if liveID.isEmpty {
                    _ = try await call(Self.script, frame: nil)
                    liveID = try await call("return zeusTranslate.documentID", frame: nil) as? String ?? ""
                }
                guard !liveID.isEmpty, ticket == epoch else { throw CancellationError() }
                var processedCharacters = 0
                repeat {
                    pending = false
                    var foundWork = false
                    // The article is translated first, independent of ad-frame order.
                    let children = frames.filter { !$0.value.isMainFrame }.sorted { $0.key < $1.key }.map { ($0.key, Optional($0.value)) }
                    let targets: [(String, WKFrameInfo?)] = [(liveID, nil)] + children
                    for (documentID, frame) in targets {
                        try Task.checkCancellation(); guard ticket == epoch else { throw CancellationError() }
                        do {
                            // start, collect AND apply must all tolerate a removed frame.
                            _ = try await call("zeusTranslate.start(language)", arguments: ["language": prefs.target], frame: frame)
                            do {
                                // Re-evaluate geometry after every batch. A scroll jump
                                // moves its visible text ahead of the remaining prefetch.
                                let raw = try await call("return zeusTranslate.collect(characters, count, true)", arguments: ["characters": prefs.engine == .googleWeb ? 12000 : prefs.engine == .googleCloud ? 5000 : 10000, "count": prefs.engine == .googleWeb ? 96 : 64], frame: frame)
                                guard let value = raw as? [String: Any], value["documentID"] as? String == documentID else { frames.removeValue(forKey: documentID); continue }
                                guard let array = value["segments"] as? [[String: String]], !array.isEmpty else { continue }
                                foundWork = true
                                let segments = array.compactMap { m -> TranslationSegment? in guard let id = m["id"], let text = m["text"] else { return nil }; return TranslationSegment(id: id, text: text) }
                                processedCharacters += segments.reduce(0) { $0 + $1.text.count }
                                guard processedCharacters < 500_000 else { throw TranslationFailure.message("توقفت الدفعة بعد نص طويل جدًا لتقليل الاستهلاك. اضغط متابعة لإكمال بقية الصفحة.") }
                                if let folder {
                                    let saved = await TranslationMemory.shared.lookup(segments, namespace: namespace, folder: folder)
                                    try Task.checkCancellation(); guard ticket == epoch else { throw CancellationError() }
                                    cache.merge(saved) { _, stored in stored }
                                }
                                var results = segments.compactMap { s in self.cache[s.text].map { TranslationSegment(id: s.id, text: $0) } }
                                reused += results.count
                                // Repeated headings/buttons in the same batch are billed once.
                                var unique = Set<String>()
                                let missing = segments.filter { self.cache[$0.text] == nil && unique.insert($0.text).inserted }
                                if !missing.isEmpty {
                                    let fresh = try await TextTranslationService.translate(missing, preferences: prefs, provider: provider, secret: secret, context: context)
                                    try Task.checkCancellation(); guard ticket == epoch else { throw CancellationError() }
                                    let originals = Dictionary(uniqueKeysWithValues: missing.map { ($0.id, $0.text) })
                                    var saved: [String: String] = [:]
                                    for value in fresh { if let text = originals[value.id] { saved[text] = value.text; cache[text] = value.text } }
                                    if let folder, !(await TranslationMemory.shared.save(saved, namespace: namespace, folder: folder)) { storageNotice = "تعذّر حفظ الترجمة على الجهاز. قد تحتاج مساحة متاحة؛ ستبقى نتيجة هذه الجلسة في الذاكرة." }
                                    try Task.checkCancellation(); guard ticket == epoch else { throw CancellationError() }
                                    results = segments.compactMap { s in cache[s.text].map { TranslationSegment(id: s.id, text: $0) } }
                                }
                                try Task.checkCancellation(); guard ticket == epoch else { throw CancellationError() }
                                let items = results.map { ["id": $0.id, "text": $0.text] }
                                let applied = try await call("return zeusTranslate.apply(items, expected)", arguments: ["items": items, "expected": documentID], frame: frame) as? Int ?? 0
                                if applied > 0 { completed += applied; translated = true }
                            }
                        } catch is FrameUnavailable {
                            frames.removeValue(forKey: documentID)
                            continue
                        }
                    }
                    // Yield between background batches so UI gestures remain responsive.
                    if foundWork { pending = true; await Task.yield() }
                } while pending
                if !translated { error = "لم تُعثر على نصوص قابلة للترجمة في الصفحة الحالية." }
            } catch is CancellationError { }
            catch { if ticket == epoch { self.error = error.localizedDescription } }
            if ticket == epoch { running = false; work = nil }
        }
    }
    func clearSessionCache() { stop(); cache.removeAll(); cacheNamespace = ""; reused = 0 }
    func resume() { translate(continuing: true) }
    func restore() async {
        stop()
        _ = try? await call("globalThis.zeusTranslate?.restore()", frame: nil)
        for frame in frames.values where !frame.isMainFrame { _ = try? await call("globalThis.zeusTranslate?.restore()", frame: frame) }
        translated = false; completed = 0; error = nil; offered = false; dismissed = true; cache.removeAll(); sessionPreferences = nil
    }
    func excludeSite() {
        guard let model, let host = tab?.webView?.url?.host else { return }
        var p = preferences; if !p.excludedHosts.contains(host) { p.excludedHosts.append(host) }; model.data.settings.translation = p; model.persist(); dismiss()
    }
}
