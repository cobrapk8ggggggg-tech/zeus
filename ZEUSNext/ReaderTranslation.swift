import Foundation
import CoreGraphics

@MainActor final class ReaderTranslation: ObservableObject {
    @Published var title: String?
    @Published var paragraphs: [String]?
    @Published var running = false
    @Published var completed = 0
    @Published var reused = 0
    @Published var error: String?
    @Published var storageNotice: String?
    @Published var suggested = false
    private var task: Task<Void, Never>?
    private var context = UUID()
    private var rectangles: [Int: CGRect] = [:]
    private var viewportHeight: CGFloat = 800
    private var results: [Int: String] = [:]
    private var cache: [String: String] = [:]
    private var cacheNamespace = ""
    private(set) var targetLanguage = "ar"
    private(set) var sourceRTL = false
    func observe(index: Int, rect: CGRect) { rectangles[index] = rect }
    func viewport(height: CGFloat) { viewportHeight = max(1, height) }
    func isTranslated(_ index: Int) -> Bool { results[index] != nil }
    func prepare(article: ReaderArticle, model: BrowserModel) {
        let p = model.data.settings.translation ?? TranslationPreferences()
        let language = PageTranslation.detect(sample: article.paragraphs.prefix(8).joined(separator: "\n"), hint: "")
        sourceRTL = TranslationPreferences.rtl(language)
        suggested = p.suggest && !language.isEmpty && language != p.target.components(separatedBy: "-")[0]
        if p.automatic && !language.isEmpty && language != p.target.components(separatedBy: "-")[0] { translate(article: article, model: model) }
    }
    func cancel() { task?.cancel(); task = nil; running = false; let old = context; context = UUID(); Task { await AIProviderService.shared.end(old) } }
    func restore() { cancel(); title = nil; paragraphs = nil; results.removeAll(); error = nil; completed = 0; reused = 0; suggested = false }
    func translate(article: ReaderArticle, model: BrowserModel) {
        guard !running else { return }; error = nil; running = true; suggested = false
        let prefs = model.data.settings.translation ?? TranslationPreferences(), owner = model.profile.id
        targetLanguage = prefs.target
        let provider = model.data.settings.aiProviders?.first { $0.id == prefs.providerID }
        let secret = AISecretVault.read(profile: owner, provider: prefs.secretKey(provider: provider))
        let namespace = TranslationMemory.namespace(page: article.sourceURL ?? model.current?.url ?? "reader:" + article.title, preferences: prefs, provider: provider)
        let folder: URL? = prefs.keepsTranslations && !model.profile.isPrivate ? model.profiles.folder(for: model.profile) : nil
        if namespace != cacheNamespace { cache.removeAll(); results.removeAll(); cacheNamespace = namespace }
        let id = context
        task = Task {
            do {
                await Task.yield() // allow first layout to publish its visible paragraphs
                let originals = [article.title] + article.paragraphs
                var processed = 0
                while results.count < originals.count {
                    try Task.checkCancellation(); guard owner == model.profile.id, !model.requiresUnlock, id == context else { throw CancellationError() }
                    let candidates = originals.indices.filter { results[$0] == nil }.sorted { priority($0) < priority($1) }
                    guard let first = candidates.first else { break }
                    let visible = priority(first).0 == 0
                    let limit = visible ? 24000 : 10000
                    var batch: [TranslationSegment] = [], count = 0
                    for index in candidates {
                        if visible && priority(index).0 != 0 { break }
                        if !batch.isEmpty && (count + originals[index].count > limit || batch.count >= (visible ? 256 : 64)) { break }
                        batch.append(TranslationSegment(id: String(index), text: originals[index])); count += originals[index].count
                    }
                    processed += count
                    guard processed < 500_000 else { throw TranslationFailure.message("توقفت الجولة عند حد النص الطويل لتقليل الاستهلاك. يمكنك المتابعة.") }
                    if let folder { cache.merge(await TranslationMemory.shared.lookup(batch, namespace: namespace, folder: folder)) { _, saved in saved } }
                    try Task.checkCancellation()
                    reused += batch.filter { cache[$0.text] != nil }.count
                    var unique = Set<String>()
                    let missing = batch.filter { cache[$0.text] == nil && unique.insert($0.text).inserted }
                    if !missing.isEmpty {
                        let values = try await TextTranslationService.translate(missing, preferences: prefs, provider: provider, secret: secret, context: id)
                        try Task.checkCancellation(); guard owner == model.profile.id, !model.requiresUnlock, id == context else { throw CancellationError() }
                        let sources = Dictionary(uniqueKeysWithValues: missing.map { ($0.id, $0.text) }); var saved: [String: String] = [:]
                        for value in values { if let source = sources[value.id] { saved[source] = value.text; cache[source] = value.text } }
                        if let folder, !(await TranslationMemory.shared.save(saved, namespace: namespace, folder: folder)) { storageNotice = "تعذّر حفظ الترجمة على الجهاز. تحقق من المساحة المتاحة؛ الترجمة الحالية في الذاكرة." }
                    }
                    try Task.checkCancellation(); guard owner == model.profile.id, !model.requiresUnlock, id == context else { throw CancellationError() }
                    for item in batch { if let index = Int(item.id), let value = cache[item.text] { results[index] = value } }
                    completed = results.count; title = results[0]
                    paragraphs = article.paragraphs.enumerated().map { results[$0.offset + 1] ?? $0.element }
                    await Task.yield()
                }
            } catch is CancellationError { } catch { if id == context { self.error = error.localizedDescription } }
            if id == context { running = false }
        }
    }
    private func priority(_ index: Int) -> (Int, CGFloat, Int) {
        guard let rect = rectangles[index] else { return (index < 6 ? 0 : 2, CGFloat(index), index) }
        let distance = max(-rect.maxY, rect.minY - viewportHeight, 0)
        return (rect.maxY > 0 && rect.minY < viewportHeight ? 0 : distance < viewportHeight * 2 ? 1 : 2, distance, index)
    }
}
